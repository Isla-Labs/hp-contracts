// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { TournamentRegistry } from "../TournamentRegistry.sol";

/// @notice Emitted when `domesticPbrTreasury` is updated
event DomesticPbrTreasuryUpdated(
    bytes32 indexed playerId, address indexed previousTreasury, address indexed newTreasury
);

/// @notice Emitted when `internationalPbrTreasury` is updated
event InternationalPbrTreasuryUpdated(
    bytes32 indexed playerId, address indexed previousTreasury, address indexed newTreasury
);

/// @notice Emitted when `isInternational` is updated
event IsInternationalUpdated(bytes32 indexed playerId, bool isInternational);

/// @notice Emitted when `isActive` is updated
event IsActiveUpdated(bytes32 indexed playerId, bool isActive);

/// @notice Emitted when ETH is successfully relayed to a treasury
event FeesRelayed(bytes32 indexed playerId, address indexed treasury, uint256 amount);

/// @notice Emitted when a relay attempt fails and ETH remains queued on this contract
event FeesQueued(bytes32 indexed playerId, address indexed treasury, uint256 amount);

/// @notice Emitted when `atFunding` is updated
event AtFundingUpdated(bytes32 indexed playerId, address indexed previousFunding, address indexed newFunding);

/// @notice Emitted when ERC20 dust is rescued
event TokenRescued(address indexed token, address indexed to, uint256 amount);

/// @notice Thrown when a required address is zero
error ZeroAddress();

/// @notice Thrown when a required id is zero
error ZeroId();

/// @notice Thrown when the treasury address is this contract
error InvalidTreasury();

/// @notice Thrown when the treasury is not a deployed contract
error TreasuryNotContract();

/**
 * @title FeeRouter
 * @notice Relays ETH trading fees to PBRTreasury (yield) and ATFunding (funding rate).
 * @dev Deployed behind `BeaconProxy` instances (one per market). Logic upgrades are atomic via
 *      a shared `UpgradeableBeacon`. Per-market state lives in each proxy; `tournamentRegistry`
 *      is immutable on the implementation and shared by all proxies.
 *
 *      Access:
 *      - `LIFECYCLE_ROLE` (LifecycleTimelock): `setDomesticPbrTreasury` for transfer zk flow.
 *      - `ADMIN_ROLE` (multisig): international treasury, ATFunding, flags, and token rescue.
 *
 *      Fee split:
 *      - If `atFunding == address(0)`, 100% of fees take the PBR route.
 *      - Otherwise 89:11 PBR:FR (remainder from rounding goes to PBR).
 *
 *      PBR routing:
 *      - `isActive == false` (OOF / retirement / waiting room): split evenly across all domestic
 *        league treasuries from TournamentRegistry.
 *      - `isInternational == true` and `internationalPbrTreasury != 0`: all PBR to international.
 *      - otherwise: all PBR to `domesticPbrTreasury`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouter is Initializable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice LifecycleTimelock role for domestic treasury updates during transfers
    bytes32 public constant LIFECYCLE_ROLE = keccak256("LIFECYCLE_ROLE");

    /// @notice Multisig role for international treasury, ATFunding, flags, and rescue
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Registry used to enumerate domestic PBR treasuries when inactive (shared by all proxies)
    TournamentRegistry public immutable tournamentRegistry;

    /// @notice Player identity associated with this FeeRouter proxy
    bytes32 public playerId;

    /// @notice Destination for relayed FR fees; zero routes 100% via PBR
    address public atFunding;

    /// @notice Destination for relayed domestic PBR fees
    address public domesticPbrTreasury;

    /// @notice Destination for relayed international PBR fees (optional)
    address public internationalPbrTreasury;

    /// @notice When true and `internationalPbrTreasury` is set, PBR fees route there
    bool public isInternational;

    /// @notice When false, PBR fees are split evenly across all domestic league treasuries
    bool public isActive;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address tournamentRegistry_) {
        if (tournamentRegistry_ == address(0)) revert ZeroAddress();
        tournamentRegistry = TournamentRegistry(tournamentRegistry_);
        _disableInitializers();
    }

    /**
     * @notice Initializes per-market proxy storage. Called once via BeaconProxy constructor data.
     * @param lifecycleTimelock_ Address granted `LIFECYCLE_ROLE`.
     * @param multisig_ Address granted `ADMIN_ROLE`.
     * @param playerId_ Player identity associated with this FeeRouter.
     * @param atFunding_ Optional ATFunding for the 11% FR share (zero = all fees via PBR).
     * @param domesticPbrTreasury_ Initial domestic PBRTreasury.
     * @param internationalPbrTreasury_ Optional international PBRTreasury (may be zero).
     * @param isInternational_ Whether this market currently routes to international treasury.
     * @param isActive_ Whether the player is active (false = OOF / retirement waiting room).
     */
    function initialize(
        address lifecycleTimelock_,
        address multisig_,
        bytes32 playerId_,
        address atFunding_,
        address domesticPbrTreasury_,
        address internationalPbrTreasury_,
        bool isInternational_,
        bool isActive_
    ) external initializer {
        if (playerId_ == bytes32(0)) revert ZeroId();
        if (lifecycleTimelock_ == address(0) || multisig_ == address(0)) revert ZeroAddress();

        playerId = playerId_;
        isInternational = isInternational_;
        isActive = isActive_;

        _grantRole(ADMIN_ROLE, multisig_);
        _grantRole(LIFECYCLE_ROLE, lifecycleTimelock_);

        if (atFunding_ != address(0)) {
            _setAtFunding(atFunding_);
        }
        _setDomesticPbrTreasury(domesticPbrTreasury_);
        if (internationalPbrTreasury_ != address(0)) {
            _setInternationalPbrTreasury(internationalPbrTreasury_);
        }
    }

    /// @notice Accepts ETH and best-effort relays fees to PBR and (optionally) FR destinations
    /// @dev Never reverts on treasury failure so Rehype buyback transfers cannot be bricked.
    receive() external payable nonReentrant {
        _relay(msg.value);
    }

    /// @dev If `atFunding` is unset, 100% takes the PBR route. Otherwise 89:11 PBR:FR.
    ///      Remainder from rounding goes to PBR. Failed legs stay queued.
    function _relay(uint256 amount) internal {
        if (amount == 0) return;

        if (atFunding == address(0)) {
            _relayPbr(amount);
            return;
        }

        uint256 frAmount = (amount * 11) / 100;
        uint256 pbrAmount = amount - frAmount;

        _send(atFunding, frAmount);
        _relayPbr(pbrAmount);
    }

    function _relayPbr(uint256 amount) internal {
        if (amount == 0) return;

        // OOF / retirement / unsupported league: split evenly across all domestic treasuries
        if (!isActive) {
            address[] memory treasuries = tournamentRegistry.getAllDomesticPbrTreasuries();
            uint256 count = treasuries.length;
            if (count == 0) {
                emit FeesQueued(playerId, address(0), amount);
                return;
            }

            uint256 share = amount / count;
            uint256 distributed;
            for (uint256 i; i < count; ++i) {
                uint256 leg = share;
                // Dust remainder from integer division goes to the last treasury
                if (i == count - 1) leg = amount - distributed;
                distributed += leg;
                _send(treasuries[i], leg);
            }
            return;
        }

        // International window: route all PBR to the international treasury when configured
        if (isInternational && internationalPbrTreasury != address(0)) {
            _send(internationalPbrTreasury, amount);
            return;
        }

        _send(domesticPbrTreasury, amount);
    }

    function _send(address treasury, uint256 amount) internal {
        if (amount == 0) return;

        if (treasury == address(0)) {
            emit FeesQueued(playerId, treasury, amount);
            return;
        }

        (bool success,) = treasury.call{ value: amount }("");
        if (success) {
            emit FeesRelayed(playerId, treasury, amount);
        } else {
            emit FeesQueued(playerId, treasury, amount);
        }
    }

    /**
     * @notice Relays any ETH balance held by this contract.
     * @dev Permissionless sweeper for queued balances after a failed relay or treasury update.
     */
    function forward() external nonReentrant {
        _relay(address(this).balance);
    }

    /**
     * @notice Recovers accidental ERC20 balances (e.g. player-token dust).
     * @param token ERC20 to rescue.
     * @param to Recipient of the rescued tokens.
     * @param amount Amount to transfer.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /**
     * @notice Updates the domestic PBRTreasury and sweeps any queued ETH.
     * @dev LifecycleTimelock-only. Part of the zk flow for player transfers between domestic leagues.
     */
    function setDomesticPbrTreasury(address newTreasury) external onlyRole(LIFECYCLE_ROLE) nonReentrant {
        _setDomesticPbrTreasury(newTreasury);
        _relay(address(this).balance);
    }

    /**
     * @notice Sets or clears the ATFunding destination for the 11% FR share.
     * @dev Pass zero to disable FR routing (100% PBR). Used when Advanced Trade funding goes live.
     */
    function setAtFunding(address newFunding) external onlyRole(ADMIN_ROLE) nonReentrant {
        address previous = atFunding;
        if (newFunding == address(0)) {
            atFunding = address(0);
            emit AtFundingUpdated(playerId, previous, address(0));
        } else {
            _setAtFunding(newFunding);
        }
        _relay(address(this).balance);
    }

    /**
     * @notice Updates the international PBRTreasury (pass zero to clear).
     */
    function setInternationalPbrTreasury(address newTreasury) external onlyRole(ADMIN_ROLE) nonReentrant {
        address previous = internationalPbrTreasury;
        if (newTreasury == address(0)) {
            internationalPbrTreasury = address(0);
            emit InternationalPbrTreasuryUpdated(playerId, previous, address(0));
        } else {
            _setInternationalPbrTreasury(newTreasury);
        }
        _relay(address(this).balance);
    }

    /**
     * @notice Toggles international PBR routing and sweeps any queued ETH.
     */
    function setIsInternational(bool isInternational_) external onlyRole(ADMIN_ROLE) nonReentrant {
        isInternational = isInternational_;
        emit IsInternationalUpdated(playerId, isInternational_);
        _relay(address(this).balance);
    }

    /**
     * @notice Toggles active status. When false, PBR fees split across all domestic treasuries.
     */
    function setIsActive(bool isActive_) external onlyRole(ADMIN_ROLE) nonReentrant {
        isActive = isActive_;
        emit IsActiveUpdated(playerId, isActive_);
        _relay(address(this).balance);
    }

    function _setDomesticPbrTreasury(address newTreasury) internal {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (newTreasury == address(this)) revert InvalidTreasury();
        if (newTreasury.code.length == 0) revert TreasuryNotContract();

        address previous = domesticPbrTreasury;
        domesticPbrTreasury = newTreasury;
        emit DomesticPbrTreasuryUpdated(playerId, previous, newTreasury);
    }

    function _setAtFunding(address newFunding) internal {
        if (newFunding == address(this)) revert InvalidTreasury();
        if (newFunding.code.length == 0) revert TreasuryNotContract();

        address previous = atFunding;
        atFunding = newFunding;
        emit AtFundingUpdated(playerId, previous, newFunding);
    }

    function _setInternationalPbrTreasury(address newTreasury) internal {
        if (newTreasury == address(this)) revert InvalidTreasury();
        if (newTreasury.code.length == 0) revert TreasuryNotContract();

        address previous = internationalPbrTreasury;
        internationalPbrTreasury = newTreasury;
        emit InternationalPbrTreasuryUpdated(playerId, previous, newTreasury);
    }
}
