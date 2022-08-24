// SPDX-License-Identifier: GPL-3.0-only
pragma solidity =0.8.15;

library BalancerConstants {
    uint256 internal constant BALANCER_PRECISION = 1e18;
    uint256 internal constant BALANCER_PRECISION_SQUARED = 1e36;
    uint256 internal constant BALANCER_ORACLE_WEIGHT_PRECISION = 1e8;
    uint32 internal constant SLIPPAGE_LIMIT_PRECISION = 1e8;

    /// @notice Precision for all percentages used by the vault
    /// 1e4 = 100% (i.e. maxBalancerPoolShare)
    uint16 internal constant VAULT_PERCENT_BASIS = 1e4;
    /// @notice Max slippage for boosted pools (5%)
    uint256 internal constant MAX_BOOSTED_POOL_SLIPPAGE_PERCENT = 9500;
    /// @notice Buffer percentage between the desired share of the Balancer pool
    /// and the maximum share of the pool allowed by maxBalancerPoolShare 1e4 = 100%, 8e3 = 80%
    uint16 internal constant BALANCER_POOL_SHARE_BUFFER = 8e3;
    /// @notice Max settlement cool down period allowed (1 day)
    uint16 internal constant MAX_SETTLEMENT_COOLDOWN_IN_MINUTES = 24 * 60;
    /// @notice Slippage limit for reward trades (5e6 = 5%)
    uint32 internal constant MAX_REWARD_TRADE_SLIPPAGE_PERCENT = 5e6;
    /// @notice Lower limit used to validate calculated pair price against oracle price (+5%)
    uint256 internal constant META_STABLE_PAIR_PRICE_UPPER_LIMIT = 10500;
    /// @notice Upper limit used to validate calculated pair price against oracle price (-5%)
    uint256 internal constant META_STABLE_PAIR_PRICE_LOWER_LIMIT = 9500;
    /// @notice Lower limit used to validate spot price against oracle price (+5%)
    uint256 internal constant META_STABLE_SPOT_PRICE_UPPER_LIMIT = 10500;
    /// @notice Upper limit used to validate spot price against oracle price (-5%)
    uint256 internal constant META_STABLE_SPOT_PRICE_LOWER_LIMIT = 9500;
    /// @notice Upper limit used to validate stable spot price against oracle price (+0.1%)
    uint256 internal constant STABLE_SPOT_PRICE_UPPER_LIMIT = 10010;
    /// @notice Lower limit used to validate stable spot price against oracle price (-0.1%)
    uint256 internal constant STABLE_SPOT_PRICE_LOWER_LIMIT = 9990;
}
