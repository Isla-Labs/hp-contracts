// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";

import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";

import {
    Hub,
    TournamentType,
    BootstrapSeason,
    BootstrapParams,
    DeployParams,
    DeployResult
} from "@types/TournamentTypes.sol";

import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";

import { IPbrTreasuryFactory } from "@interfaces/vaults/factories/IPbrTreasuryFactory.sol";
import { IPbrFeeHubFactory } from "@interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { IPbrFeeHub } from "@interfaces/markets/IPbrFeeHub.sol";

/**
 * @title DeployTournament
 * @notice Ownable entry API for atomic tournament bootstrap (upgradeable singleton).
 * @dev Owner is the Orchestrator (same as registries / factories). Callers with
 *      `DEFAULT_ADMIN_ROLE` (EOA now, Safe later) invoke `deploy` via
 *      `Orchestrator.execute`. Inner factory / registry / hub writes also relay through
 *      `Orchestrator.execute` so targets see `msg.sender == Orchestrator`. This proxy must
 *      hold `AUTHORIZED_CONTRACT` on the Orchestrator for those nested relays.
 *
 *      Unified `deploy` / `simulateDeploy` branch on `DeployParams.tournamentType`:
 *        - `DOMESTIC_LEAGUE`: deploy treasury + new fee hub, `registerHub`, create tournament
 *        - `DOMESTIC_CUP`: deploy treasury, attach under one existing league hub (`leagueIds[0]`)
 *        - `CONTINENTAL`: deploy treasury, attach under selected league hubs (`leagueIds`)
 *        - `INTERNATIONAL`: deploy treasury, attach under all existing league hubs
 *
 *      Seasons (`BootstrapSeason`) open via `TournamentRegistry.openSeason` (includes `finalRound`);
 *      round rows are filled later via `TournamentRegistry.upsertRounds`.
 *
 *      Protocol deploy order:
 *        1. Deploy AddressProvider
 *        2. Deploy Oracle set
 *        3. Deploy all other contracts as upgradeable proxies
 *        4. Register all addresses on AddressProvider
 *        5. Initialize all contracts (resolve deps from AP + transfer ownership to Orchestrator)
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DeployTournament is Initializable, AddressBook, Ownable {

    IOrchestrator public orchestrator;
    ITournamentRegistry public tournamentRegistry;

    IPbrTreasuryFactory public pbrTreasuryFactory;
    IPbrFeeHubFactory public pbrFeeHubFactory;

    bool public factoriesConfigured;

    // --------------------------------------------
    //  Constructor / initialize
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Resolve deps from AddressProvider; transfer ownership to Orchestrator.
     * @dev AddressProvider names for ORCHESTRATOR / TOURNAMENT_REGISTRY / factories must already
     *      be registered. Sets `factoriesConfigured` so `deploy` may proceed.
     */
    function initialize() external initializer {
        orchestrator = IOrchestrator(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        pbrTreasuryFactory = IPbrTreasuryFactory(_getAddress(_addressKey(Addresses.PBR_TREASURY_FACTORY)));
        pbrFeeHubFactory = IPbrFeeHubFactory(_getAddress(_addressKey(Addresses.PBR_FEE_HUB_FACTORY)));

        factoriesConfigured = true;

        _transferOwnership(address(orchestrator));
    }

    // --------------------------------------------
    //  Unified deploy
    // --------------------------------------------

    /// @notice Deploy a tournament of `params.tournamentType` (treasury + hub wiring + season stubs).
    function deploy(DeployParams calldata params) external onlyOwner returns (DeployResult memory result) {
        result = _deploy(params);
    }

    /// @notice Dry-run validation for `deploy` (reverts on invalid params / missing hubs).
    function simulateDeploy(DeployParams calldata params) external view {
        _simulate(params);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    /// @dev Shared pipeline: validate → treasury → fee hubs → create + seasons → (optional) hub attach.
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

        // Existing hubs receive the new treasury as a fee destination (league owns its hub already).
        if (t != TournamentType.DOMESTIC_LEAGUE) {
            _appendTreasuryToHubs(feeHubs, t, result.pbrTreasury);
        }
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
            feeHubs = tournamentRegistry.getAllDomesticHubs();
            if (feeHubs.length == 0) revert Errors.EmptyHubs();
            return feeHubs;
        }
        revert Errors.UnsupportedTournamentType(t);
    }

    function _resolveHubs(bytes32[] calldata leagueIds) internal view returns (Hub[] memory feeHubs) {
        uint256 length = leagueIds.length;
        feeHubs = new Hub[](length);
        for (uint256 i; i < length; ++i) {
            bytes32 leagueId = leagueIds[i];
            if (leagueId == bytes32(0)) revert Errors.ZeroId();
            address hubAddr = tournamentRegistry.pbrFeeHubOf(leagueId);
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
                address(pbrTreasuryFactory),
                abi.encodeCall(IPbrTreasuryFactory.create, (b.tournamentId, b.initialSeason, b.treasurySalt))
            ),
            (address)
        );
    }

    function _createAndRegisterHub(bytes32 leagueId, address pbrTreasury) internal returns (address hubAddr) {
        hubAddr = abi.decode(
            _exec(address(pbrFeeHubFactory), abi.encodeCall(IPbrFeeHubFactory.create, (leagueId, pbrTreasury))),
            (address)
        );
        _exec(
            address(tournamentRegistry),
            abi.encodeCall(ITournamentRegistry.registerHub, (Hub({ leagueId: leagueId, pbrFeeHub: hubAddr })))
        );
    }

    function _finalize(
        TournamentType tournamentType,
        BootstrapParams calldata b,
        Hub[] memory feeHubs,
        address pbrTreasury
    ) internal {
        _exec(
            address(tournamentRegistry),
            abi.encodeCall(ITournamentRegistry.createTournament, (b.tournamentId, tournamentType, feeHubs, pbrTreasury))
        );

        uint256 length = b.seasons.length;
        for (uint256 i; i < length; ++i) {
            BootstrapSeason calldata s = b.seasons[i];
            if (s.seasonId == bytes32(0) || s.seasonStartYear == 0) revert Errors.ZeroId();
            if (s.finalRound == 0) revert Errors.ZeroId();
            _exec(
                address(tournamentRegistry),
                abi.encodeCall(
                    ITournamentRegistry.openSeason, (b.tournamentId, s.seasonId, s.seasonStartYear, s.finalRound)
                )
            );
        }

        emit Events.TournamentDeployed(
            b.tournamentId, tournamentType, pbrTreasury, b.initialSeason, feeHubs.length, length
        );
    }

    function _appendTreasuryToHubs(Hub[] memory feeHubs, TournamentType tournamentType, address treasury) internal {
        uint256 length = feeHubs.length;
        for (uint256 i; i < length; ++i) {
            _appendTreasuryToHub(feeHubs[i].pbrFeeHub, tournamentType, treasury);
        }
    }

    function _appendTreasuryToHub(address hubAddr, TournamentType tournamentType, address treasury) internal {
        IPbrFeeHub hub = IPbrFeeHub(hubAddr);
        if (tournamentType == TournamentType.DOMESTIC_CUP) {
            _exec(hubAddr, abi.encodeCall(IPbrFeeHub.setDomesticCups, (_appendAddress(hub.getDomesticCups(), treasury))));
        } else if (tournamentType == TournamentType.CONTINENTAL) {
            _exec(hubAddr, abi.encodeCall(IPbrFeeHub.setContinental, (_appendAddress(hub.getContinental(), treasury))));
        } else if (tournamentType == TournamentType.INTERNATIONAL) {
            _exec(
                hubAddr, abi.encodeCall(IPbrFeeHub.setInternational, (_appendAddress(hub.getInternational(), treasury)))
            );
        } else {
            revert Errors.UnsupportedTournamentType(tournamentType);
        }
    }

    // --------------------------------------------
    //  Validation helpers
    // --------------------------------------------

    function _validateBootstrap(BootstrapParams calldata b) internal view {
        if (!factoriesConfigured) revert Errors.NotConfigured();
        if (b.tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (b.initialSeason == 0) revert Errors.ZeroSeason();
        if (b.treasurySalt == bytes32(0)) revert Errors.ZeroSalt();
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

    function _appendAddress(address[] memory existing, address added) internal pure returns (address[] memory next) {
        uint256 length = existing.length;
        next = new address[](length + 1);
        for (uint256 i; i < length; ++i) {
            next[i] = existing[i];
        }
        next[length] = added;
    }

    function _exec(address target, bytes memory data) internal returns (bytes memory) {
        return orchestrator.execute(target, 0, data);
    }
}
