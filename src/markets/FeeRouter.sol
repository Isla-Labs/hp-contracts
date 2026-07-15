// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
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
 * @dev LifecycleTimelock is contract owner. Domestic treasury updates are part of the zk flow
 *      for player transfers between domestic leagues.
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
contract FeeRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Player identity associated with this FeeRouter
    bytes32 public immutable playerId;

    /// @notice Destination for relayed FR fees
    address public immutable atFunding;

    /// @notice Registry used to enumerate domestic PBR treasuries when inactive
    TournamentRegistry public immutable tournamentRegistry;

    /// @notice Destination for relayed domestic PBR fees
    address public domesticPbrTreasury;

    /// @notice Destination for relayed international PBR fees (optional)
    address public internationalPbrTreasury;

    /// @notice When true and `internationalPbrTreasury` is set, PBR fees route there
    bool public isInternational;

    /// @notice When false, PBR fees are split evenly across all domestic league treasuries
    bool public isActive;

    /**
     * @param initialOwner Contract owner. Should be `LifecycleTimelock` at deployment.
     * @param playerId_ Player identity associated with this FeeRouter.
     * @param atFunding_ ATFunding that receives relayed FR fees.
     * @param tournamentRegistry_ TournamentRegistry for inactive OOF splits.
     * @param domesticPbrTreasury_ Initial domestic PBRTreasury.
     * @param internationalPbrTreasury_ Optional international PBRTreasury (may be zero).
     * @param isInternational_ Whether this market currently routes to international treasury.
     * @param isActive_ Whether the player is active (false = OOF / retirement waiting room).
     */
    constructor(
        address initialOwner,
        bytes32 playerId_,
        address atFunding_,
        address tournamentRegistry_,
        address domesticPbrTreasury_,
        address internationalPbrTreasury_,
        bool isInternational_,
        bool isActive_
    ) Ownable(initialOwner) {
        if (playerId_ == bytes32(0)) revert ZeroId();
        if (atFunding_ == address(0) || tournamentRegistry_ == address(0)) revert ZeroAddress();

        playerId = playerId_;
        atFunding = atFunding_;
        tournamentRegistry = TournamentRegistry(tournamentRegistry_);
        isInternational = isInternational_;
        isActive = isActive_;

        _setDomesticPbrTreasury(domesticPbrTreasury_);
        if (internationalPbrTreasury_ != address(0)) {
            _setInternationalPbrTreasury(internationalPbrTreasury_);
        }
    }

    /// @notice Accepts ETH and best-effort relays the 89:11 split to PBR and FR destinations
    /// @dev Never reverts on treasury failure so Rehype buyback transfers cannot be bricked.
    receive() external payable nonReentrant {
        _relay(msg.value);
    }

    /// @dev Best-effort 89:11 split. Remainder from rounding goes to PBR. Failed legs stay queued.
    function _relay(uint256 amount) internal {
        if (amount == 0) return;

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
     * @notice Relays any ETH balance held by this contract using the 89:11 split.
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
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    /**
     * @notice Updates the domestic PBRTreasury and sweeps any queued ETH.
     * @dev Part of the zk flow for player transfers between domestic leagues.
     */
    function setDomesticPbrTreasury(address newTreasury) external onlyOwner nonReentrant {
        _setDomesticPbrTreasury(newTreasury);
        _relay(address(this).balance);
    }

    /**
     * @notice Updates the international PBRTreasury (pass zero to clear).
     */
    function setInternationalPbrTreasury(address newTreasury) external onlyOwner nonReentrant {
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
    function setIsInternational(bool isInternational_) external onlyOwner nonReentrant {
        isInternational = isInternational_;
        emit IsInternationalUpdated(playerId, isInternational_);
        _relay(address(this).balance);
    }

    /**
     * @notice Toggles active status. When false, PBR fees split across all domestic treasuries.
     */
    function setIsActive(bool isActive_) external onlyOwner nonReentrant {
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

    function _setInternationalPbrTreasury(address newTreasury) internal {
        if (newTreasury == address(this)) revert InvalidTreasury();
        if (newTreasury.code.length == 0) revert TreasuryNotContract();

        address previous = internationalPbrTreasury;
        internationalPbrTreasury = newTreasury;
        emit InternationalPbrTreasuryUpdated(playerId, previous, newTreasury);
    }
}
