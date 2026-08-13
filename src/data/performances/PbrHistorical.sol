// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { PbrHistoricalErrors as Errors } from "@errors/data/PbrHistoricalErrors.sol";
import { PbrHistoricalEvents as Events } from "@events/data/PbrHistoricalEvents.sol";
import { IPbrHistorical } from "@interfaces/data/IPbrHistorical.sol";
import { IRoundManager } from "@interfaces/data/IRoundManager.sol";
import { ISquadStore } from "@interfaces/data/ISquadStore.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import {
    Appearance,
    HistoricalDmsPhase,
    HistoricalFixtureJob,
    HistoricalFixturePhase,
    PendingHistorical,
    TournamentHistoricalDms
} from "@types/data/PbrHistoricalTypes.sol";
import { SeasonRef } from "@types/data/RoundManagerTypes.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { RoundSchedule, TournamentType } from "@types/registries/TournamentTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

/**
 * @title PbrHistorical
 * @notice Historical DMS ingest after RoundManager (+ SquadStore for domestic) bootstrap.
 * @dev Peer-kicked via `openHistorical`. Per published round (Settle pattern):
 *        - Fan out one `HistoricalDms` oracle job per fixture (≤10)
 *        - Each fulfill stores RSS digest; domestic also `SquadStore.recordAppearances`
 *        - Fixture `err` → reset + auto-retry that fixture only
 *        - When round complete → open next round / season / Complete
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrHistorical is AddressBook, Oracle, IPbrHistorical {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 tournamentId => TournamentHistoricalDms) private _fetch;
    mapping(bytes32 requestId => PendingHistorical) private _pending;
    mapping(bytes32 fixtureJobId_ => bytes32 requestId) public pendingRequest;
    mapping(bytes32 fixtureJobId_ => HistoricalFixtureJob) private _fixtures;

    mapping(bytes32 fixtureId => bytes32 rssDigest) private _rssDigest;
    mapping(bytes32 fixtureId => Appearance[]) private _appearances;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyBootstrapPeer() {
        address sender = msg.sender;
        if (
            sender != _getAddress(_addressKey(Addresses.ROUND_MANAGER))
                && sender != _getAddress(_addressKey(Addresses.SQUAD_STORE))
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (`CVM_ROUTER` must already be registered).
    constructor(address addressProvider_) AddressBook(addressProvider_) Oracle(_cvmRouter(addressProvider_)) {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  Bootstrap — RoundManager / SquadStore
    // --------------------------------------------

    /// @inheritdoc IPbrHistorical
    function openHistorical(bytes32 tournamentId) external onlyBootstrapPeer returns (bytes32[] memory requestIds) {
        if (tournamentId == bytes32(0)) revert Errors.ZeroId();

        TournamentHistoricalDms storage fetch = _fetch[tournamentId];
        if (fetch.phase != HistoricalDmsPhase.None) {
            return requestIds;
        }

        SeasonRef[] memory seasons = _roundManager().getFetchState(tournamentId).seasons;
        uint256 length = seasons.length;
        if (length == 0) revert Errors.NoSeasons(tournamentId);

        for (uint256 i; i < length; ++i) {
            fetch.seasons.push(seasons[i]);
        }

        fetch.phase = HistoricalDmsPhase.Running;
        fetch.seasonIndex = 0;
        fetch.roundNumber = 1;
        fetch.writeAppearances = _tournamentRegistry().getTournamentType(tournamentId) == TournamentType.DOMESTIC_LEAGUE;

        emit Events.HistoricalDmsOpened(tournamentId, length, fetch.writeAppearances);
        emit Events.HistoricalDmsPhaseChanged(tournamentId, HistoricalDmsPhase.None, HistoricalDmsPhase.Running);

        requestIds = _openRound(tournamentId, fetch);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IPbrHistorical
    function getFetchState(bytes32 tournamentId) external view returns (TournamentHistoricalDms memory) {
        return _fetch[tournamentId];
    }

    /// @inheritdoc IPbrHistorical
    function getFetchPhase(bytes32 tournamentId) external view returns (HistoricalDmsPhase) {
        return _fetch[tournamentId].phase;
    }

    /// @inheritdoc IPbrHistorical
    function getRssDigest(bytes32 fixtureId) external view returns (bytes32) {
        return _rssDigest[fixtureId];
    }

    /// @inheritdoc IPbrHistorical
    function getAppearances(bytes32 fixtureId) external view returns (Appearance[] memory) {
        return _appearances[fixtureId];
    }

    /// @inheritdoc IPbrHistorical
    function fixtureJobId(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(tournamentId, seasonStartYear, roundNumber, fixtureId));
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        PendingHistorical memory p = _pending[requestId];
        if (p.tournamentId == bytes32(0)) revert Errors.UnknownOracleRequest(requestId);

        bytes32 fid = fixtureJobId(p.tournamentId, p.seasonStartYear, p.roundNumber, p.fixtureId);
        delete _pending[requestId];
        delete pendingRequest[fid];

        if (err.length != 0) {
            _fixtures[fid].phase = HistoricalFixturePhase.None;
            _fixtures[fid].requestId = bytes32(0);
            emit Events.HistoricalFixtureFailed(requestId, p.tournamentId, p.fixtureId, err);
            // Retry this fixture only — other in-flight fixtures keep progressing.
            bytes32 retryId = _openFixture(p.tournamentId, p.seasonId, p.seasonStartYear, p.roundNumber, p.fixtureId);
            emit Events.HistoricalFixtureRetry(p.tournamentId, p.fixtureId, retryId);
            return;
        }

        (bytes32 fixtureId, bytes32 rssDigest, Appearance[] memory appearances) =
            abi.decode(response, (bytes32, bytes32, Appearance[]));

        if (fixtureId != p.fixtureId) revert Errors.FixtureIdMismatch(p.fixtureId, fixtureId);
        if (rssDigest == bytes32(0)) revert Errors.ZeroHash();
        if (_rssDigest[fixtureId] != bytes32(0)) revert Errors.FixtureDigestExists(fixtureId);

        _rssDigest[fixtureId] = rssDigest;
        emit Events.RssDigestStored(fixtureId, rssDigest);

        for (uint256 i; i < appearances.length; ++i) {
            Appearance memory row = appearances[i];
            if (row.fixtureId == bytes32(0) || row.playerId == bytes32(0)) revert Errors.ZeroId();
            if (row.fixtureId != fixtureId) revert Errors.FixtureIdMismatch(fixtureId, row.fixtureId);
            _appearances[fixtureId].push(row);
        }

        TournamentHistoricalDms storage fetch = _fetch[p.tournamentId];
        bool wrote;
        if (fetch.writeAppearances && appearances.length != 0) {
            _squadStore().recordAppearances(p.seasonId, p.seasonStartYear, appearances);
            wrote = true;
        }

        HistoricalFixtureJob storage job = _fixtures[fid];
        job.phase = HistoricalFixturePhase.Done;
        job.requestId = bytes32(0);

        unchecked {
            ++fetch.fixturesDone;
        }

        emit Events.HistoricalFixtureApplied(requestId, p.tournamentId, fixtureId, rssDigest, appearances.length, wrote);

        if (fetch.fixturesDone >= fetch.fixturesExpected) {
            emit Events.HistoricalRoundComplete(p.tournamentId, p.seasonId, p.roundNumber, fetch.fixturesDone);
            _advanceAfterRound(p.tournamentId, fetch);
        }
    }

    // --------------------------------------------
    //  Internals — round / fixture fan-out
    // --------------------------------------------

    function _openRound(
        bytes32 tournamentId,
        TournamentHistoricalDms storage fetch
    ) private returns (bytes32[] memory requestIds) {
        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        RoundSchedule memory round =
            _tournamentRegistry().getRound(tournamentId, season.seasonStartYear, fetch.roundNumber);

        uint256 fixtureCount = round.fixtureIds.length;
        if (fixtureCount == 0) {
            revert Errors.EmptyFixtures(tournamentId, season.seasonStartYear, fetch.roundNumber);
        }

        fetch.fixturesExpected = uint32(fixtureCount);
        fetch.fixturesDone = 0;

        requestIds = new bytes32[](fixtureCount);
        for (uint256 i; i < fixtureCount;) {
            requestIds[i] = _openFixture(
                tournamentId, season.seasonId, season.seasonStartYear, fetch.roundNumber, round.fixtureIds[i]
            );
            unchecked {
                ++i;
            }
        }

        emit Events.HistoricalRoundOpened(
            tournamentId, season.seasonId, season.seasonStartYear, fetch.roundNumber, uint32(fixtureCount)
        );
    }

    function _openFixture(
        bytes32 tournamentId,
        bytes32 seasonId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) private returns (bytes32 requestId) {
        if (fixtureId == bytes32(0)) revert Errors.ZeroId();

        bytes32 fid = fixtureJobId(tournamentId, seasonStartYear, roundNumber, fixtureId);
        bytes32 existing = pendingRequest[fid];
        if (existing != bytes32(0)) revert Errors.FixturePending(fid, existing);

        HistoricalFixtureJob storage job = _fixtures[fid];
        if (job.phase == HistoricalFixturePhase.Done) revert Errors.FixtureAlreadyDone(fixtureId);
        if (job.phase == HistoricalFixturePhase.Requested) {
            revert Errors.BadFixturePhase(fid, job.phase, HistoricalFixturePhase.None);
        }

        bytes memory args = abi.encode(tournamentId, seasonId, seasonStartYear, roundNumber, fixtureId);
        requestId = _sendOracleRequest(CvmJob.HistoricalDms, args);

        _pending[requestId] = PendingHistorical({
            tournamentId: tournamentId,
            seasonId: seasonId,
            seasonStartYear: seasonStartYear,
            roundNumber: roundNumber,
            fixtureId: fixtureId
        });
        pendingRequest[fid] = requestId;

        job.phase = HistoricalFixturePhase.Requested;
        job.fixtureId = fixtureId;
        job.requestId = requestId;

        emit Events.HistoricalFixtureRequested(requestId, tournamentId, fixtureId, seasonStartYear, roundNumber);
    }

    function _advanceAfterRound(bytes32 tournamentId, TournamentHistoricalDms storage fetch) private {
        SeasonRef storage season = fetch.seasons[fetch.seasonIndex];
        uint32 finalRound = _tournamentRegistry().getFinalRound(tournamentId, season.seasonStartYear);

        if (fetch.roundNumber < finalRound) {
            unchecked {
                ++fetch.roundNumber;
            }
            _openRound(tournamentId, fetch);
            return;
        }

        uint32 nextSeason = fetch.seasonIndex + 1;
        if (nextSeason < fetch.seasons.length) {
            fetch.seasonIndex = nextSeason;
            fetch.roundNumber = 1;
            _openRound(tournamentId, fetch);
            return;
        }

        fetch.phase = HistoricalDmsPhase.Complete;
        fetch.fixturesExpected = 0;
        fetch.fixturesDone = 0;
        emit Events.HistoricalDmsPhaseChanged(tournamentId, HistoricalDmsPhase.Running, HistoricalDmsPhase.Complete);
    }

    // --------------------------------------------
    //  Internals — resolvers
    // --------------------------------------------

    function _roundManager() private view returns (IRoundManager) {
        return IRoundManager(_getAddress(_addressKey(Addresses.ROUND_MANAGER)));
    }

    function _squadStore() private view returns (ISquadStore) {
        return ISquadStore(_getAddress(_addressKey(Addresses.SQUAD_STORE)));
    }

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }
}
