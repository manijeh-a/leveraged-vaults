// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.17;

import {BalancerConstants} from "./balancer/internal/BalancerConstants.sol";
import {Errors} from "../global/Errors.sol";
import {TokenUtils} from "../utils/TokenUtils.sol";
import {
    DepositParams,
    RedeemParams,
    AuraVaultDeploymentParams,
    InitParams,
    ReinvestRewardParams,
    PoolContext,
    TwoTokenPoolContext,
    StableOracleContext,
    MetaStable2TokenAuraStrategyContext
} from "./balancer/BalancerVaultTypes.sol";
import {
    StrategyContext,
    StrategyVaultSettings,
    StrategyVaultState
} from "./common/VaultTypes.sol";
import {BalancerStrategyBase} from "./balancer/BalancerStrategyBase.sol";
import {MetaStable2TokenVaultMixin} from "./balancer/mixins/MetaStable2TokenVaultMixin.sol";
import {AuraStakingMixin} from "./balancer/mixins/AuraStakingMixin.sol";
import {VaultStorage} from "./common/VaultStorage.sol";
import {StrategyUtils} from "./common/internal/strategy/StrategyUtils.sol";
import {SettlementUtils} from "./balancer/internal/settlement/SettlementUtils.sol";
import {TwoTokenPoolUtils} from "./balancer/internal/pool/TwoTokenPoolUtils.sol";
import {Stable2TokenOracleMath} from "./balancer/internal/math/Stable2TokenOracleMath.sol";
import {MetaStable2TokenAuraHelper} from "./balancer/external/MetaStable2TokenAuraHelper.sol";
import {NotionalProxy} from "../../interfaces/notional/NotionalProxy.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {IAuraRewardPool} from "../../interfaces/aura/IAuraRewardPool.sol";

contract MetaStable2TokenAuraVault is MetaStable2TokenVaultMixin {
    using VaultStorage for StrategyVaultSettings;
    using VaultStorage for StrategyVaultState;
    using StrategyUtils for StrategyContext;
    using SettlementUtils for StrategyContext;
    using TwoTokenPoolUtils for TwoTokenPoolContext;
    using MetaStable2TokenAuraHelper for MetaStable2TokenAuraStrategyContext;
    using TokenUtils for IERC20;

    IAuraRewardPool internal immutable OLD_REWARD_POOL;

    event AuraPoolMigrated(address indexed oldPool, address indexed newPool, uint256 amount);
    
    constructor(
        NotionalProxy notional_, 
        AuraVaultDeploymentParams memory params,
        IAuraRewardPool oldRewardPool_) 
        MetaStable2TokenVaultMixin(notional_, params)
    {
        OLD_REWARD_POOL = oldRewardPool_;
    }

    function strategy() external override view returns (bytes4) {
        return bytes4(keccak256("MetaStable2TokenAura"));
    }

    function initialize(InitParams calldata params)
        external
        initializer
        onlyNotionalOwner
    {
        __INIT_VAULT(params.name, params.borrowCurrencyId);
        VaultStorage.setStrategyVaultSettings(params.settings);
        _twoTokenPoolContext()._approveBalancerTokens(address(_auraStakingContext().auraBooster));
    }

    function _depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) internal override returns (uint256 strategyTokensMinted) {
        strategyTokensMinted = _strategyContext().deposit(deposit, data);
    }

    function _redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal override returns (uint256 finalPrimaryBalance) {
        finalPrimaryBalance = _strategyContext().redeem(strategyTokens, data);
    }

    function convertStrategyToUnderlying(
        address account,
        uint256 strategyTokenAmount,
        uint256 maturity
    ) public view virtual override returns (int256 underlyingValue) {
        MetaStable2TokenAuraStrategyContext memory context = _strategyContext();
        underlyingValue = context.poolContext._convertStrategyToUnderlying({
            strategyContext: context.baseStrategy,
            oracleContext: context.oracleContext,
            strategyTokenAmount: strategyTokenAmount
        });
    }

    function settleVaultNormal(
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata data
    ) external onlyRole(NORMAL_SETTLEMENT_ROLE) {
        if (maturity <= block.timestamp) {
            revert Errors.PostMaturitySettlement();
        }
        if (block.timestamp < maturity - SETTLEMENT_PERIOD_IN_SECONDS) {
            revert Errors.NotInSettlementWindow();
        }
        MetaStable2TokenAuraStrategyContext memory context = _strategyContext();
        SettlementUtils._validateCoolDown(
            context.baseStrategy.vaultState.lastSettlementTimestamp,
            context.baseStrategy.vaultSettings.settlementCoolDownInMinutes
        );
        RedeemParams memory params = SettlementUtils._decodeParamsAndValidate(
            context.baseStrategy.vaultSettings.settlementSlippageLimitPercent,
            data
        );
        MetaStable2TokenAuraHelper.settleVault(
            context, maturity, strategyTokensToRedeem, params
        );
        context.baseStrategy.vaultState.lastSettlementTimestamp = uint32(block.timestamp);
        context.baseStrategy.vaultState.setStrategyVaultState();
    }

    function settleVaultPostMaturity(
        uint256 maturity,
        uint256 strategyTokensToRedeem,
        bytes calldata data
    ) external onlyRole(POST_MATURITY_SETTLEMENT_ROLE) {
        if (block.timestamp < maturity) {
            revert Errors.HasNotMatured();
        }
        MetaStable2TokenAuraStrategyContext memory context = _strategyContext();
        RedeemParams memory params = SettlementUtils._decodeParamsAndValidate(
            context.baseStrategy.vaultSettings.postMaturitySettlementSlippageLimitPercent,
            data
        );
        MetaStable2TokenAuraHelper.settleVault(
            context, maturity, strategyTokensToRedeem, params
        );
    }

    function settleVaultEmergency(uint256 maturity, bytes calldata data) 
        external onlyRole(EMERGENCY_SETTLEMENT_ROLE) {
        // No need for emergency settlement during the settlement window
        _revertInSettlementWindow(maturity);
        MetaStable2TokenAuraHelper.settleVaultEmergency(
            _strategyContext(), maturity, data
        );
    }

    function reinvestReward(ReinvestRewardParams calldata params) 
        external onlyRole(REWARD_REINVESTMENT_ROLE) {
        MetaStable2TokenAuraHelper.reinvestReward(_strategyContext(), params);
    }

    /// @notice Updates the vault settings
    /// @param settings vault settings
    function setStrategyVaultSettings(StrategyVaultSettings calldata settings)
        external
        onlyNotionalOwner
    {
        VaultStorage.setStrategyVaultSettings(settings);
    }
    
    function getStrategyContext() external view returns (MetaStable2TokenAuraStrategyContext memory) {
        return _strategyContext();
    }

    function getSpotPrice(uint256 tokenIndex) external view returns (uint256 spotPrice) {
        MetaStable2TokenAuraStrategyContext memory context = _strategyContext();
        spotPrice = Stable2TokenOracleMath._getSpotPrice(
            context.oracleContext, 
            context.poolContext, 
            context.poolContext.primaryBalance,
            context.poolContext.secondaryBalance,
            tokenIndex
        );
    }

    function getEmergencySettlementBPTAmount(uint256 maturity) external view returns (uint256 bptToSettle) {
        MetaStable2TokenAuraStrategyContext memory context = _strategyContext();
        bptToSettle = context.baseStrategy._getEmergencySettlementParams({
            maturity: maturity, 
            totalBPTSupply: IERC20(context.poolContext.basePool.pool).totalSupply()
        });
    }

    function migrateAura() external onlyNotionalOwner {
        uint256 oldAmount = OLD_REWARD_POOL.balanceOf(address(this));
        
        bool success = OLD_REWARD_POOL.withdrawAndUnwrap(oldAmount, true);
        if (!success) revert Errors.UnstakeFailed();

        IERC20(address(BALANCER_POOL_TOKEN)).checkApprove(address(AURA_BOOSTER), type(uint256).max);

        uint256 bptAmount = BALANCER_POOL_TOKEN.balanceOf(address(this));

        success = AURA_BOOSTER.deposit(AURA_POOL_ID, bptAmount, true);
        if (!success) revert Errors.StakeFailed();

        // New amount should equal to old amount
        require(oldAmount == AURA_REWARD_POOL.balanceOf(address(this)));

        emit AuraPoolMigrated(address(OLD_REWARD_POOL), address(AURA_REWARD_POOL), oldAmount);
    }
}

