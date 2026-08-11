// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";

import { DeploymentsErrors as Errors } from "@errors/lockers/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/lockers/DeploymentsEvents.sol";

import {
    Hub,
    TournamentType,
    BootstrapSeason,
    BootstrapParams,
    DeployParams,
    DeployResult
} from "@types/registries/TournamentTypes.sol";

import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";

import { IPbrTreasuryFactory } from "@interfaces/vaults/factories/IPbrTreasuryFactory.sol";
import { IPbrFeeHubFactory } from "@interfaces/markets/factories/IPbrFeeHubFactory.sol";

/**
 * @title DeployTournament
 * @notice Entry API for atomic tournament bootstrap (immutable singleton).
 * @dev Callers with `DEFAULT_ADMIN_ROLE` (EOA now, Safe later) invoke `deploy` via
 *      `Orchestrator.execute`. Inner factory / registry writes also relay through
 *      `Orchestrator.execute` so targets see `msg.sender == Orchestrator`. This contract must
 *      hold `AUTHORIZED_CONTRACT` on the Orchestrator for those nested relays.
 *
 *      Deps (`TOURNAMENT_REGISTRY`, treasury/hub factories, Orchestrator) resolve via AddressBook
 *      at call time — no local caches.
 *
 *      Unified `deploy` / `simulateDeploy` branch on `DeployParams.tournamentType`:
 *        - `DOMESTIC_LEAGUE`: deploy treasury + new fee hub, `registerHub`, create tournament
 *        - `DOMESTIC_CUP`: deploy treasury, register under one existing league hub (`leagueIds[0]`)
 *        - `CONTINENTAL`: deploy treasury, register under selected league hubs (`leagueIds`)
 *        - `INTERNATIONAL`: deploy treasury, register under all existing league hubs
 *
 *      Hub destination lists for non-league types are dual-written by
 *      `TournamentRegistry.createTournament` / `linkHub` (not this contract).
 *
 *      Seasons (`BootstrapSeason`) open via `TournamentRegistry.openSeason` (includes `finalRound`),
 *      which also writes the global reverse index `tournamentIdOfSeason[seasonId] = tournamentId`
 *      (for DOMESTIC_LEAGUE, that value is the `leagueId` DopplerLocker checks at intake).
 *      Round calendars are intentionally NOT written here — call
 *      `TournamentRegistry.upsertRounds(tournamentId, seasonStartYear, rounds)` separately
 *      (manual ops now; automated SP/oracle job later) so DeployTournament stays topology-only.
 *
 *      After a successful `DOMESTIC_LEAGUE` deploy:
 *        - `pbrFeeHubOf(tournamentId)` is set (`tournamentId` == `leagueId`)
 *        - `getPbrTreasury(tournamentId)` is set
 *        - DopplerLocker may `queueAssets(leagueId, seasonId, playerIds)` and resolve the hub
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DeployTournament is AddressBook {
    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider`.
    constructor(address addressProvider_) AddressBook(addressProvider_) { }

    // --------------------------------------------
    //  AddressBook resolvers
    // --------------------------------------------

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _pbrTreasuryFactory() private view returns (IPbrTreasuryFactory) {
        return IPbrTreasuryFactory(_getAddress(_addressKey(Addresses.PBR_TREASURY_FACTORY)));
    }

    function _pbrFeeHubFactory() private view returns (IPbrFeeHubFactory) {
        return IPbrFeeHubFactory(_getAddress(_addressKey(Addresses.PBR_FEE_HUB_FACTORY)));
    }

    // --------------------------------------------
    //  Unified deploy
    // --------------------------------------------

    /// @notice Deploy a tournament of `params.tournamentType` (treasury + hub wiring + season stubs).
    function deploy(DeployParams calldata params) external onlyOrchestrator returns (DeployResult memory result) {
        result = _deploy(params);
    }

    /// @notice Dry-run validation for `deploy` (reverts on invalid params / missing hubs).
    function simulateDeploy(DeployParams calldata params) external view {
        _simulate(params);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    /// @dev Shared pipeline: validate → treasury → fee hubs → create (+ hub destination dual-write) + seasons.
    function _deploy(DeployParams calldata params) internal returns (DeployResult memory result) {
        BootstrapParams calldata b = params.bootstrap;
        _validateBootstrap(b);

        TournamentType t = params.tournamentType;
        result.pbrTreasury = _deployTreasury(b);

        Hub[] memory feeHubs;
        if (t == TournamentType.DOMESTIC_LEAGUE) {
            result.pbrFeeHub = _createAndRegisterHub(b.tournamentId, result.pbrTreasury);
            feeHubs = _singleHub(b.tournamentId, result.pbrFeeHub);
        } else {
            feeHubs = _feeHubsFor(t, params.leagueIds);
        }

        _finalize(t, b, feeHubs, result.pbrTreasury);
    }

    function _simulate(DeployParams calldata params) internal view {
        _simulateBootstrap(params.bootstrap);
        if (params.tournamentType == TournamentType.DOMESTIC_LEAGUE) return;
        _feeHubsFor(params.tournamentType, params.leagueIds);
    }

    // --------------------------------------------
    //  Hub resolution
    // --------------------------------------------

    /// @notice Resolve fee-hub context for non-league types (also used by `simulateDeploy`).
    function _feeHubsFor(TournamentType t, bytes32[] calldata leagueIds) internal view returns (Hub[] memory feeHubs) {
        if (t == TournamentType.DOMESTIC_CUP) {
            if (leagueIds.length != 1) revert Errors.EmptyHubs();
            return _resolveHubs(leagueIds);
        }
        if (t == TournamentType.CONTINENTAL) {
            if (leagueIds.length == 0) revert Errors.EmptyHubs();
            return _resolveHubs(leagueIds);
        }
        if (t == TournamentType.INTERNATIONAL) {
            feeHubs = _tournamentRegistry().getAllDomesticHubs();
            if (feeHubs.length == 0) revert Errors.EmptyHubs();
            return feeHubs;
        }
        revert Errors.UnsupportedTournamentType(t);
    }

    function _resolveHubs(bytes32[] calldata leagueIds) internal view returns (Hub[] memory feeHubs) {
        ITournamentRegistry tr = _tournamentRegistry();
        uint256 length = leagueIds.length;
        feeHubs = new Hub[](length);
        for (uint256 i; i < length; ++i) {
            bytes32 leagueId = leagueIds[i];
            if (leagueId == bytes32(0)) revert Errors.ZeroId();
            address hubAddr = tr.pbrFeeHubOf(leagueId);
            if (hubAddr == address(0)) revert Errors.HubNotRegistered(leagueId);
            feeHubs[i] = Hub({ leagueId: leagueId, pbrFeeHub: hubAddr });
        }
    }

    function _singleHub(bytes32 leagueId, address hubAddr) internal pure returns (Hub[] memory feeHubs) {
        feeHubs = new Hub[](1);
        feeHubs[0] = Hub({ leagueId: leagueId, pbrFeeHub: hubAddr });
    }

    // --------------------------------------------
    //  Factory / registry writes
    // --------------------------------------------

    function _deployTreasury(BootstrapParams calldata b) internal returns (address pbrTreasury) {
        pbrTreasury = abi.decode(
            _exec(
                address(_pbrTreasuryFactory()),
                abi.encodeCall(IPbrTreasuryFactory.create, (b.tournamentId, b.initialSeasonStartYear, b.treasurySalt))
            ),
            (address)
        );
    }

    function _createAndRegisterHub(bytes32 leagueId, address pbrTreasury) internal returns (address hubAddr) {
        ITournamentRegistry tr = _tournamentRegistry();
        hubAddr = abi.decode(
            _exec(address(_pbrFeeHubFactory()), abi.encodeCall(IPbrFeeHubFactory.create, (leagueId, pbrTreasury))),
            (address)
        );
        _exec(
            address(tr),
            abi.encodeCall(ITournamentRegistry.registerHub, (Hub({ leagueId: leagueId, pbrFeeHub: hubAddr })))
        );
    }

    function _finalize(
        TournamentType tournamentType,
        BootstrapParams calldata b,
        Hub[] memory feeHubs,
        address pbrTreasury
    ) internal {
        ITournamentRegistry tr = _tournamentRegistry();
        _exec(
            address(tr),
            abi.encodeCall(ITournamentRegistry.createTournament, (b.tournamentId, tournamentType, feeHubs, pbrTreasury))
        );

        uint256 length = b.seasons.length;
        for (uint256 i; i < length; ++i) {
            BootstrapSeason calldata s = b.seasons[i];
            if (s.seasonId == bytes32(0) || s.seasonStartYear == 0) revert Errors.ZeroId();
            if (s.finalRound == 0) revert Errors.ZeroId();
            _exec(
                address(tr),
                abi.encodeCall(
                    ITournamentRegistry.openSeason, (b.tournamentId, s.seasonId, s.seasonStartYear, s.finalRound)
                )
            );
        }

        emit Events.TournamentDeployed(
            b.tournamentId, tournamentType, pbrTreasury, b.initialSeasonStartYear, feeHubs.length, length
        );
    }

    // --------------------------------------------
    //  Validation helpers
    // --------------------------------------------

    function _validateBootstrap(BootstrapParams calldata b) internal view {
        if (b.tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (b.initialSeasonStartYear == 0) revert Errors.ZeroSeason();
        if (b.treasurySalt == bytes32(0)) revert Errors.ZeroSalt();
        // Prevent double-bootstrap of the same tournament id (and league hub for DOMESTIC_LEAGUE).
        if (_tournamentRegistry().tournamentExists(b.tournamentId)) revert Errors.AlreadySet();
    }

    function _simulateBootstrap(BootstrapParams calldata b) internal view {
        _validateBootstrap(b);

        uint256 length = b.seasons.length;
        for (uint256 i; i < length; ++i) {
            BootstrapSeason calldata s = b.seasons[i];
            if (s.seasonId == bytes32(0) || s.seasonStartYear == 0 || s.finalRound == 0) {
                revert Errors.ZeroId();
            }
        }
    }

    // --------------------------------------------
    //  Low-level
    // --------------------------------------------

    function _exec(address target, bytes memory data) internal returns (bytes memory) {
        return IOrchestrator(_getAddress(_addressKey(Addresses.ORCHESTRATOR))).execute(target, 0, data);
    }
}
