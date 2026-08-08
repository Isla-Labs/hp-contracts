// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/// @notice Competition class used by fee routing (`PbrFeeHub`) and calendars.
/// @dev Domestic leagues own a fee hub; domestic cups share that hub as destinations.
enum TournamentType {
    DOMESTIC_LEAGUE,
    DOMESTIC_CUP,
    CONTINENTAL,
    INTERNATIONAL
}

struct Tournament {
    TournamentType tournamentType;
    Hub[] feeHubs; // list of PbrFeeHub contracts that distribute fees to this tournament
    bytes32 tournamentId;
    address pbrTreasury;
    Season[] seasons; // identity + round calendar SoT on `TournamentRegistry`
}

struct Hub {
    bytes32 leagueId;
    address pbrFeeHub;
}

// --------------------------------------------
//  Season + round calendar (TournamentRegistry)
// --------------------------------------------

/// @notice Season identity and round calendar — SoT on `TournamentRegistry`.
struct Season {
    bytes32 seasonId;
    uint16 seasonStartYear;
    uint32 finalRound;
    uint32 roundCount;
    RoundSchedule[] rounds;
}

struct RoundSchedule {
    uint32 roundNumber;
    uint64 startTime;
    uint64 endTime;
    bytes32[] fixtureIds;
}

// --------------------------------------------
//  DeployTournament types
// --------------------------------------------

/// @notice Season opened at deploy; rounds filled later via `upsertRounds`.
struct BootstrapSeason {
    bytes32 seasonId;
    uint16 seasonStartYear;
    uint32 finalRound;
}

/**
 * @param tournamentId Stable tournament id.
 * @param initialSeason Season written into `PbrTreasury.initialize`.
 * @param treasurySalt CreateX salt for `PbrTreasuryFactory.create` (mine offchain for `0x99…`).
 * @param seasons Optional seasons (`openSeason`); empty skips.
 */
struct BootstrapParams {
    bytes32 tournamentId;
    uint16 initialSeason;
    bytes32 treasurySalt;
    BootstrapSeason[] seasons;
}

/**
 * @param tournamentType Deployment branch selector.
 * @param bootstrap Shared treasury / season stub params.
 * @param leagueIds Type-specific hub context:
 *        - `DOMESTIC_LEAGUE` / `INTERNATIONAL`: ignored (pass empty)
 *        - `DOMESTIC_CUP`: exactly one existing domestic `leagueId`
 *        - `CONTINENTAL`: one or more existing domestic `leagueId`s
 */
struct DeployParams {
    TournamentType tournamentType;
    BootstrapParams bootstrap;
    bytes32[] leagueIds;
}

struct DeployResult {
    address pbrTreasury;
    address pbrFeeHub; // set for DOMESTIC_LEAGUE only; zero otherwise
}
