// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v6 — UNAUDITED. Build settings are listed at the top of BondingCurve.sol.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BondingCurve, CurveConfig} from "./BondingCurve.sol";
import {TokenMetadata} from "./TokenTemplate.sol";
import {CurveDeployer} from "./Deployers.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IStockVaultDeployer {
    function deploy(address xStock) external returns (address);
    function vaultOf(address xStock) external view returns (address);
    function seedAmount(address xStock) external view returns (uint256);
}

interface IPrintHookInfo {
    function factory() external view returns (address);
    function poolManager() external view returns (address);
}

/// @notice Deployment settings (a struct keeps the constructor's stack shallow).
struct FactoryInit {
    address owner; // TimelockController (48h) run by the team Safe
    address weth; // 0x4200000000000000000000000000000000000006 on Ink
    address poolManager; // Uniswap v4 PoolManager on Ink: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32
    address vaultDeployer; // StockVaultDeployer
    address treasury; // team Safe
    address usdc; // native USDC on Ink: 0x2D270e6886d130D724215A266106e6832161EAEd; address(0) = no USDC pair
    uint256 deployFee; // anti-spam fee in wei
    uint256 graduationEth; // R for ETH pairs, e.g. 5 ether
    uint256 graduationUsdc; // R for USDC pairs in 6-decimal units, e.g. 12_800e6
    uint256[4] promoPrices; // Spotlight prices per tier, in wei
}

/// @notice Everything a launch needs besides its metadata (a struct keeps the call stack shallow).
struct LaunchParams {
    address quote; // pair asset: WETH, USDC, or an approved StockVault wrapping an xStock
    uint256 firstBuyAmount; // USDC and stock pairs: the creator's first buy, in USDC or the xStock (approve first)
    uint256 creatorTaxBps; // 0–1,000 (10%); the creator can only ever lower it later
    address[] teamWallets; // up to 16, exempt from the launch tax and labelled "team"
    address[] feeRecipients; // up to 5 wallets sharing the creator's fees; empty = the creator alone
    uint16[] feeShares; // basis points per recipient, summing to 10,000
    bytes32 salt; // any value; mixed with msg.sender so a mined vanity salt cannot be front-run
    bytes32 expectedTerms; // launchTermsHash() as read when the creator was quoted
}

/// @title  Letsprint.ink LaunchpadFactory
/// @notice Deploys one TokenTemplate + BondingCurve per launch, collects the anti-spam deploy fee,
///         and sells homepage Spotlight promotions. The curve and token code live in a CurveDeployer
///         and TokenDeployer that this factory creates in its constructor (keeping every contract
///         under the 24 KB size limit); only this factory can launch through them.
/// @dev    Owned (two-step). Make the owner a TimelockController (48h) controlled by a Safe. Its reach:
///         - Settings apply to future launches only: each curve copies them into immutables at creation.
///         - The hook is set once and can never change, so no owner can redirect launches.
///         - Pair assets are only ever WETH, the USDC address fixed at deployment, or vaults from the
///           immutable StockVaultDeployer. The owner can add stock pairs, retarget or disable pairs, and
///           tune the deploy fee, promotion prices and treasury within
///           hard caps, pause new launches, and rescue tokens sent
///           here by mistake. It cannot touch trading fees, mint, pause trading or move user funds.
///         - Creators pass `expectedTerms`, so a settings change between quote and launch reverts.
///         New features ship as a new factory version, listed in the LaunchpadRegistry.
contract LaunchpadFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.2.0";

    enum PromoTier {
        OneHour,
        ThreeHours,
        NineHours,
        OneDay
    }

    uint256 public constant MIN_GRADUATION_ETH = 0.5 ether;
    uint256 public constant MAX_GRADUATION_ETH = 100 ether;
    uint256 public constant MIN_GRADUATION_USDC = 1_000e6; // $1,000
    uint256 public constant MAX_GRADUATION_USDC = 250_000e6; // $250,000
    uint256 public constant MAX_DEPLOY_FEE = 0.05 ether;
    uint256 public constant MIN_STOCK_R_SHARES = 1e15; // vault-share bounds for a stock pair's R
    uint256 public constant MAX_STOCK_R_SHARES = 1e33;
    uint256 public constant MAX_PROMO_PRICE = 10 ether;

    address public immutable weth; // 0x4200000000000000000000000000000000000006 on Ink
    address public immutable poolManager; // Uniswap v4 PoolManager on Ink
    address public immutable vaultDeployer; // StockVaultDeployer: the only source of stock-pair vaults
    address public immutable usdc; // native USDC, or address(0) if this deployment has no USDC pair
    CurveDeployer public immutable curveDeployer; // created here; only this factory can use it
    address public immutable tokenDeployer; // created by the CurveDeployer; only its curves can use it

    address public hook; // PrintHook for this factory; set once, then fixed forever
    address public treasury;
    uint256 public deployFee;
    uint256[4] public promoPrices; // per PromoTier, in wei
    bool public launchesPaused; // stops createToken only; existing curves keep trading and graduating

    mapping(address token => address curve) public curveOf;
    mapping(address curve => bool) public isCurve;
    mapping(address token => uint64) public promotedUntil; // Spotlight end time; slots are unlimited

    /// @notice Approved pair assets. WETH (and USDC, if set) are approved at deployment; xStock pairs
    ///         use one StockVault per stock. Changes apply to future launches only.
    struct QuoteConfig {
        bool enabled;
        bool isStockVault;
        uint256 graduationAmount; // R in this asset's units
    }

    mapping(address quote => QuoteConfig) public quoteConfig;
    address[] public quoteAssets;
    uint256 public tokenCount;

    event TokenCreated(
        address indexed token,
        address indexed curve,
        address indexed creator,
        bytes32 poolId,
        address hook,
        address quote,
        uint256 graduationAmount,
        uint256 creatorTaxBps,
        TokenMetadata metadata
    );
    event TeamWalletsDeclared(address indexed token, address[] wallets);
    event TokenPromoted(
        address indexed token, address indexed payer, PromoTier tier, uint64 startsAt, uint64 endsAt, uint256 paid
    );
    event ConfigUpdated(
        address hook,
        address treasury,
        uint256 deployFee,
        uint256[4] promoPrices,
        bool launchesPaused
    );
    event QuoteAssetSet(address indexed quote, bool enabled, bool isStockVault, uint256 graduationAmount);
    event StockPairAdded(address indexed xStock, address indexed vault, uint256 graduationAmount);
    event Rescued(address indexed asset, address indexed to, uint256 amount);

    error ZeroAddress();
    error InvalidConfig();
    error HookAlreadySet();
    error HookNotSet();
    error LaunchesPaused();
    error LaunchTermsChanged();
    error InsufficientDeployFee();
    error InvalidMetadata();
    error UnknownToken();
    error WrongPromoPayment();
    error DirectEthRejected();
    error PairNotApproved();
    error WrongFirstBuy();
    error CannotRenounce();

    constructor(FactoryInit memory init) Ownable(init.owner) {
        if (init.weth == address(0) || init.poolManager == address(0) || init.vaultDeployer == address(0)) {
            revert ZeroAddress();
        }
        weth = init.weth;
        poolManager = init.poolManager;
        vaultDeployer = init.vaultDeployer;
        usdc = init.usdc;
        CurveDeployer cd = new CurveDeployer();
        curveDeployer = cd;
        tokenDeployer = address(cd.tokenDeployer());
        _setTreasury(init.treasury);
        _setQuoteAsset(init.weth, true, false, init.graduationEth);
        if (init.usdc != address(0)) {
            // The USDC bounds assume 6 decimals; refuse anything else.
            if (IERC20Metadata(init.usdc).decimals() != 6) revert InvalidConfig();
            _setQuoteAsset(init.usdc, true, false, init.graduationUsdc);
        }
        _setDeployFee(init.deployFee);
        _setPromoPrices(init.promoPrices);
        _emitConfig();
    }

    /* ─────────────────────────── Launch ─────────────────────────── */

    /// @notice Hash of the terms a launch will get right now. Pass it as LaunchParams.expectedTerms.
    function launchTermsHash(address quote) public view returns (bytes32) {
        return keccak256(
            abi.encode(VERSION, hook, deployFee, treasury, quote, quoteConfig[quote].graduationAmount)
        );
    }

    /// @notice Launch a token. Send `deployFee` in ETH. The creator's optional first buy executes inside
    ///         this transaction, untaxed, before anyone else can trade: on ETH pairs send it as extra
    ///         ETH; on USDC and stock pairs approve this contract and pass `firstBuyAmount`.
    function createToken(TokenMetadata calldata meta, LaunchParams calldata p)
        external
        payable
        nonReentrant
        returns (address token, address curve)
    {
        if (launchesPaused) revert LaunchesPaused();
        if (hook == address(0)) revert HookNotSet();
        QuoteConfig memory qc = quoteConfig[p.quote];
        if (!qc.enabled) revert PairNotApproved();
        if (p.expectedTerms != launchTermsHash(p.quote)) revert LaunchTermsChanged();
        uint256 fee = deployFee;
        if (msg.value < fee) revert InsufficientDeployFee();
        // ETH pairs buy with the ETH sent above the fee; USDC and stock pairs buy with firstBuyAmount.
        bool ethPair = p.quote == weth;
        if (ethPair ? p.firstBuyAmount != 0 : msg.value != fee) revert WrongFirstBuy();
        _validate(meta);

        CurveConfig memory cfg = CurveConfig({
            factory: address(this),
            tokenDeployer: tokenDeployer,
            quote: p.quote,
            poolManager: poolManager,
            hook: hook,
            treasury: treasury,
            graduationAmount: qc.graduationAmount
        });

        BondingCurve c = curveDeployer.deploy(
            keccak256(abi.encode(msg.sender, p.salt)),
            msg.sender,
            meta,
            p.creatorTaxBps,
            p.teamWallets,
            p.feeRecipients,
            p.feeShares,
            cfg
        );
        curve = address(c);
        token = address(c.token());

        // Registered before any trade: PrintHook checks curveOf() when the pool is created.
        curveOf[token] = curve;
        isCurve[curve] = true;
        unchecked {
            ++tokenCount;
        }

        emit TokenCreated(
            token,
            curve,
            msg.sender,
            c.poolId(),
            cfg.hook,
            cfg.quote,
            cfg.graduationAmount,
            p.creatorTaxBps,
            meta
        );
        if (p.teamWallets.length != 0) emit TeamWalletsDeclared(token, p.teamWallets);

        if (ethPair) {
            if (msg.value > fee) _firstBuyETH(c, msg.value - fee);
        } else if (p.firstBuyAmount != 0) {
            if (qc.isStockVault) _firstBuyStock(c, IERC4626(p.quote), p.firstBuyAmount);
            else _firstBuyToken(c, IERC20(p.quote), p.firstBuyAmount);
        }
        // Last, so no outside code runs between registering the curve and the creator's first buy.
        if (fee != 0) Address.sendValue(payable(cfg.treasury), fee);
    }

    /* ─────────────────────────── Spotlight promotions ─────────────────────────── */

    /// @notice Promote any Letsprint.ink token (on its curve or graduated). Slots are unlimited: the
    ///         site rotates every active promotion. Booking again extends the current one.
    function promote(address token, PromoTier tier)
        external
        payable
        nonReentrant
        returns (uint64 startsAt, uint64 endsAt)
    {
        if (curveOf[token] == address(0)) revert UnknownToken();
        uint256 price = promoPrices[uint8(tier)];
        if (msg.value != price) revert WrongPromoPayment();

        uint64 nowTs = uint64(block.timestamp);
        uint64 current = promotedUntil[token];
        startsAt = current > nowTs ? current : nowTs;
        endsAt = startsAt + promoDuration(tier);
        promotedUntil[token] = endsAt;

        emit TokenPromoted(token, msg.sender, tier, startsAt, endsAt, msg.value);
        Address.sendValue(payable(treasury), msg.value);
    }

    function promoDuration(PromoTier tier) public pure returns (uint64) {
        if (tier == PromoTier.OneHour) return 1 hours;
        if (tier == PromoTier.ThreeHours) return 3 hours;
        if (tier == PromoTier.NineHours) return 9 hours;
        return 24 hours;
    }

    /* ─────────────────── Owner: settings for future launches only ─────────────────── */

    /// @notice One-time: bind the PrintHook deployed for this factory. Cannot be changed afterwards.
    function setHook(address newHook) external onlyOwner {
        if (hook != address(0)) revert HookAlreadySet();
        if (
            newHook.code.length == 0 || IPrintHookInfo(newHook).factory() != address(this)
                || IPrintHookInfo(newHook).poolManager() != poolManager
        ) revert InvalidConfig();
        hook = newHook;
        _emitConfig();
    }

    /// @notice Approve an xStock as a pair asset for future launches. Its StockVault comes from the
    ///         immutable deployer, so approved pairs always run Letsprint's own vault code.
    ///         `graduationAmount` is R in vault-share units (xStock decimals + 3), between
    ///         MIN_STOCK_R_SHARES and MAX_STOCK_R_SHARES. An empty vault converts 1 xStock unit to 1,000.
    ///         If the vault does not exist yet, the owner must hold one whole xStock and approve this
    ///         factory for it: it seeds the new vault and stays locked there for good.
    function addStockPair(address xStock, uint256 graduationAmount) external onlyOwner returns (address vault) {
        if (xStock == address(0) || xStock == weth) revert InvalidConfig();
        IStockVaultDeployer vd = IStockVaultDeployer(vaultDeployer);
        if (vd.vaultOf(xStock) == address(0)) {
            // A new vault is seeded with one whole xStock from the owner (approve this factory first).
            uint256 seed = vd.seedAmount(xStock);
            IERC20(xStock).safeTransferFrom(msg.sender, address(this), seed);
            IERC20(xStock).forceApprove(vaultDeployer, seed);
        }
        vault = vd.deploy(xStock);
        if (quoteConfig[vault].graduationAmount != 0) revert InvalidConfig(); // already added
        _setQuoteAsset(vault, true, true, graduationAmount);
        emit StockPairAdded(xStock, vault, graduationAmount);
    }

    /// @notice Enable, disable or retarget an already-approved pair (WETH, USDC or an added stock pair),
    ///         for future launches only.
    function setQuoteAsset(address quote, bool enabled, uint256 graduationAmount) external onlyOwner {
        QuoteConfig memory qc = quoteConfig[quote];
        if (qc.graduationAmount == 0) revert PairNotApproved();
        _setQuoteAsset(quote, enabled, qc.isStockVault, graduationAmount);
    }

    function quoteAssetList() external view returns (address[] memory) {
        return quoteAssets;
    }

    function setDeployFee(uint256 newDeployFee) external onlyOwner {
        _setDeployFee(newDeployFee);
        _emitConfig();
    }

    function setPromoPrices(uint256[4] calldata newPrices) external onlyOwner {
        _setPromoPrices(newPrices);
        _emitConfig();
    }

    function setTreasury(address newTreasury) external onlyOwner {
        _setTreasury(newTreasury);
        _emitConfig();
    }

    /// @notice Emergency brake for new launches only. Existing curves keep trading and graduating.
    function setLaunchesPaused(bool paused) external onlyOwner {
        launchesPaused = paused;
        _emitConfig();
    }

    /// @notice Recover tokens or ETH sent to this contract by mistake. It never holds user funds
    ///         between transactions, so there is nothing else to take.
    function rescue(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (asset == address(0)) Address.sendValue(payable(to), amount);
        else IERC20(asset).safeTransfer(to, amount);
        emit Rescued(asset, to, amount);
    }

    /* ─────────────────────────── Internals ─────────────────────────── */

    /// @dev The creator's optional first buy on an ETH pair, untaxed and before anyone else can trade.
    ///      If it sells out the curve, the curve refunds the excess WETH here; it goes back as ETH.
    function _firstBuyETH(BondingCurve c, uint256 amount) internal {
        uint256 before = IERC20(weth).balanceOf(address(this));
        IWETH(weth).deposit{value: amount}();
        IERC20(weth).forceApprove(address(c), amount);
        c.buy(amount, 0, msg.sender, block.timestamp, bytes32(0));
        uint256 refund = IERC20(weth).balanceOf(address(this)) - before;
        if (refund != 0) {
            IWETH(weth).withdraw(refund);
            Address.sendValue(payable(msg.sender), refund);
        }
    }

    /// @dev The creator's optional first buy on a USDC pair. Any refund goes straight back.
    function _firstBuyToken(BondingCurve c, IERC20 asset, uint256 amount) internal {
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        asset.forceApprove(address(c), amount);
        c.buy(amount, 0, msg.sender, block.timestamp, bytes32(0));
        uint256 refund = asset.balanceOf(address(this)) - before;
        if (refund != 0) asset.safeTransfer(msg.sender, refund);
    }

    /// @dev The creator's optional first buy on a stock pair: pulls the xStock, wraps it into the
    ///      pair's StockVault and buys. Any refunded shares go back to the creator as the xStock.
    function _firstBuyStock(BondingCurve c, IERC4626 vault, uint256 stockAmount) internal {
        IERC20 stock = IERC20(vault.asset());
        uint256 sharesBefore = IERC20(address(vault)).balanceOf(address(this));
        uint256 before = stock.balanceOf(address(this));
        stock.safeTransferFrom(msg.sender, address(this), stockAmount);
        uint256 received = stock.balanceOf(address(this)) - before;
        stock.forceApprove(address(vault), received);
        uint256 shares = vault.deposit(received, address(this));
        IERC20(address(vault)).forceApprove(address(c), shares);
        c.buy(shares, 0, msg.sender, block.timestamp, bytes32(0));
        uint256 refund = IERC20(address(vault)).balanceOf(address(this)) - sharesBefore;
        if (refund != 0) vault.redeem(refund, msg.sender, address(this));
    }

    function _setQuoteAsset(address quote, bool enabled, bool isStockVault, uint256 graduationAmount) internal {
        if (quote == address(0)) revert ZeroAddress();
        if (graduationAmount == 0) revert InvalidConfig();
        if (quote == weth) {
            if (isStockVault || graduationAmount < MIN_GRADUATION_ETH || graduationAmount > MAX_GRADUATION_ETH) {
                revert InvalidConfig();
            }
        } else if (quote == usdc) {
            if (isStockVault || graduationAmount < MIN_GRADUATION_USDC || graduationAmount > MAX_GRADUATION_USDC) {
                revert InvalidConfig();
            }
        } else if (!isStockVault) {
            revert InvalidConfig(); // anything else must be a StockVault added through addStockPair
        } else if (graduationAmount < MIN_STOCK_R_SHARES || graduationAmount > MAX_STOCK_R_SHARES) {
            revert InvalidConfig();
        }
        if (quoteConfig[quote].graduationAmount == 0) quoteAssets.push(quote);
        quoteConfig[quote] = QuoteConfig({enabled: enabled, isStockVault: isStockVault, graduationAmount: graduationAmount});
        emit QuoteAssetSet(quote, enabled, isStockVault, graduationAmount);
    }

    function _setDeployFee(uint256 newDeployFee) internal {
        if (newDeployFee > MAX_DEPLOY_FEE) revert InvalidConfig();
        deployFee = newDeployFee;
    }

    function _setPromoPrices(uint256[4] memory newPrices) internal {
        for (uint256 i; i < 4; ++i) {
            if (newPrices[i] == 0 || newPrices[i] > MAX_PROMO_PRICE) revert InvalidConfig();
        }
        promoPrices = newPrices;
    }

    function _setTreasury(address newTreasury) internal {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
    }

    function _emitConfig() internal {
        emit ConfigUpdated(hook, treasury, deployFee, promoPrices, launchesPaused);
    }

    /// @dev Length caps keep events cheap to index and stop UI-breaking metadata. A metadata file must
    ///      come with its fingerprint so anyone can verify it was never swapped.
    function _validate(TokenMetadata calldata m) internal pure {
        uint256 nameLen = bytes(m.name).length;
        uint256 symbolLen = bytes(m.symbol).length;
        if (nameLen == 0 || nameLen > 32 || symbolLen == 0 || symbolLen > 10) revert InvalidMetadata();
        if (
            bytes(m.metadataURI).length > 256 || bytes(m.twitter).length > 128 || bytes(m.telegram).length > 128
                || bytes(m.website).length > 128
        ) revert InvalidMetadata();
        if (bytes(m.metadataURI).length != 0 && m.metadataHash == bytes32(0)) revert InvalidMetadata();
    }

    /// @notice Ownership can only be handed over (two steps), never renounced: pausing launches and
    ///         rescues must always stay possible.
    function renounceOwnership() public pure override {
        revert CannotRenounce();
    }

    /// @dev Only WETH sends ETH here: unwrapping a refunded first buy.
    receive() external payable {
        if (msg.sender != weth) revert DirectEthRejected();
    }
}
