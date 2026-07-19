// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeploymentsErrors as Errors } from "@base/global/libraries/errors/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@base/global/libraries/events/DeploymentsEvents.sol";
import { Hub, RoundSchedule, TournamentType } from "@base/global/types/TournamentTypes.sol";
import { VaultData } from "@base/global/types/PlayerSetTypes.sol";
import { TournamentRegistry } from "@src/TournamentRegistry.sol";
import { PlayerSetRegistry } from "@src/PlayerSetRegistry.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";

/**
 * @title DeployTournament
 * @notice Cat-1 orchestrator for atomic tournament bootstrap via `ConstitutionalTimelock`.
 * @dev After the constitutional delay, Timelock calls `deployDomesticLeague` with pre-formatted
 *      calldata. This contract must hold:
 *        - `CATEGORY_ONE` + `CATEGORY_THREE` on `TournamentRegistry`
 *        - `CATEGORY_THREE` (or `CATEGORY_TWO`) on `PlayerSetRegistry`
 *      New treasuries grant this contract `CATEGORY_THREE` at initialize (via factory).
 *
 *      Deploy order (addresses):
 *        1. Deploy this contract (factories unset)
 *        2. Deploy `PbrTreasuryFactory` / `PbrFeeHubFactory` with `deployTournament = this`
 *        3. Timelock calls `configureFactories` once
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract DeployTournament {
    // --------------------------------------------
    //  Immutables / wiring
    // --------------------------------------------

    address public immutable constitutionalTimelock;
    TournamentRegistry public immutable tournamentRegistry;
    PlayerSetRegistry public immutable playerSetRegistry;

    PbrTreasuryFactory public pbrTreasuryFactory;
    PbrFeeHubFactory public pbrFeeHubFactory;

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
     * @param tournamentId League / tournament id (`DOMESTIC_LEAGUE` ⇒ also `leagueId`).
     * @param initialSeason Season written into `PbrTreasury.initialize`.
     * @param treasury CREATE3 params for the new `PbrTreasury`.
     * @param openSeasonData `abi.encode(uint16 seasonStartYear, uint32 finalRound)`; empty skips.
     * @param roundsSeasonStartYear Season key for `upsertRounds` (ignored when `rounds` empty).
     * @param rounds Optional calendar rows; empty skips.
     * @param registeredPlayers Optional playerIds to register vaults + mark tournament active.
     */
    struct DomesticLeagueParams {
        bytes32 tournamentId;
        uint16 initialSeason;
        TreasuryDeploy treasury;
        bytes openSeasonData;
        uint16 roundsSeasonStartYear;
        RoundSchedule[] rounds;
        bytes32[] registeredPlayers;
    }

    struct DomesticLeagueResult {
        address pbrTreasury;
        address pbrFeeHub;
    }

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyTimelock() {
        if (msg.sender != constitutionalTimelock) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Constructor / configure
    // --------------------------------------------

    /**
     * @param constitutionalTimelock_ Sole caller of deploy / configure entrypoints.
     * @param tournamentRegistry_ Canonical tournament registry.
     * @param playerSetRegistry_ Canonical player set registry.
     */
    constructor(address constitutionalTimelock_, address tournamentRegistry_, address playerSetRegistry_) {
        if (
            constitutionalTimelock_ == address(0) || tournamentRegistry_ == address(0)
                || playerSetRegistry_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        constitutionalTimelock = constitutionalTimelock_;
        tournamentRegistry = TournamentRegistry(tournamentRegistry_);
        playerSetRegistry = PlayerSetRegistry(playerSetRegistry_);
    }

    /**
     * @notice One-shot factory wiring after factories are deployed with `deployTournament = this`.
     */
    function configureFactories(address pbrTreasuryFactory_, address pbrFeeHubFactory_) external onlyTimelock {
        if (factoriesConfigured) revert Errors.Unauthorized();
        if (pbrTreasuryFactory_ == address(0) || pbrFeeHubFactory_ == address(0)) revert Errors.ZeroAddress();
        if (
            PbrTreasuryFactory(pbrTreasuryFactory_).deployTournament() != address(this)
                || PbrFeeHubFactory(pbrFeeHubFactory_).deployTournament() != address(this)
        ) {
            revert Errors.Unauthorized();
        }

        pbrTreasuryFactory = PbrTreasuryFactory(pbrTreasuryFactory_);
        pbrFeeHubFactory = PbrFeeHubFactory(pbrFeeHubFactory_);
        factoriesConfigured = true;
        emit Events.FactoriesConfigured(pbrTreasuryFactory_, pbrFeeHubFactory_);
    }

    // --------------------------------------------
    //  Entry
    // --------------------------------------------

    /**
     * @notice Cat-1 entrypoint: routes by `tournamentType` (only `DOMESTIC_LEAGUE` in this iteration).
     * @dev Intended calldata target for `ConstitutionalTimelock.execute` after the 7-day delay.
     */
    function deploy(TournamentType tournamentType, DomesticLeagueParams calldata params)
        external
        onlyTimelock
        returns (DomesticLeagueResult memory result)
    {
        if (tournamentType != TournamentType.DOMESTIC_LEAGUE) {
            revert Errors.InvalidTournamentType(tournamentType, TournamentType.DOMESTIC_LEAGUE);
        }
        result = _deployDomesticLeague(params);
    }

    // --------------------------------------------
    //  DOMESTIC_LEAGUE
    // --------------------------------------------

    /**
     * @notice Deploy + register a domestic league (treasury, fee hub, registry, optional calendar / vaults).
     */
    function deployDomesticLeague(DomesticLeagueParams calldata params)
        external
        onlyTimelock
        returns (DomesticLeagueResult memory result)
    {
        result = _deployDomesticLeague(params);
    }

    function _deployDomesticLeague(DomesticLeagueParams calldata params)
        internal
        returns (DomesticLeagueResult memory result)
    {
        if (!factoriesConfigured) revert Errors.NotConfigured();
        if (params.tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (params.initialSeason == 0) revert Errors.ZeroSeason();
        if (params.treasury.salt == bytes32(0)) revert Errors.ZeroSalt();
        if (params.treasury.expected == address(0)) revert Errors.ZeroAddress();

        // 1) Deploy treasury + fee hub, then registry hub + tournament
        result.pbrTreasury = pbrTreasuryFactory.create(
            params.tournamentId, params.initialSeason, params.treasury.salt, params.treasury.expected
        );
        result.pbrFeeHub = pbrFeeHubFactory.create(params.tournamentId, result.pbrTreasury);

        Hub memory hub = Hub({ leagueId: params.tournamentId, pbrFeeHub: result.pbrFeeHub });
        tournamentRegistry.registerHub(hub);

        Hub[] memory feeHubs = new Hub[](1);
        feeHubs[0] = hub;
        tournamentRegistry.createTournament(
            params.tournamentId, TournamentType.DOMESTIC_LEAGUE, feeHubs, result.pbrTreasury
        );

        // 2) Optional openSeason
        if (params.openSeasonData.length != 0) {
            if (params.openSeasonData.length != 64) revert Errors.InvalidOpenSeasonData();
            (uint16 seasonStartYear, uint32 finalRound) = abi.decode(params.openSeasonData, (uint16, uint32));
            tournamentRegistry.openSeason(params.tournamentId, seasonStartYear, finalRound);
        }

        // 3) Optional upsertRounds
        if (params.rounds.length != 0) {
            tournamentRegistry.upsertRounds(params.tournamentId, params.roundsSeasonStartYear, params.rounds);
        }

        // 4) Optional vault registration + active tournament flags
        if (params.registeredPlayers.length != 0) {
            _registerPlayers(params.tournamentId, result.pbrTreasury, params.registeredPlayers);
        }

        emit Events.DomesticLeagueDeployed(
            params.tournamentId,
            result.pbrTreasury,
            result.pbrFeeHub,
            params.initialSeason,
            params.registeredPlayers.length
        );
    }

    /**
     * @notice Dry-run checks for governance calldata (no state changes / deploys).
     * @dev Does not simulate CREATE3; verifies wiring, ids, and registered player vault presence.
     */
    function simulateDeployDomesticLeague(DomesticLeagueParams calldata params) external view {
        if (!factoriesConfigured) revert Errors.NotConfigured();
        if (params.tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (params.treasury.salt == bytes32(0)) revert Errors.ZeroSalt();
        if (params.treasury.expected == address(0)) revert Errors.ZeroAddress();
        if (params.initialSeason == 0) revert Errors.ZeroSeason();

        if (params.openSeasonData.length != 0) {
            if (params.openSeasonData.length != 64) revert Errors.InvalidOpenSeasonData();
            (uint16 seasonStartYear, uint32 finalRound) = abi.decode(params.openSeasonData, (uint16, uint32));
            if (seasonStartYear == 0 || finalRound == 0) revert Errors.InvalidOpenSeasonData();
        }

        if (params.rounds.length != 0 && params.roundsSeasonStartYear == 0) revert Errors.ZeroSeason();

        address predicted = pbrTreasuryFactory.computeCreate3Address(params.treasury.salt);
        if (predicted != params.treasury.expected) {
            revert Errors.AddressMismatch(predicted, params.treasury.expected);
        }

        uint256 length = params.registeredPlayers.length;
        for (uint256 i; i < length; ++i) {
            bytes32 playerId = params.registeredPlayers[i];
            if (playerId == bytes32(0)) revert Errors.ZeroId();
            VaultData memory vaultData = playerSetRegistry.getVaultData(playerId);
            if (vaultData.playerVault == address(0)) revert Errors.VaultMissing(playerId);
        }
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _registerPlayers(bytes32 tournamentId, address pbrTreasury, bytes32[] calldata playerIds) internal {
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

        PbrTreasury(payable(pbrTreasury)).registerVaults(vaults);
        playerSetRegistry.addActiveTournamentForPlayers(playerIds, tournamentId);
    }
}
