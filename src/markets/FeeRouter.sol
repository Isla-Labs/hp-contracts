// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";

/**
 * @title FeeRouter
 * @notice Per-market fee relay: ETH → 89% PBR (`PbrFeeHub`) + 11% FR (`atFunding`).
 * @dev Deployed behind `BeaconProxy` instances (one per market). Logic upgrades are atomic via
 *      a shared `UpgradeableBeacon`. Per-market state lives in each proxy; `tournamentRegistry`
 *      is immutable on the implementation and shared by all proxies.
 *
 *      Access (governance categories):
 *      - `CATEGORY_THREE` (`Automator`): `setPbrFeeHub` for league transfers / delisting.
 *      - `CATEGORY_ONE` (`ConstitutionalTimelock`): `setAtFunding`.
 *      - `CATEGORY_TWO` (`MaintenanceTimelock`): `setMinRelay`, `rescueToken`.
 *
 *      Fee split:
 *      - If `atFunding == address(0)`, 100% of fees take the PBR route.
 *      - Otherwise 89:11 PBR:FR (remainder from rounding goes to PBR).
 *
 *      Relay threshold:
 *      - On `receive`, ETH accrues until `balance >= minRelay` (default at init: 0.0001 ether),
 *        then the full balance is relayed. Maintenance may update via `setMinRelay`.
 *      - `forward` and destination updates always attempt a full-balance relay (bypass gate).
 *
 *      PBR routing:
 *      - `pbrFeeHub != 0`: all PBR to that league hub.
 *      - `pbrFeeHub == 0` (unsupported / no league): split evenly across all registered
 *        domestic hubs from `TournamentRegistry.getAllDomesticPbrFeeHubs()`.
 *
 *      Cup / continental / international splits live on each `PbrFeeHub`, not here.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouter is Initializable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Registry used to enumerate domestic PBR fee hubs when unsupported
    ITournamentRegistry public immutable tournamentRegistry;

    /// @notice Player identity associated with this FeeRouter proxy
    bytes32 public playerId;

    /// @notice Destination for relayed FR fees; zero routes 100% via PBR
    address public atFunding;

    /// @notice League `PbrFeeHub` for PBR fees; zero = unsupported (even-split across all hubs)
    address public pbrFeeHub;

    /// @notice Minimum ETH balance before auto-relay on `receive` (default 0.0001 ether at init)
    uint256 public minRelay;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address tournamentRegistry_) {
        if (tournamentRegistry_ == address(0)) revert Errors.ZeroAddress();
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        _disableInitializers();
    }

    /**
     * @notice Initializes per-market proxy storage. Called once via BeaconProxy constructor data.
     * @param automator_ `Automator` — `CATEGORY_THREE`.
     * @param maintenanceTimelock_ `MaintenanceTimelock` — `CATEGORY_TWO`.
     * @param constitutionalTimelock_ `ConstitutionalTimelock` — `CATEGORY_ONE`.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param playerId_ Player identity associated with this FeeRouter.
     * @param atFunding_ Optional ATFunding for the 11% FR share (zero = all fees via PBR).
     * @param pbrFeeHub_ Initial league `PbrFeeHub` (zero = unsupported / OOF even-split).
     */
    function initialize(
        address automator_,
        address maintenanceTimelock_,
        address constitutionalTimelock_,
        address dao_,
        bytes32 playerId_,
        address atFunding_,
        address pbrFeeHub_
    ) external initializer {
        if (playerId_ == bytes32(0)) revert Errors.ZeroId();
        if (
            automator_ == address(0) || maintenanceTimelock_ == address(0) || constitutionalTimelock_ == address(0)
                || dao_ == address(0)
        ) revert Errors.ZeroAddress();

        playerId = playerId_;
        minRelay = 0.0001 ether;

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
        _grantRole(Roles.CATEGORY_TWO, maintenanceTimelock_);
        _grantRole(Roles.CATEGORY_ONE, constitutionalTimelock_);

        if (atFunding_ != address(0)) {
            _setAtFunding(atFunding_);
        }
        _setPbrFeeHub(pbrFeeHub_);
    }

    /// @notice Accepts ETH and best-effort relays fees to PBR and (optionally) FR destinations
    /// @dev Never reverts on destination failure so Rehype buyback transfers cannot be bricked.
    ///      Accrues until `balance >= minRelay`, then relays the full balance.
    receive() external payable nonReentrant {
        _tryRelay();
    }

    /// @dev Auto-path gate for `receive`: only relay once balance meets `minRelay`.
    ///      Uses full contract balance so previously accrued dust is included.
    function _tryRelay() internal {
        uint256 bal = address(this).balance;
        if (bal == 0 || bal < minRelay) return;
        _relay(bal);
    }

    /// @dev If `atFunding` is unset, 100% takes the PBR route. Otherwise 89:11 PBR:FR.
    ///      Remainder from rounding goes to PBR. Failed legs stay queued on this contract.
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

        // Unsupported / no league: split evenly across all domestic fee hubs
        if (pbrFeeHub == address(0)) {
            address[] memory hubs = tournamentRegistry.getAllDomesticPbrFeeHubs();
            uint256 count = hubs.length;
            if (count == 0) {
                emit Events.FeesQueued(playerId, address(0), amount);
                return;
            }

            uint256 share = amount / count;
            uint256 distributed;
            for (uint256 i; i < count; ++i) {
                uint256 leg = share;
                // Dust remainder from integer division goes to the last hub
                if (i == count - 1) leg = amount - distributed;
                distributed += leg;
                _send(hubs[i], leg);
            }
            return;
        }

        _send(pbrFeeHub, amount);
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;

        if (to == address(0)) {
            emit Events.FeesQueued(playerId, to, amount);
            return;
        }

        (bool success,) = to.call{ value: amount }("");
        if (success) {
            emit Events.FeesRelayed(playerId, to, amount);
        } else {
            emit Events.FeesQueued(playerId, to, amount);
        }
    }

    /**
     * @notice Relays the full ETH balance held by this contract (bypasses `minRelay`).
     * @dev Permissionless sweeper for accrued dust below threshold, failed relays, or hub updates.
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
    function rescueToken(address token, address to, uint256 amount) external onlyRole(Roles.CATEGORY_TWO) {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Events.TokenRescued(token, to, amount);
    }

    /**
     * @notice Updates the minimum ETH balance required before auto-relay on `receive`.
     * @dev Lowering the threshold immediately attempts a gated relay if the balance qualifies.
     */
    function setMinRelay(uint256 minRelay_) external onlyRole(Roles.CATEGORY_TWO) nonReentrant {
        uint256 previous = minRelay;
        minRelay = minRelay_;
        emit Events.MinRelayUpdated(playerId, previous, minRelay_);
        _tryRelay();
    }

    /**
     * @notice Updates the league `PbrFeeHub` and sweeps any queued ETH.
     * @dev Automator (`CATEGORY_THREE`). Pass zero when the market is unsupported / has no league.
     */
    function setPbrFeeHub(address newHub) external onlyRole(Roles.CATEGORY_THREE) nonReentrant {
        _setPbrFeeHub(newHub);
    }

    /**
     * @notice Sets or clears the ATFunding destination for the 11% FR share.
     * @dev ConstitutionalTimelock (`CATEGORY_ONE`). Pass zero to disable FR (100% PBR).
     */
    function setAtFunding(address newFunding) external onlyRole(Roles.CATEGORY_ONE) nonReentrant {
        address previous = atFunding;
        if (newFunding == address(0)) {
            atFunding = address(0);
            emit Events.AtFundingUpdated(playerId, previous, address(0));
        } else {
            _setAtFunding(newFunding);
        }
        _relay(address(this).balance);
    }

    function _setPbrFeeHub(address newHub) internal {
        if (newHub != address(0)) {
            if (newHub == address(this)) revert Errors.InvalidDestination();
            if (newHub.code.length == 0) revert Errors.DestinationNotContract();
        }

        address previous = pbrFeeHub;
        pbrFeeHub = newHub;
        emit Events.PbrFeeHubUpdated(playerId, previous, newHub);
    }

    function _setAtFunding(address newFunding) internal {
        if (newFunding == address(this)) revert Errors.InvalidDestination();
        if (newFunding.code.length == 0) revert Errors.DestinationNotContract();

        address previous = atFunding;
        atFunding = newFunding;
        emit Events.AtFundingUpdated(playerId, previous, newFunding);
    }
}
