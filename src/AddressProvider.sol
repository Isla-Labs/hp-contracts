// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { EnumerableSet } from "@openzeppelin/utils/structs/EnumerableSet.sol";

import { AddressProviderErrors as Errors } from "@errors/AddressProviderErrors.sol";
import { AddressProviderEvents as Events } from "@events/AddressProviderEvents.sol";

/// @title HighPotential Address Provider
/// @notice Dynamic registry: each logical slot is a `bytes32` key; string names use `keccak256(bytes(name))`.
/// @dev Enumeration tracks keys with a non-zero address. Mutations are `DEFAULT_ADMIN_ROLE`-gated;
///      bootstrap grants the deployer admin, who may later `transferDefaultAdmin` to
///      `ConstitutionalTimelock`.
contract AddressProvider is AccessControl {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    EnumerableSet.Bytes32Set private _keys;
    mapping(bytes32 key => address) private _addr;
    mapping(bytes32 key => string) private _label;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param admin_ Deployer EOA — temporary `DEFAULT_ADMIN_ROLE` until handoff to
     *        `ConstitutionalTimelock`.
     */
    constructor(address admin_) {
        if (admin_ == address(0)) revert Errors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    // --------------------------------------------
    //  Role admin helpers
    // --------------------------------------------

    /// @notice Atomically move `DEFAULT_ADMIN_ROLE` from the caller to `newAdmin`.
    /// @dev Intended path: deployer → `ConstitutionalTimelock`.
    function transferDefaultAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert Errors.ZeroAddress();
        address previousAdmin = _msgSender();
        if (newAdmin == previousAdmin) return;
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
        emit Events.DefaultAdminTransferred(previousAdmin, newAdmin);
    }

    // --------------------------------------------
    //  Mutations (DEFAULT_ADMIN_ROLE)
    // --------------------------------------------

    /// @notice First-write only: reverts if `key` already holds a non-zero address.
    function registerName(string calldata name, address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(name).length == 0) revert Errors.EmptyName();
        if (addr == address(0)) return;

        bytes32 key = keccak256(bytes(name));
        address cur = _addr[key];
        if (cur != address(0)) revert Errors.AddressAlreadyBound(key, cur);

        _set(key, addr, name);
        emit Events.AddressSet(key, name, _addr[key], addr);
    }

    /// @notice First-write only for raw keys.
    function registerKey(bytes32 key, address addr, string calldata name) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (key == bytes32(0)) revert Errors.ZeroKey();
        if (addr == address(0)) return;
        if (bytes(name).length != 0 && keccak256(bytes(name)) != key) revert Errors.NameKeyMismatch();

        address cur = _addr[key];
        if (cur != address(0)) revert Errors.AddressAlreadyBound(key, cur);

        string memory label_ = name;
        if (bytes(name).length == 0) {
            label_ = _label[key];
        }

        _set(key, addr, label_);
        emit Events.AddressSet(key, name, _addr[key], addr);
    }

    /// @notice Upsert by human-readable `name`. Storage key is `keccak256(bytes(name))`.
    function setName(string calldata name, address addr) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bytes(name).length == 0) revert Errors.EmptyName();

        bytes32 key = keccak256(bytes(name));

        _set(key, addr, name);
        emit Events.AddressSet(key, name, _addr[key], addr);
    }

    /// @notice Upsert by raw key. Non-empty `name` must satisfy `keccak256(bytes(name)) == key`; use "" to keep the existing label.
    function setKey(bytes32 key, address addr, string calldata name) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (key == bytes32(0)) revert Errors.ZeroKey();
        if (bytes(name).length != 0) {
            if (keccak256(bytes(name)) != key) revert Errors.NameKeyMismatch();
        }

        string memory label_ = name;
        if (bytes(name).length == 0) {
            label_ = _label[key];
        }

        _set(key, addr, label_);
        emit Events.AddressSet(key, name, _addr[key], addr);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _set(bytes32 key, address addr, string memory name) private {
        address prev = _addr[key];
        if (addr == address(0)) {
            if (prev == address(0)) return;
            _addr[key] = address(0);
            _keys.remove(key);
            delete _label[key];
            return;
        }

        if (prev == address(0)) {
            _keys.add(key);
        }

        _addr[key] = addr;
        if (bytes(name).length != 0) {
            _label[key] = name;
        }
    }

    // --------------------------------------------
    //  External
    // --------------------------------------------

    function get(bytes32 key) external view returns (address) {
        return _addr[key];
    }

    function getByName(string calldata name) external view returns (address) {
        return _addr[keccak256(bytes(name))];
    }

    /// @notice Batch read by key; unset slots return `address(0)` (same semantics as `get`).
    function getMany(bytes32[] calldata keyList) external view returns (address[] memory addrs) {
        uint256 len = keyList.length;
        addrs = new address[](len);
        for (uint256 i; i < len;) {
            addrs[i] = _addr[keyList[i]];
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Batch read by registered name; empty `names[i]` reverts with `EmptyName`.
    function getManyByName(string[] calldata names) external view returns (address[] memory addrs) {
        uint256 len = names.length;
        addrs = new address[](len);
        for (uint256 i; i < len;) {
            if (bytes(names[i]).length == 0) revert Errors.EmptyName();
            addrs[i] = _addr[keccak256(bytes(names[i]))];
            unchecked {
                ++i;
            }
        }
    }

    function label(bytes32 key) external view returns (string memory) {
        return _label[key];
    }

    function keyCount() external view returns (uint256) {
        return _keys.length();
    }

    function keyAt(uint256 index) external view returns (bytes32) {
        return _keys.at(index);
    }

    function keys() external view returns (bytes32[] memory) {
        return _keys.values();
    }

    /// @notice `AddressProvider` name key: `keccak256(bytes(name))` (matches `getByName`)
    function addressKey(string memory name) external pure returns (bytes32 key) {
        key = _addressKey(name);
    }

    /// @notice `AddressProvider` name key: `keccak256(bytes(name))` (matches `getByName`)
    function _addressKey(string memory name) internal pure returns (bytes32 key) {
        key = keccak256(bytes(name));
    }

    /// @notice Resolves `address` via `AddressProvider`; reverts if missing or zero
    function getAddress(string memory name) external view returns (address) {
        address returnAddress = _addr[_addressKey(name)];
        if (returnAddress == address(0)) revert Errors.ZeroAddress();
        return returnAddress;
    }
}
