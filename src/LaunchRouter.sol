// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v6 — UNAUDITED.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ILaunchCurve {
    function quote() external view returns (address);
    function token() external view returns (address);
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient, uint256 deadline, bytes32 ref)
        external
        returns (uint256);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient, uint256 deadline, bytes32 ref)
        external
        returns (uint256);
}

interface ICurveRegistry {
    function isCurve(address curve) external view returns (bool);
}

/// @title  Letsprint.ink LaunchRouter
/// @notice Lets people trade curves in what they actually hold: ETH for ETH pairs, USDC for USDC pairs
///         (one approval or permit covers every curve), and the xStock itself for stock pairs. It wraps
///         and unwraps in the same transaction and never keeps funds.
/// @dev    No owner, no fees, no upgrade path. Only curves registered with the factory are accepted.
///         Buy refunds (when a buy sells out a curve) are returned to the buyer in the original asset.
contract LaunchRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable weth;
    ICurveRegistry public immutable factory;

    error UnknownCurve();
    error WrongPairAsset();
    error SlippageExceeded();
    error DirectEthRejected();
    error ZeroAddress();

    constructor(address weth_, address factory_) {
        if (weth_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        weth = weth_;
        factory = ICurveRegistry(factory_);
    }

    /* ─────────────────────────── ETH pairs ─────────────────────────── */

    function buyWithETH(address curve, uint256 minTokensOut, address recipient, uint256 deadline, bytes32 ref)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        _check(curve, weth);
        uint256 before = IERC20(weth).balanceOf(address(this));
        IWETH9(weth).deposit{value: msg.value}();
        IERC20(weth).forceApprove(curve, msg.value);
        tokensOut = ILaunchCurve(curve).buy(msg.value, minTokensOut, recipient, deadline, ref);
        uint256 refund = IERC20(weth).balanceOf(address(this)) - before;
        if (refund != 0) {
            IWETH9(weth).withdraw(refund);
            Address.sendValue(payable(msg.sender), refund);
        }
    }

    function sellForETH(
        address curve,
        uint256 tokensIn,
        uint256 minEthOut,
        address payable recipient,
        uint256 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 ethOut) {
        ethOut = _sellForETH(curve, tokensIn, minEthOut, recipient, deadline, ref);
    }

    function sellForETHWithPermit(
        address curve,
        uint256 tokensIn,
        uint256 minEthOut,
        address payable recipient,
        uint256 deadline,
        bytes32 ref,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 ethOut) {
        _permit(curve, tokensIn, permitDeadline, v, r, s);
        ethOut = _sellForETH(curve, tokensIn, minEthOut, recipient, deadline, ref);
    }

    /* ─────────────────────────── USDC pairs ─────────────────────────── */

    /// @notice Buy on a curve priced in USDC. Approve this router once for every USDC curve. Sells need
    ///         no router: call the curve's sell or sellWithPermit, which pays USDC directly.
    function buyWithToken(
        address curve,
        uint256 amountIn,
        uint256 minTokensOut,
        address recipient,
        uint256 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 tokensOut) {
        tokensOut = _buyWithToken(curve, amountIn, minTokensOut, recipient, deadline, ref);
    }

    /// @notice buyWithToken with an EIP-2612 signature instead of a separate approval.
    function buyWithTokenPermit(
        address curve,
        uint256 amountIn,
        uint256 minTokensOut,
        address recipient,
        uint256 deadline,
        bytes32 ref,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 tokensOut) {
        // A front-run permit reverts here, but the allowance is already in place.
        try IERC20Permit(ILaunchCurve(curve).quote()).permit(msg.sender, address(this), amountIn, permitDeadline, v, r, s)
        {} catch {}
        tokensOut = _buyWithToken(curve, amountIn, minTokensOut, recipient, deadline, ref);
    }

    /* ─────────────────────────── Stock pairs ─────────────────────────── */

    /// @notice Buy with the xStock itself. It is wrapped into the curve's StockVault on the way in.
    function buyWithStock(
        address curve,
        uint256 stockIn,
        uint256 minTokensOut,
        address recipient,
        uint256 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 tokensOut) {
        IERC4626 vault = IERC4626(ILaunchCurve(curve).quote());
        _check(curve, address(vault));
        IERC20 stock = IERC20(vault.asset());

        uint256 sharesBefore = IERC20(address(vault)).balanceOf(address(this));
        uint256 before = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), stockIn);
        uint256 received = stock.balanceOf(address(this)) - before;
        stock.forceApprove(address(vault), received);
        uint256 shares = vault.deposit(received, address(this));

        IERC20(address(vault)).forceApprove(curve, shares);
        tokensOut = ILaunchCurve(curve).buy(shares, minTokensOut, recipient, deadline, ref);

        uint256 refund = IERC20(address(vault)).balanceOf(address(this)) - sharesBefore;
        if (refund != 0) vault.redeem(refund, msg.sender, address(this));
    }

    /// @notice Sell for the xStock itself. The curve pays vault shares, redeemed here for the stock.
    function sellForStock(
        address curve,
        uint256 tokensIn,
        uint256 minStockOut,
        address recipient,
        uint256 deadline,
        bytes32 ref
    ) external nonReentrant returns (uint256 stockOut) {
        stockOut = _sellForStock(curve, tokensIn, minStockOut, recipient, deadline, ref);
    }

    function sellForStockWithPermit(
        address curve,
        uint256 tokensIn,
        uint256 minStockOut,
        address recipient,
        uint256 deadline,
        bytes32 ref,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 stockOut) {
        _permit(curve, tokensIn, permitDeadline, v, r, s);
        stockOut = _sellForStock(curve, tokensIn, minStockOut, recipient, deadline, ref);
    }

    /* ─────────────────────────── Internals ─────────────────────────── */

    function _sellForETH(
        address curve,
        uint256 tokensIn,
        uint256 minEthOut,
        address payable recipient,
        uint256 deadline,
        bytes32 ref
    ) internal returns (uint256 ethOut) {
        if (recipient == address(0)) revert ZeroAddress(); // the curve only sees this router
        _check(curve, weth);
        _pullTokens(curve, tokensIn);
        ethOut = ILaunchCurve(curve).sell(tokensIn, minEthOut, address(this), deadline, ref);
        IWETH9(weth).withdraw(ethOut);
        Address.sendValue(recipient, ethOut);
    }

    function _sellForStock(
        address curve,
        uint256 tokensIn,
        uint256 minStockOut,
        address recipient,
        uint256 deadline,
        bytes32 ref
    ) internal returns (uint256 stockOut) {
        if (recipient == address(0)) revert ZeroAddress();
        IERC4626 vault = IERC4626(ILaunchCurve(curve).quote());
        _check(curve, address(vault));
        _pullTokens(curve, tokensIn);
        uint256 shares = ILaunchCurve(curve).sell(tokensIn, 0, address(this), deadline, ref);
        stockOut = vault.redeem(shares, recipient, address(this));
        if (stockOut < minStockOut) revert SlippageExceeded();
    }

    function _buyWithToken(
        address curve,
        uint256 amountIn,
        uint256 minTokensOut,
        address recipient,
        uint256 deadline,
        bytes32 ref
    ) internal returns (uint256 tokensOut) {
        if (!factory.isCurve(curve)) revert UnknownCurve();
        IERC20 asset = IERC20(ILaunchCurve(curve).quote());
        if (address(asset) == weth) revert WrongPairAsset(); // ETH pairs use buyWithETH
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amountIn);
        asset.forceApprove(curve, amountIn);
        tokensOut = ILaunchCurve(curve).buy(amountIn, minTokensOut, recipient, deadline, ref);
        uint256 refund = asset.balanceOf(address(this)) - before;
        if (refund != 0) asset.safeTransfer(msg.sender, refund);
    }

    function _pullTokens(address curve, uint256 tokensIn) internal {
        IERC20 token = IERC20(ILaunchCurve(curve).token());
        token.safeTransferFrom(msg.sender, address(this), tokensIn);
        token.forceApprove(curve, tokensIn);
    }

    function _permit(address curve, uint256 amount, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s) internal {
        // A front-run permit reverts here, but the allowance is already in place.
        try IERC20Permit(ILaunchCurve(curve).token()).permit(msg.sender, address(this), amount, permitDeadline, v, r, s)
        {} catch {}
    }

    function _check(address curve, address expectedQuote) internal view {
        if (!factory.isCurve(curve)) revert UnknownCurve();
        if (ILaunchCurve(curve).quote() != expectedQuote) revert WrongPairAsset();
    }

    /// @dev Only WETH unwraps send ETH here.
    receive() external payable {
        if (msg.sender != weth) revert DirectEthRejected();
    }
}
