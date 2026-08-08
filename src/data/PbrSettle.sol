// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { Oracle } from "@base/abstract/Oracle.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { PbrSettleErrors as Errors } from "@errors/data/PbrSettleErrors.sol";
import { PbrSettleEvents as Events } from "@events/data/PbrSettleEvents.sol";
import { IPbrSettle } from "@interfaces/data/IPbrSettle.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { CvmJob } from "@types/oracle/CvmTypes.sol";
import { PendingSettle } from "@types/data/PbrSettleTypes.sol";
import { AddressProvider } from "@src/AddressProvider.sol";

/**
 * @title PbrSettle
 * @notice Global settle pipeline: treasury-gated `settleRound` → `CvmJob.SettleDms` → `finalizeRound`.
 * @dev Only `TournamentRegistry.getPbrTreasury(tournamentId)` may open a settle. The CVM job verifies
 *      DMS/performance via Succinct zk-proof; fulfill decodes `(vaults, mwPoints, adjTotalPoints)` and
 *      calls `PbrTreasury.finalizeRound` on the requesting treasury.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrSettle is Initializable, AddressBook, Ownable, Oracle, IPbrSettle {
    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ITournamentRegistry public tournamentRegistry;

    mapping(bytes32 requestId => PendingSettle) private _pending;
    /// @notice In-flight CVM request per `jobId(tournament, season, round)`; zero when idle.
    mapping(bytes32 id => bytes32 requestId) public pendingRequest;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_)
        AddressBook(addressProvider_)
        Ownable(msg.sender)
        Oracle(_cvmRouter(addressProvider_))
    {
        if (addressProvider_ == address(0)) revert Errors.ZeroAddress();
        _disableInitializers();
    }

    /// @notice Resolve registry; ownership → Orchestrator.
    function initialize() external initializer {
        address orch = _getAddress(_addressKey(Addresses.ORCHESTRATOR));
        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        _transferOwnership(orch);
    }

    function _cvmRouter(address addressProvider_) private view returns (address router) {
        router = AddressProvider(payable(addressProvider_)).get(keccak256(bytes(Addresses.CVM_ROUTER)));
        if (router == address(0)) revert Errors.ZeroAddress();
    }

    // --------------------------------------------
    //  Kickoff (PbrTreasury only)
    // --------------------------------------------

    /// @inheritdoc IPbrSettle
    function settleRound(
        bytes32 tournamentId,
        uint16 season,
        uint32 roundNumber,
        address[] calldata utilizedVaults
    ) external returns (bytes32 requestId) {
        // Empty utilized set is allowed (no stakers); CVM still settles the round.
        address treasury = tournamentRegistry.getPbrTreasury(tournamentId);
        if (treasury == address(0)) revert Errors.TreasuryMissing(tournamentId);
        if (msg.sender != treasury) revert Errors.Unauthorized();

        bytes32 id = jobId(tournamentId, season, roundNumber);
        bytes32 existing = pendingRequest[id];
        if (existing != bytes32(0)) revert Errors.SettlePending(id, existing);

        bytes memory args = abi.encode(tournamentId, season, roundNumber, utilizedVaults);
        requestId = _sendOracleRequest(CvmJob.SettleDms, args);

        _pending[requestId] =
            PendingSettle({ treasury: treasury, tournamentId: tournamentId, season: season, roundNumber: roundNumber });
        pendingRequest[id] = requestId;

        emit Events.SettleRequested(
            requestId, tournamentId, treasury, season, roundNumber, utilizedVaults.length
        );
    }

    // --------------------------------------------
    //  Oracle callback
    // --------------------------------------------

    /// @inheritdoc Oracle
    function _fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
        PendingSettle memory p = _pending[requestId];
        if (p.treasury == address(0)) revert Errors.UnknownOracleRequest(requestId);

        bytes32 id = jobId(p.tournamentId, p.season, p.roundNumber);
        delete _pending[requestId];
        delete pendingRequest[id];

        if (err.length != 0) {
            emit Events.SettleFailed(requestId, p.tournamentId, err);
            return;
        }

        (address[] memory vaults, uint256[] memory mwPoints, uint256 adjTotalPoints) =
            abi.decode(response, (address[], uint256[], uint256));

        if (vaults.length != mwPoints.length) revert Errors.LengthMismatch();

        uint256 sumPoints;
        for (uint256 i; i < mwPoints.length; ++i) {
            sumPoints += mwPoints[i];
        }
        // Empty set ⇒ `adjTotalPoints` must be 0; otherwise sum must match (incl. all-zero MW).
        if (sumPoints != adjTotalPoints) revert Errors.MAdjMismatch(sumPoints, adjTotalPoints);

        IPbrTreasury(p.treasury).finalizeRound(vaults, mwPoints, adjTotalPoints);

        emit Events.SettleFulfilled(
            requestId, p.tournamentId, p.season, p.roundNumber, adjTotalPoints, vaults.length
        );
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @inheritdoc IPbrSettle
    function jobId(bytes32 tournamentId, uint16 season, uint32 roundNumber) public pure returns (bytes32) {
        return keccak256(abi.encode(tournamentId, season, roundNumber));
    }
}
