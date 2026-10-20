// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v6 — UNAUDITED. Build settings are listed at the top of BondingCurve.sol.
// Deploy with CREATE2 at an address whose lowest 14 bits equal this hook's permission flags
// (0x20CC: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta).
// Mine the salt with v4-periphery's HookMiner; the constructor reverts on a wrong address.

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

interface IPrintFactory {
    function curveOf(address token) external view returns (address);
    function owner() external view returns (address);
}

interface IPrintCurve {
    function creator() external view returns (address);
    function treasury() external view returns (address);
    function creatorTaxBps() external view returns (uint256);
    function feeRecipients() external view returns (address[] memory recipients, uint16[] memory sharesBps);
    function quote() external view returns (address);
}

/// @title  Letsprint.ink PrintHook
/// @notice One shared Uniswap v4 hook for every graduated Letsprint.ink token. It does two things:
///         1. Only a token's own Letsprint.ink curve can create that token's pool (beforeInitialize),
///            so nobody can pre-create or pre-seed a graduation pool.
///         2. Every swap pays 1% plus the token's creator tax (0–10%, read live; it can only go down) in
///            the pair asset (WETH, USDC or a StockVault share), inside the swap itself: the 1% splits
///            70/30 between creators and treasury, and the creator tax goes entirely to the creators.
///            The charge is always taken on the pair-asset side: before the swap when that is the
///            amount the trader specified, after it otherwise. Payouts use PoolManager.take, and these
///            assets never run recipient code. USDC can block addresses, so a payout that fails is
///            held for its recipient as a PoolManager claim (ERC-6909, no token transfer) to collect
///            with claim(): no recipient, blocked or not, and not even a block on this hook itself,
///            can make a swap revert. (Native ETH is deliberately not pushed here: a recipient
///            contract could open an unsettled PoolManager balance and block every swap.)
///         3. A swap that names the pair-asset amount is charged before it runs, so it must fill in
///            full: hitting the trader's price limit early reverts (PartialFill) instead of charging
///            the fee on an amount that was never swapped.
/// @dev    No owner, no admin, no upgrade path. Bound to one factory forever. The pool's own fee is
///         zero, so the locked position earns nothing and the hook's 1% is the only charge. The
///         platform can rescue only tokens sent to the hook itself; held payouts are PoolManager claims
///         it cannot reach. Pools must use this hook's fee (0) and tick spacing (200).
contract PrintHook is IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    int24 public constant TICK_SPACING = 200; // must match BondingCurve.TICK_SPACING
    uint256 public constant FEE_BPS = 100; // 1%, same as the curve; the creator tax comes on top
    uint256 public constant TREASURY_SHARE_BPS = 3_000; // 30% of each fee; the creator gets the rest
    uint256 public constant BPS = 10_000;

    IPoolManager public immutable poolManager;
    address public immutable factory;

    struct PoolRecord {
        address curve;
        address quote; // the pair asset the fee is charged in (WETH, USDC or a StockVault share)
        uint16 creatorTaxBps; // read live from the curve on every swap (it can only go down)
        address treasury;
    }

    /// @notice poolId => the curve that created it and the treasury it pays.
    mapping(bytes32 => PoolRecord) public pools;

    /// @notice Payouts that could not be delivered inside a swap (for example to a USDC-blocked
    ///         address), held here for their recipient to claim.
    mapping(address asset => mapping(address account => uint256)) public owed;
    mapping(address asset => uint256) public totalOwed;

    event PoolRegistered(bytes32 indexed poolId, address indexed token, address indexed curve);
    /// @param creatorAmount 70% of the 1% fee plus the whole creator tax.
    event PoolFeePaid(bytes32 indexed poolId, uint256 creatorAmount, uint256 treasuryAmount);
    event Rescued(address indexed asset, address indexed to, uint256 amount);
    event PayoutDeferred(address indexed asset, address indexed to, uint256 amount);
    event PayoutClaimed(address indexed asset, address indexed to, uint256 amount);

    error NotPoolManager();
    error UnauthorizedPool();
    error HookNotImplemented();
    error OnlyPlatform();
    error NothingOwed();
    error CannotRescue();
    error ZeroAddress();
    error PartialFill();

    constructor(IPoolManager poolManager_, address factory_) {
        if (address(poolManager_) == address(0) || factory_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        factory = factory_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /* ─────────────────────────── Pool creation gate ─────────────────────────── */

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (key.fee != 0 || key.tickSpacing != TICK_SPACING || sender == address(0)) revert UnauthorizedPool();
        // Only the token's own curve, registered by the factory, may create its pool, and only against
        // the pair asset that curve was launched with.
        address token;
        address quoteAsset;
        if (IPrintFactory(factory).curveOf(c0) == sender) (token, quoteAsset) = (c0, c1);
        else if (IPrintFactory(factory).curveOf(c1) == sender) (token, quoteAsset) = (c1, c0);
        else revert UnauthorizedPool();
        if (IPrintCurve(sender).quote() != quoteAsset) revert UnauthorizedPool();

        bytes32 id = PoolId.unwrap(key.toId());
        pools[id] = PoolRecord({
            curve: sender,
            quote: quoteAsset,
            creatorTaxBps: uint16(IPrintCurve(sender).creatorTaxBps()),
            treasury: IPrintCurve(sender).treasury()
        });
        emit PoolRegistered(id, token, sender);
        return IHooks.beforeInitialize.selector;
    }

    /* ─────────────────────── 1% fee in the pair asset ─────────────────────── */

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        bytes32 id = PoolId.unwrap(key.toId());
        PoolRecord memory rec = _record(id);
        if (!_quoteIsSpecified(key, params, exactIn, rec.quote)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0); // charged in afterSwap
        }
        uint256 rate = FEE_BPS + rec.creatorTaxBps;
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 charge = _specifiedCharge(amount, rate, exactIn);
        if (charge == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _payOut(id, rec, charge);
        // Positive specified delta: the hook keeps `charge` of the specified currency (the pair asset).
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(SafeCast.toInt128(SafeCast.toInt256(charge)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool exactIn = params.amountSpecified < 0;
        bytes32 id = PoolId.unwrap(key.toId());
        PoolRecord memory rec = _record(id);
        if (_quoteIsSpecified(key, params, exactIn, rec.quote)) {
            // Charged in beforeSwap on the full specified amount: refuse a partial fill (price limit hit).
            uint256 amt = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 chg = _specifiedCharge(amt, FEE_BPS + rec.creatorTaxBps, exactIn);
            int256 expected = exactIn ? -int256(amt - chg) : int256(amt + chg);
            int128 swapped = (exactIn == params.zeroForOne) ? delta.amount0() : delta.amount1();
            if (int256(swapped) != expected) revert PartialFill();
            return (IHooks.afterSwap.selector, 0);
        }

        uint256 rate = FEE_BPS + rec.creatorTaxBps;
        int128 quoteDelta = Currency.unwrap(key.currency0) == rec.quote ? delta.amount0() : delta.amount1();
        uint256 charge;
        if (quoteDelta > 0) {
            // Trader receives the pair asset (exact-input sell): a share of the gross output.
            charge = Math.mulDiv(uint256(uint128(quoteDelta)), rate, BPS, Math.Rounding.Ceil);
        } else if (quoteDelta < 0) {
            // Trader pays the pair asset (exact-output buy): grossed up so it is a share of the total paid.
            charge = Math.mulDiv(uint256(uint128(-quoteDelta)), rate, BPS - rate, Math.Rounding.Ceil);
        }
        if (charge == 0) return (IHooks.afterSwap.selector, 0);

        _payOut(id, rec, charge);
        // Positive unspecified delta: the trader receives `charge` less, or pays `charge` more.
        return (IHooks.afterSwap.selector, SafeCast.toInt128(SafeCast.toInt256(charge)));
    }

    function _specifiedCharge(uint256 amount, uint256 rate, bool exactIn) internal pure returns (uint256) {
        return exactIn
            ? Math.mulDiv(amount, rate, BPS, Math.Rounding.Ceil) // share of what the trader pays in
            : Math.mulDiv(amount, rate, BPS - rate, Math.Rounding.Ceil); // share of the pool's gross output
    }

    /// @dev The specified currency is currency0 exactly when (exactIn == zeroForOne).
    function _quoteIsSpecified(PoolKey calldata key, SwapParams calldata params, bool exactIn, address quoteAsset)
        internal
        pure
        returns (bool)
    {
        bool specifiedIs0 = exactIn == params.zeroForOne;
        bool quoteIs0 = Currency.unwrap(key.currency0) == quoteAsset;
        return specifiedIs0 == quoteIs0;
    }

    function _record(bytes32 id) internal view returns (PoolRecord memory rec) {
        rec = pools[id];
        if (rec.curve == address(0)) revert UnauthorizedPool();
        rec.creatorTaxBps = uint16(IPrintCurve(rec.curve).creatorTaxBps());
    }

    /// @dev Pays the charge straight out of the PoolManager in the pair asset: the creator-tax part goes
    ///      to the creators and the 1% part splits 70/30. The hook's own balance delta for the charge
    ///      (credited by the returned swap delta) nets to zero against these takes.
    function _payOut(bytes32 id, PoolRecord memory rec, uint256 charge) internal {
        uint256 creatorTax = Math.mulDiv(charge, rec.creatorTaxBps, FEE_BPS + rec.creatorTaxBps);
        uint256 toTreasury = ((charge - creatorTax) * TREASURY_SHARE_BPS) / BPS;
        uint256 toCreator = charge - toTreasury; // 70% of the fee, all of the creator tax, rounding dust
        Currency quoteCurrency = Currency.wrap(rec.quote);

        if (toCreator != 0) {
            (address[] memory recipients, uint16[] memory shares) = IPrintCurve(rec.curve).feeRecipients();
            uint256 n = recipients.length;
            uint256 paid;
            for (uint256 i; i < n; ++i) {
                uint256 part = i + 1 == n ? toCreator - paid : (toCreator * shares[i]) / BPS;
                paid += part;
                if (part != 0) _send(quoteCurrency, recipients[i], part);
            }
        }
        if (toTreasury != 0) _send(quoteCurrency, rec.treasury, toTreasury);
        emit PoolFeePaid(id, toCreator, toTreasury);
    }

    /// @dev Pays `to` straight out of the PoolManager. If that transfer fails (an issuer can block
    ///      addresses, as USDC does), the failed take rolls back, the amount is taken to this hook
    ///      instead and is held for `to`, so the swap always completes.
    function _send(Currency currency, address to, uint256 amount) internal {
        try poolManager.take(currency, to, amount) {}
        catch {
            // No token transfer: works even if the issuer blocks this hook or the PM is short mid-swap.
            poolManager.mint(address(this), currency.toId(), amount);
            address asset = Currency.unwrap(currency);
            owed[asset][to] += amount;
            totalOwed[asset] += amount;
            emit PayoutDeferred(asset, to, amount);
        }
    }

    /// @notice Collect payouts this hook holds for you.
    function claim(address asset) external {
        _claim(asset, msg.sender);
    }

    /// @notice Anyone can push held payouts to their rightful owner. Funds only ever go to `to`.
    function claimFor(address asset, address to) external {
        _claim(asset, to);
    }

    function _claim(address asset, address to) internal {
        uint256 amount = owed[asset][to];
        if (amount == 0) revert NothingOwed();
        owed[asset][to] = 0;
        totalOwed[asset] -= amount;
        poolManager.unlock(abi.encode(asset, to, amount));
        emit PayoutClaimed(asset, to, amount);
    }

    /// @dev Only reachable through this hook's own unlock in _claim.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (address asset, address to, uint256 amount) = abi.decode(data, (address, address, uint256));
        Currency c = Currency.wrap(asset);
        poolManager.burn(address(this), c.toId(), amount);
        poolManager.take(c, to, amount);
        return "";
    }

    /// @notice Platform only: recover tokens sent to the hook by mistake. Payouts held for recipients
    ///         are excluded, so the platform can never take them.
    function rescue(address asset, address to, uint256 amount) external {
        if (msg.sender != IPrintFactory(factory).owner()) revert OnlyPlatform();
        if (to == address(0) || amount > IERC20(asset).balanceOf(address(this))) { // held payouts are 6909 claims
            revert CannotRescue();
        }
        SafeERC20.safeTransfer(IERC20(asset), to, amount);
        emit Rescued(asset, to, amount);
    }

    /* ─────────── Callbacks this hook does not enable (PoolManager never calls them) ─────────── */

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
