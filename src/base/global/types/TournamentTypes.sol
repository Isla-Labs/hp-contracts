// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

// --------------------------------------------
//  Domestic Events
// --------------------------------------------

struct League {
    address pbrTreasury;
    Cup[] cups;
}

struct Cup {
    bytes32 cupId;
    Round[] rounds;
}

struct Round {
    uint32 roundNumber;
    uint256 roundStartTime;
    uint256 roundEndTime;
}

// --------------------------------------------
//  International Events
// --------------------------------------------

struct Continental {
    address pbrTreasury;
    Cup[] cups;
}

struct International {
    address pbrTreasury;
    Cup[] cups;
}
