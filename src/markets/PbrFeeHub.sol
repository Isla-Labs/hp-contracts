// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { TournamentType } from "@types/TournamentTypes.sol";

/**
 * @title PbrFeeHub
 * @notice Per-domestic-league fee splitter: `FeeRouter` → hub → typed `PbrTreasury` destinations.
 * @dev Destinations are stored locally and dual-written when tournaments are created / wired
 *      (registry remains the topology source of truth for calendars).
 *
 *      Access: `Orchestrator` (owner) for split parameters and treasury / destination wiring.
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
contract PbrFeeHub is Initializable, AddressBook, Ownable, ReentrancyGuard {
    uint16 public constant BPS_DENOMINATOR = 10_000;

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
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Initializes per-league hub storage; league wiring stays explicit.
     * @param leagueId_ Domestic league this hub serves.
     * @param leagueTreasury_ Primary domestic league `PbrTreasury`.
     */
    function initialize(bytes32 leagueId_, address leagueTreasury_) external initializer {
        if (leagueTreasury_ == address(0)) revert Errors.ZeroAddress();
        if (leagueId_ == bytes32(0)) revert Errors.ZeroId();

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));

        leagueId = leagueId_;
        leagueTreasury = leagueTreasury_;

        domesticBps = 9000;
        continentalBps = 900;
        internationalBps = 100;
        leagueShareBps = 8900;
        internationalActiveShareBps = 9000;

        emit Events.TopLevelSplitUpdated(domesticBps, continentalBps, internationalBps);
        emit Events.LeagueShareUpdated(leagueShareBps);
        emit Events.InternationalActiveShareUpdated(internationalActiveShareBps);
        emit Events.LeagueTreasuryUpdated(address(0), leagueTreasury_);
    }

    // --------------------------------------------
    //  Receipt
    // --------------------------------------------

    receive() external payable nonReentrant {
        _split(msg.value);
    }

    /// @notice Retries pending amounts for all configured destinations
    function forward() external nonReentrant {
        _forward(TournamentType.DOMESTIC_LEAGUE, leagueTreasury);

        uint256 cups = _domesticCups.length;
        for (uint256 i; i < cups; ++i) {
            _forward(TournamentType.DOMESTIC_CUP, _domesticCups[i]);
        }

        uint256 cont = _continental.length;
        for (uint256 i; i < cont; ++i) {
            _forward(TournamentType.CONTINENTAL, _continental[i]);
        }

        _forward(TournamentType.INTERNATIONAL, internationalActiveTreasury);

        uint256 intl = _international.length;
        for (uint256 i; i < intl; ++i) {
            _forward(TournamentType.INTERNATIONAL, _international[i]);
        }
    }

    /// @notice Retries pending for a specific treasury (including orphaned destinations).
    /// @dev Emits `OrphanFeesRelayed` / `OrphanFeesQueued` — no `TournamentType` (bucket may be unknown).
    function forwardPending(address treasury) external nonReentrant {
        if (treasury == address(0)) revert Errors.ZeroAddress();
        _forwardOrphan(treasury);
    }

    // --------------------------------------------
    //  Admin (owner)
    // --------------------------------------------

    function setTopLevelSplit(
        uint16 domesticBps_,
        uint16 continentalBps_,
        uint16 internationalBps_
    ) external onlyOwner {
        uint256 total = uint256(domesticBps_) + continentalBps_ + internationalBps_;
        if (total != BPS_DENOMINATOR) revert Errors.InvalidBpsTotal(total);

        domesticBps = domesticBps_;
        continentalBps = continentalBps_;
        internationalBps = internationalBps_;
        emit Events.TopLevelSplitUpdated(domesticBps_, continentalBps_, internationalBps_);
    }

    function setLeagueShareBps(uint16 leagueShareBps_) external onlyOwner {
        if (leagueShareBps_ > BPS_DENOMINATOR) revert Errors.InvalidBpsTotal(leagueShareBps_);
        leagueShareBps = leagueShareBps_;
        emit Events.LeagueShareUpdated(leagueShareBps_);
    }

    function setLeagueTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert Errors.ZeroAddress();
        address previous = leagueTreasury;
        leagueTreasury = treasury_;
        emit Events.LeagueTreasuryUpdated(previous, treasury_);
    }

    function setDomesticCups(address[] calldata cups_) external onlyOwner {
        _setAddressList(_domesticCups, cups_);
        emit Events.DomesticCupsUpdated(cups_);
    }

    function setContinental(address[] calldata treasuries_) external onlyOwner {
        _setAddressList(_continental, treasuries_);
        emit Events.ContinentalUpdated(treasuries_);
    }

    function setInternational(address[] calldata treasuries_) external onlyOwner {
        _setAddressList(_international, treasuries_);
        emit Events.InternationalUpdated(treasuries_);
    }

    /**
     * @notice Toggle temporary international override window.
     * @dev When `active` is true, `treasury` receives `internationalActiveShareBps` of gross and
     *      the remainder uses the normal cascade. When false, `treasury` is ignored and
     *      `internationalActiveTreasury` is cleared to `address(0)`.
     */
    function setInternationalActive(bool active, address treasury) external onlyOwner {
        if (active) {
            if (treasury == address(0)) revert Errors.ZeroAddress();
            internationalActiveTreasury = treasury;
            internationalActive = true;
            emit Events.InternationalActiveUpdated(true, treasury);
            return;
        }

        internationalActive = false;
        internationalActiveTreasury = address(0);
        emit Events.InternationalActiveUpdated(false, address(0));
    }

    /// @notice Share of gross routed to `internationalActiveTreasury` while the override is active
    function setInternationalActiveShareBps(uint16 shareBps_) external onlyOwner {
        if (shareBps_ > BPS_DENOMINATOR) revert Errors.InvalidBpsTotal(shareBps_);
        internationalActiveShareBps = shareBps_;
        emit Events.InternationalActiveShareUpdated(shareBps_);
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

        emit Events.FeesReceived(amount);

        if (internationalActive) {
            address dest = internationalActiveTreasury;
            if (dest == address(0)) revert Errors.InternationalNotConfigured();

            uint256 overrideAmt = (amount * internationalActiveShareBps) / BPS_DENOMINATOR;
            _pay(TournamentType.INTERNATIONAL, dest, overrideAmt);
            amount -= overrideAmt;
            if (amount == 0) return;
        }

        _splitCascade(amount);
    }

    /// @dev Normal top-level cascade: live continental / international take fixed BPS; domestic engulfs rest.
    function _splitCascade(uint256 amount) internal {
        if (amount == 0) return;
        if (leagueTreasury == address(0)) revert Errors.NoLiveDestination();

        uint256 continentalAmt;
        if (_continental.length != 0) {
            continentalAmt = (amount * continentalBps) / BPS_DENOMINATOR;
            _payEven(TournamentType.CONTINENTAL, _continental, continentalAmt);
        }

        uint256 internationalAmt;
        if (_international.length != 0) {
            internationalAmt = (amount * internationalBps) / BPS_DENOMINATOR;
            _payEven(TournamentType.INTERNATIONAL, _international, internationalAmt);
        }

        _splitDomestic(amount - continentalAmt - internationalAmt);
    }

    function _splitDomestic(uint256 amount) internal {
        if (amount == 0) return;
        if (leagueTreasury == address(0)) revert Errors.NoLiveDestination();

        uint256 liveCups = _domesticCups.length;
        if (liveCups == 0) {
            _pay(TournamentType.DOMESTIC_LEAGUE, leagueTreasury, amount);
            return;
        }

        uint256 leagueAmt = (amount * leagueShareBps) / BPS_DENOMINATOR;
        _pay(TournamentType.DOMESTIC_LEAGUE, leagueTreasury, leagueAmt);
        _payEven(TournamentType.DOMESTIC_CUP, _domesticCups, amount - leagueAmt);
    }

    function _payEven(TournamentType tournamentType, address[] storage treasuries, uint256 amount) internal {
        if (amount == 0) return;

        uint256 count = treasuries.length;
        if (count == 0) revert Errors.NoLiveDestination();

        uint256 share = amount / count;
        uint256 distributed;
        for (uint256 i; i < count; ++i) {
            uint256 leg = i == count - 1 ? amount - distributed : share;
            distributed += leg;
            _pay(tournamentType, treasuries[i], leg);
        }
    }

    function _pay(TournamentType tournamentType, address treasury, uint256 amount) internal {
        if (amount == 0) return;
        if (treasury == address(0)) revert Errors.NoLiveDestination();

        (bool ok,) = treasury.call{ value: amount }("");
        if (ok) {
            emit Events.FeesRelayed(tournamentType, treasury, amount);
        } else {
            pending[treasury] += amount;
            emit Events.FeesQueued(tournamentType, treasury, amount);
        }
    }

    function _forward(TournamentType tournamentType, address treasury) internal {
        if (treasury == address(0)) return;

        uint256 amount = pending[treasury];
        if (amount == 0) return;

        pending[treasury] = 0;
        (bool ok,) = treasury.call{ value: amount }("");
        if (ok) {
            emit Events.FeesRelayed(tournamentType, treasury, amount);
        } else {
            pending[treasury] = amount;
            emit Events.FeesQueued(tournamentType, treasury, amount);
        }
    }

    function _forwardOrphan(address treasury) internal {
        uint256 amount = pending[treasury];
        if (amount == 0) return;

        pending[treasury] = 0;
        (bool ok,) = treasury.call{ value: amount }("");
        if (ok) {
            emit Events.OrphanFeesRelayed(treasury, amount);
        } else {
            pending[treasury] = amount;
            emit Events.OrphanFeesQueued(treasury, amount);
        }
    }

    function _setAddressList(address[] storage list, address[] calldata next) internal {
        uint256 length = next.length;
        for (uint256 i; i < length; ++i) {
            address treasury = next[i];
            if (treasury == address(0)) revert Errors.ZeroAddress();
            for (uint256 j; j < i; ++j) {
                if (next[j] == treasury) revert Errors.DuplicateTreasury(treasury);
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
