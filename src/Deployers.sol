// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v6 — UNAUDITED. Build settings are listed at the top of BondingCurve.sol.

import {BondingCurve, CurveConfig} from "./BondingCurve.sol";
import {TokenTemplate, TokenMetadata} from "./TokenTemplate.sol";

interface ILaunchWindow {
    function deploying() external view returns (bool);
}

/// @title  Letsprint.ink CurveDeployer
/// @notice Holds the BondingCurve creation code so the factory stays under the 24 KB contract size
///         limit. The LaunchpadFactory creates it in its constructor, and only that factory can use it.
/// @dev    No owner and no settings. It creates its own TokenDeployer, so the factory, the
///         CurveDeployer and the TokenDeployer are bound to each other at deployment, with no setup
///         calls anyone could front-run.
contract CurveDeployer {
    address public immutable factory;
    TokenDeployer public immutable tokenDeployer;

    error OnlyFactory();

    constructor() {
        factory = msg.sender;
        tokenDeployer = new TokenDeployer();
    }

    /// @notice Create one launch's curve, which creates its token. Factory only. The salt already
    ///         mixes in the creator, so a mined address cannot be taken by anyone else.
    function deploy(
        bytes32 salt,
        address creator,
        TokenMetadata calldata meta,
        uint256 creatorTaxBps,
        address[] calldata teamWallets,
        address[] calldata feeRecipients,
        uint16[] calldata feeShares,
        CurveConfig calldata cfg
    ) external returns (BondingCurve curve) {
        if (msg.sender != factory) revert OnlyFactory();
        // EIP-1153 transient flag: on only while the new curve's constructor runs. That constructor
        // makes one external call, to the TokenDeployer, so nothing else can act inside this window.
        assembly ("memory-safe") {
            tstore(0, 1)
        }
        curve = new BondingCurve{salt: salt}(creator, meta, creatorTaxBps, teamWallets, feeRecipients, feeShares, cfg);
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }

    /// @notice True only while this contract is constructing a curve.
    function deploying() external view returns (bool on) {
        assembly ("memory-safe") {
            on := tload(0)
        }
    }
}

/// @title  Letsprint.ink TokenDeployer
/// @notice Holds the TokenTemplate creation code. It only works while the CurveDeployer is
///         constructing a curve, so every token it ever created is a real Letsprint.ink launch, and a
///         copycat cannot mint look-alike tokens that show this contract as their creator.
/// @dev    Tokens are created with CREATE2, so each token's address is known before launch.
contract TokenDeployer {
    ILaunchWindow public immutable curveDeployer;

    error OnlyDuringLaunch();

    constructor() {
        curveDeployer = ILaunchWindow(msg.sender);
    }

    /// @notice Create the calling curve's token. The curve receives the entire supply.
    function deploy(TokenMetadata calldata meta) external returns (TokenTemplate token) {
        if (!curveDeployer.deploying()) revert OnlyDuringLaunch();
        token = new TokenTemplate{salt: bytes32(0)}(meta, msg.sender);
    }
}
