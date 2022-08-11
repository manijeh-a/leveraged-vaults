import json
from brownie import (
    ZERO_ADDRESS,
    accounts, 
    interface,
    TradingModule,
    nProxy,
    EmptyProxy,
)
from brownie.network.contract import Contract
from brownie.network.state import Chain
from scripts.common import deployArtifact

chain = Chain()

with open("abi/nComptroller.json", "r") as a:
    Comptroller = json.load(a)

with open("abi/nCErc20.json") as a:
    cToken = json.load(a)

with open("abi/nCEther.json") as a:
    cEther = json.load(a)

with open("abi/ERC20.json") as a:
    ERC20ABI = json.load(a)

with open("abi/Notional.json") as a:
    NotionalABI = json.load(a)

networks = {}

with open("v2.mainnet.json", "r") as f:
    networks["mainnet"] = json.load(f)

with open("v2.goerli.json", "r") as f:
    networks["goerli"] = json.load(f)

class Environment:
    def __init__(self, network) -> None:
        self.network = network
        addresses = networks[network]
        self.addresses = addresses
        self.deployer = accounts.at(addresses["deployer"], force=True)
        self.notional = Contract.from_abi(
            "Notional", addresses["notional"], NotionalABI
        )

        self.notional.upgradeTo("0x2C67B0C0493e358cF368073bc0B5fA6F01E981e0", {"from": self.notional.owner()})
        self.notional.updateAssetRate(1, "0x8E3D447eBE244db6D28E2303bCa86Ef3033CFAd6", {"from": self.notional.owner()})
        self.notional.updateAssetRate(2, "0x719993E82974f5b5eA0c5ebA25c260CD5AF78E00", {"from": self.notional.owner()})
        self.notional.updateAssetRate(3, "0x612741825ACedC6F88D8709319fe65bCB015C693", {"from": self.notional.owner()})
        self.notional.updateAssetRate(4, "0x39D9590721331B13C8e9A42941a2B961B513E69d", {"from": self.notional.owner()})
        self.upgradeNotional()

        self.tokens = {}
        for (symbol, obj) in addresses["tokens"].items():
            if symbol.startswith("c"):
                self.tokens[symbol] = Contract.from_abi(symbol, obj, cToken["abi"])
            else:
                self.tokens[symbol] = Contract.from_abi(symbol, obj, ERC20ABI)

        self.whales = {}
        for (name, addr) in addresses["whales"].items():
            self.whales[name] = accounts.at(addr, force=True)

        self.owner = accounts.at(self.notional.owner(), force=True)
        self.balancerVault = interface.IBalancerVault(addresses["balancer"]["vault"])

        self.deployTradingModule()

    def upgradeNotional(self):
        tradingAction = deployArtifact(
            "scripts/artifacts/TradingAction.json", 
            [], 
            self.deployer, 
            "TradingAction", 
            {"SettleAssetsExternal": self.addresses["libs"]["SettleAssetsExternal"]}
        )
        vaultAccountAction = deployArtifact(
            "scripts/artifacts/VaultAccountAction.json", 
            [], 
            self.deployer, 
            "VaultAccountAction", 
            {"TradingAction": tradingAction.address}
        )
        vaultAction = deployArtifact(
            "scripts/artifacts/VaultAction.json", 
            [], 
            self.deployer, 
            "VaultAction",  
            {"TradingAction": tradingAction.address})
        router = deployArtifact("scripts/artifacts/Router.json", [
            (
                self.addresses["actions"]["GovernanceAction"],
                self.addresses["actions"]["Views"],
                self.addresses["actions"]["InitializeMarketsAction"],
                self.addresses["actions"]["nTokenAction"],
                self.addresses["actions"]["BatchAction"],
                self.addresses["actions"]["AccountAction"],
                self.addresses["actions"]["ERC1155Action"],
                self.addresses["actions"]["LiquidateCurrencyAction"],
                self.addresses["actions"]["LiquidatefCashAction"],
                self.addresses["tokens"]["cETH"],
                self.addresses["actions"]["TreasuryAction"],
                self.addresses["actions"]["CalculationViews"],
                vaultAccountAction.address,
                vaultAction.address,
            )
        ], self.deployer, "Router")
        self.notional.upgradeTo(router.address, {'from': self.notional.owner()})

    def deployTradingModule(self):
        emptyImpl = EmptyProxy.deploy({"from": self.deployer})
        self.proxy = nProxy.deploy(emptyImpl.address, bytes(0), {"from": self.deployer})

        impl = TradingModule.deploy(self.notional.address, self.proxy.address, {"from": self.deployer})
        emptyProxy = Contract.from_abi("EmptyProxy", self.proxy.address, EmptyProxy.abi)
        emptyProxy.upgradeTo(impl.address, {"from": self.deployer})

        self.tradingModule = Contract.from_abi("TradingModule", self.proxy.address, TradingModule.abi)

        # ETH/USD oracle
        self.tradingModule.setPriceOracle(
            ZERO_ADDRESS, 
            "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419", 
            {"from": self.notional.owner()}
        )

        # WETH/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["WETH"].address, 
            "0x5f4ec3df9cbd43714fe2740f5e3616155c5b8419", 
            {"from": self.notional.owner()}
        )
        # DAI/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["DAI"].address,
            "0xaed0c38402a5d19df6e4c03f4e2dced6e29c1ee9",
            {"from": self.notional.owner()}
        )
        # USDC/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["USDC"].address,
            "0x8fffffd4afb6115b954bd326cbe7b4ba576818f6",
            {"from": self.notional.owner()}
        )
        # USDT/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["USDT"].address,
            "0x3e7d1eab13ad0104d2750b8863b489d65364e32d",
            {"from": self.notional.owner()}
        )
        # WBTC/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["WBTC"].address,
            "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c",
            {"from": self.notional.owner()}
        )
        # BAL/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["BAL"].address,
            "0xdf2917806e30300537aeb49a7663062f4d1f2b5f",
            {"from": self.notional.owner()}
        )
        # stETH/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["stETH"].address,
            "0xcfe54b5cd566ab89272946f602d76ea879cab4a8",
            {"from": self.notional.owner()}
        )
        # wstETH/USD oracle
        self.tradingModule.setPriceOracle(
            self.tokens["wstETH"].address,
            "0x54bd2a9e54532ff28cdb9208578f63788549b127",
            {"from": self.notional.owner()}
        )

def getEnvironment(network = "mainnet"):
    return Environment(network)

