// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {LocalSystem} from "./Invariants.t.sol";
import {LaunchpadFactory, LaunchParams} from "../src/LaunchpadFactory.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {LaunchpadRegistry} from "../src/LaunchpadRegistry.sol";
import {BondingCurve} from "../src/BondingCurve.sol";
import {TokenTemplate, TokenMetadata} from "../src/TokenTemplate.sol";
import {StockVault} from "../src/StockVault.sol";

contract RegStock is ERC20 {
    constructor() ERC20("Tesla xStock", "TSLAx") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// Buys from inside a PoolManager unlock, as a v4-native aggregator would.
contract UnlockedBuyer is IUnlockCallback {
    IPoolManager immutable pm;
    BondingCurve immutable curve;

    constructor(IPoolManager pm_, BondingCurve curve_) {
        pm = pm_;
        curve = curve_;
    }

    function buy(uint256 amount) external {
        pm.unlock(abi.encode(amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        IERC20(address(curve.quote())).approve(address(curve), amount);
        curve.buy(amount, 0, address(this), type(uint256).max, bytes32(0));
        return "";
    }
}

/// Regression tests for the findings of the October 2026 independent review.
contract Regressions is LocalSystem {
    LaunchRouter router;
    address bob = makeAddr("lp.bob");

    function setUp() public {
        _deploySystem();
        router = new LaunchRouter(address(weth), address(factory));
        vm.warp(1_000_000);
    }

    /// Curve M-1: a final buy without the gas to graduate reverts instead of leaving the token stuck.
    function test_finalBuyWithoutGasReverts_thenGraduatesInline() public {
        (BondingCurve c,) = _launch(address(weth), 0);
        vm.warp(block.timestamp + 10);
        uint256 need = c.quoteBuyExactTokens(c.realTokenReserve(), bob);
        weth.mint(bob, need);
        vm.startPrank(bob);
        weth.approve(address(c), need);
        vm.expectRevert(BondingCurve.InsufficientGasToGraduate.selector);
        c.buy{gas: 650_000}(need, 0, bob, FOREVER, bytes32(0));
        assertFalse(c.complete(), "nothing changed");
        c.buy{gas: 1_000_000}(need, 0, bob, FOREVER, bytes32(0));
        vm.stopPrank();
        assertTrue(c.graduated(), "graduated in the same transaction");
        vm.expectRevert(BondingCurve.NotReadyToGraduate.selector);
        c.graduate();
    }

    /// Curve L-2: a final buy from inside an unlock completes the curve and leaves graduation to anyone.
    function test_finalBuyInsideUnlockDefers_thenAnyoneGraduates() public {
        (BondingCurve c,) = _launch(address(weth), 0);
        vm.warp(block.timestamp + 10);
        UnlockedBuyer agg = new UnlockedBuyer(ipm, c);
        uint256 need = c.quoteBuyExactTokens(c.realTokenReserve(), address(agg));
        weth.mint(address(agg), need);
        agg.buy(need);
        assertTrue(c.complete(), "complete");
        assertFalse(c.graduated(), "waiting");
        vm.prank(bob);
        c.graduate();
        assertTrue(c.graduated(), "graduated");
    }

    function _seedOwner(RegStock stock) internal {
        stock.mint(owner, 1 ether);
        vm.prank(owner);
        stock.approve(address(factory), 1 ether);
    }

    /// Vault F1: a dust deposit plus a donation cannot re-price a stock vault, because every new vault is
    /// seeded with one whole xStock locked behind dead shares.
    function test_vaultCannotBeRepricedCheaply() public {
        RegStock stock = new RegStock();
        _seedOwner(stock);
        vm.prank(owner);
        address vault = factory.addStockPair(address(stock), 32_000e18);
        assertEq(IERC20(vault).balanceOf(0x000000000000000000000000000000000000dEaD), 1_000 ether, "seed locked");
        // attacker: deposit 1 unit, then donate 0.001 xStock
        stock.mint(address(this), 1e15 + 1);
        stock.approve(vault, 1);
        IERC4626(vault).deposit(1, address(this));
        stock.transfer(vault, 1e15);
        assertGe(IERC4626(vault).convertToShares(1 ether), 998 ether, "rate moved by at most 0.2%");

        stock.mint(creator, 1 ether);
        LaunchParams memory p = _stockParams(vault);
        vm.startPrank(creator);
        stock.approve(address(factory), 1 ether);
        vm.deal(creator, 1 ether);
        (address token,) = factory.createToken{value: 0.0005 ether}(TokenMetadata("S", "S", "", bytes32(0), "", "", ""), p);
        vm.stopPrank();
        assertGt(IERC20(token).balanceOf(creator), 50_000_000 ether, "first buy priced normally");
    }

    /// Stock sent to a vault's address before it exists goes to the dead seed shares, not an attacker.
    function test_donationBeforeVaultExistsIsHarmless() public {
        RegStock stock = new RegStock();
        address predicted = vm.computeCreate2Address(
            bytes32(uint256(uint160(address(stock)))),
            keccak256(abi.encodePacked(type(StockVault).creationCode, abi.encode(address(stock)))),
            factory.vaultDeployer()
        );
        stock.mint(address(this), 5 ether);
        stock.transfer(predicted, 5 ether); // pre-poison the future vault address
        _seedOwner(stock);
        vm.prank(owner);
        address vault = factory.addStockPair(address(stock), 32_000e18);
        assertEq(vault, predicted);
        assertEq(IERC20(vault).totalSupply(), 1_000 ether, "only the dead seed shares exist");
        assertEq(IERC4626(vault).totalAssets(), 6 ether, "the donation belongs to the locked seed");
    }

    /// Vault F4 / curve I-1: stock-pair targets outside sane share bounds are refused.
    function test_stockTargetBounds() public {
        RegStock stock = new RegStock();
        _seedOwner(stock);
        vm.startPrank(owner);
        vm.expectRevert(LaunchpadFactory.InvalidConfig.selector);
        factory.addStockPair(address(stock), 3);
        vm.expectRevert(LaunchpadFactory.InvalidConfig.selector);
        factory.addStockPair(address(stock), 2 ** 128);
        factory.addStockPair(address(stock), 32_000e18);
        vm.stopPrank();
    }

    /// Router F3: selling to the zero address reverts instead of burning the ETH.
    function test_sellToZeroAddressReverts() public {
        (BondingCurve c, TokenTemplate t) = _launch(address(weth), 0);
        vm.warp(block.timestamp + 10);
        vm.deal(bob, 1 ether);
        vm.startPrank(bob);
        uint256 got = router.buyWithETH{value: 0.1 ether}(address(c), 0, bob, FOREVER, bytes32(0));
        t.approve(address(router), got);
        vm.expectRevert(LaunchRouter.ZeroAddress.selector);
        router.sellForETH(address(c), got, 0, payable(address(0)), FOREVER, bytes32(0));
        vm.stopPrank();
    }

    /// Owner F5: ownership can never be renounced.
    function test_ownershipCannotBeRenounced() public {
        vm.prank(owner);
        vm.expectRevert(LaunchpadFactory.CannotRenounce.selector);
        factory.renounceOwnership();
        LaunchpadRegistry registry = new LaunchpadRegistry(owner);
        vm.prank(owner);
        vm.expectRevert(LaunchpadRegistry.CannotRenounce.selector);
        registry.renounceOwnership();
    }

    /// F6a / I-4: changing the treasury changes the launch terms, so a pending launch reverts.
    function test_treasuryChangeInvalidatesQuotedTerms() public {
        bytes32 before = factory.launchTermsHash(address(weth));
        vm.prank(owner);
        factory.setTreasury(makeAddr("lp.newTreasury"));
        assertTrue(factory.launchTermsHash(address(weth)) != before, "terms include the treasury");
    }

    function _stockParams(address vault) internal view returns (LaunchParams memory p) {
        p.quote = vault;
        p.firstBuyAmount = 1 ether;
        p.teamWallets = new address[](0);
        p.feeRecipients = new address[](0);
        p.feeShares = new uint16[](0);
        p.salt = bytes32(uint256(77));
        p.expectedTerms = factory.launchTermsHash(vault);
    }
}
