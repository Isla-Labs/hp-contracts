// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { ITournamentRegistry } from "@interfaces/registries/ITournamentRegistry.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

/**
 * @title FeeRouter
 * @notice Per-market fee relay: ETH → integrator (`HP_TREASURY`) + league `PbrFeeHub`.
 * @dev Deployed behind `BeaconProxy` instances (one per market). Logic upgrades are atomic via
 *      a shared `UpgradeableBeacon`. Per-market state lives in each proxy.
 *      `TournamentRegistry` is resolved from `AddressProvider` only on inactive / OOF /
 *      hub-registration paths (not cached in storage).
 *
 *      Trading-fee pipe (Rehype buyback → this contract):
 *        Rehype takes 5% of the swap fee for the Airlock owner before transfer.
 *        Of ETH received here (the remaining 95% of gross trading fees):
 *          - `BONDING`: 10/95 → integrator (`HP_TREASURY`) → gross 5:10:85
 *          - `GRADUATED`: 5/95 → integrator → gross 5:5:90
 *          - `INACTIVE`: no integrator cut; 100% of FeeRouter balance even-splits across
 *            domestic hubs (`TournamentRegistry.getAllDomesticPbrFeeHubs()` at relay time)
 *
 *      Post-integrator remainder (active statuses):
 *        - `pbrFeeHub != 0`: 100% → that league hub (must be a registered domestic hub).
 *        - `pbrFeeHub == 0`: even-split across domestic hubs (unsupported / OOF).
 *        - League hub is updated on transfer via `PlayerSetRegistry` → `setPbrFeeHub`.
 *
 *      Access: `PlayerSetRegistry` for `setStatus` / `setPbrFeeHub`; `Timelock` for
 *      `setIntegrator`. No owner.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouter is Initializable, AddressBook, ReentrancyGuard {
    // --------------------------------------------
    //  Internal Constants
    // --------------------------------------------

    /// @dev Denominator for post-Rehype split (95% of gross trading fee lands here).
    uint256 internal constant FEE_SPLIT_DENOM = 95;

    /// @dev Bonding integrator numerator → gross 5:10:85 (Doppler : HP : redistrib).
    uint256 internal constant BONDING_INTEGRATOR_SHARE_NUM = 10;

    /// @dev Graduated integrator numerator → gross 5:5:90 (Doppler : HP : redistrib).
    uint256 internal constant SPOT_INTEGRATOR_SHARE_NUM = 5;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    /// @notice Player identity associated with this FeeRouter proxy
    bytes32 public playerId;

    /// @notice League `PbrFeeHub`; zero = unsupported OOF even-split for the remainder
    address public pbrFeeHub;

    /// @notice Integrator (`HP_TREASURY`) — bonding 10% / spot 5% of gross trading fees
    address public integrator;

    /// @notice Local cache of `PlayerSetRegistry` status (drives integrator share + OOF).
    PlayerStatus public status;

    /// @notice Minimum ETH balance before auto-relay on `receive` (default 0.0001 ether at init)
    uint256 public minRelay;

    // --------------------------------------------
    //  Access control
    // --------------------------------------------

    modifier onlyTimelock() {
        if (msg.sender != _getAddress(_addressKey(Addresses.TIMELOCK))) revert Errors.Unauthorized();
        _;
    }

    modifier onlyPlayerSetRegistry() {
        if (msg.sender != _getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY))) revert Errors.Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        _disableInitializers();
    }

    /**
     * @notice Initializes per-market proxy storage. Called once via BeaconProxy constructor data.
     * @param playerId_ Player identity associated with this FeeRouter.
     * @param pbrFeeHub_ League `PbrFeeHub` (zero = unsupported even-split).
     */
    function initialize(bytes32 playerId_, address pbrFeeHub_) external initializer {
        if (playerId_ == bytes32(0)) revert Errors.ZeroId();

        address integrator_ = _getAddress(_addressKey(Addresses.HP_TREASURY));
        if (integrator_ == address(0)) revert Errors.ZeroAddress();

        playerId = playerId_;
        minRelay = 0.0001 ether;
        integrator = integrator_;
        status = PlayerStatus.BONDING;

        _setPbrFeeHub(pbrFeeHub_);
    }

    // --------------------------------------------
    //  Registry
    // --------------------------------------------

    /**
     * @notice Syncs local `PlayerStatus` cache (bonding vs spot integrator share; inactive → OOF).
     * @dev Sweeps queued ETH after the update.
     */
    function setStatus(PlayerStatus status_) external onlyPlayerSetRegistry nonReentrant {
        PlayerStatus previous = status;
        if (previous == status_) return;

        status = status_;
        emit Events.StatusUpdated(playerId, previous, status_);
        _relay(address(this).balance);
    }

    /**
     * @notice Updates league `PbrFeeHub` (transfer / league change).
     * @dev Pass zero when the market is unsupported / has no league. Non-zero hubs must be
     *      registered on `TournamentRegistry`. Sweeps queued ETH.
     */
    function setPbrFeeHub(address newHub) external onlyPlayerSetRegistry nonReentrant {
        _setPbrFeeHub(newHub);
        _relay(address(this).balance);
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /**
     * @notice Updates integrator (`HP_TREASURY` role) and sweeps queued ETH.
     */
    function setIntegrator(address newIntegrator) external onlyTimelock nonReentrant {
        if (newIntegrator == address(0)) revert Errors.ZeroAddress();
        if (newIntegrator == address(this)) revert Errors.InvalidDestination();

        address previous = integrator;
        integrator = newIntegrator;
        emit Events.IntegratorUpdated(playerId, previous, newIntegrator);
        _relay(address(this).balance);
    }

    // --------------------------------------------
    //  Ingest
    // --------------------------------------------

    /// @notice Accepts ETH and best-effort relays fees to integrator + PBR hub(s).
    /// @dev Never reverts on destination failure so Rehype buyback transfers cannot be bricked.
    ///      Accrues until `balance >= minRelay`, then the full balance is relayed.
    receive() external payable nonReentrant {
        _tryRelay();
    }

    /// @notice Manual call to relay the full ETH balance (bypasses `minRelay`).
    function forward() external nonReentrant {
        _relay(address(this).balance);
    }

    // --------------------------------------------
    //  Relay
    // --------------------------------------------

    /// @dev Auto-path gate for `receive`: only relay once balance meets `minRelay`.
    function _tryRelay() internal {
        uint256 bal = address(this).balance;
        if (bal == 0 || bal < minRelay) return;
        _relay(bal);
    }

    /// @dev Integrator cut from `status` (skipped when inactive), then league hub or OOF.
    function _relay(uint256 amount) internal {
        if (amount == 0) return;

        // Inactive: no HP treasury cut — full balance even-splits across domestic hubs.
        if (status == PlayerStatus.INACTIVE) {
            _relayOof(amount);
            return;
        }

        uint256 integratorAmount = (amount * _integratorShareNum()) / FEE_SPLIT_DENOM;
        uint256 remainder = amount - integratorAmount;

        if (integratorAmount != 0) {
            _send(integrator, integratorAmount);
        }

        if (remainder == 0) return;

        // Unsupported: fetch domestic hubs at relay time and even-split.
        if (pbrFeeHub == address(0)) {
            _relayOof(remainder);
            return;
        }

        _send(pbrFeeHub, remainder);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    /// @dev Even-split remainder across all domestic `PbrFeeHub`s.
    function _relayOof(uint256 remainder) internal {
        address[] memory hubs = _tournamentRegistry().getAllDomesticPbrFeeHubs();
        uint256 count = hubs.length;
        if (count == 0) {
            emit Events.FeesQueued(playerId, address(0), remainder);
            return;
        }

        uint256 share = remainder / count;
        uint256 oofDistributed;
        for (uint256 i; i < count; ++i) {
            uint256 leg = share;
            if (i == count - 1) leg = remainder - oofDistributed;
            oofDistributed += leg;
            _send(hubs[i], leg);
        }
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

    function _setPbrFeeHub(address newHub) internal {
        if (newHub != address(0)) {
            if (newHub == address(this)) revert Errors.InvalidDestination();
            if (newHub.code.length == 0) revert Errors.DestinationNotContract();
            if (!_isRegisteredDomesticHub(newHub)) revert Errors.PbrFeeHubNotRegistered(newHub);
        }

        address previous = pbrFeeHub;
        pbrFeeHub = newHub;
        emit Events.PbrFeeHubUpdated(playerId, previous, newHub);
    }

    function _isRegisteredDomesticHub(address hub) internal view returns (bool) {
        address[] memory hubs = _tournamentRegistry().getAllDomesticPbrFeeHubs();
        uint256 length = hubs.length;
        for (uint256 i; i < length; ++i) {
            if (hubs[i] == hub) return true;
        }
        return false;
    }

    function _tournamentRegistry() internal view returns (ITournamentRegistry) {
        return ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    /// @notice Integrator numerator over `FEE_SPLIT_DENOM` (10 bonding / 5 graduated / 0 inactive).
    function integratorShareNum() external view returns (uint256) {
        return _integratorShareNum();
    }

    function _integratorShareNum() internal view returns (uint256) {
        if (status == PlayerStatus.INACTIVE) return 0;
        return status == PlayerStatus.BONDING ? BONDING_INTEGRATOR_SHARE_NUM : SPOT_INTEGRATOR_SHARE_NUM;
    }
}
