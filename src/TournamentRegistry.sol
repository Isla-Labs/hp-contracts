// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { League, Continental, International, Cup, Round } from "@base/global/types/TournamentTypes.sol";

/**
 * @title TournamentRegistry
 * @notice Canonical onchain registry of domestic leagues, Europe, and International competitions.
 * @dev Nested dynamic arrays cannot be assigned wholesale from memory to storage; mutators write
 *      fields / push elements individually. Existence is keyed by `pbrTreasury != address(0)`.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract TournamentRegistry is Ownable {
    /// @notice leagueId => domestic league metadata and cup hierarchy
    mapping(bytes32 => League) private _leagues;

    /// @notice Ordered list of registered domestic league ids (for OOF fee splits)
    bytes32[] private _leagueIds;

    /// @notice Singleton Europe competition entry
    Continental private _continental;

    /// @notice Singleton International competition entry
    International private _international;

    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event LeagueCreated(bytes32 indexed leagueId, address indexed pbrTreasury);
    event ContinentalCreated(address indexed pbrTreasury);
    event InternationalCreated(address indexed pbrTreasury);

    event CupAdded(bytes32 indexed competitionId, bytes32 indexed cupId, uint256 cupIndex);
    event RoundAdded(bytes32 indexed competitionId, uint256 indexed cupIndex, uint32 roundNumber, uint256 roundIndex);
    event RoundTimesUpdated(
        bytes32 indexed competitionId,
        uint256 indexed cupIndex,
        uint256 roundIndex,
        uint256 roundStartTime,
        uint256 roundEndTime
    );

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error LeagueAlreadyExists(bytes32 leagueId);
    error LeagueDoesNotExist(bytes32 leagueId);
    error ContinentalAlreadyExists();
    error ContinentalDoesNotExist();
    error InternationalAlreadyExists();
    error InternationalDoesNotExist();
    error CupAlreadyExists(bytes32 competitionId, bytes32 cupId);
    error CupDoesNotExist(bytes32 competitionId, uint256 cupIndex);
    error RoundAlreadyExists(bytes32 competitionId, uint256 cupIndex, uint32 roundNumber);
    error RoundDoesNotExist(bytes32 competitionId, uint256 cupIndex, uint256 roundIndex);
    error InvalidTimeRange(uint256 startTime, uint256 endTime);

    /// @dev Sentinel competition ids for Europe / International cup events and lookups
    bytes32 public constant CONTINENTAL_ID = keccak256("CONTINENTAL");
    bytes32 public constant INTERNATIONAL_ID = keccak256("INTERNATIONAL");

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /**
     * @param initialOwner Contract owner. Should be `LifecycleTimelock` at deployment.
     */
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
    }

    // --------------------------------------------
    //  Writes — Domestic Leagues
    // --------------------------------------------

    /**
     * @notice Registers a new domestic league and binds its PBR treasury deployment.
     * @param leagueId Unique league identifier.
     * @param pbrTreasury Deployed PBRTreasury for this league.
     */
    function createLeague(bytes32 leagueId, address pbrTreasury) external onlyOwner {
        if (leagueId == bytes32(0)) revert ZeroId();
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (_leagues[leagueId].pbrTreasury != address(0)) revert LeagueAlreadyExists(leagueId);

        _leagues[leagueId].pbrTreasury = pbrTreasury;
        _leagueIds.push(leagueId);

        emit LeagueCreated(leagueId, pbrTreasury);
    }

    /**
     * @notice Appends a domestic cup (empty round list) to an existing league.
     */
    function addLeagueCup(bytes32 leagueId, bytes32 cupId) external onlyOwner {
        if (cupId == bytes32(0)) revert ZeroId();
        League storage league = _requireLeague(leagueId);
        if (_findCupIndex(league.cups, cupId) != type(uint256).max) {
            revert CupAlreadyExists(leagueId, cupId);
        }

        uint256 cupIndex = league.cups.length;
        Cup storage cup = league.cups.push();
        cup.cupId = cupId;

        emit CupAdded(leagueId, cupId, cupIndex);
    }

    /**
     * @notice Appends a round to an existing league cup.
     */
    function addLeagueRound(bytes32 leagueId, uint256 cupIndex, Round calldata round) external onlyOwner {
        Cup storage cup = _requireLeagueCup(leagueId, cupIndex);
        _pushRound(leagueId, cupIndex, cup, round);
    }

    /**
     * @notice Updates only `roundStartTime` / `roundEndTime` for a league cup round.
     */
    function updateLeagueRoundTimes(
        bytes32 leagueId,
        uint256 cupIndex,
        uint256 roundIndex,
        uint256 roundStartTime,
        uint256 roundEndTime
    ) external onlyOwner {
        _updateRoundTimes(leagueId, _requireLeagueCup(leagueId, cupIndex), cupIndex, roundIndex, roundStartTime, roundEndTime);
    }

    // --------------------------------------------
    //  Writes — Europe
    // --------------------------------------------

    /**
     * @notice Registers the singleton Europe competition and binds its PBR treasury.
     */
    function createContinental(address pbrTreasury) external onlyOwner {
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (_continental.pbrTreasury != address(0)) revert ContinentalAlreadyExists();

        _continental.pbrTreasury = pbrTreasury;
        emit ContinentalCreated(pbrTreasury);
    }

    function addContinentalCup(bytes32 cupId) external onlyOwner {
        if (cupId == bytes32(0)) revert ZeroId();
        if (_continental.pbrTreasury == address(0)) revert ContinentalDoesNotExist();
        if (_findCupIndex(_continental.cups, cupId) != type(uint256).max) {
            revert CupAlreadyExists(CONTINENTAL_ID, cupId);
        }

        uint256 cupIndex = _continental.cups.length;
        Cup storage cup = _continental.cups.push();
        cup.cupId = cupId;

        emit CupAdded(CONTINENTAL_ID, cupId, cupIndex);
    }

    function addContinentalRound(uint256 cupIndex, Round calldata round) external onlyOwner {
        Cup storage cup = _requireContinentalCup(cupIndex);
        _pushRound(CONTINENTAL_ID, cupIndex, cup, round);
    }

    function updateContinentalRoundTimes(uint256 cupIndex, uint256 roundIndex, uint256 roundStartTime, uint256 roundEndTime)
        external
        onlyOwner
    {
        _updateRoundTimes(CONTINENTAL_ID, _requireContinentalCup(cupIndex), cupIndex, roundIndex, roundStartTime, roundEndTime);
    }

    // --------------------------------------------
    //  Writes — International
    // --------------------------------------------

    /**
     * @notice Registers the singleton International competition and binds its PBR treasury.
     */
    function createInternational(address pbrTreasury) external onlyOwner {
        if (pbrTreasury == address(0)) revert ZeroAddress();
        if (_international.pbrTreasury != address(0)) revert InternationalAlreadyExists();

        _international.pbrTreasury = pbrTreasury;
        emit InternationalCreated(pbrTreasury);
    }

    function addInternationalCup(bytes32 cupId) external onlyOwner {
        if (cupId == bytes32(0)) revert ZeroId();
        if (_international.pbrTreasury == address(0)) revert InternationalDoesNotExist();
        if (_findCupIndex(_international.cups, cupId) != type(uint256).max) {
            revert CupAlreadyExists(INTERNATIONAL_ID, cupId);
        }

        uint256 cupIndex = _international.cups.length;
        Cup storage cup = _international.cups.push();
        cup.cupId = cupId;

        emit CupAdded(INTERNATIONAL_ID, cupId, cupIndex);
    }

    function addInternationalRound(uint256 cupIndex, Round calldata round) external onlyOwner {
        Cup storage cup = _requireInternationalCup(cupIndex);
        _pushRound(INTERNATIONAL_ID, cupIndex, cup, round);
    }

    function updateInternationalRoundTimes(
        uint256 cupIndex,
        uint256 roundIndex,
        uint256 roundStartTime,
        uint256 roundEndTime
    ) external onlyOwner {
        _updateRoundTimes(
            INTERNATIONAL_ID, _requireInternationalCup(cupIndex), cupIndex, roundIndex, roundStartTime, roundEndTime
        );
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @notice Returns every registered domestic league PBR treasury (ordered by creation).
    function getAllDomesticPbrTreasuries() external view returns (address[] memory treasuries) {
        uint256 length = _leagueIds.length;
        treasuries = new address[](length);
        for (uint256 i; i < length; ++i) {
            treasuries[i] = _leagues[_leagueIds[i]].pbrTreasury;
        }
    }

    function getLeagueIds() external view returns (bytes32[] memory) {
        return _leagueIds;
    }

    function getLeague(bytes32 leagueId) external view returns (address pbrTreasury, uint256 cupCount) {
        League storage league = _requireLeague(leagueId);
        return (league.pbrTreasury, league.cups.length);
    }

    function getLeagueCup(bytes32 leagueId, uint256 cupIndex) external view returns (bytes32 cupId, uint256 roundCount) {
        Cup storage cup = _requireLeagueCup(leagueId, cupIndex);
        return (cup.cupId, cup.rounds.length);
    }

    function getLeagueRound(bytes32 leagueId, uint256 cupIndex, uint256 roundIndex)
        external
        view
        returns (Round memory)
    {
        Cup storage cup = _requireLeagueCup(leagueId, cupIndex);
        if (roundIndex >= cup.rounds.length) revert RoundDoesNotExist(leagueId, cupIndex, roundIndex);
        return cup.rounds[roundIndex];
    }

    function leagueExists(bytes32 leagueId) external view returns (bool) {
        return _leagues[leagueId].pbrTreasury != address(0);
    }

    function getContinental() external view returns (address pbrTreasury, uint256 cupCount) {
        if (_continental.pbrTreasury == address(0)) revert ContinentalDoesNotExist();
        return (_continental.pbrTreasury, _continental.cups.length);
    }

    function getEuropeCup(uint256 cupIndex) external view returns (bytes32 cupId, uint256 roundCount) {
        Cup storage cup = _requireContinentalCup(cupIndex);
        return (cup.cupId, cup.rounds.length);
    }

    function getEuropeRound(uint256 cupIndex, uint256 roundIndex) external view returns (Round memory) {
        Cup storage cup = _requireContinentalCup(cupIndex);
        if (roundIndex >= cup.rounds.length) revert RoundDoesNotExist(CONTINENTAL_ID, cupIndex, roundIndex);
        return cup.rounds[roundIndex];
    }

    function continentalExists() external view returns (bool) {
        return _continental.pbrTreasury != address(0);
    }

    function getInternational() external view returns (address pbrTreasury, uint256 cupCount) {
        if (_international.pbrTreasury == address(0)) revert InternationalDoesNotExist();
        return (_international.pbrTreasury, _international.cups.length);
    }

    function getInternationalCup(uint256 cupIndex) external view returns (bytes32 cupId, uint256 roundCount) {
        Cup storage cup = _requireInternationalCup(cupIndex);
        return (cup.cupId, cup.rounds.length);
    }

    function getInternationalRound(uint256 cupIndex, uint256 roundIndex) external view returns (Round memory) {
        Cup storage cup = _requireInternationalCup(cupIndex);
        if (roundIndex >= cup.rounds.length) revert RoundDoesNotExist(INTERNATIONAL_ID, cupIndex, roundIndex);
        return cup.rounds[roundIndex];
    }

    function internationalExists() external view returns (bool) {
        return _international.pbrTreasury != address(0);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _requireLeague(bytes32 leagueId) internal view returns (League storage league) {
        league = _leagues[leagueId];
        if (league.pbrTreasury == address(0)) revert LeagueDoesNotExist(leagueId);
    }

    function _requireLeagueCup(bytes32 leagueId, uint256 cupIndex) internal view returns (Cup storage cup) {
        League storage league = _requireLeague(leagueId);
        if (cupIndex >= league.cups.length) revert CupDoesNotExist(leagueId, cupIndex);
        cup = league.cups[cupIndex];
    }

    function _requireContinentalCup(uint256 cupIndex) internal view returns (Cup storage cup) {
        if (_continental.pbrTreasury == address(0)) revert ContinentalDoesNotExist();
        if (cupIndex >= _continental.cups.length) revert CupDoesNotExist(CONTINENTAL_ID, cupIndex);
        cup = _continental.cups[cupIndex];
    }

    function _requireInternationalCup(uint256 cupIndex) internal view returns (Cup storage cup) {
        if (_international.pbrTreasury == address(0)) revert InternationalDoesNotExist();
        if (cupIndex >= _international.cups.length) revert CupDoesNotExist(INTERNATIONAL_ID, cupIndex);
        cup = _international.cups[cupIndex];
    }

    function _pushRound(bytes32 competitionId, uint256 cupIndex, Cup storage cup, Round calldata round) internal {
        _validateTimeRange(round.roundStartTime, round.roundEndTime);
        if (_findRoundIndex(cup, round.roundNumber) != type(uint256).max) {
            revert RoundAlreadyExists(competitionId, cupIndex, round.roundNumber);
        }

        uint256 roundIndex = cup.rounds.length;
        cup.rounds.push(round);
        emit RoundAdded(competitionId, cupIndex, round.roundNumber, roundIndex);
    }

    function _updateRoundTimes(
        bytes32 competitionId,
        Cup storage cup,
        uint256 cupIndex,
        uint256 roundIndex,
        uint256 roundStartTime,
        uint256 roundEndTime
    ) internal {
        _validateTimeRange(roundStartTime, roundEndTime);
        if (roundIndex >= cup.rounds.length) revert RoundDoesNotExist(competitionId, cupIndex, roundIndex);

        Round storage round = cup.rounds[roundIndex];
        round.roundStartTime = roundStartTime;
        round.roundEndTime = roundEndTime;

        emit RoundTimesUpdated(competitionId, cupIndex, roundIndex, roundStartTime, roundEndTime);
    }

    function _findCupIndex(Cup[] storage cups, bytes32 cupId) internal view returns (uint256) {
        uint256 length = cups.length;
        for (uint256 i; i < length; ++i) {
            if (cups[i].cupId == cupId) return i;
        }
        return type(uint256).max;
    }

    function _findRoundIndex(Cup storage cup, uint32 roundNumber) internal view returns (uint256) {
        uint256 length = cup.rounds.length;
        for (uint256 i; i < length; ++i) {
            if (cup.rounds[i].roundNumber == roundNumber) return i;
        }
        return type(uint256).max;
    }

    function _validateTimeRange(uint256 startTime, uint256 endTime) internal pure {
        if (endTime <= startTime) revert InvalidTimeRange(startTime, endTime);
    }
}
