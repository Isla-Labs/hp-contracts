// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library MarketsErrors {
    // --------------------------------------------
    //  Shared Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error Unauthorized();

    // --------------------------------------------
    //  FeeRouter Errors
    // --------------------------------------------

    error InvalidDestination();
    error DestinationNotContract();

    // --------------------------------------------
    //  PbrFeeHub Errors
    // --------------------------------------------

    error NoLiveDestination();
    error InvalidBpsTotal(uint256 total);
    error DuplicateTreasury(address treasury);
    error InternationalNotConfigured();
}
