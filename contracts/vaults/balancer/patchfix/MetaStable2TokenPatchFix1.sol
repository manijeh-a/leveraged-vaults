// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.17;

import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {BalancerVaultStorage, StrategyVaultState} from "../internal/BalancerVaultStorage.sol";
import {NotionalProxy} from "../../../../interfaces/notional/NotionalProxy.sol";
import {IAuraRewardPool} from "../../../../interfaces/aura/IAuraRewardPool.sol";
import {nProxy} from "../../../proxy/nProxy.sol";
import {VaultState} from "../../../global/Types.sol";
import {TypeConvert} from "../../../global/TypeConvert.sol";

contract MetaStable2TokenPatchFix1 is UUPSUpgradeable {
    using TypeConvert for uint256;

    NotionalProxy public constant NOTIONAL =
        NotionalProxy(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    IAuraRewardPool public constant AURA_REWARD_POOL =
        IAuraRewardPool(0xe4683Fe8F53da14cA5DAc4251EaDFb3aa614d528);
    uint256 public constant MATURITY_DEC_2022 = 1671840000;
    uint256 public constant MATURITY_MAR_2023 = 1679616000;
    uint256 public constant MATURITY_JUN_2023 = 1687392000;
    address public immutable NEW_IMPL;

    constructor(address newImpl_) {
        NEW_IMPL = newImpl_;
    }

    function _getStrategyTokenAmount(uint256 maturity)
        private
        view
        returns (uint80)
    {
        VaultState memory state = NOTIONAL.getVaultState(
            address(this),
            maturity
        );
        return state.totalStrategyTokens.toUint80();
    }

    function patch(uint256 expectedTotalStrategyTokens) external {
        require(msg.sender == NOTIONAL.owner());
        uint80 totalStrategyTokens = _getStrategyTokenAmount(MATURITY_DEC_2022) +
            _getStrategyTokenAmount(MATURITY_MAR_2023) +
            _getStrategyTokenAmount(MATURITY_JUN_2023);

        require(totalStrategyTokens == expectedTotalStrategyTokens);

        StrategyVaultState memory state = BalancerVaultStorage
            .getStrategyVaultState();
        state.totalBPTHeld = AURA_REWARD_POOL.balanceOf(address(this));
        state.totalStrategyTokenGlobal = totalStrategyTokens;
        BalancerVaultStorage.setStrategyVaultState(state);
        _upgradeTo(NEW_IMPL);
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal override {
        require(msg.sender == NOTIONAL.owner());
    }
}
