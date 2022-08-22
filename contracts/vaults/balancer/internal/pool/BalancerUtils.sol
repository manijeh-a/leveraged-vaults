// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {IBalancerVault, IAsset} from "../../../../../interfaces/balancer/IBalancerVault.sol";
import {PoolContext, PoolParams} from "../../BalancerVaultTypes.sol";
import {IPriceOracle} from "../../../../../interfaces/balancer/IPriceOracle.sol";
import {Constants} from "../../../../global/Constants.sol";
import {Deployments} from "../../../../global/Deployments.sol";
import {BalancerConstants} from "../BalancerConstants.sol";
import {TokenUtils, IERC20} from "../../../../utils/TokenUtils.sol";

library BalancerUtils {
    using TokenUtils for IERC20;

    /// @notice Special handling for ETH because UNDERLYING_TOKEN == address(0)
    /// and Balancer uses WETH
    function getTokenAddress(address token) internal pure returns (address) {
        return token == Deployments.ETH_ADDRESS ? address(Deployments.WETH) : address(token);
    }

    function _getTimeWeightedOraclePrice(
        address pool,
        IPriceOracle.Variable variable,
        uint256 secs
    ) internal view returns (uint256) {
        IPriceOracle.OracleAverageQuery[]
            memory queries = new IPriceOracle.OracleAverageQuery[](1);

        queries[0].variable = variable;
        queries[0].secs = secs;
        queries[0].ago = 0; // now

        // Gets the balancer time weighted average price denominated in the first token
        return IPriceOracle(pool).getTimeWeightedAverage(queries)[0];
    }

    /// @notice Normalizes balances to 1e18 (used by Balancer price oracle functions)
    function _normalizeBalances(
        uint256 primaryBalance,
        uint8 primaryDecimals,
        uint256 secondaryBalance,
        uint8 secondaryDecimals
    ) internal pure returns (uint256 normalizedPrimary, uint256 normalizedSecondary) {
        if (primaryDecimals == 18) {
            normalizedPrimary = primaryBalance;
        } else {
            uint256 decimalAdjust;
            unchecked { 
                decimalAdjust = 10**(18 - primaryDecimals);
            }
            normalizedPrimary = primaryBalance * decimalAdjust;
        }

        if (secondaryDecimals == 18) {
            normalizedSecondary = secondaryBalance;
        } else {
            uint256 decimalAdjust;
            unchecked { 
                decimalAdjust = 10**(18 - secondaryDecimals);
            }
            normalizedSecondary = secondaryBalance * decimalAdjust;
        }
    }

    /// @notice Joins a balancer pool using exact tokens in
    function _joinPoolExactTokensIn(
        PoolContext memory context,
        PoolParams memory params,
        uint256 minBPT
    ) internal returns (uint256 bptAmount) {
        bptAmount = IERC20(address(context.pool)).balanceOf(address(this));
        Deployments.BALANCER_VAULT.joinPool{value: params.msgValue}(
            context.poolId,
            address(this),
            address(this),
            IBalancerVault.JoinPoolRequest(
                params.assets,
                params.amounts,
                abi.encode(
                    IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                    params.amounts,
                    minBPT // Apply minBPT to prevent front running
                ),
                false // Don't use internal balances
            )
        );
        bptAmount = IERC20(address(context.pool)).balanceOf(address(this)) - bptAmount;
    }

    /// @notice Exits a balancer pool using exact BPT in
    function _exitPoolExactBPTIn(
        PoolContext memory context,
        PoolParams memory params,
        uint256 bptExitAmount
    ) internal returns (uint256[] memory exitBalances) {
        exitBalances = new uint256[](params.assets.length);

        // @audit cache length and iter
        for (uint256 i; i < params.assets.length; i++) {
            exitBalances[i] = TokenUtils.tokenBalance(address(params.assets[i]));
        }

        Deployments.BALANCER_VAULT.exitPool(
            context.poolId,
            address(this),
            payable(address(this)), // Vault will receive the underlying assets
            IBalancerVault.ExitPoolRequest(
                params.assets,
                params.amounts,
                abi.encode(
                    IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT,
                    bptExitAmount
                ),
                false // Don't use internal balances
            )
        );

        // @audit cache length and iter
        for (uint256 i; i < params.assets.length; i++) {
            exitBalances[i] = TokenUtils.tokenBalance(address(params.assets[i])) - exitBalances[i];
        }
    }

    function _swapGivenIn(
        bytes32 poolId, 
        address tokenIn, 
        address tokenOut, 
        uint256 amountIn,
        uint256 limit
    ) internal returns (uint256 amountOut) {
        amountOut = IERC20(tokenOut).balanceOf(address(this));
        Deployments.BALANCER_VAULT.swap({
            singleSwap: IBalancerVault.SingleSwap({
                poolId: poolId,
                kind: IBalancerVault.SwapKind.GIVEN_IN,
                assetIn: IAsset(tokenIn),
                assetOut: IAsset(tokenOut),
                amount: amountIn,
                userData: new bytes(0)
            }),
            funds: IBalancerVault.FundManagement({
                sender: address(this),
                fromInternalBalance: false,
                recipient: payable(address(this)),
                toInternalBalance: false
            }),
            limit: limit,
            deadline: block.timestamp
        });
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - amountOut;
    }
}
