// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Hub, TournamentType } from "@types/registries/TournamentTypes.sol";
import { IPbrFeeHub } from "@interfaces/markets/IPbrFeeHub.sol";

/// @notice Locker-grade TournamentRegistry stub (TransferLocker + DeployTournament + DopplerLocker).
contract MockTournamentRegistry {
    mapping(bytes32 => bool) public exists;
    mapping(bytes32 => address) public pbrFeeHubOf;
    mapping(bytes32 => address) public pbrTreasuryOf;
    mapping(bytes32 => bytes32) public tournamentIdOfSeason;
    mapping(bytes32 => mapping(bytes32 => bool)) public leagueLinked; // tournamentId => leagueId

    Hub[] internal _domesticHubs;

    uint256 public createTournamentCount;
    uint256 public openSeasonCount;
    uint256 public registerHubCount;

    bytes32 public lastCreatedTournamentId;
    TournamentType public lastCreatedType;
    address public lastCreatedTreasury;

    function setTournamentExists(bytes32 tournamentId, bool value) external {
        exists[tournamentId] = value;
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

    function addDomesticHub(bytes32 leagueId, address hub) external {
        _domesticHubs.push(Hub({ leagueId: leagueId, pbrFeeHub: hub }));
        pbrFeeHubOf[leagueId] = hub;
        exists[leagueId] = true;
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

    function registerHub(Hub calldata hub) external {
        pbrFeeHubOf[hub.leagueId] = hub.pbrFeeHub;
        exists[hub.leagueId] = true;
        _domesticHubs.push(hub);
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
        lastCreatedTournamentId = tournamentId;
        lastCreatedType = tournamentType;
        lastCreatedTreasury = pbrTreasury;

        // Mirror production: non-league create dual-writes treasury onto linked hubs.
        if (tournamentType != TournamentType.DOMESTIC_LEAGUE) {
            uint256 length = feeHubs.length;
            for (uint256 i; i < length; ++i) {
                _appendTreasuryToHub(feeHubs[i].pbrFeeHub, tournamentType, pbrTreasury);
            }
        }

        unchecked {
            ++createTournamentCount;
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

    function openSeason(bytes32 tournamentId, bytes32 seasonId, uint16, uint32) external {
        tournamentIdOfSeason[seasonId] = tournamentId;
        unchecked {
            ++openSeasonCount;
        }
    }
}
