// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";

import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";

import { Hub, RoundSchedule, TournamentType } from "@types/TournamentTypes.sol";
import { VaultData } from "@types/PlayerSetTypes.sol";

import { IOrchestrator } from "@interfaces/IOrchestrator.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";

import { IPbrTreasuryFactory } from "@interfaces/vaults/factories/IPbrTreasuryFactory.sol";
import { IPbrFeeHubFactory } from "@interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { IPbrFeeHub } from "@interfaces/markets/IPbrFeeHub.sol";

/**
 * @title DeployTournament
 * @notice Ownable entry API for atomic tournament bootstrap.
 * @dev Owner is the EOA or Safe. Privileged factory / registry / hub writes are relayed
 *      through `Orchestrator.execute` so `msg.sender` on targets is the Orchestrator
 *      (which owns those contracts). This contract must hold `AUTHORIZED_CONTRACT` on
 *      the Orchestrator.
 *
 *      Flows:
 *        - `DOMESTIC_LEAGUE`: deploy treasury + new fee hub, `registerHub`, create tournament
 *        - `DOMESTIC_CUP`: deploy treasury, attach under one existing league hub
 *        - `CONTINENTAL`: deploy treasury, attach under selected existing league hubs
 *        - `INTERNATIONAL`: deploy treasury, attach under all existing league hubs
 *
 *      Deploy order:
 *        1. Deploy Orchestrator + registries; grant this contract `AUTHORIZED_CONTRACT`
 *        2. Deploy factories with `orchestrator == Orchestrator`
 *        3. Owner calls `configureFactories` once
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DeployTournament is Ownable {
    // --------------------------------------------
    //  Immutables / wiring
    // --------------------------------------------

    IOrchestrator public immutable orchestrator;
    ITournamentRegistry public immutable tournamentRegistry;
    IPlayerSetRegistry public immutable playerSetRegistry;

    IPbrTreasuryFactory public pbrTreasuryFactory;
    IPbrFeeHubFactory public pbrFeeHubFactory;

    bool public factoriesConfigured;

    // --------------------------------------------
    //  Params
    // --------------------------------------------

    /**
     * @param tournamentId Stable tournament id.
     * @param initialSeason Season written into `PbrTreasury.initialize`.
     * @param treasurySalt CreateX salt for `PbrTreasuryFactory.create` (mine offchain for `0x99…`).
     * @param openSeasonData `abi.encode(bytes32 seasonId, uint16 seasonStartYear, uint32 finalRound)`; empty skips.
     * @param roundsSeasonStartYear Season key for `upsertRounds` (ignored when `rounds` empty).
     * @param rounds Optional calendar rows; empty skips.
     * @param registeredPlayers Optional playerIds to register vaults (+ sync active flags).
     */
    struct BootstrapParams {
        bytes32 tournamentId;
        uint16 initialSeason;
        bytes32 treasurySalt;
        bytes openSeasonData;
        uint16 roundsSeasonStartYear;
        RoundSchedule[] rounds;
        bytes32[] registeredPlayers;
    }

    /// @dev `DOMESTIC_LEAGUE` — deploys a new hub; `tournamentId` is also the `leagueId`.
    struct DomesticLeagueParams {
        BootstrapParams bootstrap;
    }

    /// @dev `DOMESTIC_CUP` — attaches under one existing domestic league hub.
    struct DomesticCupParams {
        BootstrapParams bootstrap;
        bytes32 leagueId;
    }

    /// @dev `CONTINENTAL` — attaches under selected existing domestic league hubs.
    struct ContinentalParams {
        BootstrapParams bootstrap;
        bytes32[] leagueIds;
    }

    /// @dev `INTERNATIONAL` — attaches under every registered domestic league hub.
    struct InternationalParams {
        BootstrapParams bootstrap;
    }

    struct DeployResult {
        address pbrTreasury;
        address pbrFeeHub; // set for DOMESTIC_LEAGUE only; zero otherwise
    }

    // --------------------------------------------
    //  Constructor / configure
    // --------------------------------------------

    /**
     * @param owner_ EOA or Safe — sole caller of `deploy*` / `configureFactories`.
     * @param orchestrator_ Canonical `Orchestrator` (this contract must be `AUTHORIZED_CONTRACT`).
     * @param tournamentRegistry_ Canonical tournament registry.
     * @param playerSetRegistry_ Canonical player set registry.
     */
    constructor(
        address owner_,
        address orchestrator_,
        address tournamentRegistry_,
        address playerSetRegistry_
    ) Ownable(owner_) {
        if (orchestrator_ == address(0) || tournamentRegistry_ == address(0) || playerSetRegistry_ == address(0)) {
            revert Errors.ZeroAddress();
        }

        orchestrator = IOrchestrator(orchestrator_);
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
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
    //  DOMESTIC_LEAGUE
    // --------------------------------------------

    /// @notice Deploy treasury + fee hub, register hub, create league tournament, optional bootstrap.
    function deployDomesticLeague(DomesticLeagueParams calldata params)
        external
        onlyOwner
        returns (DeployResult memory result)
    {
        result = _deployDomesticLeague(params);
    }

    // --------------------------------------------
    //  DOMESTIC_CUP
    // --------------------------------------------

    /// @notice Deploy cup treasury under an existing domestic league hub; wire hub destinations.
    function deployDomesticCup(DomesticCupParams calldata params)
        external
        onlyOwner
        returns (DeployResult memory result)
    {
        BootstrapParams calldata b = params.bootstrap;
        _validateBootstrap(b);
        if (params.leagueId == bytes32(0)) revert Errors.ZeroId();

        address hubAddr = tournamentRegistry.pbrFeeHubOf(params.leagueId);
        if (hubAddr == address(0)) revert Errors.HubNotRegistered(params.leagueId);

        result.pbrTreasury = _deployTreasury(b);

        Hub[] memory feeHubs = new Hub[](1);
        feeHubs[0] = Hub({ leagueId: params.leagueId, pbrFeeHub: hubAddr });

        _finalize(TournamentType.DOMESTIC_CUP, b, feeHubs, result.pbrTreasury);
        _appendTreasuryToHub(hubAddr, TournamentType.DOMESTIC_CUP, result.pbrTreasury);
    }

    // --------------------------------------------
    //  CONTINENTAL
    // --------------------------------------------

    /// @notice Deploy continental treasury under selected existing league hubs; wire destinations.
    function deployContinental(ContinentalParams calldata params)
        external
        onlyOwner
        returns (DeployResult memory result)
    {
        BootstrapParams calldata b = params.bootstrap;
        _validateBootstrap(b);
        if (params.leagueIds.length == 0) revert Errors.EmptyHubs();

        result.pbrTreasury = _deployTreasury(b);

        Hub[] memory feeHubs = _resolveHubs(params.leagueIds);
        _finalize(TournamentType.CONTINENTAL, b, feeHubs, result.pbrTreasury);
        _appendTreasuryToHubs(feeHubs, TournamentType.CONTINENTAL, result.pbrTreasury);
    }

    // --------------------------------------------
    //  INTERNATIONAL
    // --------------------------------------------

    /// @notice Deploy international treasury under every registered domestic league hub.
    function deployInternational(InternationalParams calldata params)
        external
        onlyOwner
        returns (DeployResult memory result)
    {
        BootstrapParams calldata b = params.bootstrap;
        _validateBootstrap(b);

        Hub[] memory feeHubs = tournamentRegistry.getAllDomesticHubs();
        if (feeHubs.length == 0) revert Errors.EmptyHubs();

        result.pbrTreasury = _deployTreasury(b);
        _finalize(TournamentType.INTERNATIONAL, b, feeHubs, result.pbrTreasury);
        _appendTreasuryToHubs(feeHubs, TournamentType.INTERNATIONAL, result.pbrTreasury);
    }

    // --------------------------------------------
    //  Simulate (dry-run)
    // --------------------------------------------

    function simulateDeployDomesticLeague(DomesticLeagueParams calldata params) external view {
        _simulateBootstrap(params.bootstrap);
    }

    function simulateDeployDomesticCup(DomesticCupParams calldata params) external view {
        _simulateBootstrap(params.bootstrap);
        if (params.leagueId == bytes32(0)) revert Errors.ZeroId();
        if (tournamentRegistry.pbrFeeHubOf(params.leagueId) == address(0)) {
            revert Errors.HubNotRegistered(params.leagueId);
        }
    }

    function simulateDeployContinental(ContinentalParams calldata params) external view {
        _simulateBootstrap(params.bootstrap);
        if (params.leagueIds.length == 0) revert Errors.EmptyHubs();
        _resolveHubs(params.leagueIds);
    }

    function simulateDeployInternational(InternationalParams calldata params) external view {
        _simulateBootstrap(params.bootstrap);
        if (tournamentRegistry.getAllDomesticHubs().length == 0) revert Errors.EmptyHubs();
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _deployDomesticLeague(DomesticLeagueParams calldata params) internal returns (DeployResult memory result) {
        BootstrapParams calldata b = params.bootstrap;
        _validateBootstrap(b);

        result.pbrTreasury = _deployTreasury(b);
        result.pbrFeeHub = abi.decode(
            _exec(
                address(pbrFeeHubFactory),
                abi.encodeCall(IPbrFeeHubFactory.create, (b.tournamentId, result.pbrTreasury))
            ),
            (address)
        );

        Hub memory hub = Hub({ leagueId: b.tournamentId, pbrFeeHub: result.pbrFeeHub });
        _exec(address(tournamentRegistry), abi.encodeCall(ITournamentRegistry.registerHub, (hub)));

        Hub[] memory feeHubs = new Hub[](1);
        feeHubs[0] = hub;
        _finalize(TournamentType.DOMESTIC_LEAGUE, b, feeHubs, result.pbrTreasury);
    }

    function _validateBootstrap(BootstrapParams calldata b) internal view {
        if (!factoriesConfigured) revert Errors.NotConfigured();
        if (b.tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (b.initialSeason == 0) revert Errors.ZeroSeason();
        if (b.treasurySalt == bytes32(0)) revert Errors.ZeroSalt();
    }

    function _simulateBootstrap(BootstrapParams calldata b) internal view {
        _validateBootstrap(b);

        if (b.openSeasonData.length != 0) {
            if (b.openSeasonData.length != 96) revert Errors.InvalidOpenSeasonData();
            (bytes32 seasonId, uint16 seasonStartYear, uint32 finalRound) =
                abi.decode(b.openSeasonData, (bytes32, uint16, uint32));
            if (seasonId == bytes32(0) || seasonStartYear == 0 || finalRound == 0) {
                revert Errors.InvalidOpenSeasonData();
            }
        }

        if (b.rounds.length != 0 && b.roundsSeasonStartYear == 0) revert Errors.ZeroSeason();

        uint256 length = b.registeredPlayers.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = b.registeredPlayers[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();
            VaultData memory vaultData = playerSetRegistry.getVaultData(playerId);
            if (vaultData.playerVault == address(0)) revert Errors.VaultMissing(playerId);
        }
    }

    function _deployTreasury(BootstrapParams calldata b) internal returns (address pbrTreasury) {
        pbrTreasury = abi.decode(
            _exec(
                address(pbrTreasuryFactory),
                abi.encodeCall(IPbrTreasuryFactory.create, (b.tournamentId, b.initialSeason, b.treasurySalt))
            ),
            (address)
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

        if (b.openSeasonData.length != 0) {
            if (b.openSeasonData.length != 96) revert Errors.InvalidOpenSeasonData();
            (bytes32 seasonId, uint16 seasonStartYear, uint32 finalRound) =
                abi.decode(b.openSeasonData, (bytes32, uint16, uint32));
            _exec(
                address(tournamentRegistry),
                abi.encodeCall(ITournamentRegistry.openSeason, (b.tournamentId, seasonId, seasonStartYear, finalRound))
            );
        }

        if (b.rounds.length != 0) {
            _exec(
                address(tournamentRegistry),
                abi.encodeCall(ITournamentRegistry.upsertRounds, (b.tournamentId, b.roundsSeasonStartYear, b.rounds))
            );
        }

        if (b.registeredPlayers.length != 0) {
            _registerPlayers(b.tournamentId, b.registeredPlayers);
        }

        emit Events.TournamentDeployed(
            b.tournamentId, tournamentType, pbrTreasury, b.initialSeason, feeHubs.length, b.registeredPlayers.length
        );
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

    function _appendAddress(address[] memory existing, address added) internal pure returns (address[] memory next) {
        uint256 length = existing.length;
        next = new address[](length + 1);
        for (uint256 i; i < length; ++i) {
            next[i] = existing[i];
        }
        next[length] = added;
    }

    function _registerPlayers(bytes32 tournamentId, bytes32[] calldata playerIds) internal {
        uint256 length = playerIds.length;
        address[] memory vaults = new address[](length);

        for (uint256 i; i < length; ++i) {
            bytes32 playerId = playerIds[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();

            VaultData memory vaultData = playerSetRegistry.getVaultData(playerId);
            address vault = vaultData.playerVault;
            if (vault == address(0)) revert Errors.VaultMissing(playerId);
            vaults[i] = vault;
        }

        _exec(address(tournamentRegistry), abi.encodeCall(ITournamentRegistry.registerVaults, (tournamentId, vaults)));
    }

    function _exec(address target, bytes memory data) internal returns (bytes memory) {
        return orchestrator.execute(target, 0, data);
    }
}
