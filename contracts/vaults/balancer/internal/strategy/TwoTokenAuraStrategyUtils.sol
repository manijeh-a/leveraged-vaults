// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.15;

import {
    PoolParams,
    DepositParams,
    SecondaryTradeParams,
    DepositTradeParams,
    RedeemParams,
    TwoTokenPoolContext,
    AuraStakingContext,
    StrategyContext,
    StrategyVaultSettings,
    StrategyVaultState,
    OracleContext
} from "../../BalancerVaultTypes.sol";
import {SafeInt256} from "../../../../global/SafeInt256.sol";
import {Constants} from "../../../../global/Constants.sol";
import {NotionalUtils} from "../../../../utils/NotionalUtils.sol";
import {TokenUtils, IERC20} from "../../../../utils/TokenUtils.sol";
import {TradeHandler} from "../../../../trading/TradeHandler.sol";
import {AuraStakingUtils} from "../staking/AuraStakingUtils.sol";
import {VaultUtils} from "../VaultUtils.sol";
import {SettlementUtils} from "../settlement/SettlementUtils.sol";
import {StrategyUtils} from "../strategy/StrategyUtils.sol";
import {TwoTokenPoolUtils} from "../pool/TwoTokenPoolUtils.sol";
import {BalancerUtils} from "../pool/BalancerUtils.sol";
import {ITradingModule, Trade} from "../../../../../interfaces/trading/ITradingModule.sol";

library TwoTokenAuraStrategyUtils {
    using TradeHandler for Trade;
    using TokenUtils for IERC20;
    using SafeInt256 for uint256;
    using StrategyUtils for StrategyContext;
    using TwoTokenAuraStrategyUtils for StrategyContext;
    using TwoTokenPoolUtils for TwoTokenPoolContext;
    using AuraStakingUtils for AuraStakingContext;
    using VaultUtils for StrategyVaultSettings;
    using VaultUtils for StrategyVaultState;

    /// @notice Trade primary currency for secondary if the trade is specified
    function _tradePrimaryForSecondary(
        StrategyContext memory strategyContext,
        TwoTokenPoolContext memory poolContext,
        bytes memory data
    ) private returns (uint256 primarySold, uint256 secondaryBought) {
        (DepositTradeParams memory params) = abi.decode(data, (DepositTradeParams));

        // stETH generally has deeper liquidity than wstETH, setting wrapAfterTrading
        // lets the contract trade for stETH instead of wstETH
        address buyToken = poolContext.secondaryToken;
        if (params.tradeUnwrapped && poolContext.secondaryToken == address(Constants.WRAPPED_STETH)) {
            buyToken = Constants.WRAPPED_STETH.stETH();
        }

        Trade memory trade = Trade(
            params.tradeType,
            poolContext.primaryToken,
            buyToken,
            params.tradeAmount,
            0,
            block.timestamp, // deadline
            params.exchangeData
        );

        (primarySold, secondaryBought) = 
            trade._executeTradeWithDynamicSlippage(params.dexId, strategyContext.tradingModule, params.oracleSlippagePercent);

        if (
            params.tradeUnwrapped && 
            poolContext.secondaryToken == address(Constants.WRAPPED_STETH) && 
            secondaryBought > 0
        ) {
            IERC20(buyToken).checkApprove(address(Constants.WRAPPED_STETH), secondaryBought);
            uint256 wrappedAmount = Constants.WRAPPED_STETH.balanceOf(address(this));
            /// @notice the amount returned by wrap is not always accurate for some reason
            Constants.WRAPPED_STETH.wrap(secondaryBought);
            secondaryBought = Constants.WRAPPED_STETH.balanceOf(address(this)) - wrappedAmount;
        }
    }

    function _deposit(
        StrategyContext memory strategyContext,
        AuraStakingContext memory stakingContext,
        TwoTokenPoolContext memory poolContext,
        uint256 deposit,
        DepositParams memory params
    ) internal returns (uint256 strategyTokensMinted) {
        uint256 secondaryAmount;
        if (params.tradeData.length != 0) {
            (uint256 primarySold, uint256 secondaryBought) = _tradePrimaryForSecondary({
                strategyContext: strategyContext,
                poolContext: poolContext,
                data: params.tradeData
            });
            deposit -= primarySold;
            secondaryAmount = secondaryBought;
        }

        uint256 bptMinted = strategyContext._joinPoolAndStake({
            stakingContext: stakingContext,
            poolContext: poolContext,
            primaryAmount: deposit,
            secondaryAmount: secondaryAmount,
            minBPT: params.minBPT
        });

        strategyTokensMinted = strategyContext._convertBPTClaimToStrategyTokens(bptMinted);
        require(strategyTokensMinted <= type(uint80).max); /// @dev strategyTokensMinted overflow

        // Update global supply count
        strategyContext.vaultState.totalStrategyTokenGlobal += uint80(strategyTokensMinted);
        strategyContext.vaultState._setStrategyVaultState(); 
    }

    function _redeem(
        StrategyContext memory strategyContext,
        AuraStakingContext memory stakingContext,
        TwoTokenPoolContext memory poolContext,
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        RedeemParams memory params
    ) internal returns (uint256 finalPrimaryBalance) {
        uint256 bptClaim = strategyContext._convertStrategyTokensToBPTClaim(strategyTokens);

        if (bptClaim == 0) return 0;

        // Underlying token balances from exiting the pool
        (uint256 primaryBalance, uint256 secondaryBalance)
            = TwoTokenAuraStrategyUtils._unstakeAndExitPoolExactBPTIn(
                stakingContext, poolContext, bptClaim, params.minPrimary, params.minSecondary
            );
            
        if (secondaryBalance > 0) {
            // If there is no secondary debt, we still need to sell the secondary balance
            // back to the primary token here.
            (SecondaryTradeParams memory tradeParams) = abi.decode(
                params.secondaryTradeParams, (SecondaryTradeParams)
            );
            uint256 primaryPurchased = StrategyUtils._sellSecondaryBalance({
                params: tradeParams,
                tradingModule: strategyContext.tradingModule,
                primaryToken: poolContext.primaryToken,
                secondaryToken: poolContext.secondaryToken,
                secondaryBalance: secondaryBalance
            });

            finalPrimaryBalance = primaryBalance + primaryPurchased;
        }

        // Update global strategy token balance
        // This only needs to be updated for normal redemption
        // and emergency settlement. For normal and post-maturity settlement
        // scenarios (account == address(this) && data.length == 32), we
        // update totalStrategyTokenGlobal before this function is called.
        strategyContext.vaultState.totalStrategyTokenGlobal -= uint80(strategyTokens);
        strategyContext.vaultState._setStrategyVaultState(); 
    }

    function _joinPoolAndStake(
        StrategyContext memory strategyContext,
        AuraStakingContext memory stakingContext,
        TwoTokenPoolContext memory poolContext,
        uint256 primaryAmount,
        uint256 secondaryAmount,
        uint256 minBPT
    ) internal returns (uint256 bptMinted) {
        // prettier-ignore
        PoolParams memory poolParams = poolContext._getPoolParams( 
            primaryAmount, 
            secondaryAmount,
            true // isJoin
        );

        // Join the balancer pool and stake the tokens for boosting
        bptMinted = stakingContext._joinPoolAndStake({
            poolContext: poolContext.basePool,
            poolParams: poolParams,
            totalBPTHeld: strategyContext.totalBPTHeld,
            bptThreshold: strategyContext.vaultSettings._bptThreshold(
                poolContext.basePool.pool.totalSupply()
            ),
            minBPT: minBPT
        });
    }

    function _unstakeAndExitPoolExactBPTIn(
        AuraStakingContext memory stakingContext,
        TwoTokenPoolContext memory poolContext,
        uint256 bptClaim,
        uint256 minPrimary,
        uint256 minSecondary
    ) internal returns (uint256 primaryBalance, uint256 secondaryBalance) {
        uint256[] memory exitBalances = AuraStakingUtils._unstakeAndExitPoolExactBPTIn({
            stakingContext: stakingContext, 
            poolContext: poolContext.basePool,
            poolParams: poolContext._getPoolParams(minPrimary, minSecondary, false), // isJoin = false
            bptExitAmount: bptClaim
        });

        (primaryBalance, secondaryBalance) 
            = (exitBalances[poolContext.primaryIndex], exitBalances[poolContext.secondaryIndex]);
    }

    function _convertStrategyToUnderlying(
        StrategyContext memory strategyContext,
        OracleContext memory oracleContext,
        TwoTokenPoolContext memory poolContext,
        uint256 strategyTokenAmount
    ) internal view returns (int256 underlyingValue) {
        
        uint256 bptClaim 
            = strategyContext._convertStrategyTokensToBPTClaim(strategyTokenAmount);

        underlyingValue 
            = poolContext._getTimeWeightedPrimaryBalance(oracleContext, bptClaim).toInt();
    }
}
