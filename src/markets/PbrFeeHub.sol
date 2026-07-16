// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

/**
 * @title PbrFeeHub
 * @notice Per-domestic-league fee splitter: `FeeRouter` → hub → typed `PbrTreasury` destinations.
 * @dev Top-level default split (BPS of incoming ETH):
 *        domestic 90% / continental 9% / international 1%.
 *
 *      Destination kinds: `1 = domestic`, `2 = continental`, `3 = international`.
 *
 *      Domestic sub-split: 89% league treasury, 11% split evenly across domestic cup treasuries.
 *      Continental sub-split: relative weights (default 5:3:1 for UCL:UEL:UECL).
 *      International: 1% accrues to the international treasury; when `internationalActive`,
 *      100% of incoming fees route there instead.
 *
 *      Failed legs are tracked in `pending` and retried via `forward`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrFeeHub is Initializable, AccessControl, ReentrancyGuard {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;

    uint8 public constant KIND_DOMESTIC = 1;
    uint8 public constant KIND_CONTINENTAL = 2;
    uint8 public constant KIND_INTERNATIONAL = 3;

    uint16 public constant DEFAULT_DOMESTIC_BPS = 9000;
    uint16 public constant DEFAULT_CONTINENTAL_BPS = 900;
    uint16 public constant DEFAULT_INTERNATIONAL_BPS = 100;
    uint16 public constant DEFAULT_LEAGUE_SHARE_BPS = 8900;

    bytes32 public leagueId;

    /// @notice Top-level BPS; must sum to `BPS_DENOMINATOR`
    uint16 public domesticBps;
    uint16 public continentalBps;
    uint16 public internationalBps;

    /// @notice Share of the domestic bucket paid to `leagueTreasury` (remainder → cups evenly)
    uint16 public leagueShareBps;

    address public leagueTreasury;
    address[] private _domesticCups;

    address[] private _continentalTreasuries;
    uint16[] private _continentalWeights;

    address public internationalTreasury;

    /// @notice When true, all incoming fees go to `internationalTreasury`
    bool public internationalActive;

    mapping(address treasury => uint256) public pending;

    event FeesReceived(uint256 amount);
    event FeesRelayed(uint8 indexed kind, address indexed treasury, uint256 amount);
    event FeesQueued(uint8 indexed kind, address indexed treasury, uint256 amount);
    event TopLevelSplitUpdated(uint16 domesticBps, uint16 continentalBps, uint16 internationalBps);
    event DomesticUpdated(address leagueTreasury, address[] cups, uint16 leagueShareBps);
    event ContinentalUpdated(address[] treasuries, uint16[] weights);
    event InternationalTreasuryUpdated(address indexed previous, address indexed treasury);
    event InternationalActiveUpdated(bool active);

    error ZeroAddress();
    error ZeroId();
    error LengthMismatch();
    error EmptySplit();
    error InvalidBpsTotal(uint256 total);
    error InvalidWeightTotal();
    error DuplicateTreasury(address treasury);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin_ Admin for split / destination updates.
     * @param leagueId_ Domestic league this hub serves.
     * @param leagueTreasury_ Primary domestic league `PbrTreasury`.
     * @param domesticCups_ Domestic cup treasuries (11% of domestic bucket, even split).
     * @param continentalTreasuries_ Continental cup treasuries (e.g. UCL, UEL, UECL).
     * @param continentalWeights_ Relative weights (default 5,3,1). Length must match treasuries.
     * @param internationalTreasury_ International pot treasury.
     */
    function initialize(
        address admin_,
        bytes32 leagueId_,
        address leagueTreasury_,
        address[] calldata domesticCups_,
        address[] calldata continentalTreasuries_,
        uint16[] calldata continentalWeights_,
        address internationalTreasury_
    ) external initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        if (leagueId_ == bytes32(0)) revert ZeroId();

        leagueId = leagueId_;
        _grantRole(ADMIN_ROLE, admin_);

        domesticBps = DEFAULT_DOMESTIC_BPS;
        continentalBps = DEFAULT_CONTINENTAL_BPS;
        internationalBps = DEFAULT_INTERNATIONAL_BPS;
        leagueShareBps = DEFAULT_LEAGUE_SHARE_BPS;

        _setDomestic(leagueTreasury_, domesticCups_, DEFAULT_LEAGUE_SHARE_BPS);
        _setContinental(continentalTreasuries_, continentalWeights_);
        _setInternationalTreasury(internationalTreasury_);

        emit TopLevelSplitUpdated(domesticBps, continentalBps, internationalBps);
    }

    receive() external payable nonReentrant {
        _split(msg.value);
    }

    /// @notice Retries any pending failed relay amounts across all configured destinations
    function forward() external nonReentrant {
        _forwardOne(KIND_DOMESTIC, leagueTreasury);

        uint256 cups = _domesticCups.length;
        for (uint256 i; i < cups; ++i) {
            _forwardOne(KIND_DOMESTIC, _domesticCups[i]);
        }

        uint256 cont = _continentalTreasuries.length;
        for (uint256 i; i < cont; ++i) {
            _forwardOne(KIND_CONTINENTAL, _continentalTreasuries[i]);
        }

        _forwardOne(KIND_INTERNATIONAL, internationalTreasury);
    }

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

    function setDomestic(address leagueTreasury_, address[] calldata cups_, uint16 leagueShareBps_)
        external
        onlyRole(ADMIN_ROLE)
    {
        _setDomestic(leagueTreasury_, cups_, leagueShareBps_);
    }

    function setContinental(address[] calldata treasuries_, uint16[] calldata weights_) external onlyRole(ADMIN_ROLE) {
        _setContinental(treasuries_, weights_);
    }

    function setInternationalTreasury(address treasury_) external onlyRole(ADMIN_ROLE) {
        _setInternationalTreasury(treasury_);
    }

    /// @notice Toggle World Cup / international window: when true, 100% of fees → international pot
    function setInternationalActive(bool active) external onlyRole(ADMIN_ROLE) {
        internationalActive = active;
        emit InternationalActiveUpdated(active);
    }

    function getDomesticCups() external view returns (address[] memory) {
        return _domesticCups;
    }

    function getContinental() external view returns (address[] memory treasuries, uint16[] memory weights) {
        return (_continentalTreasuries, _continentalWeights);
    }

    // --------------------------------------------
    //  Internals
    // --------------------------------------------

    function _split(uint256 amount) internal {
        if (amount == 0) return;

        emit FeesReceived(amount);

        if (internationalActive) {
            _pay(KIND_INTERNATIONAL, internationalTreasury, amount);
            return;
        }

        uint256 domesticAmt = (amount * domesticBps) / BPS_DENOMINATOR;
        uint256 continentalAmt = (amount * continentalBps) / BPS_DENOMINATOR;
        uint256 internationalAmt = amount - domesticAmt - continentalAmt;

        _splitDomestic(domesticAmt);
        _splitContinental(continentalAmt);
        _pay(KIND_INTERNATIONAL, internationalTreasury, internationalAmt);
    }

    function _splitDomestic(uint256 amount) internal {
        if (amount == 0) return;

        uint256 cupCount = _domesticCups.length;
        if (cupCount == 0) {
            _pay(KIND_DOMESTIC, leagueTreasury, amount);
            return;
        }

        uint256 leagueAmt = (amount * leagueShareBps) / BPS_DENOMINATOR;
        uint256 cupsAmt = amount - leagueAmt;
        _pay(KIND_DOMESTIC, leagueTreasury, leagueAmt);

        uint256 share = cupsAmt / cupCount;
        uint256 distributed;
        for (uint256 i; i < cupCount; ++i) {
            uint256 leg = i == cupCount - 1 ? cupsAmt - distributed : share;
            distributed += leg;
            _pay(KIND_DOMESTIC, _domesticCups[i], leg);
        }
    }

    function _splitContinental(uint256 amount) internal {
        if (amount == 0) return;

        uint256 length = _continentalTreasuries.length;
        if (length == 0) {
            emit FeesQueued(KIND_CONTINENTAL, address(0), amount);
            return;
        }

        uint256 totalWeight;
        for (uint256 i; i < length; ++i) {
            totalWeight += _continentalWeights[i];
        }

        uint256 distributed;
        for (uint256 i; i < length; ++i) {
            uint256 leg =
                i == length - 1 ? amount - distributed : (amount * _continentalWeights[i]) / totalWeight;
            distributed += leg;
            _pay(KIND_CONTINENTAL, _continentalTreasuries[i], leg);
        }
    }

    function _pay(uint8 kind, address treasury, uint256 amount) internal {
        if (amount == 0) return;

        if (treasury == address(0)) {
            emit FeesQueued(kind, treasury, amount);
            return;
        }

        (bool ok,) = treasury.call{ value: amount }("");
        if (ok) {
            emit FeesRelayed(kind, treasury, amount);
        } else {
            pending[treasury] += amount;
            emit FeesQueued(kind, treasury, amount);
        }
    }

    function _forwardOne(uint8 kind, address treasury) internal {
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

    function _setDomestic(address leagueTreasury_, address[] calldata cups_, uint16 leagueShareBps_) internal {
        if (leagueTreasury_ == address(0)) revert ZeroAddress();
        if (leagueShareBps_ > BPS_DENOMINATOR) revert InvalidBpsTotal(leagueShareBps_);

        _assertUnique(leagueTreasury_, cups_);

        leagueTreasury = leagueTreasury_;
        leagueShareBps = leagueShareBps_;
        delete _domesticCups;

        uint256 length = cups_.length;
        for (uint256 i; i < length; ++i) {
            if (cups_[i] == address(0)) revert ZeroAddress();
            _domesticCups.push(cups_[i]);
        }

        emit DomesticUpdated(leagueTreasury_, cups_, leagueShareBps_);
    }

    function _setContinental(address[] calldata treasuries_, uint16[] calldata weights_) internal {
        uint256 length = treasuries_.length;
        if (length == 0) revert EmptySplit();
        if (length != weights_.length) revert LengthMismatch();

        delete _continentalTreasuries;
        delete _continentalWeights;

        uint256 totalWeight;
        for (uint256 i; i < length; ++i) {
            address treasury = treasuries_[i];
            if (treasury == address(0)) revert ZeroAddress();
            if (weights_[i] == 0) revert InvalidWeightTotal();

            for (uint256 j; j < i; ++j) {
                if (treasuries_[j] == treasury) revert DuplicateTreasury(treasury);
            }

            _continentalTreasuries.push(treasury);
            _continentalWeights.push(weights_[i]);
            totalWeight += weights_[i];
        }

        if (totalWeight == 0) revert InvalidWeightTotal();
        emit ContinentalUpdated(treasuries_, weights_);
    }

    function _setInternationalTreasury(address treasury_) internal {
        if (treasury_ == address(0)) revert ZeroAddress();
        address previous = internationalTreasury;
        internationalTreasury = treasury_;
        emit InternationalTreasuryUpdated(previous, treasury_);
    }

    function _assertUnique(address leagueTreasury_, address[] calldata cups_) internal pure {
        uint256 length = cups_.length;
        for (uint256 i; i < length; ++i) {
            if (cups_[i] == leagueTreasury_) revert DuplicateTreasury(cups_[i]);
            for (uint256 j; j < i; ++j) {
                if (cups_[i] == cups_[j]) revert DuplicateTreasury(cups_[i]);
            }
        }
    }
}
