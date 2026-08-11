// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library AddressProviderEvents {
    event AddressSet(bytes32 indexed key, string name, address previous, address current);
    event DefaultAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
}
