import pytest
import eth_abi
from brownie import (
    ZERO_ADDRESS,
    MetaStable2TokenAuraVault,
    MockMetaStable2TokenAuraVault,
    MockBoosted3TokenAuraVault,
    MetaStable2TokenAuraHelper,
    Boosted3TokenAuraHelper
)
from brownie.network import Chain
from brownie import network, Contract
from scripts.BalancerEnvironment import getEnvironment
from scripts.common import set_dex_flags, set_trade_type_flags

chain = Chain()

@pytest.fixture(autouse=True)
def run_around_tests():
    chain.snapshot()
    yield
    chain.revert()
    
@pytest.fixture()
def StratStableETHstETH():
    env = getEnvironment(network.show_active())
    strat = "StratStableETHstETH"
    vault = Contract.from_abi(
        "MetaStable2TokenAuraVault", 
        "0xF049B944eC83aBb50020774D48a8cf40790996e6", 
        MetaStable2TokenAuraVault.abi
    )
    impl = env.deployBalancerVault(strat, MetaStable2TokenAuraVault, [MetaStable2TokenAuraHelper])
    stratConfig = env.getStratConfig(strat)
    settingsData = vault.setStrategyVaultSettings.encode_input([
        stratConfig["maxUnderlyingSurplus"],
        stratConfig["settlementSlippageLimitPercent"], 
        stratConfig["postMaturitySettlementSlippageLimitPercent"], 
        stratConfig["emergencySettlementSlippageLimitPercent"], 
        stratConfig["maxBalancerPoolShare"],
        stratConfig["settlementCoolDownInMinutes"],
        stratConfig["oraclePriceDeviationLimitPercent"],
        stratConfig["balancerPoolSlippageLimitPercent"]
    ])
    vault.upgradeToAndCall(impl, settingsData, {"from": env.notional.owner()})

    # Deploy mock contract necessary for liquidation tests
    mockImpl = env.deployBalancerVault(strat, MockMetaStable2TokenAuraVault, [MetaStable2TokenAuraHelper])
    mock = env.deployVaultProxy(strat, mockImpl, MockMetaStable2TokenAuraVault)
    env.tradingModule.setTokenPermissions(
        mock.address, 
        env.tokens["wstETH"].address, 
        [True, set_dex_flags(0, BALANCER_V2=True, CURVE=True), set_trade_type_flags(0, EXACT_IN_SINGLE=True)], 
        {"from": env.notional.owner()})
    env.tradingModule.setTokenPermissions(
        mock.address, 
        env.tokens["stETH"].address, 
        [True, set_dex_flags(0, CURVE=True), set_trade_type_flags(0, EXACT_IN_SINGLE=True)], 
        {"from": env.notional.owner()})
    env.tradingModule.setTokenPermissions(
        mock.address, 
        env.tokens["WETH"].address, 
        [True, set_dex_flags(0, BALANCER_V2=True, CURVE=True), set_trade_type_flags(0, EXACT_IN_SINGLE=True)], 
        {"from": env.notional.owner()})
    env.tradingModule.setTokenPermissions(
        mock.address, 
        ZERO_ADDRESS, 
        [True, set_dex_flags(0, BALANCER_V2=True, CURVE=True), set_trade_type_flags(0, EXACT_IN_SINGLE=True)], 
        {"from": env.notional.owner()})

    return (env, vault, mock)

@pytest.fixture()
def StratBoostedPoolDAIPrimary():
    env = getEnvironment(network.show_active())
    vault = env.deployBalancerVault("StratBoostedPoolDAIPrimary", MockBoosted3TokenAuraVault, [Boosted3TokenAuraHelper])
    return (env, vault)

@pytest.fixture()
def StratBoostedPoolUSDCPrimary():
    env = getEnvironment(network.show_active())
    vault = env.deployBalancerVault("StratBoostedPoolUSDCPrimary", MockBoosted3TokenAuraVault, [Boosted3TokenAuraHelper])
    return (env, vault)
