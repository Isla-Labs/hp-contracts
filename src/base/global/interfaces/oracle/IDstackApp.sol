// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IDstackApp
 * @notice Minimal surface of Phala Onchain KMS `DstackApp` used by `CvmCoordinator`.
 * @dev See https://github.com/Phala-Network/dstack/blob/master/kms/auth-eth/contracts/DstackApp.sol
 */
interface IDstackApp {
    function owner() external view returns (address);

    function allowAnyDevice() external view returns (bool);

    function allowedComposeHashes(bytes32 composeHash) external view returns (bool);

    function allowedDeviceIds(bytes32 deviceId) external view returns (bool);

    function addComposeHash(bytes32 composeHash) external;

    function removeComposeHash(bytes32 composeHash) external;

    function addDevice(bytes32 deviceId) external;

    function removeDevice(bytes32 deviceId) external;

    function setAllowAnyDevice(bool allowAnyDevice_) external;

    function transferOwnership(address newOwner) external;
}
