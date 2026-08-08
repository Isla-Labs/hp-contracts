// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

struct Beneficiary {
    address account;
    uint256 shareWad;
}

struct Position {
    bytes32 playerId;
    address vault;
    uint256 advancedTradeReserve;
    uint256 vaultPrincipal;
    uint256 stakedRemaining;
    uint256 unlockedClaimable;
    uint64 allocatedAt;
    uint8 nextTranche;
    bool allocated;
}
