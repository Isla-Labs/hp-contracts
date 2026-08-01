// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IDstackApp } from "@interfaces/oracle/IDstackApp.sol";

/// @dev Minimal DstackApp stand-in for coordinator tests.
contract MockDstackApp is IDstackApp {
    address public owner;
    bool public allowAnyDevice;
    mapping(bytes32 => bool) public allowedComposeHashes;
    mapping(bytes32 => bool) public allowedDeviceIds;

    constructor(address initialOwner) {
        owner = initialOwner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function addComposeHash(bytes32 composeHash) external onlyOwner {
        allowedComposeHashes[composeHash] = true;
    }

    function removeComposeHash(bytes32 composeHash) external onlyOwner {
        allowedComposeHashes[composeHash] = false;
    }

    function addDevice(bytes32 deviceId) external onlyOwner {
        allowedDeviceIds[deviceId] = true;
    }

    function removeDevice(bytes32 deviceId) external onlyOwner {
        allowedDeviceIds[deviceId] = false;
    }

    function setAllowAnyDevice(bool allowAnyDevice_) external onlyOwner {
        allowAnyDevice = allowAnyDevice_;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        owner = newOwner;
    }
}
