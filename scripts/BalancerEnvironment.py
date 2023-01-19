import eth_abi
from brownie import (
    network, 
    nProxy,
    MetaStable2TokenAuraVault,
    Boosted3TokenAuraVault,
    Boosted3TokenAuraHelper,
    MetaStable2TokenAuraHelper,
    FlashLiquidator,
    nMockProxy
)
from brownie.network.contract import Contract
from brownie.convert.datatypes import Wei
from brownie.network.state import Chain
from brownie.convert import to_bytes
from scripts.common import deployArtifact, get_vault_config, set_flags
from scripts.EnvironmentConfig import Environment
from eth_utils import keccak

chain = Chain()
ETH_ADDRESS = "0x0000000000000000000000000000000000000000"

StrategyConfig = {
    "balancer2TokenStrats": {
        "StratStableETHstETH": {
            "vaultConfig": get_vault_config(
                flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
                currencyId=1,
                minAccountBorrowSize=1,
                maxBorrowMarketIndex=2,
                secondaryBorrowCurrencies=[0,0]
            ),
            "secondaryBorrowCurrency": None,
            "maxPrimaryBorrowCapacity": 100_000_000e8,
            "name": "Balancer Stable ETH-stETH Strategy",
            "primaryCurrency": 1, # ETH
            "poolId": "0x32296969ef14eb0c6d29669c550d4a0449130230000200000000000000000080",
            "liquidityGauge": "0xcd4722b7c24c29e0413bdcd9e51404b4539d14ae",
            "auraRewardPool": "0xe4683fe8f53da14ca5dac4251eadfb3aa614d528",
            "feeReceiver": "0x0190702d5e52e0269c9319144d3ad62a60ebe526",
            "maxUnderlyingSurplus": 2000e18, # 2000 ETH
            "maxBalancerPoolShare": Wei(1.5e3), # 15%
            "settlementSlippageLimitPercent": Wei(3e6), # 3%
            "postMaturitySettlementSlippageLimitPercent": Wei(5e6), # 5%
            "emergencySettlementSlippageLimitPercent": Wei(4e6), # 4%
            "maxRewardTradeSlippageLimitPercent": 2e6, # 2%
            "settlementCoolDownInMinutes": 20, # 20 minute settlement cooldown
            "settlementWindow": 172800,  # 1-week settlement
            "oraclePriceDeviationLimitPercent": 200, # +/- 2%
            "balancerPoolSlippageLimitPercent": 9975, # 0.25%
        },
        "StratBoostedPoolDAIPrimary": {
            "vaultConfig": get_vault_config(
                flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
                currencyId=2,
                minAccountBorrowSize=1,
                maxBorrowMarketIndex=3,
                secondaryBorrowCurrencies=[0,0]
            ),
            "secondaryBorrowCurrency": None,
            "maxPrimaryBorrowCapacity": 100_000_000e8,
            "name": "Balancer Boosted Pool Strategy",
            "primaryCurrency": 2, # DAI
            "poolId": "0x7b50775383d3d6f0215a8f290f2c9e2eebbeceb20000000000000000000000fe",
            "liquidityGauge": "0x68d019f64a7aa97e2d4e7363aee42251d08124fb",
            "auraRewardPool": "0xcc2f52b57247f2bc58fec182b9a60dac5963d010",
            "feeReceiver": "0x0190702d5e52e0269c9319144d3ad62a60ebe526",
            "maxUnderlyingSurplus": 10000e18, # 10000 DAI
            "maxBalancerPoolShare": 2e3, # 20%
            "settlementSlippageLimitPercent": 5e6, # 5%
            "postMaturitySettlementSlippageLimitPercent": 10e6, # 10%
            "emergencySettlementSlippageLimitPercent": 10e6, # 10%
            "maxRewardTradeSlippageLimitPercent": 5e6,
            "settlementCoolDownInMinutes": 60 * 6, # 6 hour settlement cooldown
            "settlementWindow": 3600 * 24 * 7,  # 1-week settlement
            "oraclePriceDeviationLimitPercent": 50, # +/- 0.5%
            "balancerPoolSlippageLimitPercent": 9900, # 1%
        },
        "StratBoostedPoolUSDCPrimary": {
            "vaultConfig": get_vault_config(
                flags=set_flags(0, ENABLED=True, ALLOW_ROLL_POSITION=True),
                currencyId=3,
                minAccountBorrowSize=1,
                maxBorrowMarketIndex=3,
                secondaryBorrowCurrencies=[0,0]
            ),
            "secondaryBorrowCurrency": None,
            "maxPrimaryBorrowCapacity": 100_000_000e8,
            "name": "Balancer Boosted Pool Strategy",
            "primaryCurrency": 3, # USDC
            "poolId": "0x7b50775383d3d6f0215a8f290f2c9e2eebbeceb20000000000000000000000fe",
            "liquidityGauge": "0x68d019f64a7aa97e2d4e7363aee42251d08124fb",
            "auraRewardPool": "0xcc2f52b57247f2bc58fec182b9a60dac5963d010",
            "feeReceiver": "0x0190702d5e52e0269c9319144d3ad62a60ebe526",
            "maxUnderlyingSurplus": 10000e6, # 10000 USDC
            "oracleWindowInSeconds": 0,
            "maxBalancerPoolShare": 2e3, # 20%
            "settlementSlippageLimitPercent": 5e6, # 5%
            "postMaturitySettlementSlippageLimitPercent": 10e6, # 10%
            "emergencySettlementSlippageLimitPercent": 10e6, # 10%
            "maxRewardTradeSlippageLimitPercent": 5e6,
            "settlementCoolDownInMinutes": 60 * 6, # 6 hour settlement cooldown
            "settlementWindow": 3600 * 24 * 7,  # 1-week settlement
            "oraclePriceDeviationLimitPercent": 50, # +/- 0.5%
            "balancerPoolSlippageLimitPercent": 9900, # 1%
        }
    }
}

class BalancerEnvironment(Environment):
    def __init__(self, network) -> None:
        Environment.__init__(self, network)
        self.liquidator = self.deployLiquidator()

    def getStratConfig(self, strat):
        return StrategyConfig["balancer2TokenStrats"][strat]

    def initializeBalancerVault(self, vault, strat):
        stratConfig = StrategyConfig["balancer2TokenStrats"][strat]
        vault.initialize(
            [
                stratConfig["name"],
                stratConfig["primaryCurrency"],
                [
                    stratConfig["maxUnderlyingSurplus"],
                    stratConfig["settlementSlippageLimitPercent"], 
                    stratConfig["postMaturitySettlementSlippageLimitPercent"], 
                    stratConfig["emergencySettlementSlippageLimitPercent"], 
                    stratConfig["maxBalancerPoolShare"],
                    stratConfig["settlementCoolDownInMinutes"],
                    stratConfig["oraclePriceDeviationLimitPercent"],
                    stratConfig["balancerPoolSlippageLimitPercent"]
                ]
            ],
            {"from": self.notional.owner()}
        )        

        self.notional.updateVault(
            vault.address,
            stratConfig["vaultConfig"],
            stratConfig["maxPrimaryBorrowCapacity"],
            {"from": self.notional.owner()}
        )

    def deployBalancerVault(self, strat, vaultContract, libs=None):
        stratConfig = StrategyConfig["balancer2TokenStrats"][strat]

        # Deploy external libs
        if libs != None:
            for lib in libs:
                lib.deploy({"from": self.deployer})

        return vaultContract.deploy(
            self.addresses["notional"],
            [
                stratConfig["auraRewardPool"],
                [
                    stratConfig["primaryCurrency"],
                    stratConfig["poolId"],
                    stratConfig["liquidityGauge"],
                    self.tradingModule.address,
                    stratConfig["settlementWindow"]
                ]
            ],
            {"from": self.deployer}
        )

    def deployVaultProxy(self, strat, impl, vaultContract, mockImpl=None):
        stratConfig = StrategyConfig["balancer2TokenStrats"][strat]

        if mockImpl == None:
            proxy = nProxy.deploy(impl.address, bytes(0), {"from": self.deployer})
        else:
            proxy = nMockProxy.deploy(impl.address, bytes(0), mockImpl, {"from": self.deployer})
        vaultProxy = Contract.from_abi(stratConfig["name"], proxy.address, vaultContract.abi)
        vaultProxy.initialize(
            [
                stratConfig["name"],
                stratConfig["primaryCurrency"],
                [
                    stratConfig["maxUnderlyingSurplus"],
                    stratConfig["settlementSlippageLimitPercent"], 
                    stratConfig["postMaturitySettlementSlippageLimitPercent"], 
                    stratConfig["emergencySettlementSlippageLimitPercent"], 
                    stratConfig["maxRewardTradeSlippageLimitPercent"], 
                    stratConfig["maxBalancerPoolShare"],
                    stratConfig["settlementCoolDownInMinutes"],
                    stratConfig["oraclePriceDeviationLimitPercent"],
                    stratConfig["balancerPoolSlippageLimitPercent"]
                ]
            ],
            {"from": self.notional.owner()}
        )

        self.notional.updateVault(
            proxy.address,
            stratConfig["vaultConfig"],
            stratConfig["maxPrimaryBorrowCapacity"],
            {"from": self.notional.owner()}
        )

        return vaultProxy

    def deployLiquidator(self):
        liquidator = FlashLiquidator.deploy(
            self.notional, 
            "0x27182842E098f60e3D576794A5bFFb0777E025d3",
            "0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3",
            {"from": self.deployer}
        )
        liquidator.enableCurrencies([1, 2, 3], {"from": self.deployer})
        return liquidator

def getEnvironment(network = "mainnet"):
    if network == "mainnet-fork" or network == "hardhat-fork":
        network = "mainnet"
    return BalancerEnvironment(network)

def main():
    networkName = network.show_active()
    if networkName == "hardhat-fork":
        networkName = "mainnet"
    env = BalancerEnvironment(networkName)
    maturity = env.notional.getActiveMarkets(1)[0][1]

    vault1 = env.deployBalancerVault(
        "StratStableETHstETH", 
        MetaStable2TokenAuraVault,
        [MetaStable2TokenAuraHelper]
    )
    vault2 = env.deployBalancerVault(
        "StratBoostedPoolDAIPrimary", 
        Boosted3TokenAuraVault,
        [Boosted3TokenAuraHelper]
    )
    vault3 = env.deployBalancerVault(
        "StratBoostedPoolUSDCPrimary", 
        Boosted3TokenAuraVault,
        [Boosted3TokenAuraHelper]
    )
