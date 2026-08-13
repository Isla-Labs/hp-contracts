// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { RateLimit } from "@base/abstract/RateLimit.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MatchweekErrors as Errors } from "@errors/data/MatchweekErrors.sol";
import { MatchweekEvents as Events } from "@events/data/MatchweekEvents.sol";
import { IPbrHistorical } from "@interfaces/data/IPbrHistorical.sol";
import { IRoundManager } from "@interfaces/data/IRoundManager.sol";
import { ISquadStore } from "@interfaces/data/ISquadStore.sol";
import { ITournamentInitializer } from "@interfaces/initializers/ITournamentInitializer.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import {
    LiveRoundSyncKind,
    RoundFetchPhase,
    SeasonFetchStep,
    SeasonRef,
    TournamentRoundFetch
} from "@types/data/RoundManagerTypes.sol";
import { SquadFetchPhase } from "@types/data/SquadStoreTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { RoundSchedule, TournamentType } from "@types/registries/TournamentTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

/**
 * @title RoundManager
 * @notice Round-calendar fetch state machine + SoT writes into `TournamentRegistry`.
 * @dev Seasons are batched under a parent `tournamentId` onchain, but oracle args key off
 *      `seasonId`. Per season (earliest → latest):
 *        1) `FormatRounds` — one schedule job with all round windows (e.g. 38)
 *        2) `UpsertFixtures` — paged schedule job (10 rounds / ≤100 fixtures each)
 *      Historical uses `HistoricalRoundSync`; Live uses `RoundSync` (calendar probe + refresh).
 *      After historical seasons complete → `Live` (latest season only; `refreshRounds`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract RoundManager is AddressBook, Oracle, RateLimit, IRoundManager {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @notice Max rounds covered by one fixture-page oracle request (≤100 fixtures).
    uint32 public constant FIXTURE_ROUNDS_PER_REQUEST = 10;

    /// @notice Default min seconds between `refreshRounds` kicks (cron cadence).
    uint256 public constant DEFAULT_REFRESH_COOLDOWN = 1 hours;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 tournamentId => TournamentRoundFetch) private _fetch;
    mapping(bytes32 requestId => bytes32 tournamentId) private _requestTournament;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /**
     * @param addressProvider_ Canonical `AddressProvider` (`CVM_ROUTER` must already be registered).
     * @param refreshCooldown_ Min seconds between `refreshRounds` (`0` → 1 hour).
     */
    constructor(
        address addressProvider_,
        uint256 refreshCooldown_
    )
        AddressBook(addressProvider_)
        Oracle(_cvmRouter(addressProvider_))
        RateLimit(refreshCooldown_ == 0 ? DEFAULT_REFRESH_COOLDOWN : refreshCooldown_)
    {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  Bootstrap
    // --------------------------------------------

    /// @inheritdoc IRoundManager
    function openTournament(
        bytes32 tournamentId,
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) external onlyOrchestrator returns (bytes32 requestId) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        uint256 length = seasonIds.length;
        if (length != seasonStartYears.length) revert Errors.ArrayLengthsMismatch();

        TournamentRoundFetch storage fetch = _fetch[tournamentId];
        if (fetch.phase != RoundFetchPhase.None) revert Errors.FetchAlreadyActive(tournamentId);

        if (length == 0) {
            emit Events.RoundFetchQueued(tournamentId, seasonIds, seasonStartYears, RoundFetchPhase.None);
            return bytes32(0);
        }

        SeasonRef[] memory ordered = _sortSeasonsAscending(seasonIds, seasonStartYears);
        for (uint256 i; i < length; ++i) {
            fetch.seasons.push(ordered[i]);
        }

        fetch.phase = RoundFetchPhase.Historical;
        fetch.step = SeasonFetchStep.FormatRounds;
        fetch.seasonIndex = 0;
        fetch.fixtureRoundCursor = 0;
        fetch.finalRound = 0;

        emit Events.RoundFetchQueued(tournamentId, seasonIds, seasonStartYears, RoundFetchPhase.Historical);
        emit Events.RoundFetchPhaseChanged(tournamentId, RoundFetchPhase.None, RoundFetchPhase.Historical);

        requestId = _openOracleRequest(tournamentId, fetch);
    }

    // --------------------------------------------
    //  Recurring — permissionless (latest season)
    // --------------------------------------------

    /// @inheritdoc IRoundManager
    function refreshRounds(bytes32 tournamentId) external rateLimited returns (bytes32 requestId) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();
        TournamentRoundFetch storage fetch = _fetch[tournamentId];
        if (fetch.phase != RoundFetchPhase.Live) revert Errors.NotLive(tournamentId);
        if (fetch.seasons.length == 0) revert Errors.ZeroId();
        if (fetch.pendingRequestId != bytes32(0)) {
            revert Errors.OracleRequestPending(fetch.pendingRequestId);
        }

        fetch.seasonIndex = uint32(fetch.seasons.length - 1);
        fetch.step = SeasonFetchStep.FormatRounds;
        fetch.fixtureRoundCursor = 0;
        fetch.finalRound = 0;

        requestId = _openOracleRequest(tournamentId, fetch);
        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        emit Events.RoundRefreshQueued(tournamentId, season.seasonId, season.seasonStartYear, requestId);
    }

    // --------------------------------------------
    //  Writes (manual ops → TournamentRegistry)
    // --------------------------------------------

    /// @inheritdoc IRoundManager
    /// @dev `finalRound` is set by `TournamentRegistry.openSeason`; RoundManager does not mutate it.
    function setFinalRound(bytes32, uint16, uint32) external view onlyOrchestrator {
        revert Errors.InvalidFinalRound();
    }

    /// @inheritdoc IRoundManager
    function upsertRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule calldata round
    ) external onlyOrchestrator {
        _tournamentRegistry().upsertRound(tournamentId, seasonStartYear, round);
    }

    /// @inheritdoc IRoundManager
    function upsertRounds(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        RoundSchedule[] calldata rounds
    ) external onlyOrchestrator {
        _tournamentRegistry().upsertRounds(tournamentId, seasonStartYear, rounds);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IRoundManager
    function getFetchState(bytes32 tournamentId) external view returns (TournamentRoundFetch memory) {
        return _fetch[tournamentId];
    }

    /// @inheritdoc IRoundManager
    function getLatestSeason(bytes32 tournamentId) external view returns (SeasonRef memory) {
        SeasonRef[] storage seasons = _fetch[tournamentId].seasons;
        uint256 length = seasons.length;
        if (length == 0) revert Errors.ZeroId();
        return seasons[length - 1];
    }

    /// @inheritdoc IRoundManager
    function getFetchPhase(bytes32 tournamentId) external view returns (RoundFetchPhase) {
        return _fetch[tournamentId].phase;
    }

    /// @inheritdoc IRoundManager
    function getFinalRound(bytes32 tournamentId, uint16 seasonStartYear) external view returns (uint32) {
        return _tournamentRegistry().getFinalRound(tournamentId, seasonStartYear);
    }

    /// @inheritdoc IRoundManager
    function getRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSchedule memory) {
        return _tournamentRegistry().getRound(tournamentId, seasonStartYear, roundNumber);
    }

    /// @inheritdoc IRoundManager
    function isRoundPublished(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (bool) {
        return _tournamentRegistry().isRoundPublished(tournamentId, seasonStartYear, roundNumber);
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        bytes32 tournamentId = _requestTournament[requestId];
        if (tournamentId == bytes32(0)) revert Errors.UnknownOracleRequest(requestId);

        TournamentRoundFetch storage fetch = _fetch[tournamentId];
        if (fetch.pendingRequestId != requestId) revert Errors.UnknownOracleRequest(requestId);

        delete _requestTournament[requestId];
        fetch.pendingRequestId = bytes32(0);

        if (err.length != 0) {
            emit Events.RoundOracleFailed(requestId, tournamentId, err);
            return;
        }

        if (fetch.phase == RoundFetchPhase.Live) {
            _fulfillLive(tournamentId, fetch, response);
            return;
        }

        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];

        if (fetch.step == SeasonFetchStep.FormatRounds) {
            _applyFormatRounds(tournamentId, season.seasonStartYear, fetch, response);
            fetch.step = SeasonFetchStep.UpsertFixtures;
            fetch.fixtureRoundCursor = 1;
            emit Events.SeasonFetchStepChanged(
                tournamentId, season.seasonId, SeasonFetchStep.FormatRounds, SeasonFetchStep.UpsertFixtures
            );
            _openOracleRequest(tournamentId, fetch);
            return;
        }

        if (fetch.step != SeasonFetchStep.UpsertFixtures) {
            revert Errors.UnexpectedFetchStep(uint8(fetch.step));
        }

        _applyFixtureRounds(tournamentId, season.seasonStartYear, response);

        uint32 nextCursor = fetch.fixtureRoundCursor + FIXTURE_ROUNDS_PER_REQUEST;
        if (nextCursor <= fetch.finalRound) {
            fetch.fixtureRoundCursor = nextCursor;
            _openOracleRequest(tournamentId, fetch);
            return;
        }

        _advanceAfterSeasonComplete(tournamentId, fetch);
    }

    // --------------------------------------------
    //  Internals — oracle requests
    // --------------------------------------------

    function _openOracleRequest(
        bytes32 tournamentId,
        TournamentRoundFetch storage fetch
    ) private returns (bytes32 requestId) {
        if (fetch.pendingRequestId != bytes32(0)) {
            revert Errors.OracleRequestPending(fetch.pendingRequestId);
        }

        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        uint32 cursor = fetch.step == SeasonFetchStep.FormatRounds ? 0 : fetch.fixtureRoundCursor;

        bytes memory args;
        CvmJob job;
        if (fetch.phase == RoundFetchPhase.Live) {
            // Live: include tournamentId for competitionUuid → tournamentCalendar?comp=
            args = abi.encode(tournamentId, season.seasonId, season.seasonStartYear, fetch.step, cursor);
            job = CvmJob.RoundSync;
        } else {
            // Historical: CVM keys off seasonId only.
            args = abi.encode(season.seasonId, season.seasonStartYear, fetch.step, cursor);
            job = CvmJob.HistoricalRoundSync;
        }
        requestId = _sendOracleRequest(job, args);

        fetch.pendingRequestId = requestId;
        _requestTournament[requestId] = tournamentId;

        emit Events.RoundScheduleRequested(
            requestId, tournamentId, season.seasonId, season.seasonStartYear, fetch.step, cursor
        );
    }

    /// @dev Live `RoundSync` response: `abi.encode(uint8 kind, bytes payload)`.
    function _fulfillLive(bytes32 tournamentId, TournamentRoundFetch storage fetch, bytes memory response) private {
        (uint8 kindRaw, bytes memory payload) = abi.decode(response, (uint8, bytes));
        LiveRoundSyncKind kind = LiveRoundSyncKind(kindRaw);

        if (kind == LiveRoundSyncKind.OpenSeason) {
            (bytes32 newSeasonId, uint16 seasonStartYear, uint32 finalRound) =
                abi.decode(payload, (bytes32, uint16, uint32));
            _applyOpenSeason(tournamentId, fetch, newSeasonId, seasonStartYear, finalRound);
            return;
        }

        if (kind != LiveRoundSyncKind.Refresh) revert Errors.UnexpectedLiveKind(kindRaw);

        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];

        if (fetch.step == SeasonFetchStep.FormatRounds) {
            _applyFormatRounds(tournamentId, season.seasonStartYear, fetch, payload);
            fetch.step = SeasonFetchStep.UpsertFixtures;
            fetch.fixtureRoundCursor = 1;
            emit Events.SeasonFetchStepChanged(
                tournamentId, season.seasonId, SeasonFetchStep.FormatRounds, SeasonFetchStep.UpsertFixtures
            );
            _openOracleRequest(tournamentId, fetch);
            return;
        }

        if (fetch.step != SeasonFetchStep.UpsertFixtures) {
            revert Errors.UnexpectedFetchStep(uint8(fetch.step));
        }

        _applyFixtureRounds(tournamentId, season.seasonStartYear, payload);

        uint32 nextCursor = fetch.fixtureRoundCursor + FIXTURE_ROUNDS_PER_REQUEST;
        if (nextCursor <= fetch.finalRound) {
            fetch.fixtureRoundCursor = nextCursor;
            _openOracleRequest(tournamentId, fetch);
            return;
        }

        // Live season fully refreshed — stay Live on latest.
        fetch.step = SeasonFetchStep.UpsertFixtures;
        fetch.fixtureRoundCursor = 0;
    }

    function _applyOpenSeason(
        bytes32 tournamentId,
        TournamentRoundFetch storage fetch,
        bytes32 newSeasonId,
        uint16 seasonStartYear,
        uint32 finalRound
    ) private {
        if (newSeasonId == bytes32(0) || seasonStartYear == 0 || finalRound == 0) {
            revert Errors.ZeroId();
        }

        SeasonRef storage latest = fetch.seasons[fetch.seasons.length - 1];
        if (seasonStartYear <= latest.seasonStartYear) revert Errors.DuplicateSeasonYear(seasonStartYear);

        _tournamentInitializer().openSeason(tournamentId, newSeasonId, seasonStartYear, finalRound);

        fetch.seasons.push(SeasonRef({ seasonId: newSeasonId, seasonStartYear: seasonStartYear }));
        fetch.seasonIndex = uint32(fetch.seasons.length - 1);
        fetch.step = SeasonFetchStep.FormatRounds;
        fetch.fixtureRoundCursor = 0;
        fetch.finalRound = 0;

        emit Events.SeasonOpenedViaRefresh(tournamentId, newSeasonId, seasonStartYear, finalRound);

        if (_tournamentRegistry().getTournamentType(tournamentId) == TournamentType.DOMESTIC_LEAGUE) {
            _squadStore().adoptSeason(tournamentId, newSeasonId, seasonStartYear);
        }

        _openOracleRequest(tournamentId, fetch);
    }

    function _tournamentInitializer() private view returns (ITournamentInitializer) {
        return ITournamentInitializer(_getAddress(_addressKey(Addresses.TOURNAMENT_INITIALIZER)));
    }

    function _advanceAfterSeasonComplete(bytes32 tournamentId, TournamentRoundFetch storage fetch) private {
        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        uint32 nextSeason = fetch.seasonIndex + 1;

        if (nextSeason < fetch.seasons.length) {
            emit Events.SeasonFetchStepChanged(
                tournamentId, season.seasonId, SeasonFetchStep.UpsertFixtures, SeasonFetchStep.FormatRounds
            );
            fetch.seasonIndex = nextSeason;
            fetch.step = SeasonFetchStep.FormatRounds;
            fetch.fixtureRoundCursor = 0;
            fetch.finalRound = 0;
            _openOracleRequest(tournamentId, fetch);
            return;
        }

        RoundFetchPhase previous = fetch.phase;
        fetch.phase = RoundFetchPhase.Live;
        fetch.seasonIndex = uint32(fetch.seasons.length - 1);
        fetch.step = SeasonFetchStep.UpsertFixtures;
        fetch.fixtureRoundCursor = 0;
        emit Events.RoundFetchPhaseChanged(tournamentId, previous, RoundFetchPhase.Live);
        // Live `RoundSync` kick is a separate entrypoint (latest season only).
        _tryOpenHistoricalDms(tournamentId);
    }

    /**
     * @dev Peer rendezvous: when rounds are Live, open `PbrHistorical` if squads are ready
     *      (domestic) or immediately (non-domestic — SquadStore never arms).
     */
    function _tryOpenHistoricalDms(bytes32 tournamentId) private {
        TournamentType tournamentType = _tournamentRegistry().getTournamentType(tournamentId);
        if (tournamentType == TournamentType.DOMESTIC_LEAGUE) {
            if (_squadStore().getFetchPhase(tournamentId) != SquadFetchPhase.Live) return;
        }
        _pbrHistorical().openHistorical(tournamentId);
    }

    // --------------------------------------------
    //  Internals — apply responses
    // --------------------------------------------

    /// @dev Response: `abi.encode(RoundSchedule[] rounds)` — windows only (`fixtureIds` empty).
    function _applyFormatRounds(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        TournamentRoundFetch storage fetch,
        bytes memory response
    ) private {
        RoundSchedule[] memory rounds = abi.decode(response, (RoundSchedule[]));
        uint256 length = rounds.length;
        if (length == 0) revert Errors.EmptyRounds();

        uint32 expected = _tournamentRegistry().getFinalRound(tournamentId, seasonStartYear);
        if (uint32(length) != expected) revert Errors.RoundCountMismatch(expected, uint32(length));

        for (uint256 i; i < length; ++i) {
            if (rounds[i].fixtureIds.length != 0) {
                // Format phase must not carry fixtures (keeps the first response small).
                delete rounds[i].fixtureIds;
            }
        }

        _tournamentRegistry().upsertRounds(tournamentId, seasonStartYear, rounds);
        fetch.finalRound = uint32(length);
    }

    /// @dev Response: `abi.encode(RoundSchedule[] rounds)` — up to 10 rounds with fixture ids.
    function _applyFixtureRounds(bytes32 tournamentId, uint16 seasonStartYear, bytes memory response) private {
        RoundSchedule[] memory rounds = abi.decode(response, (RoundSchedule[]));
        if (rounds.length == 0) revert Errors.EmptyRounds();
        _tournamentRegistry().upsertRounds(tournamentId, seasonStartYear, rounds);
    }

    // --------------------------------------------
    //  Internals — helpers
    // --------------------------------------------

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _squadStore() private view returns (ISquadStore) {
        return ISquadStore(_getAddress(_addressKey(Addresses.SQUAD_STORE)));
    }

    function _pbrHistorical() private view returns (IPbrHistorical) {
        return IPbrHistorical(_getAddress(_addressKey(Addresses.PBR_HISTORICAL)));
    }

    /// @dev Insertion sort by `seasonStartYear` ascending; reverts on duplicate years.
    function _sortSeasonsAscending(
        bytes32[] calldata seasonIds,
        uint16[] calldata seasonStartYears
    ) private pure returns (SeasonRef[] memory ordered) {
        uint256 length = seasonIds.length;
        ordered = new SeasonRef[](length);
        for (uint256 i; i < length; ++i) {
            if (seasonIds[i] == bytes32(0) || seasonStartYears[i] == 0) revert Errors.ZeroId();
            ordered[i] = SeasonRef({ seasonId: seasonIds[i], seasonStartYear: seasonStartYears[i] });
        }

        for (uint256 i = 1; i < length; ++i) {
            SeasonRef memory key = ordered[i];
            uint256 j = i;
            while (j > 0 && ordered[j - 1].seasonStartYear > key.seasonStartYear) {
                ordered[j] = ordered[j - 1];
                unchecked {
                    --j;
                }
            }
            if (j > 0 && ordered[j - 1].seasonStartYear == key.seasonStartYear) {
                revert Errors.DuplicateSeasonYear(key.seasonStartYear);
            }
            ordered[j] = key;
        }

        for (uint256 i = 1; i < length; ++i) {
            if (ordered[i].seasonStartYear == ordered[i - 1].seasonStartYear) {
                revert Errors.DuplicateSeasonYear(ordered[i].seasonStartYear);
            }
        }
    }
}
