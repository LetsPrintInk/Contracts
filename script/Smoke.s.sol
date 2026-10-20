// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {LaunchpadFactory, LaunchParams} from "../src/LaunchpadFactory.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {TokenMetadata} from "../src/TokenTemplate.sol";

/// @notice Post-deploy check. Launches a coin on the ETH pair with a small creator first buy, buys again
///         through the router, then sells half back through the router. The sender is the creator, so
///         its buys skip the 5-second launch tax. Costs the deploy fee plus about 2 x SMOKE_BUY.
///   FACTORY, ROUTER  addresses printed by Deploy.s.sol (required)
///   SMOKE_BUY        wei per buy, default 0.001 ether
/// Run: FACTORY=0x.. ROUTER=0x.. forge script script/Smoke.s.sol --rpc-url $RPC --account <keystore> --broadcast
/// Graduation is checked separately by script/rehearse.sh, which buys out a curve on a local fork.
contract Smoke is Script {
    function run() external {
        LaunchpadFactory factory = LaunchpadFactory(payable(vm.envAddress("FACTORY")));
        LaunchRouter router = LaunchRouter(payable(vm.envAddress("ROUTER")));
        uint256 buyAmount = vm.envOr("SMOKE_BUY", uint256(0.001 ether));
        address me = msg.sender;
        address weth = factory.weth();
        uint256 deadline = block.timestamp + 1 hours;

        LaunchParams memory p;
        p.quote = weth;
        p.teamWallets = new address[](0);
        p.feeRecipients = new address[](0);
        p.feeShares = new uint16[](0);
        p.salt = keccak256(abi.encode("letsprint smoke test", block.timestamp));
        p.expectedTerms = factory.launchTermsHash(weth);
        TokenMetadata memory meta = TokenMetadata({
            name: "Letsprint Smoke Test",
            symbol: "SMOKE",
            metadataURI: "ipfs://letsprint-smoke-test",
            metadataHash: keccak256("letsprint smoke test"),
            twitter: "",
            telegram: "",
            website: ""
        });

        vm.startBroadcast(me);
        (address token, address curve) = factory.createToken{value: factory.deployFee() + buyAmount}(meta, p);
        uint256 firstBuy = IERC20(token).balanceOf(me);
        uint256 bought = router.buyWithETH{value: buyAmount}(curve, 1, me, deadline, bytes32("smoke"));
        uint256 half = IERC20(token).balanceOf(me) / 2;
        IERC20(token).approve(address(router), half);
        uint256 ethBack = router.sellForETH(curve, half, 1, payable(me), deadline, bytes32("smoke"));
        vm.stopBroadcast();

        require(factory.curveOf(token) == curve, "factory did not register the curve");
        require(firstBuy != 0 && bought != 0 && ethBack != 0, "a trade returned nothing");
        console2.log("token", token);
        console2.log("curve", curve);
        console2.log("creator first buy (tokens)", firstBuy);
        console2.log("router buy (tokens)", bought);
        console2.log("sold half for (wei)", ethBack);
    }
}
