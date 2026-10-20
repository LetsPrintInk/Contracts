// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v6 — UNAUDITED.
// Build: solc 0.8.26+, via_ir = true, evm_version = "cancun", OpenZeppelin Contracts v5.x, and
// Uniswap v4-core + v4-periphery pinned to the release that matches the PoolManager deployed on Ink
// (this code uses the src/types/PoolOperation.sol struct layout).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

import {TokenTemplate, TokenMetadata} from "./TokenTemplate.sol";

interface IOwned {
    function owner() external view returns (address);
}

interface ITokenDeployer {
    function deploy(TokenMetadata calldata meta) external returns (TokenTemplate);
}

/// @notice Settings the factory copies into every curve at launch. A curve never reads the factory
///         again (except to check who the platform owner is for rescue), so no later owner action can
///         change a launched token.
struct CurveConfig {
    address factory; // the LaunchpadFactory; its owner is the platform (read only by rescue)
    address tokenDeployer; // creates this launch's token while the curve is being constructed
    address quote; // the pair asset: WETH for ETH launches, native USDC, or a StockVault wrapping an xStock
    address poolManager; // Uniswap v4 PoolManager on Ink
    address hook; // PrintHook bound to this factory
    address treasury; // Letsprint.ink treasury (a Safe)
    uint256 graduationAmount; // R, in quote units: what the curve holds when its last token sells
}

/// @title  Letsprint.ink BondingCurve
/// @notice One curve per launch, priced in one pair asset (WETH, native USDC, or a non-rebasing
///         StockVault share wrapping an xStock). Sells 800M tokens on a constant-product virtual-reserve curve, pays the
///         1% fee 70/30 to creators/treasury plus any creator tax (0–10%, all to the creators) inside
///         every trade, slows snipers with a buy tax that fades to zero in 5 seconds, and graduates into
///         a full-range Uniswap v4 pool whose position this contract holds forever.
/// @dev    No owner, admin, pause or upgrade path. The current `creator` (a role only the creator can
///         hand on) can only: lower the creator tax (never raise it), choose up to 5 wallets that share
///         the creator fees, and update the token's social links. The platform can only rescue
///         unrelated tokens sent here by mistake, never this token or the pair asset.
///         Payouts never block a trade: if a transfer to a fee recipient fails (for example, USDC has
///         blocked the recipient), the amount is kept for that recipient to claim().
///         ETH, USDC and xStock users can trade through LaunchRouter, which wraps and unwraps for them.
contract BondingCurve is ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /* ─────────────────────────── Constants ─────────────────────────── */

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether; // S
    uint256 public constant LP_SUPPLY = 200_000_000 ether; // L

    uint256 public constant FEE_BPS = 100; // 1% on every buy and sell, on the curve and in the pool
    uint256 public constant TREASURY_SHARE_BPS = 3_000; // 30% of each fee; the creators get the rest
    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_CREATOR_TAX_BPS = 1_000; // 10%

    /// @notice Launch tax on buys: 98% at launch (less the creator tax), quartering every second, zero
    ///         from second 5. With the 1% fee and any creator tax, a buyer always keeps at least 1%.
    ///         The creator and declared team wallets are exempt.
    uint256 public constant SNIPE_WINDOW = 5; // seconds after launch
    uint256 public constant SNIPE_TAX_START_BPS = 9_800;
    uint256 public constant MAX_TEAM_WALLETS = 16;
    uint256 public constant MAX_FEE_RECIPIENTS = 5;

    int24 public constant TICK_SPACING = 200;
    uint256 public constant MIN_GRADUATION_GAS = 600_000; // calibrate on an Ink fork

    /* ─────────────────────────── Immutables ─────────────────────────── */

    TokenTemplate public immutable token;
    IERC20 public immutable quote;
    IPoolManager public immutable poolManager;
    address public immutable hook;
    address public immutable treasury;
    address public immutable factory;
    address public immutable launcher; // the creator at launch; exempt from the launch tax
    uint256 public immutable launchedAt;
    uint256 public immutable graduationAmount; // R, in quote units
    uint256 public immutable initialVirtualQuote; // x0 = R·L / (S − L)
    uint256 public immutable initialVirtualToken; // y0 = S² / (S − L)

    /* ─────────────────────────── State ─────────────────────────── */

    address public creator;
    /// @notice 0–1,000 (10%). Set at launch; the creator can only ever lower it.
    uint256 public creatorTaxBps;
    address[] internal _feeRecipients; // the creator side of every fee is split across these
    uint16[] internal _feeShares; // basis points, summing to 10,000
    uint256 public virtualQuoteReserve; // x
    uint256 public virtualTokenReserve; // y
    uint256 public realQuoteReserve; // pair asset backing the curve; fees and owed payouts excluded
    uint256 public realTokenReserve; // tokens still for sale
    bool public complete; // curve sold out; its reserves now belong to the pool
    bool public graduated; // pool created and seeded

    mapping(address => bool) public isTeamWallet;
    /// @notice Payouts a recipient could not receive in-trade, claimable at any time.
    mapping(address => uint256) public owed;
    uint256 public totalOwed;

    struct BuyQuote {
        uint256 tokensOut;
        uint256 quoteIn; // pair asset entering the reserves
        uint256 fee; // 1% trading fee
        uint256 creatorTax; // optional creator tax, all to the creators
        uint256 snipeTax; // launch tax, 0 after the first 5 seconds or for exempt recipients
        uint256 refund;
        bool completes;
    }

    /* ─────────────────────────── Events & errors ─────────────────────────── */

    event CurveSwapped(
        address indexed token,
        address indexed trader,
        address indexed recipient,
        bool isBuy,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 creatorTax,
        uint256 snipeTax,
        uint256 virtualQuote,
        uint256 virtualToken,
        uint256 realQuote
    );
    event CurveCompleted(address indexed token, uint256 raised);
    event GraduationDeferred(address indexed token);
    event TokenGraduated(
        address indexed token, bytes32 indexed poolId, uint256 quoteLiquidity, uint256 tokenLiquidity, uint128 liquidity
    );
    event CreatorUpdated(address indexed previousCreator, address indexed newCreator);
    event CreatorTaxLowered(uint256 previousBps, uint256 newBps);
    event FeeRecipientsUpdated(address[] recipients, uint16[] sharesBps);
    /// @notice Optional referral tag on a trade. Nothing is paid out; it lets referrals start later.
    event Referral(address indexed trader, bytes32 indexed ref, bool isBuy, uint256 quoteAmount);
    event PayoutDeferred(address indexed to, uint256 amount);
    event PayoutClaimed(address indexed to, uint256 amount);
    event Rescued(address indexed asset, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidConfig();
    error TooManyTeamWallets();
    error CreatorTaxTooHigh();
    error Expired();
    error CurveComplete();
    error NotReadyToGraduate();
    error InsufficientGasToGraduate();
    error SlippageExceeded();
    error OnlyCreator();
    error OnlyPoolManager();
    error InvalidFeeSplit();
    error TaxCanOnlyDecrease();
    error OnlyPlatform();
    error CannotRescue();
    error NothingOwed();

    /* ─────────────────────────── Launch ─────────────────────────── */

    constructor(
        address creator_,
        TokenMetadata memory meta,
        uint256 creatorTaxBps_,
        address[] memory teamWallets,
        address[] memory feeRecipients_,
        uint16[] memory feeShares_,
        CurveConfig memory cfg
    ) {
        if (
            creator_ == address(0) || cfg.factory == address(0) || cfg.tokenDeployer == address(0)
                || cfg.quote == address(0) || cfg.poolManager == address(0) || cfg.hook == address(0)
                || cfg.treasury == address(0)
        ) revert ZeroAddress();
        if (teamWallets.length > MAX_TEAM_WALLETS) revert TooManyTeamWallets();
        if (creatorTaxBps_ > MAX_CREATOR_TAX_BPS) revert CreatorTaxTooHigh();

        // The token mints its entire supply to this contract. Its code lives in the TokenDeployer,
        // which only answers while the CurveDeployer is constructing a curve.
        TokenTemplate t = ITokenDeployer(cfg.tokenDeployer).deploy(meta);
        if (t.balanceOf(address(this)) != TOTAL_SUPPLY) revert InvalidConfig();

        // Virtual reserves that sell exactly S tokens for R and end at the pool's opening price R / L.
        uint256 x0 = Math.mulDiv(cfg.graduationAmount, LP_SUPPLY, CURVE_SUPPLY - LP_SUPPLY);
        uint256 y0 = Math.mulDiv(CURVE_SUPPLY, CURVE_SUPPLY, CURVE_SUPPLY - LP_SUPPLY);
        if (x0 == 0) revert InvalidConfig();

        token = t;
        quote = IERC20(cfg.quote);
        poolManager = IPoolManager(cfg.poolManager);
        hook = cfg.hook;
        treasury = cfg.treasury;
        factory = cfg.factory;
        launcher = creator_;
        launchedAt = block.timestamp;
        graduationAmount = cfg.graduationAmount;
        initialVirtualQuote = x0;
        initialVirtualToken = y0;

        creator = creator_;
        creatorTaxBps = creatorTaxBps_;
        if (feeRecipients_.length == 0) {
            address[] memory soloRecipient = new address[](1);
            uint16[] memory soloShare = new uint16[](1);
            soloRecipient[0] = creator_;
            soloShare[0] = uint16(BPS);
            _setFeeRecipients(soloRecipient, soloShare);
        } else {
            _setFeeRecipients(feeRecipients_, feeShares_);
        }
        virtualQuoteReserve = x0;
        virtualTokenReserve = y0;
        realTokenReserve = CURVE_SUPPLY;

        isTeamWallet[creator_] = true;
        for (uint256 i; i < teamWallets.length; ++i) {
            isTeamWallet[teamWallets[i]] = true;
        }
    }

    /* ─────────────────────────── Trading ─────────────────────────── */

    /// @notice Buy tokens with the pair asset (approve it first, or use LaunchRouter). The buy that
    ///         takes the last curve token pays only for what is left, is refunded the rest, and
    ///         graduates the token in the same transaction (it reverts if sent without the gas for that).
    /// @param recipient Receives the tokens; the launch tax is keyed on it. Refunds go to msg.sender.
    /// @param ref       Optional referral tag (bytes32(0) for none). Recorded in an event only.
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient, uint256 deadline, bytes32 ref)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (complete) revert CurveComplete();
        if (recipient == address(0)) revert ZeroAddress();
        if (quoteIn == 0) revert ZeroAmount();

        // The pair asset is WETH, USDC or a factory-deployed StockVault: no transfer fees, exact amounts.
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);

        BuyQuote memory q = _quoteBuy(quoteIn, snipeTaxBps(recipient));
        tokensOut = q.tokensOut;
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert SlippageExceeded();

        // Effects
        virtualQuoteReserve += q.quoteIn;
        virtualTokenReserve -= tokensOut;
        realQuoteReserve += q.quoteIn;
        realTokenReserve -= tokensOut;
        if (q.completes) complete = true;

        // Interactions
        IERC20(address(token)).safeTransfer(recipient, tokensOut);
        _distribute(q.fee + q.snipeTax, q.creatorTax);
        _emitSwap(msg.sender, recipient, true, q.quoteIn, tokensOut, q.fee, q.creatorTax, q.snipeTax);
        if (ref != bytes32(0)) emit Referral(msg.sender, ref, true, q.quoteIn);

        if (q.completes) {
            emit CurveCompleted(address(token), realQuoteReserve);
            // Graduation happens here. A buy without the gas for it reverts rather than leaving the token
            // stuck between curve and pool, so wallets' gas estimates always include it. Only a buy made
            // from inside a PoolManager unlock (which cannot open the pool itself) leaves it to graduate().
            if (TransientStateLibrary.isUnlocked(poolManager)) emit GraduationDeferred(address(token));
            else if (gasleft() < MIN_GRADUATION_GAS) revert InsufficientGasToGraduate();
            else _graduate();
        }
        if (q.refund != 0) quote.safeTransfer(msg.sender, q.refund);
    }

    /// @notice Sell tokens for the pair asset. Requires a prior approval; see sellWithPermit.
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient, uint256 deadline, bytes32 ref)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        quoteOut = _sell(tokensIn, minQuoteOut, recipient, deadline, ref);
    }

    /// @notice Sell using an EIP-2612 signature instead of a separate approve transaction.
    function sellWithPermit(
        uint256 tokensIn,
        uint256 minQuoteOut,
        address recipient,
        uint256 deadline,
        bytes32 ref,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant returns (uint256 quoteOut) {
        // If a griefer front-runs the permit it reverts here, but the allowance is already set.
        try IERC20Permit(address(token)).permit(msg.sender, address(this), tokensIn, permitDeadline, v, r, s) {}
            catch {}
        quoteOut = _sell(tokensIn, minQuoteOut, recipient, deadline, ref);
    }

    /// @notice Finish a graduation the final buy could not do itself (only when that buy was made from
    ///         inside a PoolManager unlock). Anyone can call it.
    function graduate() external nonReentrant {
        if (!complete || graduated) revert NotReadyToGraduate();
        _graduate();
    }

    /// @notice Collect payouts held for you: the treasury's accrued share, or any creator payout that
    ///         could not be delivered inside a trade.
    function claim() external nonReentrant {
        _claim(msg.sender);
    }

    /// @notice Anyone can push held payouts to their rightful owner, so a keeper can sweep the
    ///         treasury's share across many curves. Funds only ever go to `to`.
    function claimFor(address to) external nonReentrant {
        _claim(to);
    }

    /* ─────────────────────────── Creator controls ─────────────────────────── */

    /// @notice Hand the creator role to a new address. Only the current creator.
    function setCreator(address newCreator) external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();
        if (newCreator == address(0)) revert ZeroAddress();
        emit CreatorUpdated(creator, newCreator);
        creator = newCreator;
    }

    /// @notice Lower the creator tax. It can never be raised again. Only the current creator.
    function lowerCreatorTax(uint256 newBps) external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();
        if (newBps >= creatorTaxBps) revert TaxCanOnlyDecrease();
        emit CreatorTaxLowered(creatorTaxBps, newBps);
        creatorTaxBps = newBps;
    }

    /// @notice Split the creator side of every fee across up to 5 wallets (shares in bps, summing to
    ///         10,000). Only the current creator. Applies on the curve and, through PrintHook, in the pool.
    function setFeeRecipients(address[] calldata recipients, uint16[] calldata sharesBps) external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();
        _setFeeRecipients(recipients, sharesBps);
    }

    /// @notice Platform only: recover unrelated tokens sent here by mistake. Never this token or the
    ///         pair asset, so reserves, owed payouts and graduation funds are untouchable.
    function rescue(address asset, address to, uint256 amount) external nonReentrant {
        if (msg.sender != IOwned(factory).owner()) revert OnlyPlatform();
        if (asset == address(token) || asset == address(quote) || asset == address(0) || to == address(0)) {
            revert CannotRescue();
        }
        IERC20(asset).safeTransfer(to, amount);
        emit Rescued(asset, to, amount);
    }

    /* ─────────────────────────── Views ─────────────────────────── */

    function feeRecipients() external view returns (address[] memory recipients, uint16[] memory sharesBps) {
        return (_feeRecipients, _feeShares);
    }

    /// @notice Current launch tax for a buy delivered to `recipient`, in basis points.
    function snipeTaxBps(address recipient) public view returns (uint256) {
        if (isTeamWallet[recipient]) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed >= SNIPE_WINDOW) return 0;
        uint256 rate = SNIPE_TAX_START_BPS >> (2 * elapsed);
        uint256 cap = SNIPE_TAX_START_BPS - creatorTaxBps; // a buyer always keeps at least 1%
        return rate < cap ? rate : cap;
    }

    /// @notice Exactly what buy() would do with `quoteInGross` for `recipient` right now.
    function quoteBuy(uint256 quoteInGross, address recipient)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 creatorTax, uint256 snipeTax, uint256 refund, bool completes)
    {
        if (complete) return (0, 0, 0, 0, quoteInGross, false);
        BuyQuote memory q = _quoteBuy(quoteInGross, snipeTaxBps(recipient));
        return (q.tokensOut, q.fee, q.creatorTax, q.snipeTax, q.refund, q.completes);
    }

    /// @notice Gross pair asset that buys at least `tokensOut` (capped at the tokens left).
    function quoteBuyExactTokens(uint256 tokensOut, address recipient) external view returns (uint256 grossQuote) {
        if (complete) return 0;
        uint256 remaining = realTokenReserve;
        if (tokensOut > remaining) tokensOut = remaining;
        uint256 quoteIn =
            Math.mulDiv(virtualQuoteReserve, tokensOut, virtualTokenReserve - tokensOut, Math.Rounding.Ceil);
        uint256 deductBps = FEE_BPS + creatorTaxBps + snipeTaxBps(recipient);
        // The +1 absorbs the fee's round-up, so this amount always buys at least `tokensOut`.
        grossQuote = Math.mulDiv(quoteIn + 1, BPS, BPS - deductBps, Math.Rounding.Ceil);
    }

    /// @notice Exactly what sell() would pay for `tokensIn` right now.
    function quoteSell(uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee, uint256 creatorTax) {
        if (complete) return (0, 0, 0);
        uint256 grossQuote;
        (grossQuote, fee, creatorTax) = _quoteSell(tokensIn);
        quoteOut = grossQuote - fee - creatorTax;
    }

    /// @notice Spot price in quote units per whole token. After graduation, read the pool instead.
    function spotPrice() external view returns (uint256) {
        return Math.mulDiv(virtualQuoteReserve, 1 ether, virtualTokenReserve);
    }

    /// @notice Market cap in quote units at the spot price, using the live supply (reflects burns).
    function marketCap() external view returns (uint256) {
        return Math.mulDiv(virtualQuoteReserve, IERC20(address(token)).totalSupply(), virtualTokenReserve);
    }

    /// @notice Share of the curve sold, in basis points (10,000 = sold out).
    function progressBps() external view returns (uint256) {
        return ((CURVE_SUPPLY - realTokenReserve) * BPS) / CURVE_SUPPLY;
    }

    /// @notice All curve state in one call.
    function curveState()
        external
        view
        returns (uint256 vQuote, uint256 vToken, uint256 rQuote, uint256 rToken, bool isComplete, bool isGraduated)
    {
        return (virtualQuoteReserve, virtualTokenReserve, realQuoteReserve, realTokenReserve, complete, graduated);
    }

    /// @notice The Uniswap v4 pool this token graduates into. Deterministic from launch.
    function poolKey() public view returns (PoolKey memory key) {
        address q = address(quote);
        (address c0, address c1) = q < address(token) ? (q, address(token)) : (address(token), q);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0, // the pool charges nothing itself; PrintHook charges the 1% and splits it
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    function poolId() public view returns (bytes32) {
        return PoolId.unwrap(poolKey().toId());
    }

    /* ─────────────────────────── Graduation ─────────────────────────── */

    /// @dev Creates and seeds the pool inside one PoolManager unlock. Only this curve can create its
    ///      pool (PrintHook.beforeInitialize), and creation and seeding happen in the same call, so
    ///      there is no moment anyone can pre-seed or move the price.
    function _graduate() internal {
        graduated = true;
        uint256 quoteAmount = realQuoteReserve;
        realQuoteReserve = 0;
        (uint128 liquidity, uint256 quoteUsed, uint256 tokensUsed) =
            abi.decode(poolManager.unlock(abi.encode(quoteAmount)), (uint128, uint256, uint256));
        emit TokenGraduated(address(token), poolId(), quoteUsed, tokensUsed, liquidity);
    }

    /// @dev PoolManager callback during graduation. Opens the pool at exactly the curve's final price
    ///      and adds one full-range position owned by this contract. This contract has no function
    ///      that removes liquidity, so the position is locked forever. Rounding dust stays here.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        uint256 quoteAmount = abi.decode(data, (uint256));

        PoolKey memory key = poolKey();
        bool quoteIs0 = Currency.unwrap(key.currency0) == address(quote);
        (uint256 amount0, uint256 amount1) = quoteIs0 ? (quoteAmount, LP_SUPPLY) : (LP_SUPPLY, quoteAmount);

        // price = amount1 / amount0 in raw units; sqrtPriceX96 = sqrt(price) · 2^96.
        uint160 sqrtPriceX96 = uint160(Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)));
        poolManager.initialize(key, sqrtPriceX96);

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), amount0, amount1
        );

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        uint256 paid0 = uint256(uint128(-delta.amount0()));
        uint256 paid1 = uint256(uint128(-delta.amount1()));
        _settle(key.currency0, paid0);
        _settle(key.currency1, paid1);

        (uint256 quoteUsed, uint256 tokensUsed) = quoteIs0 ? (paid0, paid1) : (paid1, paid0);
        return abi.encode(liquidity, quoteUsed, tokensUsed);
    }

    function _settle(Currency currency, uint256 amount) internal {
        if (amount == 0) return;
        poolManager.sync(currency);
        IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    /* ─────────────────────────── Internals ─────────────────────────── */

    /// @dev Buy math shared by buy() and quoteBuy(). Every rounding favours the curve.
    function _quoteBuy(uint256 value, uint256 snipeBps) internal view returns (BuyQuote memory q) {
        uint256 x = virtualQuoteReserve;
        uint256 y = virtualTokenReserve;
        uint256 remaining = realTokenReserve;
        uint256 deductBps = FEE_BPS + creatorTaxBps + snipeBps; // at most 9,900: a buyer keeps >= 1%

        uint256 charge = Math.mulDiv(value, deductBps, BPS, Math.Rounding.Ceil);
        q.quoteIn = value - charge;
        q.tokensOut = Math.mulDiv(y, q.quoteIn, x + q.quoteIn);

        if (q.tokensOut >= remaining) {
            // Final buy: take exactly what is left, charge exactly its cost, refund the rest.
            q.completes = true;
            q.tokensOut = remaining;
            q.quoteIn = Math.mulDiv(x, remaining, y - remaining, Math.Rounding.Ceil);
            uint256 gross = Math.mulDiv(q.quoteIn, BPS, BPS - deductBps, Math.Rounding.Ceil);
            charge = gross - q.quoteIn;
            q.refund = value - gross;
        }
        // Split the charge pro rata; the trading fee absorbs the rounding.
        q.snipeTax = Math.mulDiv(charge, snipeBps, deductBps);
        q.creatorTax = Math.mulDiv(charge, creatorTaxBps, deductBps);
        q.fee = charge - q.snipeTax - q.creatorTax;
    }

    /// @dev Sell math shared by sell() and quoteSell(): output rounded down, charges rounded up.
    ///      Sells pay the fee and any creator tax, never the launch tax.
    function _quoteSell(uint256 tokensIn) internal view returns (uint256 grossQuote, uint256 fee, uint256 creatorTax) {
        grossQuote = Math.mulDiv(virtualQuoteReserve, tokensIn, virtualTokenReserve + tokensIn);
        uint256 deductBps = FEE_BPS + creatorTaxBps;
        uint256 charge = Math.mulDiv(grossQuote, deductBps, BPS, Math.Rounding.Ceil);
        creatorTax = Math.mulDiv(charge, creatorTaxBps, deductBps);
        fee = charge - creatorTax;
    }

    function _sell(uint256 tokensIn, uint256 minQuoteOut, address recipient, uint256 deadline, bytes32 ref)
        internal
        returns (uint256 quoteOut)
    {
        if (block.timestamp > deadline) revert Expired();
        if (complete) revert CurveComplete(); // the curve's reserves now belong to the pool
        if (recipient == address(0)) revert ZeroAddress();
        if (tokensIn == 0) revert ZeroAmount();

        (uint256 grossQuote, uint256 fee, uint256 creatorTax) = _quoteSell(tokensIn);
        if (grossQuote == 0) revert ZeroAmount();
        quoteOut = grossQuote - fee - creatorTax;
        if (quoteOut < minQuoteOut) revert SlippageExceeded();

        // Effects. realQuoteReserve cannot underflow: k never decreases and holders can never return
        // more tokens than the curve sold (checked arithmetic backs this up).
        virtualQuoteReserve -= grossQuote;
        virtualTokenReserve += tokensIn;
        realQuoteReserve -= grossQuote;
        realTokenReserve += tokensIn;

        // Interactions
        IERC20(address(token)).safeTransferFrom(msg.sender, address(this), tokensIn);
        _distribute(fee, creatorTax);
        _emitSwap(msg.sender, recipient, false, grossQuote, tokensIn, fee, creatorTax, 0);
        if (ref != bytes32(0)) emit Referral(msg.sender, ref, false, grossQuote);
        quote.safeTransfer(recipient, quoteOut);
    }

    /// @dev Paid inside the trade: the fee pool (1% fee plus any launch tax) splits 70/30, and the
    ///      creator tax goes entirely to the creator side, which is split across the fee recipients by
    ///      share (the last recipient absorbs rounding dust).
    function _distribute(uint256 feePool, uint256 creatorTax) internal {
        uint256 toTreasury = (feePool * TREASURY_SHARE_BPS) / BPS;
        uint256 toCreators = feePool - toTreasury + creatorTax;
        // The treasury's share accrues here and is collected with claim(): saves a transfer per trade.
        if (toTreasury != 0) {
            owed[treasury] += toTreasury;
            totalOwed += toTreasury;
        }
        uint256 n = _feeRecipients.length;
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            uint256 part = i + 1 == n ? toCreators - paid : (toCreators * _feeShares[i]) / BPS;
            paid += part;
            _pay(_feeRecipients[i], part);
        }
    }

    /// @dev Transfers the pair asset without letting a failed transfer block the trade. The quote is
    ///      WETH, USDC or a StockVault share: ERC-20s that never call the recipient and return at most
    ///      one word, so the call is bounded. A blocked or failing recipient is credited to `owed`.
    function _pay(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory ret) = address(quote).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) {
            owed[to] += amount;
            totalOwed += amount;
            emit PayoutDeferred(to, amount);
        }
    }

    function _claim(address to) internal {
        uint256 amount = owed[to];
        if (amount == 0) revert NothingOwed();
        owed[to] = 0;
        totalOwed -= amount;
        quote.safeTransfer(to, amount);
        emit PayoutClaimed(to, amount);
    }

    function _setFeeRecipients(address[] memory recipients, uint16[] memory sharesBps) internal {
        uint256 n = recipients.length;
        if (n == 0 || n > MAX_FEE_RECIPIENTS || sharesBps.length != n) revert InvalidFeeSplit();
        uint256 total;
        for (uint256 i; i < n; ++i) {
            if (recipients[i] == address(0) || sharesBps[i] == 0) revert InvalidFeeSplit();
            total += sharesBps[i];
        }
        if (total != BPS) revert InvalidFeeSplit();
        _feeRecipients = recipients;
        _feeShares = sharesBps;
        emit FeeRecipientsUpdated(recipients, sharesBps);
    }

    function _emitSwap(
        address trader,
        address recipient,
        bool isBuy,
        uint256 quoteAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 creatorTax,
        uint256 snipeTax
    ) internal {
        emit CurveSwapped(
            address(token),
            trader,
            recipient,
            isBuy,
            quoteAmount,
            tokenAmount,
            fee,
            creatorTax,
            snipeTax,
            virtualQuoteReserve,
            virtualTokenReserve,
            realQuoteReserve
        );
    }
}
