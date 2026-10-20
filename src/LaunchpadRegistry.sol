// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Letsprint.ink v4 — UNAUDITED.

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IVersionedFactory {
    function VERSION() external view returns (string memory);
}

/// @title  Letsprint.ink LaunchpadRegistry
/// @notice One address that lists every Letsprint.ink factory version, so the site, the indexer and
///         aggregators find new versions automatically. Retiring a factory here is informational:
///         its own launchesPaused switch is what stops launches. Owned by the same timelocked Safe.
contract LaunchpadRegistry is Ownable2Step {
    struct Entry {
        address factory;
        string version;
        uint64 addedAt;
        bool retired;
    }

    Entry[] internal _entries;
    mapping(address factory => uint256) public indexOf; // 1-based; 0 = not listed

    event FactoryAdded(address indexed factory, string version);
    event FactoryRetired(address indexed factory);

    error ZeroAddress();
    error CannotRenounce();
    error AlreadyListed();
    error UnknownFactory();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice Ownership can be handed over (two steps) but never renounced.
    function renounceOwnership() public pure override {
        revert CannotRenounce();
    }

    function addFactory(address factory) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (indexOf[factory] != 0) revert AlreadyListed();
        string memory version = IVersionedFactory(factory).VERSION();
        _entries.push(Entry({factory: factory, version: version, addedAt: uint64(block.timestamp), retired: false}));
        indexOf[factory] = _entries.length;
        emit FactoryAdded(factory, version);
    }

    function retireFactory(address factory) external onlyOwner {
        uint256 i = indexOf[factory];
        if (i == 0) revert UnknownFactory();
        _entries[i - 1].retired = true;
        emit FactoryRetired(factory);
    }

    function factories() external view returns (Entry[] memory) {
        return _entries;
    }

    /// @notice The newest factory that has not been retired, or address(0).
    function latest() external view returns (address) {
        for (uint256 i = _entries.length; i > 0; --i) {
            if (!_entries[i - 1].retired) return _entries[i - 1].factory;
        }
        return address(0);
    }
}
