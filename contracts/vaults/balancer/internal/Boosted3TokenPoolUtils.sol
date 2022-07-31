// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.15;

import {
    ThreeTokenPoolContext, 
    TwoTokenPoolContext, 
    BoostedOracleContext, 
    PoolParams
} from "../BalancerVaultTypes.sol";
import {SafeInt256} from "../../../global/SafeInt256.sol";
import {Constants} from "../../../global/Constants.sol";
import {Errors} from "../../../global/Errors.sol";
import {IAsset} from "../../../../interfaces/balancer/IBalancerVault.sol";
import {BalancerUtils} from "./BalancerUtils.sol";
import {ITradingModule} from "../../../../interfaces/trading/ITradingModule.sol";
import {IBoostedPool} from "../../../../interfaces/balancer/IBalancerPool.sol";
import {TokenUtils, IERC20} from "../../../utils/TokenUtils.sol";
import {TwoTokenPoolUtils} from "./TwoTokenPoolUtils.sol";
import {StableMath} from "./StableMath.sol";

library Boosted3TokenPoolUtils {
    using SafeInt256 for uint256;
    using SafeInt256 for int256;
    using TokenUtils for IERC20;
    using TwoTokenPoolUtils for TwoTokenPoolContext;

    // Preminted BPT is sometimes called Phantom BPT, as the preminted BPT (which is deposited in the Vault as balance of
    // the Pool) doesn't belong to any entity until transferred out of the Pool. The Pool's arithmetic behaves as if it
    // didn't exist, and the BPT total supply is not a useful value: we rely on the 'virtual supply' (how much BPT is
    // actually owned by some entity) instead.
    uint256 private constant _MAX_TOKEN_BALANCE = 2**(112) - 1;

    function _validateSpotPrice(
        ITradingModule tradingModule,
        address tokenIn,
        uint8 tokenIndexIn,
        address tokenOut,
        uint8 tokenIndexOut,
        uint256[] memory balances,
        uint256 ampParam,
        uint256 invariant
    ) private view {
        (int256 answer, int256 decimals) = tradingModule.getOraclePrice(tokenOut, tokenIn);
        require(decimals == BalancerUtils.BALANCER_PRECISION.toInt());
        
        uint256 spotPrice = _getSpotPrice({
            ampParam: ampParam,
            invariant: invariant,
            balances: balances, 
            tokenIndexIn: tokenIndexIn, // Primary index
            tokenIndexOut: tokenIndexOut // Secondary index
        });

        uint256 oraclePrice = answer.toUint();
        uint256 lowerLimit = (oraclePrice * Constants.STABLE_SPOT_PRICE_LOWER_LIMIT) / 
            Constants.VAULT_PERCENT_BASIS;
        uint256 upperLimit = (oraclePrice * Constants.STABLE_SPOT_PRICE_UPPER_LIMIT) / 
            Constants.VAULT_PERCENT_BASIS;

        // Check spot price against oracle price to make sure it hasn't been manipulated
        if (spotPrice < lowerLimit || upperLimit < spotPrice) {
            revert Errors.InvalidSpotPrice(oraclePrice, spotPrice);
        }
    }

    function _validateTokenPrices(
        ThreeTokenPoolContext memory poolContext, 
        ITradingModule tradingModule,
        uint256[] memory balances,
        uint256 ampParam,
        uint256 invariant
    ) private view {
        address primaryUnderlying = IBoostedPool(address(poolContext.basePool.primaryToken)).getMainToken();
        address secondaryUnderlying = IBoostedPool(address(poolContext.basePool.secondaryToken)).getMainToken();
        address tertiaryUnderlying = IBoostedPool(address(poolContext.tertiaryToken)).getMainToken();

        _validateSpotPrice({
            tradingModule: tradingModule,
            tokenIn: primaryUnderlying,
            tokenIndexIn: 0, // primary index
            tokenOut: secondaryUnderlying,
            tokenIndexOut: 1, // secondary index
            balances: balances,
            ampParam: ampParam,
            invariant: invariant
        });

        _validateSpotPrice({
            tradingModule: tradingModule,
            tokenIn: primaryUnderlying,
            tokenIndexIn: 0, // primary index
            tokenOut: tertiaryUnderlying,
            tokenIndexOut: 2, // secondary index
            balances: balances,
            ampParam: ampParam,
            invariant: invariant
        });
    }

    function _getSpotPrice(
        uint256 ampParam,
        uint256 invariant,
        uint256[] memory balances, 
        uint8 tokenIndexIn, 
        uint8 tokenIndexOut
    ) private pure returns (uint256 spotPrice) {
        // Trade 1 unit of tokenIn for tokenOut to get the spot price
        uint256 amountIn = BalancerUtils.BALANCER_PRECISION;
        uint256 amountOut = StableMath._calcOutGivenIn({
            amplificationParameter: ampParam,
            balances: balances,
            tokenIndexIn: tokenIndexIn,
            tokenIndexOut: tokenIndexOut,
            tokenAmountIn: amountIn,
            invariant: invariant
        });
        spotPrice = amountOut;
    }

    /// @notice Gets the time-weighted primary token balance for a given bptAmount
    /// @dev Boosted pool can't use the Balancer oracle, using Chainlink instead
    /// @param poolContext pool context variables
    /// @param oracleContext oracle context variables
    /// @param bptAmount amount of balancer pool lp tokens
    /// @return primaryAmount primary token balance
    function _getTimeWeightedPrimaryBalance(
        ThreeTokenPoolContext memory poolContext,
        BoostedOracleContext memory oracleContext,
        ITradingModule tradingModule,
        uint256 bptAmount
    ) internal view returns (uint256 primaryAmount) {
        (uint256 virtualSupply, uint256[] memory balances) = 
            _getVirtualSupplyAndBalances(poolContext, oracleContext);

        // Get the current and new invariants. Since we need a bigger new invariant, we round the current one up.
        uint256 invariant = StableMath._calculateInvariant(
            oracleContext.ampParam, balances, true // roundUp = true
        );

        // validate spot prices against oracle prices
        _validateTokenPrices({
            poolContext: poolContext,
            tradingModule: tradingModule,
            balances: balances,
            ampParam: oracleContext.ampParam,
            invariant: invariant
        });

        // NOTE: For Boosted 3 token pools, the LP token (BPT) is just another
        // token in the pool. So, we use _calcTokenOutGivenExactBptIn
        // to value it in terms of the primary currency
        // Use virtual total supply and zero swap fees for joins
        primaryAmount = StableMath._calcTokenOutGivenExactBptIn({
            amp: oracleContext.ampParam, 
            balances: balances, 
            tokenIndex: poolContext.basePool.primaryIndex, 
            bptAmountIn: bptAmount, 
            bptTotalSupply: virtualSupply, 
            swapFeePercentage: 0, 
            invariant: invariant
        });
    }

    function _getVirtualSupplyAndBalances(
        ThreeTokenPoolContext memory poolContext, 
        BoostedOracleContext memory oracleContext
    ) internal view returns (uint256 virtualSupply, uint256[] memory amountsWithoutBpt) {
        // The initial amount of BPT pre-minted is _MAX_TOKEN_BALANCE and it goes entirely to the pool balance in the
        // vault. So the virtualSupply (the actual supply in circulation) is defined as:
        // virtualSupply = totalSupply() - (_balances[_bptIndex] - _dueProtocolFeeBptAmount)
        //
        // However, since this Pool never mints or burns BPT outside of the initial supply (except in the event of an
        // emergency pause), we can simply use `_MAX_TOKEN_BALANCE` instead of `totalSupply()` and save
        // gas.
        virtualSupply = _MAX_TOKEN_BALANCE - oracleContext.bptBalance + oracleContext.dueProtocolFeeBptAmount;

        amountsWithoutBpt = new uint256[](3);
        amountsWithoutBpt[0] = poolContext.basePool.primaryBalance;
        amountsWithoutBpt[1] = poolContext.basePool.secondaryBalance;
        amountsWithoutBpt[2] = poolContext.tertiaryBalance;
    }

    function _approveBalancerTokens(ThreeTokenPoolContext memory poolContext, address bptSpender) internal {
        poolContext.basePool._approveBalancerTokens(bptSpender);
        IERC20(poolContext.tertiaryToken).checkApprove(address(BalancerUtils.BALANCER_VAULT), type(uint256).max);

        // For boosted pools, the tokens inside pool context are AaveLinearPool tokens.
        // So, we need to approve the _underlyingToken (primary borrow currency) for trading.
        IBoostedPool underlyingPool = IBoostedPool(poolContext.basePool.primaryToken);
        address primaryUnderlyingAddress = BalancerUtils.getTokenAddress(underlyingPool.getMainToken());
        IERC20(primaryUnderlyingAddress).checkApprove(address(BalancerUtils.BALANCER_VAULT), type(uint256).max);
    }
}
