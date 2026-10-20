// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {LaunchpadFactory, FactoryInit, LaunchParams} from "../src/LaunchpadFactory.sol";
import {BondingCurve, CurveConfig} from "../src/BondingCurve.sol";
import {TokenTemplate, TokenMetadata} from "../src/TokenTemplate.sol";
import {PrintHook} from "../src/PrintHook.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {LaunchpadRegistry} from "../src/LaunchpadRegistry.sol";
import {StockVaultDeployer} from "../src/StockVault.sol";
import {CurveDeployer, TokenDeployer} from "../src/Deployers.sol";

interface IWETH {
    function deposit() external payable;
}

interface IUSDC {
    function blacklister() external view returns (address);
    function blacklist(address) external;
    function unBlacklist(address) external;
}

contract MockStock is ERC20 {
    constructor() ERC20("Tesla xStock", "TSLAx") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// End-to-end checks on a fork of Ink mainnet: real Uniswap v4 PoolManager, WETH and native USDC.
contract ForkTest is Test {
    using StateLibrary for IPoolManager;

    address constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x2D270e6886d130D724215A266106e6832161EAEd;
    uint256 constant FEE = 0.0005 ether;
    uint256 constant DEADLINE = type(uint256).max; // via-IR can cache block.timestamp across vm.warp

    IPoolManager pm = IPoolManager(POOL_MANAGER);
    LaunchpadFactory factory;
    PrintHook hook;
    LaunchRouter router;
    LaunchpadRegistry registry;
    StockVaultDeployer vaultDeployer;
    PoolSwapTest swapper;

    address owner = makeAddr("letsprint.owner");
    address treasury = makeAddr("letsprint.treasury");
    address creator = makeAddr("letsprint.creator");
    address collab = makeAddr("letsprint.collab");
    address alice = makeAddr("letsprint.alice");
    address bob = makeAddr("letsprint.bob");
    address sniper = makeAddr("letsprint.sniper");

    function setUp() public {
        vaultDeployer = new StockVaultDeployer();
        uint256[4] memory promo = [uint256(0.1 ether), 0.2 ether, 0.5 ether, 1 ether];
        uint256 g = gasleft();
        factory = new LaunchpadFactory(
            FactoryInit({
                owner: owner,
                weth: WETH,
                poolManager: POOL_MANAGER,
                vaultDeployer: address(vaultDeployer),
                treasury: treasury,
                usdc: USDC,
                deployFee: FEE,
                graduationEth: 5 ether,
                graduationUsdc: 12_800e6,
                promoPrices: promo
            })
        );
        console2.log("gas: deploy factory (+ CurveDeployer + TokenDeployer)", g - gasleft());

        bytes memory initCode = abi.encodePacked(type(PrintHook).creationCode, abi.encode(POOL_MANAGER, address(factory)));
        (bytes32 salt, address predicted) = _mineHook(keccak256(initCode));
        hook = new PrintHook{salt: salt}(pm, address(factory));
        assertEq(address(hook), predicted, "hook address");
        vm.prank(owner);
        factory.setHook(address(hook));

        router = new LaunchRouter(WETH, address(factory));
        registry = new LaunchpadRegistry(owner);
        vm.prank(owner);
        registry.addFactory(address(factory));
        swapper = new PoolSwapTest(pm);

        address[7] memory actors = [owner, treasury, creator, collab, alice, bob, sniper];
        for (uint256 i; i < actors.length; ++i) {
            vm.etch(actors[i], "");
        }
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(sniper, 100 ether);
    }

    /* ─────────────────────────── helpers ─────────────────────────── */

    function _mineHook(bytes32 initCodeHash) internal view returns (bytes32 salt, address addr) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        require(flags == 0x20CC, "flags");
        for (uint256 i; i < 2_000_000; ++i) {
            addr = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash)))));
            if (uint160(addr) & Hooks.ALL_HOOK_MASK == flags) return (bytes32(i), addr);
        }
        revert("no salt");
    }

    function _meta(string memory sym) internal pure returns (TokenMetadata memory) {
        return TokenMetadata({
            name: string.concat("Print ", sym),
            symbol: sym,
            metadataURI: "ipfs://bafy-test",
            metadataHash: keccak256("meta"),
            twitter: "https://x.com/letsprintink",
            telegram: "",
            website: ""
        });
    }

    function _params(address quote, uint256 firstBuy, uint256 taxBps, bytes32 salt)
        internal
        view
        returns (LaunchParams memory p)
    {
        p.quote = quote;
        p.firstBuyAmount = firstBuy;
        p.creatorTaxBps = taxBps;
        p.teamWallets = new address[](0);
        p.feeRecipients = new address[](0);
        p.feeShares = new uint16[](0);
        p.salt = salt;
        p.expectedTerms = factory.launchTermsHash(quote);
    }

    /// Expected creator/treasury split of a charge, mirroring the curve and the hook.
    function _split(uint256 feePool, uint256 creatorTax) internal pure returns (uint256 toCreators, uint256 toTreasury) {
        toTreasury = (feePool * 3_000) / 10_000;
        toCreators = feePool - toTreasury + creatorTax;
    }

    function _swap(PoolKey memory key, address trader, address tokenIn, int256 amountSpecified, bool zeroForOne)
        internal
        returns (BalanceDelta d)
    {
        vm.startPrank(trader);
        IERC20(tokenIn).approve(address(swapper), type(uint256).max);
        d = swapper.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /* ─────────────────────────── ETH pair ─────────────────────────── */

    // State shared by the steps of the ETH lifecycle (small steps keep the stack shallow).
    TokenTemplate eTok;
    BondingCurve eCurve;
    PoolKey ethKey;
    bool wethIs0;

    function test_EthPair_FullLifecycle() public {
        _ethLaunch();
        _ethSnipe();
        _ethBuyAndSell();
        _ethGraduate();
        _ethPoolBuyExactIn();
        _ethPoolOtherShapes();
        _ethCreatorControls();
        _ethPlatform();
    }

    function _ethLaunch() internal {
        // Launch with a 2% creator tax and a 0.2 ETH first buy.
        LaunchParams memory p = _params(WETH, 0, 200, bytes32(uint256(1)));
        uint256 g = gasleft();
        vm.prank(creator);
        (address token, address curveAddr) = factory.createToken{value: FEE + 0.2 ether}(_meta("PRNT"), p);
        console2.log("gas: createToken with 0.2 ETH first buy", g - gasleft());
        eCurve = BondingCurve(curveAddr);
        eTok = TokenTemplate(token);

        assertEq(eTok.totalSupply(), 1_000_000_000 ether, "supply");
        assertEq(eTok.curve(), curveAddr, "token.curve");
        assertEq(eTok.owner(), address(0), "ownerless");
        assertEq(factory.curveOf(token), curveAddr);
        assertTrue(factory.isCurve(curveAddr));
        assertEq(eCurve.factory(), address(factory), "curve.factory");
        assertEq(treasury.balance, FEE, "deploy fee to treasury");
        uint256 creatorTokens = eTok.balanceOf(creator);
        assertGt(creatorTokens, 0, "first buy");
        console2.log("first buy 0.2 ETH -> tokens (whole)", creatorTokens / 1e18);
        assertEq(eTok.balanceOf(curveAddr), 1_000_000_000 ether - creatorTokens, "curve holds the rest");
    }

    function _ethSnipe() internal {
        // Launch tax: a sniper in the launch second keeps only a sliver.
        (uint256 snipeOut,,, uint256 snipeTax,,) = eCurve.quoteBuy(1 ether, sniper);
        vm.prank(sniper);
        uint256 got = router.buyWithETH{value: 1 ether}(address(eCurve), 0, sniper, DEADLINE, bytes32(0));
        assertEq(got, snipeOut, "snipe quote");
        assertGt(snipeTax, 0.9 ether, "snipe tax");
        console2.log("sniper paid 1 ETH, launch tax (milli-ETH)", snipeTax / 1e15);
    }

    function _ethBuyAndSell() internal {
        // After 5 seconds: a normal buy pays 1% + 2% creator tax; the creator is paid in the trade.
        vm.warp(block.timestamp + 5);
        (uint256 out, uint256 fee, uint256 ctax,,,) = eCurve.quoteBuy(1 ether, alice);
        (uint256 toC, uint256 toT) = _split(fee, ctax);
        uint256 cWeth = IERC20(WETH).balanceOf(creator);
        uint256 owedT = eCurve.owed(treasury);
        uint256 g = gasleft();
        vm.prank(alice);
        uint256 got = router.buyWithETH{value: 1 ether}(address(eCurve), out, alice, DEADLINE, keccak256("ref:alice"));
        console2.log("gas: router.buyWithETH", g - gasleft());
        assertEq(got, out, "buy quote");
        assertEq(IERC20(WETH).balanceOf(creator) - cWeth, toC, "creator paid in-trade");
        assertEq(eCurve.owed(treasury) - owedT, toT, "treasury accrues");

        // Sell half back for ETH.
        uint256 half = got / 2;
        (uint256 qOut,,) = eCurve.quoteSell(half);
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        eTok.approve(address(router), half);
        g = gasleft();
        router.sellForETH(address(eCurve), half, qOut, payable(alice), DEADLINE, bytes32(0));
        console2.log("gas: router.sellForETH", g - gasleft());
        vm.stopPrank();
        assertEq(alice.balance - ethBefore, qOut, "sell quote");

        // Holders can burn; market cap follows the live supply.
        uint256 mcBefore = eCurve.marketCap();
        vm.prank(alice);
        eTok.burn(1_000_000 ether);
        assertLt(eCurve.marketCap(), mcBefore, "burn lowers mcap");
    }

    function _ethGraduate() internal {
        // Bob buys out the curve with 10 ETH: it graduates in the same transaction and refunds him.
        (,,,, uint256 refundQ, bool completes) = eCurve.quoteBuy(10 ether, bob);
        assertTrue(completes, "completes");
        uint256 bobEth = bob.balance;
        uint256 g = gasleft();
        vm.prank(bob);
        router.buyWithETH{value: 10 ether}(address(eCurve), 0, bob, DEADLINE, bytes32(0));
        console2.log("gas: final buy + graduation", g - gasleft());
        assertEq(bobEth - bob.balance, 10 ether - refundQ, "refund in ETH");
        assertTrue(eCurve.complete() && eCurve.graduated(), "graduated");

        ethKey = eCurve.poolKey();
        wethIs0 = Currency.unwrap(ethKey.currency0) == WETH;
        PoolId id = PoolId.wrap(eCurve.poolId());
        (uint160 sqrtP,,,) = pm.getSlot0(id);
        assertGt(sqrtP, 0, "pool live");
        assertGt(pm.getLiquidity(id), 0, "liquidity");
        assertEq(eCurve.realQuoteReserve(), 0);
        // Everything the curve still holds in WETH is owed to someone (plus rounding dust).
        uint256 curveWeth = IERC20(WETH).balanceOf(address(eCurve));
        assertGe(curveWeth, eCurve.totalOwed(), "owed is fully backed");
        console2.log("WETH dust left on curve after graduation (wei)", curveWeth - eCurve.totalOwed());
        assertLt(curveWeth - eCurve.totalOwed(), 1e12, "dust is tiny");
        console2.log("token dust left on curve", eTok.balanceOf(address(eCurve)));

        // Nobody else can create a pool for this token with the hook.
        PoolKey memory fake = PoolKey(ethKey.currency0, ethKey.currency1, 0, 60, IHooks(address(hook)));
        vm.expectRevert();
        pm.initialize(fake, sqrtP);
    }

    function _ethPoolBuyExactIn() internal {
        // Pool trades pay the hook fee in WETH to creator and treasury. Exact-in buy: fee before the swap.
        vm.prank(alice);
        IWETH(WETH).deposit{value: 20 ether}();
        uint256 amt = 0.5 ether;
        uint256 charge = (amt * 300 + 9_999) / 10_000;
        uint256 ctaxPart = (charge * 200) / 300;
        (uint256 toC, uint256 toT) = _split(charge - ctaxPart, ctaxPart);
        uint256 cWeth = IERC20(WETH).balanceOf(creator);
        uint256 tWeth = IERC20(WETH).balanceOf(treasury);
        uint256 g = gasleft();
        BalanceDelta d = _swap(ethKey, alice, WETH, -int256(amt), wethIs0);
        console2.log("gas: pool exact-in buy via hook", g - gasleft());
        assertEq(IERC20(WETH).balanceOf(creator) - cWeth, toC, "pool creator fee");
        assertEq(IERC20(WETH).balanceOf(treasury) - tWeth, toT, "pool treasury fee");
        int128 tokOut = wethIs0 ? d.amount1() : d.amount0();
        assertGt(tokOut, 0, "tokens out");
        console2.log("pool: 0.5 WETH bought tokens (whole)", uint256(uint128(tokOut)) / 1e18);
    }

    function _ethPoolOtherShapes() internal {
        // Exact-in sell: fee after the swap, on the WETH received.
        uint256 cWeth = IERC20(WETH).balanceOf(creator);
        uint256 sellAmt = eTok.balanceOf(alice) / 4;
        BalanceDelta d = _swap(ethKey, alice, address(eTok), -int256(sellAmt), !wethIs0);
        int128 wethOut = wethIs0 ? d.amount0() : d.amount1();
        assertGt(wethOut, 0, "weth out");
        uint256 creatorGain = IERC20(WETH).balanceOf(creator) - cWeth;
        // The creator gets 90% of the 3% charge (0.7% + 2% of 3%).
        assertApproxEqRel(creatorGain, (uint256(uint128(wethOut)) * 300 / 9_700) * 2_700 / 3_000, 0.01e18, "sell fee");

        // Exact-out buy (fee after, grossed up) and exact-out sell (fee before, on the WETH out).
        cWeth = IERC20(WETH).balanceOf(creator);
        _swap(ethKey, alice, WETH, int256(1_000_000 ether), wethIs0);
        assertGt(IERC20(WETH).balanceOf(creator), cWeth, "exact-out buy fee");
        cWeth = IERC20(WETH).balanceOf(creator);
        uint256 aliceWeth = IERC20(WETH).balanceOf(alice);
        _swap(ethKey, alice, address(eTok), int256(0.01 ether), !wethIs0);
        assertEq(IERC20(WETH).balanceOf(alice) - aliceWeth, 0.01 ether, "exact out received");
        assertGt(IERC20(WETH).balanceOf(creator), cWeth, "exact-out sell fee");
    }

    function _ethCreatorControls() internal {
        // Treasury collects what accrued on the curve.
        uint256 tWeth = IERC20(WETH).balanceOf(treasury);
        uint256 accrued = eCurve.owed(treasury);
        vm.prank(treasury);
        eCurve.claim();
        assertEq(IERC20(WETH).balanceOf(treasury) - tWeth, accrued, "treasury claim");

        vm.prank(creator);
        eCurve.lowerCreatorTax(100);
        vm.prank(creator);
        vm.expectRevert(BondingCurve.TaxCanOnlyDecrease.selector);
        eCurve.lowerCreatorTax(150);
        vm.prank(alice);
        vm.expectRevert(BondingCurve.OnlyCreator.selector);
        eCurve.lowerCreatorTax(0);
        vm.prank(creator);
        eTok.setSocials("https://x.com/new", "https://t.me/new", "");
        assertEq(eTok.telegram(), "https://t.me/new");
        vm.prank(alice);
        vm.expectRevert(TokenTemplate.OnlyCreator.selector);
        eTok.setSocials("", "", "");

        // The lowered tax applies in the pool straight away (1% + 1%).
        uint256 cWeth = IERC20(WETH).balanceOf(creator);
        _swap(ethKey, alice, WETH, -int256(1 ether), wethIs0);
        uint256 charge = (uint256(1 ether) * 200 + 9_999) / 10_000;
        (uint256 toC,) = _split(charge - charge / 2, charge / 2);
        assertEq(IERC20(WETH).balanceOf(creator) - cWeth, toC, "live tax in pool");
    }

    function _ethPlatform() internal {
        // Rescue: platform only, never the token or the pair asset.
        MockStock junk = new MockStock();
        junk.mint(address(eCurve), 1 ether);
        vm.expectRevert(BondingCurve.OnlyPlatform.selector);
        eCurve.rescue(address(junk), alice, 1 ether);
        vm.startPrank(owner);
        vm.expectRevert(BondingCurve.CannotRescue.selector);
        eCurve.rescue(WETH, owner, 1);
        vm.expectRevert(BondingCurve.CannotRescue.selector);
        eCurve.rescue(address(eTok), owner, 1);
        eCurve.rescue(address(junk), owner, 1 ether);
        vm.stopPrank();
        assertEq(junk.balanceOf(owner), 1 ether);

        // Spotlight promotion pays the treasury.
        uint256 tEth = treasury.balance;
        vm.prank(alice);
        factory.promote{value: 0.1 ether}(address(eTok), LaunchpadFactory.PromoTier.OneHour);
        assertEq(treasury.balance - tEth, 0.1 ether);
    }

    function test_FinalBuyGraduatesOrReverts() public {
        LaunchParams memory p = _params(WETH, 0, 0, bytes32(uint256(2)));
        vm.prank(creator);
        (, address curveAddr) = factory.createToken{value: FEE}(_meta("DEFR"), p);
        BondingCurve curve = BondingCurve(curveAddr);
        vm.warp(block.timestamp + 10);
        // Without the gas to graduate, the final buy reverts instead of leaving the token in limbo.
        vm.prank(bob);
        vm.expectRevert();
        router.buyWithETH{value: 6 ether, gas: 600_000}(curveAddr, 0, bob, DEADLINE, bytes32(0));
        assertFalse(curve.complete(), "nothing changed");
        uint256 g = gasleft();
        vm.prank(bob);
        router.buyWithETH{value: 6 ether, gas: 1_200_000}(curveAddr, 0, bob, DEADLINE, bytes32(0));
        console2.log("gas: final buy with graduation, via the router", g - gasleft());
        assertTrue(curve.graduated(), "graduated in the same transaction");
        vm.expectRevert(BondingCurve.NotReadyToGraduate.selector);
        curve.graduate();
    }

    /* ─────────────────────────── USDC pair ─────────────────────────── */

    BondingCurve uCurve;
    address uToken;
    address blacklister;

    function test_UsdcPair_BlockedRecipientNeverBlocksTrading() public {
        _usdcLaunch();
        _usdcTradeWithBlockedRecipient();
        _usdcGraduateAndSwap();
        _usdcClaims();
    }

    function _usdcLaunch() internal {
        deal(USDC, creator, 1_000e6);
        deal(USDC, alice, 20_000e6);
        deal(USDC, bob, 20_000e6);

        LaunchParams memory p = _params(USDC, 100e6, 0, bytes32(uint256(3)));
        p.feeRecipients = new address[](2);
        p.feeRecipients[0] = creator;
        p.feeRecipients[1] = collab;
        p.feeShares = new uint16[](2);
        p.feeShares[0] = 5_000;
        p.feeShares[1] = 5_000;

        // USDC launches take the deploy fee in ETH and nothing more.
        vm.startPrank(creator);
        IERC20(USDC).approve(address(factory), 100e6);
        vm.expectRevert(LaunchpadFactory.WrongFirstBuy.selector);
        factory.createToken{value: FEE + 1}(_meta("USD"), p);
        (address token, address curveAddr) = factory.createToken{value: FEE}(_meta("USD"), p);
        vm.stopPrank();
        uCurve = BondingCurve(curveAddr);
        uToken = token;
        assertEq(address(uCurve.quote()), USDC);
        assertGt(IERC20(token).balanceOf(creator), 0, "first buy in USDC");
        // Starting market cap is 0.3125 x 12,800 = $4,000; the first buy lifts it a little.
        console2.log("USDC pair market cap after a 100 USDC first buy (USD)", uCurve.marketCap() / 1e6);

        // Circle blocks the collaborator's wallet.
        blacklister = IUSDC(USDC).blacklister();
        vm.prank(blacklister);
        IUSDC(USDC).blacklist(collab);
    }

    function _usdcTradeWithBlockedRecipient() internal {
        vm.warp(block.timestamp + 6);
        vm.startPrank(alice);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 got = router.buyWithToken(address(uCurve), 500e6, 0, alice, DEADLINE, bytes32(0));
        vm.stopPrank();
        assertGt(got, 0, "buy with blocked recipient");
        assertGt(uCurve.owed(collab), 0, "collab share held");
        uint256 creatorUsdc = IERC20(USDC).balanceOf(creator);

        // Sell directly on the curve (pays USDC).
        vm.startPrank(alice);
        IERC20(uToken).approve(address(uCurve), got / 3);
        uCurve.sell(got / 3, 0, alice, DEADLINE, bytes32(0));
        vm.stopPrank();
        assertGt(IERC20(USDC).balanceOf(creator), creatorUsdc, "creator paid on sell");
    }

    function _usdcGraduateAndSwap() internal {
        // Bob fills the curve; graduation opens a USDC pool at a $64,000 market cap.
        vm.startPrank(bob);
        IERC20(USDC).approve(address(router), type(uint256).max);
        uint256 bobUsdc = IERC20(USDC).balanceOf(bob);
        router.buyWithToken(address(uCurve), 15_000e6, 0, bob, DEADLINE, bytes32(0));
        vm.stopPrank();
        assertTrue(uCurve.graduated(), "usdc graduated");
        console2.log("bob paid for the rest of the curve (USDC)", (bobUsdc - IERC20(USDC).balanceOf(bob)) / 1e6);

        PoolKey memory key = uCurve.poolKey();
        uint256 aliceTok = IERC20(uToken).balanceOf(alice);
        _swap(key, alice, USDC, -int256(64e6), Currency.unwrap(key.currency0) == USDC);
        uint256 bought = IERC20(uToken).balanceOf(alice) - aliceTok;
        // $64 at a $64,000 market cap buys about 0.1% of supply, less the 1% fee and price impact.
        console2.log("pool: 64 USDC bought tokens (whole)", bought / 1e18);
        assertApproxEqRel(bought, 1_000_000 ether, 0.03e18, "pool opens at $64,000 market cap");
        assertGt(hook.owed(USDC, collab), 0, "hook holds the blocked share");
    }

    function _usdcClaims() internal {
        // Once unblocked, the collaborator claims from both the curve and the hook.
        vm.prank(blacklister);
        IUSDC(USDC).unBlacklist(collab);
        uint256 owedCurve = uCurve.owed(collab);
        uint256 owedHook = hook.owed(USDC, collab);
        uint256 collabBefore = IERC20(USDC).balanceOf(collab);
        vm.startPrank(collab);
        uCurve.claim();
        hook.claim(USDC);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(collab) - collabBefore, owedCurve + owedHook, "claims");
        assertEq(hook.totalOwed(USDC), 0, "nothing left held");
    }

    /* ─────────────────────────── Stock pair ─────────────────────────── */

    function test_StockPair_WrapsAndUnwraps() public {
        MockStock stock = new MockStock();
        stock.mint(owner, 1 ether); // the seed every new vault locks away
        vm.startPrank(owner);
        stock.approve(address(factory), 1 ether);
        address vault = factory.addStockPair(address(stock), 32_000e18); // R in vault shares (decimals + 3)
        vm.stopPrank();
        stock.mint(creator, 10 ether);
        stock.mint(alice, 10 ether);

        vm.startPrank(creator);
        stock.approve(address(factory), 1 ether);
        (address token, address curveAddr) = factory.createToken{value: FEE}(_meta("TSLA"), _params(vault, 1 ether, 0, bytes32(uint256(4))));
        vm.stopPrank();
        assertGt(IERC20(token).balanceOf(creator), 0, "first buy in stock");

        vm.warp(block.timestamp + 6);
        vm.startPrank(alice);
        stock.approve(address(router), 2 ether);
        uint256 got = router.buyWithStock(curveAddr, 2 ether, 0, alice, DEADLINE, bytes32(0));
        IERC20(token).approve(address(router), got);
        uint256 before = stock.balanceOf(alice);
        router.sellForStock(curveAddr, got, 0, alice, DEADLINE, bytes32(0));
        vm.stopPrank();
        uint256 back = stock.balanceOf(alice) - before;
        console2.log("stock round trip: 2 TSLAx in, back (milli)", back / 1e15);
        assertApproxEqRel(back, 2 ether, 0.03e18, "round trip within fees");
    }

    /* ─────────────────────────── Access ─────────────────────────── */

    function test_DeployersAreLocked() public {
        CurveDeployer cd = factory.curveDeployer();
        TokenDeployer td = TokenDeployer(factory.tokenDeployer());
        assertEq(cd.factory(), address(factory));
        assertEq(address(cd.tokenDeployer()), address(td));
        assertEq(address(td.curveDeployer()), address(cd));
        assertFalse(cd.deploying());

        vm.prank(alice);
        vm.expectRevert(TokenDeployer.OnlyDuringLaunch.selector);
        td.deploy(_meta("FAKE"));

        CurveConfig memory cfg = CurveConfig({
            factory: address(factory),
            tokenDeployer: address(td),
            quote: WETH,
            poolManager: POOL_MANAGER,
            hook: address(hook),
            treasury: treasury,
            graduationAmount: 5 ether
        });
        vm.prank(alice);
        vm.expectRevert(CurveDeployer.OnlyFactory.selector);
        cd.deploy(bytes32(0), alice, _meta("FAKE"), 0, new address[](0), new address[](0), new uint16[](0), cfg);

        // Terms changed between quote and launch.
        LaunchParams memory p = _params(WETH, 0, 0, bytes32(uint256(9)));
        vm.prank(owner);
        factory.setDeployFee(0.001 ether);
        vm.prank(creator);
        vm.expectRevert(LaunchpadFactory.LaunchTermsChanged.selector);
        factory.createToken{value: 0.001 ether}(_meta("TERM"), p);

        // A pool for an unlaunched pair cannot use the hook.
        MockStock x = new MockStock();
        (address a, address b) = address(x) < WETH ? (address(x), WETH) : (WETH, address(x));
        vm.expectRevert();
        pm.initialize(PoolKey(Currency.wrap(a), Currency.wrap(b), 0, 200, IHooks(address(hook))), TickMath.getSqrtPriceAtTick(0));
    }
}
