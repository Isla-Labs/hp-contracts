// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { PbrSettleErrors as Errors } from "@errors/data/PbrSettleErrors.sol";
import { PbrSettleEvents as Events } from "@events/data/PbrSettleEvents.sol";
import { IPbrSettle } from "@interfaces/data/IPbrSettle.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import {
    FixturePhase,
    FixtureSettlement,
    PendingSettle,
    RoundSettlePhase,
    RoundSettlement
} from "@types/data/PbrSettleTypes.sol";
import { RoundSchedule } from "@types/registries/TournamentTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

/**
 * @title PbrSettle
 * @notice Per-fixture settle: `settleRound` fans out `SettleDms` → fulfill applies vault points.
 * @dev Fulfill response:
 *      `abi.encode(bytes32 utilizedHash, bytes32 fixtureDigest, bytes proof, address[] vaults, uint256[] mwPoints)`.
 *      On oracle `err`: auto-retry that fixture up to `MAX_FIXTURE_SETTLE_RETRIES`, then permissionless
 *      `retryFixtureSettle`. See `pbrSettleFlow.md`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrSettle is AddressBook, Oracle, IPbrSettle {
    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    /// @dev Auto-retries after oracle `err` before ops must call `retryFixtureSettle`.
    uint8 public constant MAX_FIXTURE_SETTLE_RETRIES = 3;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 requestId => PendingSettle) private _pending;
    mapping(bytes32 fixtureJobId_ => bytes32 requestId) public pendingRequest;

    mapping(bytes32 roundId_ => RoundSettlement) private _rounds;
    mapping(bytes32 fixtureJobId_ => FixtureSettlement) private _fixtures;

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
    //  AddressBook resolvers
    // --------------------------------------------

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    // --------------------------------------------
    //  Settle (PbrTreasury only)
    // --------------------------------------------

    /// @inheritdoc IPbrSettle
    function settleRound(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 utilizedHash
    ) external returns (bytes32[] memory requestIds) {
        if (utilizedHash == bytes32(0)) revert Errors.ZeroHash();
        ITournamentRegistry tournamentRegistry = _tournamentRegistry();

        address treasury = tournamentRegistry.getPbrTreasury(tournamentId);
        if (treasury == address(0)) revert Errors.TreasuryMissing(tournamentId);
        if (msg.sender != treasury) revert Errors.Unauthorized();

        bytes32 rid = roundId(tournamentId, seasonStartYear, roundNumber);
        RoundSettlement storage round = _rounds[rid];
        if (round.phase == RoundSettlePhase.Requested) revert Errors.RoundSettlePending(rid);

        RoundSchedule memory schedule = tournamentRegistry.getRound(tournamentId, seasonStartYear, roundNumber);
        uint256 fixtureCount = schedule.fixtureIds.length;
        if (fixtureCount == 0) revert Errors.NoFixtures();

        round.phase = RoundSettlePhase.Requested;
        round.treasury = treasury;
        round.tournamentId = tournamentId;
        round.seasonStartYear = seasonStartYear;
        round.roundNumber = roundNumber;
        round.utilizedHash = utilizedHash;
        round.fixturesExpected = uint32(fixtureCount);
        round.fixturesSettled = 0;

        requestIds = new bytes32[](fixtureCount);
        for (uint256 i; i < fixtureCount;) {
            requestIds[i] = _settleFixture(
                treasury, tournamentId, seasonStartYear, roundNumber, schedule.fixtureIds[i], utilizedHash
            );
            unchecked {
                ++i;
            }
        }

        emit Events.RoundSettleOpened(
            tournamentId, treasury, seasonStartYear, roundNumber, utilizedHash, uint32(fixtureCount)
        );
    }

    /// @inheritdoc IPbrSettle
    function retryFixtureSettle(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) external returns (bytes32 requestId) {
        bytes32 rid = roundId(tournamentId, seasonStartYear, roundNumber);
        RoundSettlement storage round = _rounds[rid];
        if (round.phase != RoundSettlePhase.Requested) revert Errors.RoundNotSettlePending(rid);
        if (round.treasury == address(0)) revert Errors.Unauthorized();

        bytes32 fid = fixtureJobId(tournamentId, seasonStartYear, roundNumber, fixtureId);
        FixtureSettlement storage f = _fixtures[fid];
        if (f.phase != FixturePhase.None) revert Errors.FixtureNotRetryable(fid, f.phase);

        requestId =
            _settleFixture(round.treasury, tournamentId, seasonStartYear, roundNumber, fixtureId, round.utilizedHash);
        emit Events.FixtureSettleRetry(tournamentId, fixtureId, requestId, f.retryCount);
    }

    /// @dev Open one `SettleDms` job for `fixtureId`. Preserves `retryCount` across re-opens.
    function _settleFixture(
        address treasury,
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId,
        bytes32 utilizedHash
    ) internal returns (bytes32 requestId) {
        if (fixtureId == bytes32(0)) revert Errors.ZeroFixture();

        bytes32 fid = fixtureJobId(tournamentId, seasonStartYear, roundNumber, fixtureId);
        bytes32 existing = pendingRequest[fid];
        if (existing != bytes32(0)) revert Errors.FixturePending(fid, existing);

        FixtureSettlement storage f = _fixtures[fid];
        if (f.phase == FixturePhase.Proven) revert Errors.FixtureAlreadySettled(fixtureId);
        if (f.phase == FixturePhase.Requested) {
            revert Errors.BadFixturePhase(fid, f.phase, FixturePhase.None);
        }

        bytes memory args = abi.encode(tournamentId, seasonStartYear, roundNumber, fixtureId, utilizedHash);
        requestId = _sendOracleRequest(CvmJob.SettleDms, args);

        _pending[requestId] = PendingSettle({
            treasury: treasury,
            tournamentId: tournamentId,
            seasonStartYear: seasonStartYear,
            roundNumber: roundNumber,
            fixtureId: fixtureId,
            utilizedHash: utilizedHash
        });
        pendingRequest[fid] = requestId;

        f.phase = FixturePhase.Requested;
        f.fixtureId = fixtureId;
        f.fixtureDigest = bytes32(0);
        f.proofHash = bytes32(0);
        f.requestId = requestId;
        // `retryCount` left intact (0 on first open; incremented only on auto-retry).

        emit Events.FixtureSettleRequested(
            requestId, tournamentId, fixtureId, seasonStartYear, roundNumber, utilizedHash
        );
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        PendingSettle memory p = _pending[requestId];
        if (p.treasury == address(0)) revert Errors.UnknownOracleRequest(requestId);

        bytes32 fid = fixtureJobId(p.tournamentId, p.seasonStartYear, p.roundNumber, p.fixtureId);
        delete _pending[requestId];
        delete pendingRequest[fid];

        if (err.length != 0) {
            FixtureSettlement storage failed = _fixtures[fid];
            failed.phase = FixturePhase.None;
            failed.requestId = bytes32(0);
            emit Events.FixtureSettleFailed(requestId, p.tournamentId, p.fixtureId, err);

            // Auto-retry this fixture only — other in-flight fixtures keep progressing.
            if (failed.retryCount < MAX_FIXTURE_SETTLE_RETRIES) {
                unchecked {
                    ++failed.retryCount;
                }
                bytes32 retryId = _settleFixture(
                    p.treasury, p.tournamentId, p.seasonStartYear, p.roundNumber, p.fixtureId, p.utilizedHash
                );
                emit Events.FixtureSettleRetry(p.tournamentId, p.fixtureId, retryId, failed.retryCount);
            } else {
                emit Events.FixtureSettleRetryExhausted(p.tournamentId, p.fixtureId, failed.retryCount, err);
            }
            return;
        }

        (
            bytes32 utilizedHash,
            bytes32 fixtureDigest,
            bytes memory proof,
            address[] memory vaults,
            uint256[] memory mwPoints
        ) = abi.decode(response, (bytes32, bytes32, bytes, address[], uint256[]));

        if (utilizedHash != p.utilizedHash) {
            revert Errors.UtilizedHashMismatch(p.utilizedHash, utilizedHash);
        }
        if (fixtureDigest == bytes32(0)) revert Errors.ZeroHash();
        if (vaults.length != mwPoints.length) revert Errors.LengthMismatch();

        bytes32 proofHash = keccak256(proof);

        FixtureSettlement storage f = _fixtures[fid];
        f.phase = FixturePhase.Proven;
        f.fixtureDigest = fixtureDigest;
        f.proofHash = proofHash;

        bool done = IPbrTreasury(p.treasury).applyFixtureSettlement(p.fixtureId, fixtureDigest, vaults, mwPoints);

        bytes32 rid = roundId(p.tournamentId, p.seasonStartYear, p.roundNumber);
        RoundSettlement storage round = _rounds[rid];
        unchecked {
            ++round.fixturesSettled;
        }
        if (done || round.fixturesSettled >= round.fixturesExpected) {
            round.phase = RoundSettlePhase.Complete;
            emit Events.RoundSettleComplete(p.tournamentId, p.seasonStartYear, p.roundNumber, round.fixturesSettled);
        }

        emit Events.FixtureSettleProven(requestId, p.tournamentId, p.fixtureId, fixtureDigest, proofHash, vaults.length);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IPbrSettle
    function roundId(bytes32 tournamentId, uint16 seasonStartYear, uint32 roundNumber) public pure returns (bytes32) {
        return keccak256(abi.encode(tournamentId, seasonStartYear, roundNumber));
    }

    /// @inheritdoc IPbrSettle
    function fixtureJobId(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(tournamentId, seasonStartYear, roundNumber, fixtureId));
    }

    /// @inheritdoc IPbrSettle
    function getRoundSettlement(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber
    ) external view returns (RoundSettlement memory) {
        return _rounds[roundId(tournamentId, seasonStartYear, roundNumber)];
    }

    /// @inheritdoc IPbrSettle
    function getFixtureSettlement(
        bytes32 tournamentId,
        uint16 seasonStartYear,
        uint32 roundNumber,
        bytes32 fixtureId
    ) external view returns (FixtureSettlement memory) {
        return _fixtures[fixtureJobId(tournamentId, seasonStartYear, roundNumber, fixtureId)];
    }
}
