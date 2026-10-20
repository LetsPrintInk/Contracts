// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v6 — UNAUDITED. Build settings are listed at the top of BondingCurve.sol.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice Launch metadata. `name` and `symbol` become the ERC-20 fields. `metadataURI` and
///         `metadataHash` are fixed forever. The three social links can be updated later by the
///         token's current creator; every change emits SocialsUpdated.
struct TokenMetadata {
    string name;
    string symbol;
    string metadataURI; // JSON with image + description, hosted on R2 or IPFS
    bytes32 metadataHash; // keccak256 of the exact metadata file, so anyone can verify it was never swapped
    string twitter; // optional, "" if unused
    string telegram; // optional
    string website; // optional
}

interface ICurveCreator {
    function creator() external view returns (address);
}

/// @title  Letsprint.ink TokenTemplate
/// @notice A fixed-supply, ownerless ERC-20. One is deployed per launch, through the TokenDeployer,
///         while its BondingCurve is being created.
/// @dev    - 1,000,000,000 tokens are minted once, here, to the curve. There is no mint function, so
///           supply can only ever go down (holders can burn their own tokens).
///         - No owner, pause, blacklist, transfer tax, transfer restriction or upgrade path.
///         - EIP-2612 permit lets traders sell without a separate approve transaction.
///         - contractURI() (ERC-7572) points wallets and explorers at the metadata file.
contract TokenTemplate is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MAX_SOCIAL_LENGTH = 128;

    /// @notice The bonding curve this token launched on, which received the full supply.
    address public immutable curve;
    bytes32 public immutable metadataHash;

    string public metadataURI;
    string public twitter;
    string public telegram;
    string public website;

    event SocialsUpdated(address indexed by, string twitter, string telegram, string website);

    error OnlyCreator();
    error SocialTooLong();

    constructor(TokenMetadata memory meta, address curve_) ERC20(meta.name, meta.symbol) ERC20Permit(meta.name) {
        curve = curve_;
        metadataHash = meta.metadataHash;
        metadataURI = meta.metadataURI;
        twitter = meta.twitter;
        telegram = meta.telegram;
        website = meta.website;
        _mint(curve_, INITIAL_SUPPLY);
    }

    /// @notice The token's current creator (as recorded on its curve) can update the social links.
    function setSocials(string calldata twitter_, string calldata telegram_, string calldata website_) external {
        if (msg.sender != ICurveCreator(curve).creator()) revert OnlyCreator();
        if (
            bytes(twitter_).length > MAX_SOCIAL_LENGTH || bytes(telegram_).length > MAX_SOCIAL_LENGTH
                || bytes(website_).length > MAX_SOCIAL_LENGTH
        ) revert SocialTooLong();
        twitter = twitter_;
        telegram = telegram_;
        website = website_;
        emit SocialsUpdated(msg.sender, twitter_, telegram_, website_);
    }

    /// @notice ERC-7572 contract-level metadata.
    function contractURI() external view returns (string memory) {
        return metadataURI;
    }

    /// @notice Always address(0): this token has no owner. Exposed so token scanners read it as renounced.
    function owner() external pure returns (address) {
        return address(0);
    }
}
