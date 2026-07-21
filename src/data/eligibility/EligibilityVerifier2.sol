// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { CreReceiver } from "@base/abstract/CreReceiver.sol";
import { EligibilityErrors as Errors } from "@base/global/libraries/errors/EligibilityErrors.sol";
import { EligibilityEvents as Events } from "@base/global/libraries/events/EligibilityEvents.sol";
import { MinutesStore } from "@src/data/eligibility/types/EligibilityTypes2.sol";

/**
 * @title EligibilityVerifier2
 * @notice Squad-first eligibility store: CRE upserts identity (`name` / `symbol` / `birthDate`);
 *         season minutes are filled later by the PPM path.
 * @dev CRE report path: KeystoneForwarder → `onReport` → `_processReport`.
 *      Constructor pins `expectedWorkflowId` so only the squad-fill workflow may write.
 *
 *      Report ABI (encoded by CRE):
 *        `(bytes32[] playerIds, string[] names, string[] symbols, uint256[] birthDates)`
 *
 *      Already-tracked `playerId`s are skipped (idempotent pages for historical backfill).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract EligibilityVerifier2 is CreReceiver {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    mapping(bytes32 playerId => MinutesStore) private _minutesStore;

    bytes32[] private _playerIds;
    mapping(bytes32 playerId => bool) private _tracked;

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param forwarder_ Chainlink `KeystoneForwarder` for this chain.
    /// @param expectedWorkflowId_ Squad-fill CRE workflow id (required; non-zero).
    constructor(address forwarder_, bytes32 expectedWorkflowId_) CreReceiver(forwarder_) {
        if (expectedWorkflowId_ == bytes32(0)) revert Errors.ZeroWorkflowId();
        _setExpectedWorkflowId(expectedWorkflowId_);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function playerCount() external view returns (uint256) {
        return _playerIds.length;
    }

    function playerIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory out) {
        uint256 total = _playerIds.length;
        if (offset >= total || limit == 0) {
            return new bytes32[](0);
        }

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 n = end - offset;
        out = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _playerIds[offset + i];
        }
    }

    function playerExists(bytes32 playerId) external view returns (bool) {
        return _tracked[playerId];
    }

    function getMinutesStore(bytes32 playerId) external view returns (MinutesStore memory) {
        return _minutesStore[playerId];
    }

    // --------------------------------------------
    //  CRE fulfill (squad-fill)
    // --------------------------------------------

    /// @inheritdoc CreReceiver
    function _processReport(bytes calldata, bytes calldata report) internal override {
        (
            bytes32[] memory playerIds_,
            string[] memory names,
            string[] memory symbols,
            uint256[] memory birthDates
        ) = abi.decode(report, (bytes32[], string[], string[], uint256[]));

        uint256 length = playerIds_.length;
        if (length == 0) revert Errors.EmptyReport();
        if (names.length != length) revert Errors.LengthMismatch(length, names.length);
        if (symbols.length != length) revert Errors.LengthMismatch(length, symbols.length);
        if (birthDates.length != length) revert Errors.LengthMismatch(length, birthDates.length);

        uint256 created;
        uint256 skipped;

        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds_[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();

            if (_tracked[playerId]) {
                unchecked {
                    ++skipped;
                }
                continue;
            }

            uint256 birthDate = birthDates[i];
            if (birthDate == 0) revert Errors.ZeroBirthDate(playerId);

            string memory name = names[i];
            string memory symbol = symbols[i];
            if (bytes(name).length == 0) revert Errors.EmptyName(playerId);
            if (bytes(symbol).length == 0) revert Errors.EmptySymbol(playerId);

            MinutesStore storage store = _minutesStore[playerId];
            store.name = name;
            store.symbol = symbol;
            store.birthDate = birthDate;
            // `expectedPosition` defaults to Position(0); `seasonMinutes` stays empty until PPM.

            _tracked[playerId] = true;
            _playerIds.push(playerId);

            unchecked {
                ++created;
            }

            emit Events.SquadPlayerCreated(playerId, name, symbol, birthDate);
        }

        emit Events.SquadPlayersCreated(created, skipped);
    }
}
