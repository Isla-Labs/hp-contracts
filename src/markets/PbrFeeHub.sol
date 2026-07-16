// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

/**
 * @title PbrFeeHub
 * @notice Per-domestic-league fee splitter: `FeeRouter` → hub → typed `PbrTreasury` destinations.
 * @dev Top-level default weights (BPS): domestic 90% / continental 9% / international 1%.
 *
 *      Destination kinds: `1 = domestic`, `2 = continental`, `3 = international`.
 *
 *      Zero / unset destinations are skipped. Top-level weights are renormalized across
 *      buckets that have at least one live treasury, so day-one EPL-only (league treasury
 *      set, cups / continental / international zero) routes 100% to the league pot while
 *      keeping the same relative weights once other treasuries are wired.
 *
 *      Domestic sub-split: 89% league, 11% even across non-zero domestic cup treasuries
 *      (if no live cups, 100% → league).
 *      Continental sub-split: relative weights among non-zero continental treasuries.
 *      International: accrues when set; `internationalActive` routes 100% there.
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

    /// @notice Top-level weights; must sum to `BPS_DENOMINATOR` (renormalized at relay time)
    uint16 public domesticBps;
    uint16 public continentalBps;
    uint16 public internationalBps;

    /// @notice Share of the domestic bucket paid to `leagueTreasury` (remainder → live cups evenly)
    uint16 public leagueShareBps;

    address public leagueTreasury;
    address[] private _domesticCups;

    address[] private _continentalTreasuries;
    uint16[] private _continentalWeights;

    address public internationalTreasury;

    /// @notice When true, all incoming fees go to `internationalTreasury` (must be non-zero)
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
    error NoLiveDestination();
    error InvalidBpsTotal(uint256 total);
    error InvalidWeightTotal();
    error DuplicateTreasury(address treasury);
    error InternationalNotConfigured();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param admin_ Admin for split / destination updates.
     * @param leagueId_ Domestic league this hub serves.
     * @param leagueTreasury_ Primary domestic league `PbrTreasury` (required).
     * @param domesticCups_ Domestic cup treasuries; `address(0)` slots are ignored at relay.
     * @param continentalTreasuries_ Continental cup treasuries; zeros / empty = inactive bucket.
     * @param continentalWeights_ Relative weights (aligned with treasuries; zero weight iff zero addr).
     * @param internationalTreasury_ International pot (zero until configured).
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
        if (active && internationalTreasury == address(0)) revert InternationalNotConfigured();
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

        bool liveDomestic = leagueTreasury != address(0);
        bool liveContinental = _hasLiveContinental();
        bool liveInternational = internationalTreasury != address(0);

        uint256 dWeight = liveDomestic ? domesticBps : 0;
        uint256 cWeight = liveContinental ? continentalBps : 0;
        uint256 iWeight = liveInternational ? internationalBps : 0;
        uint256 activeWeight = dWeight + cWeight + iWeight;
        if (activeWeight == 0) revert NoLiveDestination();

        uint256 distributed;
        if (dWeight != 0) {
            uint256 domesticAmt = (amount * dWeight) / activeWeight;
            distributed += domesticAmt;
            _splitDomestic(domesticAmt);
        }
        if (cWeight != 0) {
            uint256 continentalAmt = (amount * cWeight) / activeWeight;
            distributed += continentalAmt;
            _splitContinental(continentalAmt);
        }
        if (iWeight != 0) {
            // Dust remainder from integer division lands on the last live top-level bucket
            _pay(KIND_INTERNATIONAL, internationalTreasury, amount - distributed);
        } else if (distributed < amount) {
            // No international: give dust to continental if live, else domestic
            uint256 dust = amount - distributed;
            if (cWeight != 0) {
                _splitContinental(dust);
            } else {
                _splitDomestic(dust);
            }
        }
    }

    function _splitDomestic(uint256 amount) internal {
        if (amount == 0) return;
        if (leagueTreasury == address(0)) revert NoLiveDestination();

        uint256 liveCups;
        uint256 length = _domesticCups.length;
        for (uint256 i; i < length; ++i) {
            if (_domesticCups[i] != address(0)) ++liveCups;
        }

        if (liveCups == 0) {
            _pay(KIND_DOMESTIC, leagueTreasury, amount);
            return;
        }

        uint256 leagueAmt = (amount * leagueShareBps) / BPS_DENOMINATOR;
        uint256 cupsAmt = amount - leagueAmt;
        _pay(KIND_DOMESTIC, leagueTreasury, leagueAmt);

        uint256 share = cupsAmt / liveCups;
        uint256 distributed;
        uint256 seen;
        for (uint256 i; i < length; ++i) {
            address cup = _domesticCups[i];
            if (cup == address(0)) continue;
            unchecked {
                ++seen;
            }
            uint256 leg = seen == liveCups ? cupsAmt - distributed : share;
            distributed += leg;
            _pay(KIND_DOMESTIC, cup, leg);
        }
    }

    function _splitContinental(uint256 amount) internal {
        if (amount == 0) return;

        uint256 length = _continentalTreasuries.length;
        uint256 totalWeight;
        for (uint256 i; i < length; ++i) {
            if (_continentalTreasuries[i] != address(0)) {
                totalWeight += _continentalWeights[i];
            }
        }
        if (totalWeight == 0) revert NoLiveDestination();

        uint256 distributed;
        uint256 remainingWeight = totalWeight;
        for (uint256 i; i < length; ++i) {
            address treasury = _continentalTreasuries[i];
            uint16 weight = _continentalWeights[i];
            if (treasury == address(0) || weight == 0) continue;

            uint256 leg;
            if (remainingWeight == weight) {
                leg = amount - distributed;
            } else {
                leg = (amount * weight) / totalWeight;
            }
            remainingWeight -= weight;
            distributed += leg;
            _pay(KIND_CONTINENTAL, treasury, leg);
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
            _domesticCups.push(cups_[i]);
        }

        emit DomesticUpdated(leagueTreasury_, cups_, leagueShareBps_);
    }

    function _setContinental(address[] calldata treasuries_, uint16[] calldata weights_) internal {
        uint256 length = treasuries_.length;
        if (length != weights_.length) revert LengthMismatch();

        delete _continentalTreasuries;
        delete _continentalWeights;

        for (uint256 i; i < length; ++i) {
            address treasury = treasuries_[i];
            uint16 weight = weights_[i];

            if (treasury == address(0)) {
                if (weight != 0) revert InvalidWeightTotal();
            } else if (weight == 0) {
                revert InvalidWeightTotal();
            }

            for (uint256 j; j < i; ++j) {
                if (treasury != address(0) && treasuries_[j] == treasury) revert DuplicateTreasury(treasury);
            }

            _continentalTreasuries.push(treasury);
            _continentalWeights.push(weight);
        }

        emit ContinentalUpdated(treasuries_, weights_);
    }

    function _setInternationalTreasury(address treasury_) internal {
        if (treasury_ == address(0) && internationalActive) revert InternationalNotConfigured();
        address previous = internationalTreasury;
        internationalTreasury = treasury_;
        emit InternationalTreasuryUpdated(previous, treasury_);
    }

    function _hasLiveContinental() internal view returns (bool) {
        uint256 length = _continentalTreasuries.length;
        for (uint256 i; i < length; ++i) {
            if (_continentalTreasuries[i] != address(0)) return true;
        }
        return false;
    }

    function _assertUnique(address leagueTreasury_, address[] calldata cups_) internal pure {
        uint256 length = cups_.length;
        for (uint256 i; i < length; ++i) {
            address cup = cups_[i];
            if (cup == address(0)) continue;
            if (cup == leagueTreasury_) revert DuplicateTreasury(cup);
            for (uint256 j; j < i; ++j) {
                if (cup == cups_[j]) revert DuplicateTreasury(cup);
            }
        }
    }
}
