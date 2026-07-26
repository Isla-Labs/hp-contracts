// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

interface IAppRegistry {
    function isBeneficiary(bytes32 appId, address account) external view returns (bool);
}
