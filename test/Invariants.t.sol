// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {LaunchpadFactory, FactoryInit, LaunchParams} from "../src/LaunchpadFactory.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {TokenTemplate, TokenMetadata} from "../src/TokenTemplate.sol";
import {PrintHook} from "../src/PrintHook.sol";
import {StockVaultDeployer} from "../src/StockVault.sol";

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 a) external {
        _burn(msg.sender, a);
        payable(msg.sender).transfer(a);
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// The whole system on a local chain, with a real Uniswap v4 PoolManager, so thousands of runs are fast.
abstract contract LocalSystem is Test {
    uint256 constant FOREVER = type(uint256).max; // deadlines; via-IR can cache block.timestamp across vm.warp

    MockWETH weth;
    MockUSDC usdc;
    PoolManager pm;
    IPoolManager ipm;
    LaunchpadFactory factory;
    PrintHook hook;
    address owner = makeAddr("lp.owner");
    address treasury = makeAddr("lp.treasury");
    address creator = makeAddr("lp.creator");
    uint256 launches;

    function _deploySystem() internal {
        weth = new MockWETH();
        usdc = new MockUSDC();
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
    }

    function _launch(address quote, uint256 taxBps) internal returns (BondingCurve c, TokenTemplate t) {
        LaunchParams memory p;
        p.quote = quote;
        p.creatorTaxBps = taxBps;
        p.teamWallets = new address[](0);
        p.feeRecipients = new address[](0);
        p.feeShares = new uint16[](0);
        p.salt = keccak256(abi.encode(quote, taxBps, ++launches));
        p.expectedTerms = factory.launchTermsHash(quote);
        TokenMetadata memory meta = TokenMetadata("Fuzz", "FUZZ", "", bytes32(0), "", "", "");
        vm.deal(creator, 1 ether);
        vm.prank(creator);
        (address token, address curve) = factory.createToken{value: 0.0005 ether}(meta, p);
        c = BondingCurve(curve);
        t = TokenTemplate(token);
    }
}

/// Random buys, sells, burns and time jumps from several wallets against one curve.
contract CurveHandler is Test {
    BondingCurve public curve;
    TokenTemplate public token;
    MockWETH public weth;
    address[] internal actors;
    uint256 public buys;
    uint256 public sells;
    uint256 public burned;

    constructor(BondingCurve c, TokenTemplate t, MockWETH w) {
        curve = c;
        token = t;
        weth = w;
        for (uint256 i; i < 5; ++i) {
            actors.push(address(uint160(uint256(keccak256(abi.encode("lp.actor", i))))));
        }
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        if (curve.complete()) return;
        amount = bound(amount, 1e9, 0.6 ether); // small enough that most runs trade for a while before graduating
        address a = actors[actorSeed % actors.length];
        weth.mint(a, amount);
        vm.startPrank(a);
        weth.approve(address(curve), amount);
        curve.buy(amount, 0, a, type(uint256).max, bytes32(0));
        vm.stopPrank();
        buys++;
    }

    function sell(uint256 actorSeed, uint256 shareBps) external {
        if (curve.complete()) return;
        address a = actors[actorSeed % actors.length];
        uint256 amount = (token.balanceOf(a) * bound(shareBps, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        (uint256 out,,) = curve.quoteSell(amount);
        if (out == 0) return;
        vm.startPrank(a);
        token.approve(address(curve), amount);
        curve.sell(amount, 0, a, type(uint256).max, bytes32(0));
        vm.stopPrank();
        sells++;
    }

    function burn(uint256 actorSeed, uint256 shareBps) external {
        address a = actors[actorSeed % actors.length];
        uint256 amount = (token.balanceOf(a) * bound(shareBps, 1, 1_000)) / 10_000;
        if (amount == 0) return;
        vm.prank(a);
        token.burn(amount);
        burned += amount;
    }

    function wait(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3));
    }

    function graduate() external {
        if (curve.complete() && !curve.graduated()) curve.graduate();
    }
}

/// Properties that must hold after any sequence of trades.
contract CurveInvariants is LocalSystem {
    using StateLibrary for IPoolManager;

    CurveHandler handler;
    BondingCurve curve;
    TokenTemplate token;
    uint256 k0;

    function setUp() public {
        _deploySystem();
        (curve, token) = _launch(address(weth), 200);
        handler = new CurveHandler(curve, token, weth);
        k0 = curve.initialVirtualQuote() * curve.initialVirtualToken();
        targetContract(address(handler));
    }

    /// The curve always holds at least its reserves plus every payout it is holding for someone.
    function invariant_solvent() public view {
        uint256 bal = weth.balanceOf(address(curve));
        if (!curve.graduated()) assertGe(bal, curve.realQuoteReserve() + curve.totalOwed(), "curve insolvent");
        else assertGe(bal, curve.totalOwed(), "held payouts unbacked");
    }

    /// k = x * y never drops: every rounding favours the curve.
    function invariant_kNeverDrops() public view {
        if (curve.graduated()) return;
        assertGe(curve.virtualQuoteReserve() * curve.virtualTokenReserve(), k0, "k dropped");
    }

    /// Real reserves move in lockstep with the virtual ones.
    function invariant_reservesInLockstep() public view {
        if (curve.graduated()) return;
        assertEq(curve.realQuoteReserve(), curve.virtualQuoteReserve() - curve.initialVirtualQuote(), "quote drift");
        assertEq(
            curve.realTokenReserve(),
            curve.virtualTokenReserve() - (curve.initialVirtualToken() - curve.CURVE_SUPPLY()),
            "token drift"
        );
    }

    /// Until graduation the curve holds every unsold token plus the 200M reserved for the pool.
    function invariant_tokensAccounted() public view {
        if (curve.graduated()) return;
        assertEq(token.balanceOf(address(curve)), curve.realTokenReserve() + curve.LP_SUPPLY(), "tokens missing");
    }

    /// If every holder sold everything back at once, the curve could pay them all.
    function invariant_everyoneCanExit() public view {
        if (curve.complete()) return;
        uint256 sold = curve.CURVE_SUPPLY() - curve.realTokenReserve();
        uint256 gross = Math.mulDiv(curve.virtualQuoteReserve(), sold, curve.virtualTokenReserve() + sold);
        assertLe(gross, curve.realQuoteReserve(), "exit underfunded");
    }

    /// After graduation the pool has liquidity and the curve owns that position, which it can never remove.
    function invariant_graduatedPoolLocked() public view {
        if (!curve.graduated()) return;
        PoolId id = PoolId.wrap(curve.poolId());
        assertGt(ipm.getLiquidity(id), 0, "pool empty");
        bytes32 position = Position.calculatePositionKey(
            address(curve), TickMath.minUsableTick(200), TickMath.maxUsableTick(200), bytes32(0)
        );
        assertGt(ipm.getPositionLiquidity(id, position), 0, "curve does not hold the position");
    }

    function afterInvariant() external view {
        console2.log("buys", handler.buys(), "sells", handler.sells());
        console2.log("graduated", curve.graduated() ? 1 : 0, "burned (whole tokens)", handler.burned() / 1e18);
    }
}

/// Targeted properties, each checked over 1,000 random inputs.
contract CurveFuzz is LocalSystem {
    BondingCurve curve;
    TokenTemplate token;
    address trader = makeAddr("lp.trader");

    function setUp() public {
        _deploySystem();
        (curve, token) = _launch(address(weth), 0);
        vm.warp(block.timestamp + 10); // past the launch tax
    }

    function _buy(BondingCurve c, address who, uint256 amount) internal returns (uint256 got) {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(c), amount);
        got = c.buy(amount, 0, who, FOREVER, bytes32(0));
        vm.stopPrank();
    }

    /// Buying and selling straight back never makes money.
    function testFuzz_roundTripNeverProfits(uint256 amount) public {
        amount = bound(amount, 1e12, 4.9 ether);
        uint256 got = _buy(curve, trader, amount);
        if (curve.complete()) return;
        vm.startPrank(trader);
        token.approve(address(curve), got);
        uint256 back = curve.sell(got, 0, trader, FOREVER, bytes32(0));
        vm.stopPrank();
        assertLt(back, amount, "round trip profited");
    }

    /// quoteBuy and quoteSell predict buy() and sell() exactly, refunds included.
    function testFuzz_quotesMatch(uint256 amount, uint256 sellBps) public {
        amount = bound(amount, 1e12, 7 ether);
        weth.mint(trader, amount);
        (uint256 qOut,,,, uint256 qRefund, bool qDone) = curve.quoteBuy(amount, trader);
        vm.startPrank(trader);
        weth.approve(address(curve), amount);
        uint256 before = weth.balanceOf(trader);
        uint256 got = curve.buy(amount, 0, trader, FOREVER, bytes32(0));
        assertEq(got, qOut, "buy quote");
        assertEq(weth.balanceOf(trader), before - amount + qRefund, "refund quote");
        assertEq(curve.complete(), qDone, "completion quote");
        if (!qDone) {
            uint256 s = (got * bound(sellBps, 1, 10_000)) / 10_000;
            (uint256 sOut,,) = curve.quoteSell(s);
            if (s > 0 && sOut > 0) {
                token.approve(address(curve), s);
                assertEq(curve.sell(s, 0, trader, FOREVER, bytes32(0)), sOut, "sell quote");
            }
        }
        vm.stopPrank();
    }

    /// However the curve got there, the buy that sells it out raises exactly R into the pool and is
    /// charged only for the tokens that were left.
    function testFuzz_finalBuyRaisesExactlyR(uint256 pre, uint256 extra) public {
        pre = bound(pre, 0, 4 ether);
        extra = bound(extra, 0, 20 ether);
        if (pre > 1e12) _buy(curve, trader, pre);
        if (curve.complete()) return;
        uint256 need = curve.quoteBuyExactTokens(curve.realTokenReserve(), trader);
        uint256 pay = need + extra;
        uint256 poolBefore = weth.balanceOf(address(pm));
        weth.mint(trader, pay);
        uint256 walletBefore = weth.balanceOf(trader);
        vm.startPrank(trader);
        weth.approve(address(curve), pay);
        curve.buy(pay, 0, trader, FOREVER, bytes32(0));
        vm.stopPrank();
        assertTrue(curve.complete() && curve.graduated(), "graduated");
        assertEq(curve.realTokenReserve(), 0, "tokens left");
        assertLe(walletBefore - weth.balanceOf(trader), need, "charged more than the rest cost");
        assertApproxEqAbs(weth.balanceOf(address(pm)) - poolBefore, 5 ether, 1e9, "pool seeded with R");
    }

    /// The launch tax fades to zero by second 5, never leaves a buyer less than 1%, and never applies
    /// to the creator.
    function testFuzz_launchTaxBounded(uint256 taxBps, uint256 elapsed, uint256 amount) public {
        taxBps = bound(taxBps, 0, 1_000);
        uint256 e = bound(elapsed, 0, 6);
        amount = bound(amount, 1e12, 1 ether);
        (BondingCurve c,) = _launch(address(weth), taxBps);
        vm.warp(block.timestamp + e);
        (uint256 out, uint256 fee, uint256 ctax, uint256 snipe,,) = c.quoteBuy(amount, trader);
        assertGt(out, 0, "no tokens");
        assertLe(fee + ctax + snipe, (amount * 9_900) / 10_000 + 1, "buyer kept less than 1%");
        if (e >= 5) assertEq(snipe, 0, "tax after second 5");
        (,,, uint256 creatorSnipe,,) = c.quoteBuy(amount, creator);
        assertEq(creatorSnipe, 0, "creator taxed");
    }

    /// The same guarantees on a 6-decimal USDC curve.
    function testFuzz_usdcRoundTripNeverProfits(uint256 amount) public {
        (BondingCurve c, TokenTemplate t) = _launch(address(usdc), 0);
        vm.warp(block.timestamp + 10);
        amount = bound(amount, 1e3, 12_000e6);
        usdc.mint(trader, amount);
        vm.startPrank(trader);
        usdc.approve(address(c), amount);
        uint256 got = c.buy(amount, 0, trader, FOREVER, bytes32(0));
        if (!c.complete()) {
            t.approve(address(c), got);
            uint256 back = c.sell(got, 0, trader, FOREVER, bytes32(0));
            assertLt(back, amount, "round trip profited");
        }
        vm.stopPrank();
    }
}
