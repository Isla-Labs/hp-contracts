// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeploymentsErrors as Errors } from "@errors/initializers/DeploymentsErrors.sol";
import { ITournamentInitializer } from "@interfaces/initializers/ITournamentInitializer.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import { IPbrFeeHubFactory } from "@interfaces/markets/factories/IPbrFeeHubFactory.sol";
import { IPbrTreasuryFactory } from "@interfaces/vaults/factories/IPbrTreasuryFactory.sol";
import {
    BootstrapParams,
    BootstrapSeason,
    CreateTournamentData,
    DeployParams,
    Hub,
    TournamentType
} from "@types/registries/TournamentTypes.sol";

/**
 * @title TournamentInitializer
 * @notice Ringfenced tournament creation: factories + registry hub/tournament/season writes.
 * @dev `create` — Orchestrator only. `openSeason` — Orchestrator or RoundManager (live rollover).
 *      Sole permitted caller of `PbrTreasuryFactory`, `PbrFeeHubFactory`, and registry topology
 *      writes (`registerHub` / `createTournament` / `openSeason` / `linkHub`).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentInitializer is AddressBook, ITournamentInitializer {
    // --------------------------------------------
    //  Access
    // --------------------------------------------

    modifier onlyOrchestrator() {
        if (msg.sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))) revert Errors.Unauthorized();
        _;
    }

    modifier onlySeasonOpener() {
        address sender = msg.sender;
        if (
            sender != _getAddress(_addressKey(Addresses.ORCHESTRATOR))
                && sender != _getAddress(_addressKey(Addresses.ROUND_MANAGER))
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    // --------------------------------------------
    //  Construction
    // --------------------------------------------

    constructor(address addressProvider_) AddressBook(addressProvider_) { }

    // --------------------------------------------
    //  Create
    // --------------------------------------------

    /// @inheritdoc ITournamentInitializer
    function create(DeployParams calldata params) external onlyOrchestrator returns (CreateTournamentData memory data) {
        BootstrapParams calldata bootstrap = params.bootstrap;
        if (bootstrap.tournamentId == bytes32(0)) revert Errors.ZeroId();
        if (bootstrap.treasurySalt == bytes32(0)) revert Errors.ZeroSalt();
        if (bootstrap.initialSeasonStartYear == 0) revert Errors.ZeroSeason();

        ITournamentRegistry registry = _tournamentRegistry();
        if (registry.tournamentExists(bootstrap.tournamentId)) {
            revert Errors.TournamentsExist(1);
        }

        address pbrTreasury = _createTreasury(bootstrap);
        Hub[] memory feeHubs;
        address pbrFeeHub;
        Hub memory newLeagueHub;

        if (params.tournamentType == TournamentType.DOMESTIC_LEAGUE) {
            pbrFeeHub = _createFeeHub(bootstrap.tournamentId, pbrTreasury);
            newLeagueHub = Hub({ leagueId: bootstrap.tournamentId, pbrFeeHub: pbrFeeHub });
            registry.registerHub(newLeagueHub);
            feeHubs = new Hub[](1);
            feeHubs[0] = newLeagueHub;
        } else if (params.tournamentType == TournamentType.DOMESTIC_CUP) {
            if (params.leagueIds.length != 1) revert Errors.EmptyHubs();
            feeHubs = _resolveHubs(registry, params.leagueIds);
        } else if (params.tournamentType == TournamentType.CONTINENTAL) {
            if (params.leagueIds.length == 0) revert Errors.EmptyHubs();
            feeHubs = _resolveHubs(registry, params.leagueIds);
        } else if (params.tournamentType == TournamentType.INTERNATIONAL) {
            feeHubs = registry.getAllDomesticHubs();
            if (feeHubs.length == 0) revert Errors.EmptyHubs();
        } else {
            revert Errors.UnsupportedTournamentType(params.tournamentType);
        }

        registry.createTournament(bootstrap.tournamentId, params.tournamentType, feeHubs, pbrTreasury);

        // New domestic league → attach its hub to every existing CONTINENTAL / INTERNATIONAL.
        if (params.tournamentType == TournamentType.DOMESTIC_LEAGUE) {
            _linkNewLeagueHub(registry, newLeagueHub);
        }

        (bytes32[] memory seasonIds, uint16[] memory seasonStartYears) =
            _openSeasons(registry, bootstrap.tournamentId, bootstrap.seasons);

        data = CreateTournamentData({
            tournamentId: bootstrap.tournamentId,
            tournamentType: params.tournamentType,
            pbrTreasury: pbrTreasury,
            pbrFeeHub: pbrFeeHub,
            seasonIds: seasonIds,
            seasonStartYears: seasonStartYears
        });
    }

    /// @inheritdoc ITournamentInitializer
    function openSeason(
        bytes32 tournamentId,
        bytes32 seasonId,
        uint16 seasonStartYear,
        uint32 finalRound
    ) external onlySeasonOpener {
        if (tournamentId == bytes32(0) || seasonId == bytes32(0) || seasonStartYear == 0) {
            revert Errors.ZeroId();
        }
        if (finalRound == 0) revert Errors.InvalidOpenSeasonData();
        _tournamentRegistry().openSeason(tournamentId, seasonId, seasonStartYear, finalRound);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _tournamentRegistry() private view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    function _createTreasury(BootstrapParams calldata bootstrap) private returns (address pbrTreasury) {
        pbrTreasury = IPbrTreasuryFactory(_getAddress(_addressKey(Addresses.PBR_TREASURY_FACTORY)))
            .create(bootstrap.tournamentId, bootstrap.initialSeasonStartYear, bootstrap.treasurySalt);
    }

    function _createFeeHub(bytes32 leagueId, address leagueTreasury) private returns (address hub) {
        hub =
            IPbrFeeHubFactory(_getAddress(_addressKey(Addresses.PBR_FEE_HUB_FACTORY))).create(leagueId, leagueTreasury);
    }

    function _resolveHubs(
        ITournamentRegistry registry,
        bytes32[] calldata leagueIds
    ) private view returns (Hub[] memory hubs) {
        uint256 length = leagueIds.length;
        hubs = new Hub[](length);
        for (uint256 i; i < length; ++i) {
            bytes32 leagueId = leagueIds[i];
            if (leagueId == bytes32(0)) revert Errors.ZeroId();
            address pbrFeeHub = registry.pbrFeeHubOf(leagueId);
            if (pbrFeeHub == address(0)) revert Errors.HubNotRegistered(leagueId);
            hubs[i] = Hub({ leagueId: leagueId, pbrFeeHub: pbrFeeHub });
        }
    }

    function _openSeasons(
        ITournamentRegistry registry,
        bytes32 tournamentId,
        BootstrapSeason[] calldata seasons
    ) private returns (bytes32[] memory seasonIds, uint16[] memory seasonStartYears) {
        uint256 length = seasons.length;
        seasonIds = new bytes32[](length);
        seasonStartYears = new uint16[](length);
        for (uint256 i; i < length; ++i) {
            BootstrapSeason calldata season = seasons[i];
            registry.openSeason(tournamentId, season.seasonId, season.seasonStartYear, season.finalRound);
            seasonIds[i] = season.seasonId;
            seasonStartYears[i] = season.seasonStartYear;
        }
    }

    /// @dev Prerequisite: a newly created `DOMESTIC_LEAGUE` hub must join existing multi-hub pots.
    function _linkNewLeagueHub(ITournamentRegistry registry, Hub memory hub) private {
        uint256 length = registry.tournamentCount();
        for (uint256 i; i < length; ++i) {
            bytes32 tournamentId = registry.tournamentIdAt(i);
            TournamentType tournamentType = registry.getTournamentType(tournamentId);
            if (tournamentType == TournamentType.CONTINENTAL || tournamentType == TournamentType.INTERNATIONAL) {
                registry.linkHub(tournamentId, hub);
            }
        }
    }
}
