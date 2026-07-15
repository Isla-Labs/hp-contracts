// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @notice Emitted when `pbrTreasury` is updated
event PbrTreasuryUpdated(address indexed market, address indexed previousTreasury, address indexed newTreasury);

/// @notice Emitted when ETH is successfully relayed to the PBRTreasury
event FeesRelayed(address indexed market, address indexed treasury, uint256 amount);

/// @notice Emitted when a relay attempt fails and ETH remains queued on this contract
event FeesQueued(address indexed market, address indexed treasury, uint256 amount);

/// @notice Emitted when ERC20 dust is rescued
event TokenRescued(address indexed token, address indexed to, uint256 amount);

/// @notice Thrown when a required address is zero
error ZeroAddress();

/// @notice Thrown when the treasury address is this contract
error InvalidTreasury();

/// @notice Thrown when the treasury is not a deployed contract
error TreasuryNotContract();

/**
 * @title FeeRouter
 * @notice Relays ETH trading fees to PBRTreasury (yield) and ATFunding (funding rate).
 * @dev LifecycleTimelock is contract owner. PBRTreasury updates are part of the zk flow
 *      for player transfers between domestic leagues.
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Market that this FeeRouter is associated with
    address public immutable playerToken;

    /// @notice Destination for relayed FR fees
    address public immutable atFunding;

    /// @notice Destination for relayed ETH fees
    address public pbrTreasury;

    /**
     * @param initialOwner Contract owner. Should be `LifecycleTimelock` at deployment.
     * @param playerToken_ Player token associated with this FeeRouter.
     * @param atFunding_ Initial ATFunding that receives relayed FR fees.
     * @param pbrTreasury_ Initial PBRTreasury that receives relayed ETH fees.
     */
    constructor(address initialOwner, address playerToken_, address atFunding_, address pbrTreasury_) Ownable(initialOwner) {
        if (playerToken_ == address(0) || atFunding_ == address(0) || pbrTreasury_ == address(0)) revert ZeroAddress();

        playerToken = playerToken_;
        atFunding = atFunding_;
        _setPbrTreasury(pbrTreasury_);
    }

    /// @notice Accepts ETH and best-effort relays the 89:11 split to PBRTreasury and FRTreasury
    /// @dev Never reverts on treasury failure so Rehype buyback transfers cannot be bricked.
    receive() external payable nonReentrant {
        _relay(msg.value);
    }

    /// @dev Best-effort 89:11 split to PBRTreasury and FRTreasury (`atFunding`).
    ///      Remainder from rounding goes to PBR. Failed legs stay queued for `forward()`.
    function _relay(uint256 amount) internal {
        if (amount == 0) return;

        uint256 frAmount = (amount * 11) / 100;
        uint256 pbrAmount = amount - frAmount;

        _send(atFunding, frAmount);
        _send(pbrTreasury, pbrAmount);
    }

    function _send(address treasury, uint256 amount) internal {
        if (amount == 0) return;

        // IMPORTANT: this handles transfers out of supported leagues
        // Effectively, a temporary solution for cross-league transfers.
        // This actually needs to be more dynamic: if the transfer is out of top-5 leagues,
        // fees should be split between all pbrTreasury contracts.
        //
        // However, this does not handle retirements or other OOF discontinuations.
        // Those should not change anything. Any fees from trading the player can still
        // contribute to the original pbrTreasury.
        //
        // CORRECTION:
        // If the transfer is in a waitingRoom (retired, OOF, unsupported league), fees
        // are split evenly between all pbrTreasury contracts that exist.
        // 
        // This is a catch-all solution which works permanently. Because adding a new league
        // updates all playerId entries in AssetRegistry with the corresponding leagueId and
        // its newly-deployed pbrTreasury. So we can recursively set any FeeRouter impls to
        // that new pbrTreasury.
        //
        // This means that we should be able to set an array of pbrTreasury contracts to split
        // fees between, in this contract. Just to handle that waitingRoom edge case.
        if (treasury == address(0)) {
            emit FeesQueued(playerToken, treasury, amount);
            return;
        }

        (bool success,) = treasury.call{ value: amount }("");
        if (success) {
            emit FeesRelayed(playerToken, treasury, amount);
        } else {
            emit FeesQueued(playerToken, treasury, amount);
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
     * @notice Updates the PBRTreasury that receives relayed fees and sweeps any queued ETH.
     * @dev This function is part of the zk flow for player transfers between domestic leagues.
     * @param newTreasury New treasury address. Must be a non-zero contract other than this router.
     */
    function setPbrTreasury(address newTreasury) external onlyOwner nonReentrant {
        _setPbrTreasury(newTreasury);
        _relay(address(this).balance);
    }

    function _setPbrTreasury(address newTreasury) internal {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (newTreasury == address(this)) revert InvalidTreasury();
        if (newTreasury.code.length == 0) revert TreasuryNotContract();

        address previous = pbrTreasury;
        pbrTreasury = newTreasury;
        emit PbrTreasuryUpdated(playerToken, previous, newTreasury);
    }
}
