// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";

import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";

import { Hub, TournamentType } from "@types/TournamentTypes.sol";

import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";

import { IPbrTreasuryFactory } from "@interfaces/vaults/factories/IPbrTreasuryFactory.sol";
import { IPbrFeeHubFactory } from "@interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { IPbrFeeHub } from "@interfaces/markets/IPbrFeeHub.sol";

/**
 * @title DeployTournament
 * @notice Ownable entry API for atomic tournament bootstrap (upgradeable singleton).
 * @dev Owner is the EOA or Safe. Privileged factory / registry / hub writes are relayed
 *      through `Orchestrator.execute` so `msg.sender` on targets is the Orchestrator
 *      (which owns those contracts). This contract (proxy) must hold `AUTHORIZED_CONTRACT`
 *      on the Orchestrator.
 *
 *      Unified `deploy` / `simulateDeploy` branch on `DeployParams.tournamentType`:
 *        - `DOMESTIC_LEAGUE`: deploy treasury + new fee hub, `registerHub`, create tournament
 *        - `DOMESTIC_CUP`: deploy treasury, attach under one existing league hub (`leagueIds[0]`)
 *        - `CONTINENTAL`: deploy treasury, attach under selected league hubs (`leagueIds`)
 *        - `INTERNATIONAL`: deploy treasury, attach under all existing league hubs
 *
 *      Season identity stubs (`BootstrapSeason`) open via `TournamentRegistry.openSeason`;
 *      RoundManager later owns `setFinalRound` + `upsertRounds`.
 *
 *      Deploy order:
 *        1. Deploy Orchestrator + registries + this proxy; grant `AUTHORIZED_CONTRACT`
 *        2. Deploy factories with `orchestrator == Orchestrator`
 *        3. Owner calls `configureFactories` once
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DeployTournament is Initializable, AddressBook, Ownable {
    // --------------------------------------------
    //  Wiring (set in initialize)
    // --------------------------------------------

    IOrchestrator public orchestrator;
    ITournamentRegistry public tournamentRegistry;
    IPlayerSetRegistry public playerSetRegistry;

    IPbrTreasuryFactory public pbrTreasuryFactory;
    IPbrFeeHubFactory public pbrFeeHubFactory;

    bool public factoriesConfigured;

    // --------------------------------------------
    //  Params
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

    // --------------------------------------------
    //  Constructor / initialize / configure
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Resolve Orchestrator + registries from AddressProvider; set deploy owner (EOA/Safe).
     * @dev AddressProvider names for ORCHESTRATOR / registries must already be registered.
     */
    function initialize(address owner_) external initializer {
        if (owner_ == address(0)) revert Errors.ZeroAddress();

        orchestrator = IOrchestrator(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));

        _transferOwnership(owner_);
    }

    /**
     * @notice One-shot factory wiring after factories are deployed with `orchestrator == Orchestrator`.
     */
    function configureFactories(address pbrTreasuryFactory_, address pbrFeeHubFactory_) external onlyOwner {
        if (factoriesConfigured) revert Errors.Unauthorized();
        if (pbrTreasuryFactory_ == address(0) || pbrFeeHubFactory_ == address(0)) revert Errors.ZeroAddress();
        if (
            IPbrTreasuryFactory(pbrTreasuryFactory_).orchestrator() != address(orchestrator)
                || IPbrFeeHubFactory(pbrFeeHubFactory_).orchestrator() != address(orchestrator)
        ) {
            revert Errors.Unauthorized();
        }

        pbrTreasuryFactory = IPbrTreasuryFactory(pbrTreasuryFactory_);
        pbrFeeHubFactory = IPbrFeeHubFactory(pbrFeeHubFactory_);
        factoriesConfigured = true;
        emit Events.FactoriesConfigured(pbrTreasuryFactory_, pbrFeeHubFactory_);
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
            _exec(
                address(tournamentRegistry),
                abi.encodeCall(ITournamentRegistry.openSeason, (b.tournamentId, s.seasonId, s.seasonStartYear))
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
            if (s.seasonId == bytes32(0) || s.seasonStartYear == 0) revert Errors.ZeroId();
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
