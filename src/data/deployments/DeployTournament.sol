// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";

import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { DeploymentsErrors as Errors } from "@base/global/libraries/errors/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@base/global/libraries/events/DeploymentsEvents.sol";

import { Hub, RoundSchedule, TournamentType } from "@base/global/types/TournamentTypes.sol";
import { VaultData } from "@base/global/types/PlayerSetTypes.sol";

import { ITournamentRegistry } from "@base/global/interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@base/global/interfaces/IPlayerSetRegistry.sol";

import { IPbrTreasuryFactory } from "@base/global/interfaces/vaults/factories/IPbrTreasuryFactory.sol";
import { IPbrFeeHubFactory } from "@base/global/interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { IPbrTreasury } from "@base/global/interfaces/vaults/IPbrTreasury.sol";
import { IPbrFeeHub } from "@base/global/interfaces/markets/IPbrFeeHub.sol";

/**
 * @title DeployTournament
 * @notice Cat-1 orchestrator for atomic tournament bootstrap via `ConstitutionalTimelock`.
 * @dev Access:
 *        - `CATEGORY_ONE` (`ConstitutionalTimelock`): `configureFactories`, all `deploy*` entrypoints.
 *        - `DEFAULT_ADMIN_ROLE` (Aragon DAO): role admin.
 *
 *      After the constitutional delay, Timelock calls a typed `deploy*` entrypoint with
 *      pre-formatted calldata. This contract must also hold:
 *        - `CATEGORY_ONE` + `CATEGORY_THREE` on `TournamentRegistry`
 *        - `CATEGORY_ONE` on each `PbrFeeHub` (granted at hub initialize)
 *      New treasuries grant this contract `CATEGORY_THREE` at initialize (via factory).
 *
 *      Flows:
 *        - `DOMESTIC_LEAGUE`: deploy treasury + new fee hub, `registerHub`, create tournament
 *        - `DOMESTIC_CUP`: deploy treasury, attach under one existing league hub
 *        - `CONTINENTAL`: deploy treasury, attach under selected existing league hubs
 *        - `INTERNATIONAL`: deploy treasury, attach under all existing league hubs
 *
 *      Non-league types also append the new treasury onto each hub's destination list
 *      (`setDomesticCups` / `setContinental` / `setInternational`).
 *
 *      Deploy order (addresses):
 *        1. Deploy this contract (factories unset)
 *        2. Deploy `PbrTreasuryFactory` / `PbrFeeHubFactory` with `deployTournament = this`
 *        3. Timelock calls `configureFactories` once
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DeployTournament is AccessControl {
    // --------------------------------------------
    //  Immutables / wiring
    // --------------------------------------------

    ITournamentRegistry public immutable tournamentRegistry;
    IPlayerSetRegistry public immutable playerSetRegistry;

    IPbrTreasuryFactory public pbrTreasuryFactory;
    IPbrFeeHubFactory public pbrFeeHubFactory;

    bool public factoriesConfigured;

    // --------------------------------------------
    //  Params
    // --------------------------------------------

    /// @notice CREATE3 salt + predicted address for `PbrTreasuryFactory.create`.
    struct TreasuryDeploy {
        bytes32 salt;
        address expected;
    }

    /**
     * @param tournamentId Stable tournament id.
     * @param initialSeason Season written into `PbrTreasury.initialize`.
     * @param treasury CREATE3 params for the new `PbrTreasury`.
     * @param openSeasonData `abi.encode(uint16 seasonStartYear, uint32 finalRound)`; empty skips.
     * @param roundsSeasonStartYear Season key for `upsertRounds` (ignored when `rounds` empty).
     * @param rounds Optional calendar rows; empty skips.
     * @param registeredPlayers Optional playerIds to register vaults (+ sync active flags).
     */
    struct BootstrapParams {
        bytes32 tournamentId;
        uint16 initialSeason;
        TreasuryDeploy treasury;
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
     * @param constitutionalTimelock_ `ConstitutionalTimelock` — `CATEGORY_ONE`.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param tournamentRegistry_ Canonical tournament registry.
     * @param playerSetRegistry_ Canonical player set registry.
     */
    constructor(
        address constitutionalTimelock_,
        address dao_,
        address tournamentRegistry_,
        address playerSetRegistry_
    ) {
        if (
            constitutionalTimelock_ == address(0) || dao_ == address(0) || tournamentRegistry_ == address(0)
                || playerSetRegistry_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, constitutionalTimelock_);

        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
    }

    /**
     * @notice One-shot factory wiring after factories are deployed with `deployTournament = this`.
     */
    function configureFactories(address pbrTreasuryFactory_, address pbrFeeHubFactory_)
        external
        onlyRole(Roles.CATEGORY_ONE)
    {
        if (factoriesConfigured) revert Errors.Unauthorized();
        if (pbrTreasuryFactory_ == address(0) || pbrFeeHubFactory_ == address(0)) revert Errors.ZeroAddress();
        if (
            IPbrTreasuryFactory(pbrTreasuryFactory_).deployTournament() != address(this)
                || IPbrFeeHubFactory(pbrFeeHubFactory_).deployTournament() != address(this)
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

    /**
     * @notice Deploy treasury + fee hub, register hub, create league tournament, optional bootstrap.
     */
    function deployDomesticLeague(DomesticLeagueParams calldata params)
        external
        onlyRole(Roles.CATEGORY_ONE)
        returns (DeployResult memory result)
    {
        BootstrapParams calldata b = params.bootstrap;
        _validateBootstrap(b);

        result.pbrTreasury = _deployTreasury(b);
        result.pbrFeeHub = pbrFeeHubFactory.create(b.tournamentId, result.pbrTreasury);

        Hub memory hub = Hub({ leagueId: b.tournamentId, pbrFeeHub: result.pbrFeeHub });
        tournamentRegistry.registerHub(hub);

        Hub[] memory feeHubs = new Hub[](1);
        feeHubs[0] = hub;
        _finalize(TournamentType.DOMESTIC_LEAGUE, b, feeHubs, result.pbrTreasury);
    }

    // --------------------------------------------
    //  DOMESTIC_CUP
    // --------------------------------------------

    /**
     * @notice Deploy cup treasury under an existing domestic league hub; wire hub destinations.
     */
    function deployDomesticCup(DomesticCupParams calldata params)
        external
        onlyRole(Roles.CATEGORY_ONE)
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
        _appendTreasuryToHub(IPbrFeeHub(hubAddr), TournamentType.DOMESTIC_CUP, result.pbrTreasury);
    }

    // --------------------------------------------
    //  CONTINENTAL
    // --------------------------------------------

    /**
     * @notice Deploy continental treasury under selected existing league hubs; wire destinations.
     */
    function deployContinental(ContinentalParams calldata params)
        external
        onlyRole(Roles.CATEGORY_ONE)
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

    /**
     * @notice Deploy international treasury under every registered domestic league hub.
     */
    function deployInternational(InternationalParams calldata params)
        external
        onlyRole(Roles.CATEGORY_ONE)
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

    function _validateBootstrap(BootstrapParams calldata b) internal view {
        if (!factoriesConfigured) revert Errors.NotConfigured();
        if (b.tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (b.initialSeason == 0) revert Errors.ZeroSeason();
        if (b.treasury.salt == bytes32(0)) revert Errors.ZeroSalt();
        if (b.treasury.expected == address(0)) revert Errors.ZeroAddress();
    }

    function _simulateBootstrap(BootstrapParams calldata b) internal view {
        _validateBootstrap(b);

        if (b.openSeasonData.length != 0) {
            if (b.openSeasonData.length != 64) revert Errors.InvalidOpenSeasonData();
            (uint16 seasonStartYear, uint32 finalRound) = abi.decode(b.openSeasonData, (uint16, uint32));
            if (seasonStartYear == 0 || finalRound == 0) revert Errors.InvalidOpenSeasonData();
        }

        if (b.rounds.length != 0 && b.roundsSeasonStartYear == 0) revert Errors.ZeroSeason();

        address predicted = pbrTreasuryFactory.computeCreate3Address(b.treasury.salt);
        if (predicted != b.treasury.expected) {
            revert Errors.AddressMismatch(predicted, b.treasury.expected);
        }

        uint256 length = b.registeredPlayers.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = b.registeredPlayers[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();
            VaultData memory vaultData = playerSetRegistry.getVaultData(playerId);
            if (vaultData.playerVault == address(0)) revert Errors.VaultMissing(playerId);
        }
    }

    function _deployTreasury(BootstrapParams calldata b) internal returns (address pbrTreasury) {
        pbrTreasury = pbrTreasuryFactory.create(
            b.tournamentId, b.initialSeason, b.treasury.salt, b.treasury.expected
        );
    }

    function _finalize(
        TournamentType tournamentType,
        BootstrapParams calldata b,
        Hub[] memory feeHubs,
        address pbrTreasury
    ) internal {
        tournamentRegistry.createTournament(b.tournamentId, tournamentType, feeHubs, pbrTreasury);

        if (b.openSeasonData.length != 0) {
            if (b.openSeasonData.length != 64) revert Errors.InvalidOpenSeasonData();
            (uint16 seasonStartYear, uint32 finalRound) = abi.decode(b.openSeasonData, (uint16, uint32));
            tournamentRegistry.openSeason(b.tournamentId, seasonStartYear, finalRound);
        }

        if (b.rounds.length != 0) {
            tournamentRegistry.upsertRounds(b.tournamentId, b.roundsSeasonStartYear, b.rounds);
        }

        if (b.registeredPlayers.length != 0) {
            _registerPlayers(pbrTreasury, b.registeredPlayers);
        }

        emit Events.TournamentDeployed(
            b.tournamentId,
            tournamentType,
            pbrTreasury,
            b.initialSeason,
            feeHubs.length,
            b.registeredPlayers.length
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

    function _appendTreasuryToHubs(Hub[] memory feeHubs, TournamentType tournamentType, address treasury)
        internal
    {
        uint256 length = feeHubs.length;
        for (uint256 i; i < length; ++i) {
            _appendTreasuryToHub(IPbrFeeHub(feeHubs[i].pbrFeeHub), tournamentType, treasury);
        }
    }

    function _appendTreasuryToHub(IPbrFeeHub hub, TournamentType tournamentType, address treasury) internal {
        if (tournamentType == TournamentType.DOMESTIC_CUP) {
            hub.setDomesticCups(_appendAddress(hub.getDomesticCups(), treasury));
        } else if (tournamentType == TournamentType.CONTINENTAL) {
            hub.setContinental(_appendAddress(hub.getContinental(), treasury));
        } else if (tournamentType == TournamentType.INTERNATIONAL) {
            hub.setInternational(_appendAddress(hub.getInternational(), treasury));
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

    function _registerPlayers(address pbrTreasury, bytes32[] calldata playerIds) internal {
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

        // `registerVaults` syncs `PlayerSetRegistry` active-tournament flags via the treasury.
        IPbrTreasury(pbrTreasury).registerVaults(vaults);
    }
}
