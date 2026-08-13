// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Hub, TournamentType } from "@types/registries/TournamentTypes.sol";
import { IPbrFeeHub } from "@interfaces/markets/IPbrFeeHub.sol";

/// @notice Initializer-grade TournamentRegistry stub (MI + LM + TI).
contract MockTournamentRegistry {
    mapping(bytes32 => bool) public exists;
    mapping(bytes32 => address) public pbrFeeHubOf;
    mapping(bytes32 => address) public pbrTreasuryOf;
    mapping(bytes32 => bytes32) public tournamentIdOfSeason;
    mapping(bytes32 => mapping(bytes32 => bool)) public leagueLinked; // tournamentId => leagueId
    mapping(bytes32 => TournamentType) internal _types;

    Hub[] internal _domesticHubs;
    bytes32[] internal _tournamentIds;

    uint256 public createTournamentCount;
    uint256 public openSeasonCount;
    uint256 public registerHubCount;
    uint256 public linkHubCount;

    bytes32 public lastCreatedTournamentId;
    TournamentType public lastCreatedType;
    address public lastCreatedTreasury;

    function setTournamentExists(bytes32 tournamentId, bool value) external {
        exists[tournamentId] = value;
        if (value) _pushTournamentId(tournamentId);
    }

    function setPbrFeeHub(bytes32 leagueId, address hub) external {
        pbrFeeHubOf[leagueId] = hub;
    }

    function setPbrTreasury(bytes32 tournamentId, address treasury) external {
        pbrTreasuryOf[tournamentId] = treasury;
    }

    function setSeasonTournament(bytes32 seasonId, bytes32 tournamentId) external {
        tournamentIdOfSeason[seasonId] = tournamentId;
    }

    function setLeagueLinked(bytes32 tournamentId, bytes32 leagueId, bool linked) external {
        leagueLinked[tournamentId][leagueId] = linked;
    }

    function setTournamentType(bytes32 tournamentId, TournamentType tournamentType) external {
        _types[tournamentId] = tournamentType;
    }

    function addDomesticHub(bytes32 leagueId, address hub) external {
        _domesticHubs.push(Hub({ leagueId: leagueId, pbrFeeHub: hub }));
        pbrFeeHubOf[leagueId] = hub;
        exists[leagueId] = true;
        _types[leagueId] = TournamentType.DOMESTIC_LEAGUE;
        _pushTournamentId(leagueId);
    }

    function tournamentExists(bytes32 tournamentId) external view returns (bool) {
        return exists[tournamentId];
    }

    function getPbrTreasury(bytes32 tournamentId) external view returns (address) {
        return pbrTreasuryOf[tournamentId];
    }

    function isLeagueLinkedToTournament(bytes32 tournamentId, bytes32 leagueId) external view returns (bool) {
        if (tournamentId == leagueId) return true;
        return leagueLinked[tournamentId][leagueId];
    }

    function getAllDomesticHubs() external view returns (Hub[] memory) {
        return _domesticHubs;
    }

    function tournamentCount() external view returns (uint256) {
        return _tournamentIds.length;
    }

    function tournamentIdAt(uint256 index) external view returns (bytes32) {
        return _tournamentIds[index];
    }

    function getTournamentType(bytes32 tournamentId) external view returns (TournamentType) {
        return _types[tournamentId];
    }

    function registerHub(Hub calldata hub) external {
        pbrFeeHubOf[hub.leagueId] = hub.pbrFeeHub;
        exists[hub.leagueId] = true;
        _types[hub.leagueId] = TournamentType.DOMESTIC_LEAGUE;
        _domesticHubs.push(hub);
        _pushTournamentId(hub.leagueId);
        unchecked {
            ++registerHubCount;
        }
    }

    function createTournament(
        bytes32 tournamentId,
        TournamentType tournamentType,
        Hub[] calldata feeHubs,
        address pbrTreasury
    ) external {
        exists[tournamentId] = true;
        pbrTreasuryOf[tournamentId] = pbrTreasury;
        _types[tournamentId] = tournamentType;
        lastCreatedTournamentId = tournamentId;
        lastCreatedType = tournamentType;
        lastCreatedTreasury = pbrTreasury;
        _pushTournamentId(tournamentId);

        if (tournamentType != TournamentType.DOMESTIC_LEAGUE) {
            uint256 length = feeHubs.length;
            for (uint256 i; i < length; ++i) {
                _appendTreasuryToHub(feeHubs[i].pbrFeeHub, tournamentType, pbrTreasury);
                leagueLinked[tournamentId][feeHubs[i].leagueId] = true;
            }
        }

        unchecked {
            ++createTournamentCount;
        }
    }

    function linkHub(bytes32 tournamentId, Hub calldata hub) external {
        leagueLinked[tournamentId][hub.leagueId] = true;
        unchecked {
            ++linkHubCount;
        }
    }

    function openSeason(bytes32 tournamentId, bytes32 seasonId, uint16, uint32) external {
        tournamentIdOfSeason[seasonId] = tournamentId;
        unchecked {
            ++openSeasonCount;
        }
    }

    function _appendTreasuryToHub(address hubAddr, TournamentType tournamentType, address treasury) internal {
        IPbrFeeHub hub = IPbrFeeHub(hubAddr);
        if (tournamentType == TournamentType.DOMESTIC_CUP) {
            hub.setDomesticCups(_appendAddress(hub.getDomesticCups(), treasury));
        } else if (tournamentType == TournamentType.CONTINENTAL) {
            hub.setContinental(_appendAddress(hub.getContinental(), treasury));
        } else if (tournamentType == TournamentType.INTERNATIONAL) {
            hub.setInternational(_appendAddress(hub.getInternational(), treasury));
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

    function _pushTournamentId(bytes32 tournamentId) internal {
        uint256 length = _tournamentIds.length;
        for (uint256 i; i < length; ++i) {
            if (_tournamentIds[i] == tournamentId) return;
        }
        _tournamentIds.push(tournamentId);
    }
}
