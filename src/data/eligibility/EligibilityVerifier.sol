// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { EligibilityErrors as Errors } from "@base/global/libraries/errors/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@base/global/libraries/events/EligibilityEvents.sol";
import { IEligibilityVerifier } from "@base/global/interfaces/data/IEligibilityVerifier.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";
import { Position } from "@base/global/types/PlayerSetTypes.sol";
import {
    Appearance,
    EligibilityBucket,
    EligibilityGroups,
    MinutesStore,
    POSITION_COUNT,
    THRESHOLD_GK,
    THRESHOLD_OUTFIELD,
    THRESHOLD_UNDER_21,
    UNDER_21_AGE
} from "@src/data/eligibility/types/EligibilityTypes.sol";

/**
 * @title EligibilityVerifier
 * @notice Accumulates per-position minutes for every player that appears in match data, and
 *         backfills missing `birthDate` values via CRE-pushed reports.
 * @dev No access control yet. CRE authenticity is gated by `CreReceiver` forwarder checks.
 *      Solidity cannot pull CRE; missing-DOB detection enqueues + emits `BirthDateFetchNeeded`
 *      for an event/cron-driven CRE workflow that posts back through `onReport`.
 *
 *      `playerId` values MUST be HPIDs (`hpid-v1` bytes32), not raw Opta personUuids.
 *      Writers (ingest / CRE) call `toHpid(personUuid, HP_ID_KEY, "person")` before
 *      `recordAppearances` — see `cre/workflows/lib/hpid`.
 *
 *      Eligibility thresholds match the original Supabase edge fn (previous-season mins):
 *      GK ≥ 361, under-21 ≥ 181, otherwise ≥ 901. Rules may be revised once upstream
 *      season-scoping nuances are settled.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier is CreReceiver, IEligibilityVerifier {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    IPlayerSetRegistry public immutable override playerSetRegistry;

    mapping(bytes32 playerId => MinutesStore) private _minutesStore;

    /// @dev All players that have ever appeared (deployed markets or not).
    bytes32[] private _playerIds;
    mapping(bytes32 playerId => bool) private _tracked;

    /// @dev Players with `birthDate == 0` awaiting a CRE reference fetch.
    bytes32[] private _pendingBirthDateIds;
    /// @dev 1-based index into `_pendingBirthDateIds`; `0` means not pending.
    mapping(bytes32 playerId => uint256) private _pendingBirthDateIndex;

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param forwarder_ Chainlink `KeystoneForwarder` for this chain.
    /// @param playerSetRegistry_ Canonical registry used to skip already-deployed markets.
    constructor(address forwarder_, address playerSetRegistry_) CreReceiver(forwarder_) {
        if (playerSetRegistry_ == address(0)) revert Errors.ZeroAddress();
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
    }

    // --------------------------------------------
    //  Minutes ingest
    // --------------------------------------------

    /// @inheritdoc IEligibilityVerifier
    function recordAppearances(Appearance[] calldata appearances) external {
        uint256 length = appearances.length;
        bytes32[] memory newlyPending = new bytes32[](length);
        uint256 pendingCount;

        for (uint256 i; i < length; ++i) {
            Appearance calldata appearance = appearances[i];
            if (appearance.playerId == bytes32(0)) revert Errors.ZeroId();
            if (appearance.minsPlayed == 0) continue;

            MinutesStore storage store = _minutesStore[appearance.playerId];

            if (!_tracked[appearance.playerId]) {
                _tracked[appearance.playerId] = true;
                _playerIds.push(appearance.playerId);
            }

            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 posIndex = uint256(uint8(appearance.position));
            if (posIndex >= POSITION_COUNT) revert Errors.ZeroId();

            uint32 cumulative = store.minsByPosition[posIndex] + appearance.minsPlayed;
            store.minsByPosition[posIndex] = cumulative;
            store.expectedPosition = _deriveExpectedPosition(store);

            emit Events.MinutesUpdated(
                appearance.playerId, appearance.position, appearance.minsPlayed, cumulative, store.expectedPosition
            );

            if (store.birthDate == 0 && _enqueuePendingBirthDate(appearance.playerId)) {
                newlyPending[pendingCount] = appearance.playerId;
                unchecked {
                    ++pendingCount;
                }
            }
        }

        emit Events.AppearancesRecorded(length);

        if (pendingCount != 0) {
            bytes32[] memory queued = new bytes32[](pendingCount);
            for (uint256 j; j < pendingCount; ++j) {
                queued[j] = newlyPending[j];
            }
            emit Events.BirthDateFetchNeeded(queued);
        }
    }

    // --------------------------------------------
    //  DOB scanner (CRE trigger surface)
    // --------------------------------------------

    /// @inheritdoc IEligibilityVerifier
    function scanMissingBirthDates(uint256 offset, uint256 limit) external returns (bytes32[] memory queued) {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return new bytes32[](0);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        bytes32[] memory buffer = new bytes32[](end - offset);
        uint256 count;

        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            if (_minutesStore[playerId].birthDate != 0) continue;
            if (!_enqueuePendingBirthDate(playerId)) continue;
            buffer[count] = playerId;
            unchecked {
                ++count;
            }
        }

        queued = new bytes32[](count);
        for (uint256 j; j < count; ++j) {
            queued[j] = buffer[j];
        }

        if (count != 0) {
            emit Events.BirthDateFetchNeeded(queued);
        }
    }

    // --------------------------------------------
    //  Eligibility
    // --------------------------------------------

    /// @inheritdoc IEligibilityVerifier
    function verifyEligibility(uint256 offset, uint256 limit)
        external
        view
        returns (EligibilityGroups memory groups)
    {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return groups;
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 gkCount;
        uint256 u21Count;
        uint256 outCount;

        // Pass 1: size cohorts for this page.
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            if (playerSetRegistry.playerExists(playerId)) continue;

            (bool eligible, EligibilityBucket bucket,) = _evaluate(playerId);
            if (!eligible) continue;

            if (bucket == EligibilityBucket.Goalkeeper) {
                unchecked {
                    ++gkCount;
                }
            } else if (bucket == EligibilityBucket.Under21) {
                unchecked {
                    ++u21Count;
                }
            } else if (bucket == EligibilityBucket.Outfield) {
                unchecked {
                    ++outCount;
                }
            }
        }

        groups.goalkeepers = new bytes32[](gkCount);
        groups.under21 = new bytes32[](u21Count);
        groups.outfield = new bytes32[](outCount);

        uint256 gkIdx;
        uint256 u21Idx;
        uint256 outIdx;

        // Pass 2: fill.
        for (uint256 i = offset; i < end; ++i) {
            bytes32 playerId = _playerIds[i];
            if (playerSetRegistry.playerExists(playerId)) continue;

            (bool eligible, EligibilityBucket bucket,) = _evaluate(playerId);
            if (!eligible) continue;

            if (bucket == EligibilityBucket.Goalkeeper) {
                groups.goalkeepers[gkIdx] = playerId;
                unchecked {
                    ++gkIdx;
                }
            } else if (bucket == EligibilityBucket.Under21) {
                groups.under21[u21Idx] = playerId;
                unchecked {
                    ++u21Idx;
                }
            } else if (bucket == EligibilityBucket.Outfield) {
                groups.outfield[outIdx] = playerId;
                unchecked {
                    ++outIdx;
                }
            }
        }
    }

    /// @inheritdoc IEligibilityVerifier
    function isEligible(bytes32 playerId)
        external
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 totalMins)
    {
        return _evaluate(playerId);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IEligibilityVerifier
    function playerCount() external view returns (uint256) {
        return _playerIds.length;
    }

    /// @inheritdoc IEligibilityVerifier
    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return _slice(_playerIds, offset, limit);
    }

    /// @inheritdoc IEligibilityVerifier
    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _minutesStore[playerId];
    }

    /// @inheritdoc IEligibilityVerifier
    function totalMinsPlayed(bytes32 playerId) external view returns (uint32) {
        return _totalMins(_minutesStore[playerId]);
    }

    /// @inheritdoc IEligibilityVerifier
    function pendingBirthDateCount() external view returns (uint256) {
        return _pendingBirthDateIds.length;
    }

    /// @inheritdoc IEligibilityVerifier
    function pendingBirthDateIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory) {
        return _slice(_pendingBirthDateIds, offset, limit);
    }

    // --------------------------------------------
    //  CRE fulfill
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    function _processReport(bytes calldata, bytes calldata report) internal override {
        (bytes32[] memory playerIds_, uint256[] memory birthDates) = abi.decode(report, (bytes32[], uint256[]));

        uint256 length = playerIds_.length;
        if (length == 0) revert Errors.EmptyReport();
        if (length != birthDates.length) revert Errors.LengthMismatch(length, birthDates.length);

        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds_[i];
            uint256 birthDate = birthDates[i];

            if (playerId == bytes32(0)) revert Errors.ZeroId();
            if (birthDate == 0) revert Errors.ZeroBirthDate(playerId);
            if (!_tracked[playerId]) revert Errors.UnknownPlayer(playerId);

            MinutesStore storage store = _minutesStore[playerId];
            if (store.birthDate != 0) revert Errors.BirthDateAlreadySet(playerId, store.birthDate);

            store.birthDate = birthDate;
            _dequeuePendingBirthDate(playerId);

            emit Events.BirthDateUpdated(playerId, birthDate);
        }
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    /**
     * @dev Mirrors `isPlayerEligible` from the original edge fn:
     *      missing DOB → false; GK → 361; age < 21 → 181; else → 901.
     *      Age uses whole years from unix DOB (`(now - birth) / 365 days`).
     */
    function _evaluate(bytes32 playerId)
        private
        view
        returns (bool eligible, EligibilityBucket bucket, uint32 totalMins)
    {
        MinutesStore storage store = _minutesStore[playerId];
        totalMins = _totalMins(store);

        if (store.birthDate == 0) {
            return (false, EligibilityBucket.None, totalMins);
        }

        if (store.expectedPosition == Position.GK) {
            bucket = EligibilityBucket.Goalkeeper;
            eligible = totalMins >= THRESHOLD_GK;
            return (eligible, bucket, totalMins);
        }

        if (_ageYears(store.birthDate) < UNDER_21_AGE) {
            bucket = EligibilityBucket.Under21;
            eligible = totalMins >= THRESHOLD_UNDER_21;
            return (eligible, bucket, totalMins);
        }

        bucket = EligibilityBucket.Outfield;
        eligible = totalMins >= THRESHOLD_OUTFIELD;
    }

    function _totalMins(MinutesStore storage store) private view returns (uint32 total) {
        for (uint256 i; i < POSITION_COUNT; ++i) {
            total += store.minsByPosition[i];
        }
    }

    /// @dev Whole years since unix DOB; leap years are ignored (same spirit as a simple day-count age).
    function _ageYears(uint256 birthDate) private view returns (uint256) {
        if (birthDate == 0 || birthDate >= block.timestamp) return 0;
        return (block.timestamp - birthDate) / 365 days;
    }

    /// @dev Ties keep the current `expectedPosition` (no change when the new max equals the old).
    function _deriveExpectedPosition(MinutesStore storage store) private view returns (Position) {
        Position best = store.expectedPosition;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 bestMins = store.minsByPosition[uint8(best)];

        for (uint256 i; i < POSITION_COUNT; ++i) {
            uint32 mins = store.minsByPosition[i];
            if (mins > bestMins) {
                bestMins = mins;
                // forge-lint: disable-next-line(unsafe-typecast)
                best = Position(uint8(i));
            }
        }
        return best;
    }

    /// @return enqueued True if the player was newly added to the pending queue.
    function _enqueuePendingBirthDate(bytes32 playerId) private returns (bool enqueued) {
        if (_pendingBirthDateIndex[playerId] != 0) return false;
        _pendingBirthDateIds.push(playerId);
        _pendingBirthDateIndex[playerId] = _pendingBirthDateIds.length; // 1-based
        return true;
    }

    function _dequeuePendingBirthDate(bytes32 playerId) private {
        uint256 index1 = _pendingBirthDateIndex[playerId];
        if (index1 == 0) return;

        uint256 index0 = index1 - 1;
        uint256 lastIndex0 = _pendingBirthDateIds.length - 1;

        if (index0 != lastIndex0) {
            bytes32 lastId = _pendingBirthDateIds[lastIndex0];
            _pendingBirthDateIds[index0] = lastId;
            _pendingBirthDateIndex[lastId] = index1;
        }

        _pendingBirthDateIds.pop();
        delete _pendingBirthDateIndex[playerId];
    }

    function _slice(bytes32[] storage source, uint256 offset, uint256 limit) private view returns (bytes32[] memory out) {
        uint256 total = source.length;
        if (offset >= total || limit == 0) {
            return new bytes32[](0);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 n = end - offset;
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = source[offset + i];
        }
    }
}
