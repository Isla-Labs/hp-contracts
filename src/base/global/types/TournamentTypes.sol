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
    Season[] seasons; // identity stubs; round calendar SoT is `RoundManager`
}

struct Hub {
    bytes32 leagueId;
    address pbrFeeHub;
}

// --------------------------------------------
//  Season identity per tournament (TournamentRegistry)
// --------------------------------------------

/// @notice Season identity only — `finalRound` / rounds live in `RoundManager`.
struct Season {
    bytes32 seasonId;
    uint16 seasonStartYear;
}

// --------------------------------------------
//  Round calendar (RoundManager)
// --------------------------------------------

struct RoundSchedule {
    uint32 roundNumber;
    uint64 startTime;
    uint64 endTime;
    bytes32[] fixtureIds;
}

// --------------------------------------------
//  DeployTournament types
// --------------------------------------------

/// @notice Season stub opened at deploy; calendar filled later by RoundManager.
struct BootstrapSeason {
    bytes32 seasonId;
    uint16 seasonStartYear;
}

/**
 * @param tournamentId Stable tournament id.
 * @param initialSeason Season written into `PbrTreasury.initialize`.
 * @param treasurySalt CreateX salt for `PbrTreasuryFactory.create` (mine offchain for `0x99…`).
 * @param seasons Optional season stubs (`openSeason`); empty skips.
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