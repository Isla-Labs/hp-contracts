// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library AccessRoles {
    bytes32 public constant CATEGORY_THREE = keccak256("CATEGORY_THREE");
    bytes32 public constant CATEGORY_TWO = keccak256("CATEGORY_TWO");
    bytes32 public constant CATEGORY_ONE = keccak256("CATEGORY_ONE");
}