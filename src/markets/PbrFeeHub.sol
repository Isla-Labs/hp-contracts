// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

/**
 * @title PbrFeeHub
 * @notice Per-domestic-league fee splitter: `FeeRouter` → hub → typed `PbrTreasury` destinations.
 * @dev Destinations are stored locally and dual-written by TournamentExecutor when tournaments
 *      are created / wired (registry remains the topology source of truth for calendars).
 *
 *      Top-level default weights (BPS): domestic 90% / continental 9% / international 1%.
 *      Cascade split: live continental / international buckets take their fixed BPS of gross;
 *      domestic always receives the remainder (engulfs inactive bucket shares).
 *
 *      Domestic sub-split: `leagueShareBps` → league treasury; remainder even across cups
 *      (if no cups, 100% → league). Continental / international: even split.
 *      `internationalActive`: `internationalActiveShareBps` of gross → `internationalActiveTreasury`;
 *      remainder continues through the normal cascade.
 *
 *      Failed legs are tracked in `pending` and retried via `forward` / `forwardPending`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHub is Initializable, AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // --------------------------------------------
    //  Internal Constants
    // --------------------------------------------

    uint16 public constant BPS_DENOMINATOR = 10_000;

    uint8 public constant KIND_DOMESTIC_LEAGUE = 1;
    uint8 public constant KIND_DOMESTIC_CUP = 2;
    uint8 public constant KIND_CONTINENTAL = 3;
    uint8 public constant KIND_INTERNATIONAL = 4;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    bytes32 public leagueId;

    /// @notice Top-level weights; must sum to `BPS_DENOMINATOR`
    /// @dev Continental / international take fixed BPS when live; domestic gets the remainder.
    uint16 public domesticBps;
    uint16 public continentalBps;
    uint16 public internationalBps;

    /// @notice Share of the domestic bucket paid to the league treasury (remainder → cups evenly)
    uint16 public leagueShareBps;

    /// @notice Primary domestic-league `PbrTreasury`
    address public leagueTreasury;

    address[] private _domesticCups;
    address[] private _continental;
    address[] private _international;

    /// @notice When true, `internationalActiveShareBps` of gross → `internationalActiveTreasury`
    bool public internationalActive;

    /// @notice Temporary override destination while `internationalActive`; cleared on deactivate
    address public internationalActiveTreasury;

    /// @notice Share of gross paid to `internationalActiveTreasury` when active (remainder → cascade)
    uint16 public internationalActiveShareBps;

    mapping(address treasury => uint256) public pending;

    // --------------------------------------------
    //  Events
    // --------------------------------------------

    event FeesReceived(uint256 amount);
    event FeesRelayed(uint8 indexed kind, address indexed treasury, uint256 amount);
    event FeesQueued(uint8 indexed kind, address indexed treasury, uint256 amount);
    event TopLevelSplitUpdated(uint16 domesticBps, uint16 continentalBps, uint16 internationalBps);
    event LeagueShareUpdated(uint16 leagueShareBps);
    event LeagueTreasuryUpdated(address indexed previous, address indexed treasury);
    event DomesticCupsUpdated(address[] cups);
    event ContinentalUpdated(address[] treasuries);
    event InternationalUpdated(address[] treasuries);
    event InternationalActiveUpdated(bool active, address indexed treasury);
    event InternationalActiveShareUpdated(uint16 internationalActiveShareBps);

    // --------------------------------------------
    //  Errors
    // --------------------------------------------

    error ZeroAddress();
    error ZeroId();
    error NoLiveDestination();
    error InvalidBpsTotal(uint256 total);
    error DuplicateTreasury(address treasury);
    error InternationalNotConfigured();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin_ Admin for split / destination updates (TournamentExecutor / multisig).
     * @param leagueId_ Domestic league this hub serves.
     * @param leagueTreasury_ Primary domestic league `PbrTreasury`.
     */
    function initialize(address admin_, bytes32 leagueId_, address leagueTreasury_) external initializer {
        if (admin_ == address(0) || leagueTreasury_ == address(0)) revert ZeroAddress();
        if (leagueId_ == bytes32(0)) revert ZeroId();

        leagueId = leagueId_;
        leagueTreasury = leagueTreasury_;
        _grantRole(ADMIN_ROLE, admin_);

        domesticBps = 9000;
        continentalBps = 900;
        internationalBps = 100;
        leagueShareBps = 8900;
        internationalActiveShareBps = 9000;

        emit TopLevelSplitUpdated(domesticBps, continentalBps, internationalBps);
        emit LeagueShareUpdated(leagueShareBps);
        emit InternationalActiveShareUpdated(internationalActiveShareBps);
        emit LeagueTreasuryUpdated(address(0), leagueTreasury_);
    }

    // --------------------------------------------
    //  Receipt
    // --------------------------------------------

    receive() external payable nonReentrant {
        _split(msg.value);
    }

    /// @notice Retries pending amounts for all configured destinations
    function forward() external nonReentrant {
        _forward(KIND_DOMESTIC_LEAGUE, leagueTreasury);

        uint256 cups = _domesticCups.length;
        for (uint256 i; i < cups; ++i) {
            _forward(KIND_DOMESTIC_CUP, _domesticCups[i]);
        }

        uint256 cont = _continental.length;
        for (uint256 i; i < cont; ++i) {
            _forward(KIND_CONTINENTAL, _continental[i]);
        }

        _forward(KIND_INTERNATIONAL, internationalActiveTreasury);

        uint256 intl = _international.length;
        for (uint256 i; i < intl; ++i) {
            _forward(KIND_INTERNATIONAL, _international[i]);
        }
    }

    /// @notice Retries pending for a specific treasury (including orphaned destinations)
    function forwardPending(address treasury) external nonReentrant {
        if (treasury == address(0)) revert ZeroAddress();
        _forward(0, treasury);
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function setTopLevelSplit(uint16 domesticBps_, uint16 continentalBps_, uint16 internationalBps_)
        external
        onlyRole(ADMIN_ROLE)
    {
        uint256 total = uint256(domesticBps_) + continentalBps_ + internationalBps_;
        if (total != BPS_DENOMINATOR) revert InvalidBpsTotal(total);

        domesticBps = domesticBps_;
        continentalBps = continentalBps_;
        internationalBps = internationalBps_;
        emit TopLevelSplitUpdated(domesticBps_, continentalBps_, internationalBps_);
    }

    function setLeagueShareBps(uint16 leagueShareBps_) external onlyRole(ADMIN_ROLE) {
        if (leagueShareBps_ > BPS_DENOMINATOR) revert InvalidBpsTotal(leagueShareBps_);
        leagueShareBps = leagueShareBps_;
        emit LeagueShareUpdated(leagueShareBps_);
    }

    function setLeagueTreasury(address treasury_) external onlyRole(ADMIN_ROLE) {
        if (treasury_ == address(0)) revert ZeroAddress();
        address previous = leagueTreasury;
        leagueTreasury = treasury_;
        emit LeagueTreasuryUpdated(previous, treasury_);
    }

    function setDomesticCups(address[] calldata cups_) external onlyRole(ADMIN_ROLE) {
        _setAddressList(_domesticCups, cups_);
        emit DomesticCupsUpdated(cups_);
    }

    function setContinental(address[] calldata treasuries_) external onlyRole(ADMIN_ROLE) {
        _setAddressList(_continental, treasuries_);
        emit ContinentalUpdated(treasuries_);
    }

    function setInternational(address[] calldata treasuries_) external onlyRole(ADMIN_ROLE) {
        _setAddressList(_international, treasuries_);
        emit InternationalUpdated(treasuries_);
    }

    /**
     * @notice Toggle temporary international override window.
     * @dev When `active` is true, `treasury` receives `internationalActiveShareBps` of gross and
     *      the remainder uses the normal cascade. When false, `treasury` is ignored and
     *      `internationalActiveTreasury` is cleared to `address(0)`.
     */
    function setInternationalActive(bool active, address treasury) external onlyRole(ADMIN_ROLE) {
        if (active) {
            if (treasury == address(0)) revert ZeroAddress();
            internationalActiveTreasury = treasury;
            internationalActive = true;
            emit InternationalActiveUpdated(true, treasury);
            return;
        }

        internationalActive = false;
        internationalActiveTreasury = address(0);
        emit InternationalActiveUpdated(false, address(0));
    }

    /// @notice Share of gross routed to `internationalActiveTreasury` while the override is active
    function setInternationalActiveShareBps(uint16 shareBps_) external onlyRole(ADMIN_ROLE) {
        if (shareBps_ > BPS_DENOMINATOR) revert InvalidBpsTotal(shareBps_);
        internationalActiveShareBps = shareBps_;
        emit InternationalActiveShareUpdated(shareBps_);
    }

    // --------------------------------------------
    //  External View
    // --------------------------------------------

    function getDomesticCups() external view returns (address[] memory) {
        return _domesticCups;
    }

    function getContinental() external view returns (address[] memory) {
        return _continental;
    }

    function getInternational() external view returns (address[] memory) {
        return _international;
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _split(uint256 amount) internal {
        if (amount == 0) return;

        emit FeesReceived(amount);

        if (internationalActive) {
            address dest = internationalActiveTreasury;
            if (dest == address(0)) revert InternationalNotConfigured();

            uint256 overrideAmt = (amount * internationalActiveShareBps) / BPS_DENOMINATOR;
            _pay(KIND_INTERNATIONAL, dest, overrideAmt);
            amount -= overrideAmt;
            if (amount == 0) return;
        }

        _splitCascade(amount);
    }

    /// @dev Normal top-level cascade: live continental / international take fixed BPS; domestic engulfs rest.
    function _splitCascade(uint256 amount) internal {
        if (amount == 0) return;
        if (leagueTreasury == address(0)) revert NoLiveDestination();

        uint256 continentalAmt;
        if (_continental.length != 0) {
            continentalAmt = (amount * continentalBps) / BPS_DENOMINATOR;
            _payEven(KIND_CONTINENTAL, _continental, continentalAmt);
        }

        uint256 internationalAmt;
        if (_international.length != 0) {
            internationalAmt = (amount * internationalBps) / BPS_DENOMINATOR;
            _payEven(KIND_INTERNATIONAL, _international, internationalAmt);
        }

        _splitDomestic(amount - continentalAmt - internationalAmt);
    }

    function _splitDomestic(uint256 amount) internal {
        if (amount == 0) return;
        if (leagueTreasury == address(0)) revert NoLiveDestination();

        uint256 liveCups = _domesticCups.length;
        if (liveCups == 0) {
            _pay(KIND_DOMESTIC_LEAGUE, leagueTreasury, amount);
            return;
        }

        uint256 leagueAmt = (amount * leagueShareBps) / BPS_DENOMINATOR;
        _pay(KIND_DOMESTIC_LEAGUE, leagueTreasury, leagueAmt);
        _payEven(KIND_DOMESTIC_CUP, _domesticCups, amount - leagueAmt);
    }

    function _payEven(uint8 kind, address[] storage treasuries, uint256 amount) internal {
        if (amount == 0) return;

        uint256 count = treasuries.length;
        if (count == 0) revert NoLiveDestination();

        uint256 share = amount / count;
        uint256 distributed;
        for (uint256 i; i < count; ++i) {
            uint256 leg = i == count - 1 ? amount - distributed : share;
            distributed += leg;
            _pay(kind, treasuries[i], leg);
        }
    }

    function _pay(uint8 kind, address treasury, uint256 amount) internal {
        if (amount == 0) return;
        if (treasury == address(0)) revert NoLiveDestination();

        (bool ok,) = treasury.call{ value: amount }("");
        if (ok) {
            emit FeesRelayed(kind, treasury, amount);
        } else {
            pending[treasury] += amount;
            emit FeesQueued(kind, treasury, amount);
        }
    }

    function _forward(uint8 kind, address treasury) internal {
        if (treasury == address(0)) return;

        uint256 amount = pending[treasury];
        if (amount == 0) return;

        pending[treasury] = 0;
        (bool ok,) = treasury.call{ value: amount }("");
        if (ok) {
            emit FeesRelayed(kind, treasury, amount);
        } else {
            pending[treasury] = amount;
            emit FeesQueued(kind, treasury, amount);
        }
    }

    function _setAddressList(address[] storage list, address[] calldata next) internal {
        uint256 length = next.length;
        for (uint256 i; i < length; ++i) {
            address treasury = next[i];
            if (treasury == address(0)) revert ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (next[j] == treasury) revert DuplicateTreasury(treasury);
            }
        }

        uint256 existing = list.length;
        for (uint256 i; i < existing; ++i) {
            list.pop();
        }
        for (uint256 i; i < length; ++i) {
            list.push(next[i]);
        }
    }
}
