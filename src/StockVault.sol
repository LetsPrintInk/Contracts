// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v5 — UNAUDITED.

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  Letsprint.ink StockVault
/// @notice A non-rebasing wrapper for one xStock. xStock balances rebase on EVM chains when the issuer
///         applies a dividend or split, which would break any contract that records its own reserves
///         (bonding curves, Uniswap v4 pools). Curves and pools therefore hold shares of this vault,
///         whose balances never change; dividends and splits move the share price instead, because
///         totalAssets() is simply this vault's live xStock balance.
/// @dev    Plain OpenZeppelin ERC-4626 with no owner, fee, pause or upgrade path. The decimals offset
///         makes the classic first-depositor donation attack unprofitable, and StockVaultDeployer seeds
///         every vault with one locked xStock so its rate cannot be moved cheaply.
///         Issuer risk is not removable: if the xStock issuer paused transfers, wrapping and unwrapping
///         would pause too (trading in vault shares would continue); if it blocked or seized this
///         vault's balance, every share would lose its backing. The site must disclose this.
contract StockVault is ERC4626 {
    constructor(IERC20Metadata stock)
        ERC20(string.concat("Letsprint ", stock.symbol()), string.concat("lp", stock.symbol()))
        ERC4626(stock)
    {}

    function _decimalsOffset() internal pure override returns (uint8) {
        return 3;
    }

    /// @dev While no shares exist the rate is fixed at 1 xStock unit = 1,000 shares, so stock sent here
    ///      before the first deposit cannot move it (it simply goes to the first depositor). Pairs set
    ///      their graduation target in shares, which this keeps meaningful.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        if (totalSupply() == 0) return assets * 1e3;
        return super._convertToShares(assets, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        if (totalSupply() == 0) return Math.mulDiv(shares, 1, 1e3, rounding);
        return super._convertToAssets(shares, rounding);
    }
}

/// @title  Letsprint.ink StockVaultDeployer
/// @notice Deploys exactly one StockVault per xStock at a deterministic address. The factory only
///         approves vaults from this deployer, so a stock pair can never use foreign code.
///         Each new vault is seeded with one whole xStock, paid by the caller and locked forever behind
///         shares owned by a dead address. Those shares own most of anything sent to the vault, so
///         re-pricing its shares costs the attacker real stock (doubling the rate costs at least one
///         whole xStock, lost for good) instead of dust.
contract StockVaultDeployer {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    mapping(address xStock => address vault) public vaultOf;
    mapping(address vault => bool) public isVault;

    event VaultDeployed(address indexed xStock, address indexed vault);

    /// @notice One whole unit of the xStock: what a new vault is seeded with.
    function seedAmount(address xStock) public view returns (uint256) {
        return 10 ** IERC20Metadata(xStock).decimals();
    }

    /// @notice Permissionless and idempotent: returns the existing vault if there is one. Creating a vault
    ///         pulls seedAmount(xStock) from the caller (approve this contract first).
    function deploy(address xStock) external returns (address vault) {
        vault = vaultOf[xStock];
        if (vault != address(0)) return vault;
        vault = address(new StockVault{salt: bytes32(uint256(uint160(xStock)))}(IERC20Metadata(xStock)));
        vaultOf[xStock] = vault;
        isVault[vault] = true;
        uint256 seed = seedAmount(xStock);
        IERC20(xStock).safeTransferFrom(msg.sender, address(this), seed);
        IERC20(xStock).forceApprove(vault, seed);
        StockVault(vault).deposit(seed, DEAD);
        emit VaultDeployed(xStock, vault);
    }
}
