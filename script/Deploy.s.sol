// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {LaunchpadFactory, FactoryInit} from "../src/LaunchpadFactory.sol";
import {PrintHook} from "../src/PrintHook.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {LaunchpadRegistry} from "../src/LaunchpadRegistry.sol";
import {StockVaultDeployer} from "../src/StockVault.sol";

/// @notice Deploys Letsprint.ink in one run. Settings come from the environment:
///   POOL_MANAGER    Uniswap v4 PoolManager (required)
///   TREASURY        where fees and Spotlight payments go, normally the team Safe (required)
///   WETH            default 0x4200000000000000000000000000000000000006 (the OP Stack predeploy)
///   USDC            native USDC, or unset for no USDC pair
///   SAFE            set on mainnet: the script deploys a TimelockController run by this Safe and starts
///                   handing the factory and registry to it. Unset on testnet: the deployer stays owner.
///   TIMELOCK_DELAY  seconds, default 172800 (48 hours)
///   DEPLOY_FEE      wei, default 0.0005 ether
///   GRAD_ETH        default 5 ether          GRAD_USDC   default 12_800e6
/// Rehearse:  ./script/rehearse.sh (deploys on a local fork of Ink mainnet and checks everything)
/// Dry run:   forge script script/Deploy.s.sol --rpc-url $RPC --sender $DEPLOYER
/// Broadcast: add --broadcast and a signer: --account <keystore> --sender $DEPLOYER, or --ledger.
///            Verify on the explorer afterwards (see DEPLOYMENT.md).
/// After a SAFE deploy, the Safe schedules acceptOwnership() on the factory and the registry through
/// the timelock, waits the delay, and executes both calls. Until then the deployer remains owner.
contract Deploy is Script {
    /// The standard deterministic CREATE2 deployer, preinstalled on OP Stack chains including Ink.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 constant HOOK_FLAGS = 0x20CC;

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address treasury = vm.envAddress("TREASURY");
        address weth = vm.envOr("WETH", address(0x4200000000000000000000000000000000000006));
        address usdc = vm.envOr("USDC", address(0));
        address safe = vm.envOr("SAFE", address(0));
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(2 days));
        uint256 deployFee = vm.envOr("DEPLOY_FEE", uint256(0.0005 ether));
        uint256 gradEth = vm.envOr("GRAD_ETH", uint256(5 ether));
        uint256 gradUsdc = vm.envOr("GRAD_USDC", uint256(12_800e6));
        require(poolManager.code.length != 0, "POOL_MANAGER has no code on this chain");
        require(weth.code.length != 0, "WETH has no code on this chain");
        require(usdc == address(0) || usdc.code.length != 0, "USDC has no code on this chain");
        require(CREATE2_DEPLOYER.code.length != 0, "no CREATE2 deployer on this chain");
        require(block.chainid != 57073 || safe.code.length != 0, "SAFE must be a deployed Safe on Ink mainnet");

        address deployer = msg.sender;
        vm.startBroadcast(deployer);

        StockVaultDeployer vaults = new StockVaultDeployer();
        uint256[4] memory promo = [uint256(0.1 ether), 0.2 ether, 0.5 ether, 1 ether];
        LaunchpadFactory factory = new LaunchpadFactory(
            FactoryInit({
                owner: deployer,
                weth: weth,
                poolManager: poolManager,
                vaultDeployer: address(vaults),
                treasury: treasury,
                usdc: usdc,
                deployFee: deployFee,
                graduationEth: gradEth,
                graduationUsdc: gradUsdc,
                promoPrices: promo
            })
        );

        // The hook's address must carry its permission flags, so mine a CREATE2 salt for it and deploy it
        // by calling the CREATE2 deployer directly. (`new PrintHook{salt: ...}` leaves this to Foundry's
        // CREATE2 routing, which skipped the deployer in the rehearsal and landed on an invalid address.)
        bytes memory initCode =
            abi.encodePacked(type(PrintHook).creationCode, abi.encode(poolManager, address(factory)));
        (bytes32 salt, address predicted) = mineHookSalt(keccak256(initCode));
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && predicted.code.length != 0, "hook deployment failed");
        PrintHook hook = PrintHook(predicted);
        factory.setHook(address(hook));

        LaunchRouter router = new LaunchRouter(weth, address(factory));
        LaunchpadRegistry registry = new LaunchpadRegistry(deployer);
        registry.addFactory(address(factory));

        address timelock;
        if (safe != address(0)) {
            address[] memory roles = new address[](1);
            roles[0] = safe;
            timelock = address(new TimelockController(delay, roles, roles, address(0)));
            factory.transferOwnership(timelock);
            registry.transferOwnership(timelock);
        }
        vm.stopBroadcast();

        console2.log("StockVaultDeployer", address(vaults));
        console2.log("LaunchpadFactory  ", address(factory));
        console2.log("  CurveDeployer   ", address(factory.curveDeployer()));
        console2.log("  TokenDeployer   ", factory.tokenDeployer());
        console2.log("PrintHook         ", address(hook));
        console2.log("LaunchRouter      ", address(router));
        console2.log("LaunchpadRegistry ", address(registry));
        if (timelock != address(0)) console2.log("TimelockController", timelock);
        console2.log("owner now         ", factory.owner());
        console2.log("pending owner     ", factory.pendingOwner());
    }

    function mineHookSalt(bytes32 initCodeHash) public pure returns (bytes32 salt, address hookAddress) {
        for (uint256 i; i < 5_000_000; ++i) {
            hookAddress = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, bytes32(i), initCodeHash))))
            );
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) return (bytes32(i), hookAddress);
        }
        revert("no hook salt found");
    }
}
