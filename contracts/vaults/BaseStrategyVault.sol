// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.15;

import {Token, TokenType} from "../global/Types.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IStrategyVault} from "../../interfaces/notional/IStrategyVault.sol";
import {NotionalProxy} from "../../interfaces/notional/NotionalProxy.sol";
import {ITradingModule, Trade} from "../../interfaces/trading/ITradingModule.sol";
import {IERC20} from "../../interfaces/IERC20.sol";
import {TokenUtils} from "../utils/TokenUtils.sol";
import {NotionalUtils} from "../utils/NotionalUtils.sol";
import {nProxy} from "../proxy/nProxy.sol";

abstract contract BaseStrategyVault is Initializable, IStrategyVault {
    using TokenUtils for IERC20;

    /// @notice Hardcoded on the implementation contract during deployment
    NotionalProxy public immutable NOTIONAL;
    ITradingModule public immutable TRADING_MODULE;
    uint8 constant internal INTERNAL_TOKEN_DECIMALS = 8;

    // Borrowing Currency ID the vault is configured with
    uint16 private _BORROW_CURRENCY_ID;
    // True if the underlying is ETH
    bool private _UNDERLYING_IS_ETH;
    // Address of the underlying token
    IERC20 private _UNDERLYING_TOKEN;
    // NOTE: end of first storage slot here

    // Name of the vault
    string private _NAME;


    /**************************************************************************/
    /* Global Modifiers, Constructor and Initializer                          */
    /**************************************************************************/
    modifier onlyNotional() {
        require(msg.sender == address(NOTIONAL));
        _;
    }

    modifier onlyNotionalOwner() {
        require(msg.sender == address(NOTIONAL.owner()));
        _;
    }
    
    /// @notice Set the NOTIONAL address on deployment
    constructor(NotionalProxy notional_, ITradingModule tradingModule_) initializer {
        NOTIONAL = notional_;
        TRADING_MODULE = tradingModule_;
    }

    /// @notice Override this method and revert if the contract should not receive ETH.
    /// Upgradeable proxies must have this implemented on the proxy for transfer calls
    /// succeed (use nProxy for this).
    receive() external virtual payable {
        // Allow ETH transfers to succeed
    }

    /// @notice All strategy vaults MUST implement 8 decimal precision
    function decimals() public override view returns (uint8) {
        return INTERNAL_TOKEN_DECIMALS;
    }

    function name() external override view returns (string memory) {
        return _NAME;
    }

    function _borrowCurrencyId() internal view returns (uint16) {
        return _BORROW_CURRENCY_ID;
    }

    function _underlyingToken() internal view returns (IERC20) {
        return _UNDERLYING_TOKEN;
    }

    function _isUnderlyingETH() internal view returns (bool) {
        return _UNDERLYING_IS_ETH;
    }

    /// @notice Can only be called once during initialization
    function __INIT_VAULT(
        string memory name_,
        uint16 borrowCurrencyId_
    ) internal onlyInitializing {
        _NAME = name_;
        _BORROW_CURRENCY_ID = borrowCurrencyId_;

        address underlyingAddress = NotionalUtils._getNotionalUnderlyingToken(borrowCurrencyId_);
        _UNDERLYING_TOKEN = IERC20(underlyingAddress);
        _UNDERLYING_IS_ETH = underlyingAddress == address(0);
    }

    /// @notice Can be used to delegate call to the TradingModule's implementation in order to execute
    /// a trade.
    function _executeTrade(
        uint16 dexId,
        Trade memory trade
    ) internal returns (uint256 amountSold, uint256 amountBought) {
        (bool success, bytes memory result) = nProxy(payable(address(TRADING_MODULE))).getImplementation()
            .delegatecall(abi.encodeWithSelector(ITradingModule.executeTrade.selector, dexId, trade));
        require(success);
        (amountSold, amountBought) = abi.decode(result, (uint256, uint256));
    }

    /// @notice Can be used to delegate call to the TradingModule's implementation in order to execute
    /// a trade.
    function _executeTradeWithDynamicSlippage(
        uint16 dexId,
        Trade memory trade,
        uint32 dynamicSlippageLimit
    ) internal returns (uint256 amountSold, uint256 amountBought) {
        (bool success, bytes memory result) = nProxy(payable(address(TRADING_MODULE))).getImplementation()
            .delegatecall(abi.encodeWithSelector(
                ITradingModule.executeTradeWithDynamicSlippage.selector,
                dexId, trade, dynamicSlippageLimit
            )
        );
        require(success);
        (amountSold, amountBought) = abi.decode(result, (uint256, uint256));
    }

    /**************************************************************************/
    /* Virtual Methods Requiring Implementation                               */
    /**************************************************************************/
    function convertStrategyToUnderlying(
        address account,
        uint256 strategyTokens,
        uint256 maturity
    ) public view virtual returns (int256 underlyingValue);
    
    // Vaults need to implement these two methods
    function _depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) internal virtual returns (uint256 strategyTokensMinted);

    function _redeemFromNotional(
        address account,
        uint256 strategyTokens,
        uint256 maturity,
        bytes calldata data
    ) internal virtual returns (uint256 tokensFromRedeem);

    // This can be overridden if the vault borrows in a secondary currency, but reverts by default.
    function _repaySecondaryBorrowCallback(
        address token,  uint256 underlyingRequired, bytes calldata data
    ) internal virtual returns (bytes memory returnData) {
        revert();
    }

    /**************************************************************************/
    /* Default External Method Implementations                                */
    /**************************************************************************/
    function depositFromNotional(
        address account,
        uint256 deposit,
        uint256 maturity,
        bytes calldata data
    ) external payable onlyNotional returns (uint256 strategyTokensMinted) {
        return _depositFromNotional(account, deposit, maturity, data);
    }

    function redeemFromNotional(
        address account,
        address receiver,
        uint256 strategyTokens,
        uint256 maturity,
        uint256 underlyingToRepayDebt,
        bytes calldata data
    ) external onlyNotional {
        uint256 borrowedCurrencyAmount = _redeemFromNotional(account, strategyTokens, maturity, data);

        uint256 transferToNotional;
        uint256 transferToAccount;
        if (account == address(this) || borrowedCurrencyAmount <= underlyingToRepayDebt) {
            // It may be the case that insufficient tokens were redeemed to repay the debt. If this
            // happens the Notional will attempt to recover the shortfall from the account directly.
            // This can happen if an account wants to reduce their leverage by paying off debt but
            // does not want to sell strategy tokens to do so.
            // The other situation would be that the vault is calling redemption to deleverage or
            // settle. In that case all tokens go back to Notional.
            transferToNotional = borrowedCurrencyAmount;
        } else {
            transferToNotional = underlyingToRepayDebt;
            unchecked { transferToAccount = borrowedCurrencyAmount - underlyingToRepayDebt; }
        }

        if (_UNDERLYING_IS_ETH) {
            if (transferToAccount > 0) payable(receiver).transfer(transferToAccount);
            if (transferToNotional > 0) payable(address(NOTIONAL)).transfer(transferToNotional);
        } else {
            if (transferToAccount > 0) _UNDERLYING_TOKEN.checkTransfer(receiver, transferToAccount);
            if (transferToNotional > 0) _UNDERLYING_TOKEN.checkTransfer(address(NOTIONAL), transferToNotional);
        }
    }

    function repaySecondaryBorrowCallback(
        address token, uint256 underlyingRequired, bytes calldata data
    ) external onlyNotional returns (bytes memory returnData) {
        return _repaySecondaryBorrowCallback(token, underlyingRequired, data);
    }

    // Storage gap for future potential upgrades
    uint256[45] private __gap;
}
