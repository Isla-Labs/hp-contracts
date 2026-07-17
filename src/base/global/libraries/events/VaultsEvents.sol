// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

library VaultsEvents {
    // --------------------------------------------
    //  PBRTreasury Events
    // --------------------------------------------

    event PbrTreasuryCreated(bytes32 indexed tournamentId, address indexed pbrTreasury, uint16 initialSeason);

    event FeesReceived(uint256 amount);
    event VaultRegistered(address indexed vault);
    event VaultUnregistered(address indexed vault);
    event RoundLocked(uint16 indexed season, uint32 roundNumber, uint256 R, uint64 startTime, uint64 endTime, uint32 newTradingRound);
    event SeasonWrapped(uint16 indexed settledSeason, uint16 newSeason);
    event VaultSnapshotted(uint16 indexed season, uint32 roundNumber, address indexed vault, uint256 snapId);
    event SnapshotBatchProgress(uint16 indexed season, uint32 roundNumber, uint256 cursor, bool done);
    event RoundSettled(uint16 indexed season, uint32 roundNumber, uint256 M_adj, uint256 vaultCount);
    event ClaimPaid(uint16 indexed season, uint32 roundNumber, address indexed vault, address user, uint256 payout);

    // --------------------------------------------
    //  PlayerVault Events
    // --------------------------------------------

    event PlayerVaultCreated(bytes32 indexed playerId, address indexed playerVault, address indexed stToken);

    event Staked(address indexed user, uint256 amount, uint256 newTotalStaked);
    event Unstaked(address indexed user, uint256 amount, uint256 newTotalStaked);
    event SnapshotTaken(
        bytes32 indexed tournamentId, uint16 indexed seasonId, uint32 roundNumber, uint256 snapId, uint256 totalSupply
    );
    event Claimed(
        address indexed user, bytes32 indexed tournamentId, uint16 indexed seasonId, uint32 roundNumber, uint256 payout
    );

    // --------------------------------------------
    //  StakedToken Events
    // --------------------------------------------

    event StakedTokenCreated(address indexed vault, address indexed stToken, string name, string symbol);
}