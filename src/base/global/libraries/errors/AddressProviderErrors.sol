// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library AddressProviderErrors {
    error ZeroKey();
    error EmptyName();
    error NameKeyMismatch();
    error AddressAlreadyBound(bytes32 key, address current);
    error ZeroAddress();
    error AddressNotFound();
}
