// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolDonateTest} from "v4-core/src/test/PoolDonateTest.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";

import {LocalSystem, MockWETH, MockUSDC} from "./Invariants.t.sol";
import {LaunchpadFactory, FactoryInit, LaunchParams} from "../src/LaunchpadFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {TokenTemplate, TokenMetadata} from "../src/TokenTemplate.sol";
import {PrintHook} from "../src/PrintHook.sol";
import {StockVaultDeployer} from "../src/StockVault.sol";

/// USDC-like token: issuer can blacklist addresses and pause (FiatToken semantics on transfer/transferFrom).
contract BlacklistUSDC is MockUSDC {
    mapping(address => bool) public blacklisted;
    bool public paused;

    function blacklist(address a, bool b) external {
        blacklisted[a] = b;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function _update(address from, address to, uint256 v) internal override {
        require(!paused, "paused");
        require(!blacklisted[msg.sender] && !blacklisted[from] && !blacklisted[to], "blacklisted");
        super._update(from, to, v);
    }
}

contract MockStock is ERC20 {
    constructor() ERC20("Tesla xStock", "TSLAx") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// Reads the hook's and the caller's open deltas right after a swap, inside the unlock.
contract DeltaProbe is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;

    IPoolManager immutable pm;
    address immutable hook;

    constructor(IPoolManager pm_, address hook_) {
        pm = pm_;
        hook = hook_;
    }

    function run(PoolKey memory key, SwapParams memory p) external returns (int256 h0, int256 h1) {
        (h0, h1) = abi.decode(pm.unlock(abi.encode(key, p)), (int256, int256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, SwapParams memory p) = abi.decode(data, (PoolKey, SwapParams));
        pm.swap(key, p, "");
        int256 h0 = pm.currencyDelta(hook, key.currency0);
        int256 h1 = pm.currencyDelta(hook, key.currency1);
        // settle our own side so the unlock can close
        int256 d0 = pm.currencyDelta(address(this), key.currency0);
        int256 d1 = pm.currencyDelta(address(this), key.currency1);
        _close(key.currency0, d0);
        _close(key.currency1, d1);
        return abi.encode(h0, h1);
    }

    function _close(Currency c, int256 d) internal {
        if (d < 0) {
            pm.sync(c);
            IERC20(Currency.unwrap(c)).transfer(address(pm), uint256(-d));
            pm.settle();
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }
}

abstract contract HookHarness is LocalSystem {
    using StateLibrary for IPoolManager;

    PoolSwapTest swapper;
    BlacklistUSDC busdc;
    MockStock stock;
    address vault;
    address buyer = makeAddr("rv.buyer");
    address trader = makeAddr("rv.trader");
    uint256 ts = 1_000_000;

    function _deployAll() internal {
        weth = new MockWETH();
        busdc = new BlacklistUSDC();
        usdc = busdc;
        pm = new PoolManager(address(this));
        ipm = IPoolManager(address(pm));
        StockVaultDeployer vaults = new StockVaultDeployer();
        uint256[4] memory promo = [uint256(0.1 ether), 0.2 ether, 0.5 ether, 1 ether];
        factory = new LaunchpadFactory(
            FactoryInit({
                owner: owner,
                weth: address(weth),
                poolManager: address(pm),
                vaultDeployer: address(vaults),
                treasury: treasury,
                usdc: address(usdc),
                deployFee: 0.0005 ether,
                graduationEth: 5 ether,
                graduationUsdc: 12_800e6,
                promoPrices: promo
            })
        );
        bytes32 h = keccak256(abi.encodePacked(type(PrintHook).creationCode, abi.encode(address(pm), address(factory))));
        bytes32 salt;
        for (uint256 i; i < 2_000_000; ++i) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), h)))));
            if (uint160(a) & Hooks.ALL_HOOK_MASK == 0x20CC) {
                salt = bytes32(i);
                break;
            }
        }
        hook = new PrintHook{salt: salt}(ipm, address(factory));
        vm.prank(owner);
        factory.setHook(address(hook));
        stock = new MockStock();
        stock.mint(owner, 1 ether); // the seed every new vault locks away
        vm.startPrank(owner);
        stock.approve(address(factory), 1 ether);
        vault = factory.addStockPair(address(stock), 32_000e18);
        vm.stopPrank();
        swapper = new PoolSwapTest(ipm);
        vm.warp(ts);
    }

    function _quoteAddr(uint256 kind) internal view returns (address) {
        return kind == 0 ? address(weth) : kind == 1 ? address(usdc) : vault;
    }

    function _fund(address quote, address who, uint256 amount) internal {
        if (quote == address(weth)) {
            weth.mint(who, amount);
        } else if (quote == address(usdc)) {
            usdc.mint(who, amount);
        } else {
            uint256 assets = IERC4626(vault).previewMint(amount);
            stock.mint(address(this), assets);
            stock.approve(vault, assets);
            IERC4626(vault).mint(amount, who);
        }
    }

    function _launchOrdered(address quote, uint256 taxBps, bool wantQuoteIs0)
        internal
        returns (BondingCurve c, TokenTemplate t)
    {
        for (uint256 i; i < 64; ++i) {
            (c, t) = _launch(quote, taxBps);
            if ((quote < address(t)) == wantQuoteIs0) return (c, t);
        }
        revert("ordering");
    }

    function _graduateCurve(BondingCurve c) internal {
        ts += 10;
        vm.warp(ts);
        address q = address(c.quote());
        uint256 need = c.quoteBuyExactTokens(c.realTokenReserve(), buyer);
        _fund(q, buyer, need);
        vm.startPrank(buyer);
        IERC20(q).approve(address(c), need);
        c.buy(need, 0, buyer, FOREVER, bytes32(0));
        vm.stopPrank();
        require(c.graduated(), "not graduated");
    }

    function _swapAs(address who, PoolKey memory key, bool zeroForOne, int256 amt, uint160 limit)
        internal
        returns (BalanceDelta d)
    {
        vm.startPrank(who);
        IERC20(Currency.unwrap(key.currency0)).approve(address(swapper), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(swapper), type(uint256).max);
        d = swapper.swap(key, SwapParams(zeroForOne, amt, limit), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    function _noLimit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _sqrtP(BondingCurve c) internal view returns (uint160 p) {
        (p,,,) = ipm.getSlot0(PoolId.wrap(c.poolId()));
    }
}

/// Property 4: partial fills (sqrtPriceLimitX96 reached before the specified amount is used).
contract PartialFillTest is HookHarness {
    using StateLibrary for IPoolManager;

    BondingCurve c;
    TokenTemplate t;
    PoolKey key;
    bool quoteIs0;
    address victim = makeAddr("rv.victim");

    function setUp() public {
        _deployAll();
        (c, t) = _launch(address(weth), 1_000); // 10% creator tax (max) -> 11% pool charge
        _graduateCurve(c);
        key = c.poolKey();
        quoteIs0 = Currency.unwrap(key.currency0) == address(weth);
    }

    function _feeTaken() internal view returns (uint256) {
        return weth.balanceOf(creator) + weth.balanceOf(treasury) + hook.totalOwed(address(weth));
    }

    function _swapExpectRevert(address who, bool zfo, int256 amt, uint160 limit) internal {
        vm.startPrank(who);
        IERC20(Currency.unwrap(key.currency0)).approve(address(swapper), type(uint256).max);
        IERC20(Currency.unwrap(key.currency1)).approve(address(swapper), type(uint256).max);
        vm.expectRevert();
        swapper.swap(key, SwapParams(zfo, amt, limit), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }

    /// An exact-in buy whose price limit stops it early reverts instead of paying the fee on all of it.
    function test_partialFill_exactInBuy_reverts() public {
        bool zfo = quoteIs0;
        uint160 p = _sqrtP(c);
        uint160 limit = zfo ? uint160(uint256(p) * 999 / 1000) : uint160(uint256(p) * 1001 / 1000);
        _fund(address(weth), victim, 10 ether);
        uint256 fee0 = _feeTaken();
        _swapExpectRevert(victim, zfo, -int256(10 ether), limit);
        assertEq(weth.balanceOf(victim), 10 ether, "nothing paid");
        assertEq(_feeTaken(), fee0, "no fee");
    }

    /// An exact-out sell that would stop at its limit reverts instead of making the seller pay to sell.
    function test_partialFill_exactOutSell_reverts() public {
        bool zfo = !quoteIs0;
        vm.prank(buyer);
        t.transfer(victim, 50_000_000 ether);
        uint160 p = _sqrtP(c);
        uint160 limit = zfo ? uint160(uint256(p) * 9995 / 10000) : uint160(uint256(p) * 10005 / 10000);
        _swapExpectRevert(victim, zfo, int256(1 ether), limit);
        assertEq(t.balanceOf(victim), 50_000_000 ether, "tokens kept");
    }

    /// A limit the swap never reaches still works, and the fee is the usual share.
    function test_limitNotReached_fills() public {
        bool zfo = quoteIs0;
        uint160 p = _sqrtP(c);
        uint160 limit = zfo ? uint160(uint256(p) * 900 / 1000) : uint160(uint256(p) * 1100 / 1000);
        _fund(address(weth), victim, 0.01 ether);
        uint256 fee0 = _feeTaken();
        _swapAs(victim, key, zfo, -int256(0.01 ether), limit);
        assertEq(_feeTaken() - fee0, Math.mulDiv(0.01 ether, 1_100, 10_000, Math.Rounding.Ceil), "fee on what was swapped");
        assertGt(t.balanceOf(victim), 0);
    }
}

/// Property 3/5: fee exactness on the 4 shapes x 2 orderings x 3 quote decimals, split, and hook delta = 0.
contract FeeExactnessTest is HookHarness {
    BondingCurve[6] curves;
    TokenTemplate[6] toks;
    uint256[3] R = [uint256(5 ether), 12_800e6, 32_000e18];

    function setUp() public {
        _deployAll();
        for (uint256 k; k < 3; ++k) {
            for (uint256 o; o < 2; ++o) {
                (BondingCurve c, TokenTemplate t) = _launchOrdered(_quoteAddr(k), 1_000, o == 0);
                _graduateCurve(c);
                curves[k * 2 + o] = c;
                toks[k * 2 + o] = t;
            }
        }
        for (uint256 i; i < 6; ++i) {
            vm.prank(buyer);
            toks[i].transfer(trader, 600_000_000 ether);
        }
    }

    struct S {
        uint256 cr;
        uint256 tr;
        uint256 owed;
        uint256 pmq;
        uint256 tq;
        uint256 tt;
    }

    function _snap(address q, TokenTemplate t) internal view returns (S memory s) {
        s.cr = IERC20(q).balanceOf(creator);
        s.tr = IERC20(q).balanceOf(treasury);
        s.owed = hook.totalOwed(q);
        s.pmq = IERC20(q).balanceOf(address(pm));
        s.tq = IERC20(q).balanceOf(trader);
        s.tt = t.balanceOf(trader);
    }

    function testFuzz_feeExact(uint256 idx, uint256 shape, uint256 amt, uint256 tax) public {
        idx = bound(idx, 0, 5);
        shape = bound(shape, 0, 3);
        tax = bound(tax, 0, 1_000);
        BondingCurve c = curves[idx];
        TokenTemplate t = toks[idx];
        if (tax < 1_000) {
            vm.prank(creator);
            c.lowerCreatorTax(tax);
        }
        uint256 rate = 100 + tax;
        PoolKey memory key = c.poolKey();
        address q = address(c.quote());
        bool qIs0 = Currency.unwrap(key.currency0) == q;
        uint256 r = R[idx / 2];
        bool isBuy = shape < 2;
        bool exactIn = shape % 2 == 0;
        if (shape == 0) amt = bound(amt, 1, 2 * r);
        else if (shape == 1) amt = bound(amt, 1, 100_000_000 ether);
        else if (shape == 2) amt = bound(amt, 1, 400_000_000 ether);
        else amt = bound(amt, 1, r / 2);
        if (isBuy) _fund(q, trader, 4 * r);
        bool zfo = isBuy ? qIs0 : !qIs0;

        S memory a = _snap(q, t);
        _swapAs(trader, key, zfo, exactIn ? -int256(amt) : int256(amt), _noLimit(zfo));
        S memory b = _snap(q, t);

        uint256 fee = (b.cr - a.cr) + (b.tr - a.tr) + (b.owed - a.owed);
        uint256 expected;
        if (isBuy) {
            uint256 paid = a.tq - b.tq;
            uint256 gross = b.pmq - a.pmq;
            assertEq(paid, gross + fee, "buy conservation");
            if (exactIn) {
                assertEq(paid, amt, "exact-in pays exactly amt");
                expected = Math.mulDiv(amt, rate, 10_000, Math.Rounding.Ceil);
            } else {
                assertEq(b.tt - a.tt, amt, "exact-out buy gets exactly amt");
                expected = Math.mulDiv(gross, rate, 10_000 - rate, Math.Rounding.Ceil);
            }
            if (paid > 0) assertGe(fee * 10_000, paid * rate, "fee >= rate of total paid");
        } else {
            uint256 recv = b.tq - a.tq;
            uint256 gross = a.pmq - b.pmq;
            assertEq(recv + fee, gross, "sell conservation");
            if (exactIn) {
                assertEq(a.tt - b.tt, amt, "exact-in sell gives exactly amt");
                expected = Math.mulDiv(gross, rate, 10_000, Math.Rounding.Ceil);
            } else {
                assertEq(recv, amt, "exact-out sell receives exactly amt");
                expected = Math.mulDiv(amt, rate, 10_000 - rate, Math.Rounding.Ceil);
            }
            if (gross > 0) assertGe(fee * 10_000, gross * rate, "fee >= rate of gross output");
        }
        assertEq(fee, expected, "fee formula");
        uint256 ctax = Math.mulDiv(fee, tax, rate);
        uint256 toT = ((fee - ctax) * 3_000) / 10_000;
        assertEq(b.tr - a.tr + 0, toT, "treasury share");
        assertEq(b.cr - a.cr, fee - toT, "creator share");
        assertEq(b.owed, a.owed, "nothing deferred");
    }

    /// The hook's own currency deltas are exactly zero right after the swap, inside the unlock.
    function testFuzz_hookDeltaZero(uint256 idx, uint256 shape, uint256 amt) public {
        idx = bound(idx, 0, 5);
        shape = bound(shape, 0, 3);
        BondingCurve c = curves[idx];
        PoolKey memory key = c.poolKey();
        address q = address(c.quote());
        bool qIs0 = Currency.unwrap(key.currency0) == q;
        uint256 r = R[idx / 2];
        DeltaProbe probe = new DeltaProbe(ipm, address(hook));
        _fund(q, address(probe), 4 * r);
        vm.prank(trader);
        toks[idx].transfer(address(probe), 500_000_000 ether);
        bool isBuy = shape < 2;
        bool exactIn = shape % 2 == 0;
        amt = bound(amt, 1, shape == 0 ? 2 * r : shape == 1 ? 100_000_000 ether : shape == 2 ? 400_000_000 ether : r / 2);
        bool zfo = isBuy ? qIs0 : !qIs0;
        (int256 h0, int256 h1) = probe.run(key, SwapParams(zfo, exactIn ? -int256(amt) : int256(amt), _noLimit(zfo)));
        assertEq(h0, 0, "hook delta0");
        assertEq(h1, 0, "hook delta1");
    }
}

/// Property 6: liveness under USDC blacklisting, PM balance, recipient count.
contract LivenessTest is HookHarness {
    BondingCurve c;
    TokenTemplate t;
    PoolKey key;
    bool qIs0;
    address collab = makeAddr("rv.collab");

    function setUp() public {
        _deployAll();
        (c, t) = _launch(address(usdc), 500);
        address[] memory rs = new address[](2);
        rs[0] = creator;
        rs[1] = collab;
        uint16[] memory sh = new uint16[](2);
        sh[0] = 5_000;
        sh[1] = 5_000;
        vm.prank(creator);
        c.setFeeRecipients(rs, sh);
        _graduateCurve(c);
        key = c.poolKey();
        qIs0 = Currency.unwrap(key.currency0) == address(usdc);
        vm.prank(buyer);
        t.transfer(trader, 400_000_000 ether);
        _fund(address(usdc), trader, 100_000e6);
    }

    function _allShapes() internal {
        bool buy = qIs0;
        _swapAs(trader, key, buy, -int256(100e6), _noLimit(buy)); // exact-in buy
        _swapAs(trader, key, buy, int256(1_000_000 ether), _noLimit(buy)); // exact-out buy
        _swapAs(trader, key, !buy, -int256(1_000_000 ether), _noLimit(!buy)); // exact-in sell
        _swapAs(trader, key, !buy, int256(10e6), _noLimit(!buy)); // exact-out sell
    }

    function test_blacklistedRecipient_tradingContinues() public {
        busdc.blacklist(collab, true);
        _allShapes();
        assertGt(hook.owed(address(usdc), collab), 0, "held");
        vm.expectRevert();
        hook.claim(address(usdc)); // nothing owed to this test contract
        busdc.blacklist(collab, false);
        uint256 o = hook.owed(address(usdc), collab);
        hook.claimFor(address(usdc), collab);
        assertEq(usdc.balanceOf(collab) >= o, true);
        assertEq(hook.totalOwed(address(usdc)), 0);
    }

    function test_blacklistedTreasury_tradingContinues() public {
        busdc.blacklist(treasury, true);
        _allShapes();
        assertGt(hook.owed(address(usdc), treasury), 0);
    }

    function test_blacklistedHookAlone_tradingContinues() public {
        busdc.blacklist(address(hook), true);
        _allShapes();
    }

    /// Hook and a payee both blocked: trading continues and the payee's share is held as a claim.
    function test_blacklistedHookAndRecipient_tradingContinues() public {
        busdc.blacklist(address(hook), true);
        busdc.blacklist(collab, true);
        _allShapes();
        assertGt(hook.owed(address(usdc), collab), 0, "held");
        // a holder can still dump everything
        _swapAs(trader, key, !qIs0, -int256(300_000_000 ether), _noLimit(!qIs0));
        uint256 o = hook.owed(address(usdc), collab);
        busdc.blacklist(collab, false);
        busdc.blacklist(address(hook), false);
        uint256 b0 = usdc.balanceOf(collab);
        hook.claimFor(address(usdc), collab);
        assertEq(usdc.balanceOf(collab) - b0, o, "claimed in full");
        assertEq(hook.owed(address(usdc), collab), 0);
    }

    function swapExt(bool zfo, int256 amt) external {
        _swapAs(trader, key, zfo, amt, _noLimit(zfo));
    }

    /// 5 recipients, all blacklisted: gas per swap.
    function test_gas_fiveBlacklistedRecipients() public {
        address[] memory rs = new address[](5);
        uint16[] memory sh = new uint16[](5);
        for (uint256 i; i < 5; ++i) {
            rs[i] = address(uint160(0xB000 + i));
            sh[i] = 2_000;
            busdc.blacklist(rs[i], true);
        }
        vm.prank(creator);
        c.setFeeRecipients(rs, sh);
        busdc.blacklist(treasury, true);
        bool buy = qIs0;
        _swapAs(trader, key, buy, -int256(100e6), _noLimit(buy)); // warm
        uint256 g = gasleft();
        _swapAs(trader, key, buy, -int256(100e6), _noLimit(buy));
        console2.log("gas: exact-in buy, 5 blocked recipients + blocked treasury", g - gasleft());
    }
}

/// A buy whose charge exceeds what the PoolManager holds still goes through.
contract PmBalanceTest is HookHarness {
    function setUp() public {
        _deployAll();
    }

    function test_bigBuyWorksWhenChargeExceedsPmBalance() public {
        (BondingCurve c, TokenTemplate t) = _launch(address(weth), 1_000);
        _graduateCurve(c);
        PoolKey memory key = c.poolKey();
        bool qIs0 = Currency.unwrap(key.currency0) == address(weth);
        // holders dump the 800M curve tokens into the pool: WETH reserve falls to ~1 ETH
        uint256 bal = t.balanceOf(buyer);
        _swapAs(buyer, key, !qIs0, -int256(bal), _noLimit(!qIs0));
        uint256 pmWeth = weth.balanceOf(address(pm));
        console2.log("PM WETH after dump", pmWeth);
        _fund(address(weth), trader, 100 ether);
        uint256 amt = (pmWeth * 10_000) / 1_100 + 1 ether; // charge > PM balance
        _swapAs(trader, key, qIs0, -int256(amt), _noLimit(qIs0));
        assertGt(t.balanceOf(trader), 0, "the big buy went through");
    }
}

/// Properties 1, 2, 5, 8: pool-creation gate, liquidity rules, rescue/claims, quoter consistency.
contract AccessTest is HookHarness {
    using StateLibrary for IPoolManager;

    PoolModifyLiquidityTest lp;
    PoolDonateTest donor;
    address mallory = makeAddr("rv.mallory");

    function setUp() public {
        _deployAll();
        lp = new PoolModifyLiquidityTest(ipm);
        donor = new PoolDonateTest(ipm);
    }

    function test_onlyCurveCanInitialize() public {
        (BondingCurve c, TokenTemplate t) = _launch(address(weth), 0);
        PoolKey memory k = c.poolKey();
        uint160 p = TickMath.getSqrtPriceAtTick(0);
        // anyone, official key, before graduation
        vm.prank(mallory);
        vm.expectRevert();
        ipm.initialize(k, p);
        // other tick spacing / dynamic fee
        PoolKey memory k2 = PoolKey(k.currency0, k.currency1, 0, 60, k.hooks);
        vm.expectRevert();
        ipm.initialize(k2, p);
        k2 = PoolKey(k.currency0, k.currency1, 0x800000, 200, k.hooks);
        vm.prank(address(c));
        vm.expectRevert();
        ipm.initialize(k2, p);
        // curve itself, wrong pair asset
        (address a, address b) = address(usdc) < address(t) ? (address(usdc), address(t)) : (address(t), address(usdc));
        PoolKey memory k3 = PoolKey(Currency.wrap(a), Currency.wrap(b), 0, 200, IHooks(address(hook)));
        vm.prank(address(c));
        vm.expectRevert();
        ipm.initialize(k3, p);
        // arbitrary foreign pair
        MockStock x = new MockStock();
        MockStock y = new MockStock();
        (a, b) = address(x) < address(y) ? (address(x), address(y)) : (address(y), address(x));
        vm.expectRevert();
        ipm.initialize(PoolKey(Currency.wrap(a), Currency.wrap(b), 0, 200, IHooks(address(hook))), p);
        // no liquidity can be pre-added: the pool does not exist
        vm.expectRevert();
        lp.modifyLiquidity(k, ModifyLiquidityParams(-887200, 887200, 1e18, 0), "");
        // the hook pins the tick spacing too: even the curve cannot open a second pool with another one
        k2 = PoolKey(k.currency0, k.currency1, 0, 1, k.hooks);
        vm.prank(address(c));
        vm.expectRevert();
        ipm.initialize(k2, p);
    }

    function test_thirdPartyLiquidity_noFeeDodge_and_lockedPosition() public {
        (BondingCurve c, TokenTemplate t) = _launch(address(weth), 0);
        _graduateCurve(c);
        PoolKey memory k = c.poolKey();
        bool qIs0 = Currency.unwrap(k.currency0) == address(weth);
        PoolId id = PoolId.wrap(c.poolId());
        // mallory cannot touch the curve's position (positions are keyed by owner)
        vm.prank(mallory);
        vm.expectRevert();
        lp.modifyLiquidity(k, ModifyLiquidityParams(-887200, 887200, -1e18, 0), "");
        // JIT: mallory adds a huge narrow position around the price, a trader swaps, mallory removes
        (, int24 tick,,) = ipm.getSlot0(id);
        int24 lo = (tick / 200) * 200 - 200;
        int24 hi = lo + 600;
        _fund(address(weth), mallory, 1_000 ether);
        vm.prank(buyer);
        t.transfer(mallory, 500_000_000 ether);
        vm.startPrank(mallory);
        weth.approve(address(lp), type(uint256).max);
        t.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(k, ModifyLiquidityParams(lo, hi, 1e24, bytes32("jit")), "");
        vm.stopPrank();
        uint256 fee0 = weth.balanceOf(creator) + weth.balanceOf(treasury);
        _fund(address(weth), trader, 1 ether);
        _swapAs(trader, k, qIs0, -1 ether, _noLimit(qIs0));
        assertEq(weth.balanceOf(creator) + weth.balanceOf(treasury) - fee0, 0.01 ether, "full 1% still charged");
        vm.prank(mallory);
        BalanceDelta d = lp.modifyLiquidity(k, ModifyLiquidityParams(lo, hi, -1e24, bytes32("jit")), "");
        // LP fee is 0: removal returns principal only (no fee growth)
        (uint256 f0, uint256 f1) = _feeGrowth(id);
        assertEq(f0 + f1, 0, "no LP fees accrue");
        d;
        // donate is permitted (to in-range LPs; the curve's share can never be collected)
        _fund(address(weth), mallory, 1 ether);
        vm.startPrank(mallory);
        weth.approve(address(donor), type(uint256).max);
        t.approve(address(donor), type(uint256).max);
        donor.donate(k, qIs0 ? 1 ether : 0, qIs0 ? 0 : 1 ether, "");
        vm.stopPrank();
        assertGt(ipm.getPositionLiquidity(id, keccak256(abi.encodePacked(address(c), int24(-887200), int24(887200), bytes32(0)))), 0);
    }

    function _feeGrowth(PoolId id) internal view returns (uint256 a, uint256 b) {
        (a, b) = ipm.getFeeGrowthGlobals(id);
    }

    function test_rescueCannotTakeHeldPayouts() public {
        (BondingCurve c, TokenTemplate t) = _launch(address(usdc), 0);
        _graduateCurve(c);
        PoolKey memory k = c.poolKey();
        bool qIs0 = Currency.unwrap(k.currency0) == address(usdc);
        busdc.blacklist(creator, true);
        _fund(address(usdc), trader, 1_000e6);
        _swapAs(trader, k, qIs0, -int256(1_000e6), _noLimit(qIs0));
        uint256 held = hook.totalOwed(address(usdc));
        assertGt(held, 0);
        usdc.mint(address(hook), 5e6); // stray
        vm.prank(mallory);
        vm.expectRevert(PrintHook.OnlyPlatform.selector);
        hook.rescue(address(usdc), mallory, 1);
        vm.startPrank(owner);
        vm.expectRevert(PrintHook.CannotRescue.selector);
        hook.rescue(address(usdc), owner, 5e6 + 1);
        hook.rescue(address(usdc), owner, 5e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(hook)), 0, "only the stray tokens were rescued");
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(usdc)))), held, "held payouts intact");
        // claimFor only ever pays the owner
        busdc.blacklist(creator, false);
        vm.prank(mallory);
        hook.claimFor(address(usdc), creator);
        assertEq(usdc.balanceOf(mallory), 0);
        t;
    }

    function test_quoterMatchesSwaps() public {
        V4Quoter quoter = new V4Quoter(ipm);
        for (uint256 kind; kind < 3; ++kind) {
            address q = _quoteAddr(kind);
            (BondingCurve c, TokenTemplate t) = _launch(q, 300);
            _graduateCurve(c);
            PoolKey memory k = c.poolKey();
            bool qIs0 = Currency.unwrap(k.currency0) == q;
            vm.prank(buyer);
            t.transfer(trader, 100_000_000 ether);
            uint256 r = kind == 0 ? 5 ether : kind == 1 ? 12_800e6 : 32_000e18;
            _fund(q, trader, r);
            for (uint256 s; s < 4; ++s) {
                bool buy = s < 2;
                bool exactIn = s % 2 == 0;
                bool zfo = buy ? qIs0 : !qIs0;
                uint256 amt = buy ? (exactIn ? r / 10 : 1_000_000 ether) : (exactIn ? 1_000_000 ether : r / 100);
                uint256 quoted;
                if (exactIn) {
                    (quoted,) = quoter.quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams(k, zfo, uint128(amt), ""));
                } else {
                    (quoted,) = quoter.quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams(k, zfo, uint128(amt), ""));
                }
                BalanceDelta d = _swapAs(trader, k, zfo, exactIn ? -int256(amt) : int256(amt), _noLimit(zfo));
                int128 other = exactIn ? (zfo ? d.amount1() : d.amount0()) : (zfo ? d.amount0() : d.amount1());
                uint256 actual = other < 0 ? uint256(uint128(-other)) : uint256(uint128(other));
                assertEq(quoted, actual, "quoter == swap");
            }
        }
    }
}

contract EdgeTest is HookHarness {
    function setUp() public {
        _deployAll();
    }

    function test_tinyAndHugeSwaps() public {
        (BondingCurve c, TokenTemplate t) = _launch(address(usdc), 1_000);
        _graduateCurve(c);
        PoolKey memory k = c.poolKey();
        bool qIs0 = Currency.unwrap(k.currency0) == address(usdc);
        vm.prank(buyer);
        t.transfer(trader, 1_000_000 ether);
        _fund(address(usdc), trader, 1_000e6);
        // 1-unit swaps of every shape settle; trader can never get a fee-free trade
        uint256 f0 = usdc.balanceOf(creator) + usdc.balanceOf(treasury);
        _swapAs(trader, k, qIs0, -1, _noLimit(qIs0));
        _swapAs(trader, k, qIs0, 1, _noLimit(qIs0));
        _swapAs(trader, k, !qIs0, -1e18, _noLimit(!qIs0));
        _swapAs(trader, k, !qIs0, 1, _noLimit(!qIs0));
        assertGe(usdc.balanceOf(creator) + usdc.balanceOf(treasury) - f0, 4, "each charged >= 1 unit");
        // near-int128 amounts revert cleanly instead of mis-accounting
        vm.startPrank(trader);
        vm.expectRevert();
        swapper.swap(k, SwapParams(qIs0, -int256(uint256(type(uint128).max >> 1)), _noLimit(qIs0)), PoolSwapTest.TestSettings(false, false), "");
        vm.expectRevert();
        swapper.swap(k, SwapParams(!qIs0, int256(uint256(type(uint128).max >> 1)), _noLimit(!qIs0)), PoolSwapTest.TestSettings(false, false), "");
        vm.expectRevert();
        swapper.swap(k, SwapParams(qIs0, type(int256).min, _noLimit(qIs0)), PoolSwapTest.TestSettings(false, false), "");
        vm.stopPrank();
    }
}
