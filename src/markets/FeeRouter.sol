// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { MarketsErrors as Errors } from "@errors/markets/MarketsErrors.sol";
import { MarketsEvents as Events } from "@events/markets/MarketsEvents.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { PlayerStatus } from "@types/registries/PlayerSetTypes.sol";

/**
 * @title FeeRouter
 * @notice Per-market fee relay: ETH → integrator + redistribution hubs.
 * @dev Deployed behind `BeaconProxy` instances (one per market). Logic upgrades are atomic via
 *      a shared `UpgradeableBeacon`. Per-market state lives in each proxy; `tournamentRegistry`
 *      is immutable on the implementation and shared by all proxies.
 *
 *      Trading-fee pipe (Rehype buyback → this contract):
 *        Rehype takes 5% of the swap fee for the Airlock owner before transfer.
 *        Of ETH received here (the remaining 95% of gross trading fees), integrator share
 *        follows the local `status` cache (synced from `PlayerSetRegistry.setStatus`):
 *          - `BONDING`: 10/95 → integrator (= 10% of gross) → gross 5:10:85
 *          - `GRADUATED` / `INACTIVE`: 5/95 → integrator (= 5% of gross) → gross 5:5:90
 *
 *      Redistribution:
 *        - `redistributionHubs[i]` receives `feeSplit[i] / WAD` of the post-integrator remainder.
 *        - When `pbrFeeHub != 0`, it MUST appear in `redistributionHubs` (enforced on write).
 *        - Default at init / `setPbrFeeHub`: `{ pbrFeeHub }` / `{ WAD }`.
 *        - When `pbrFeeHub == 0` (unsupported / OOF): hubs cleared; remainder even-splits across
 *          domestic hubs from `TournamentRegistry.getAllDomesticPbrFeeHubs()`.
 *
 *      Access: `Orchestrator` (owner) for config + `rescueToken`; `setStatus` and
 *      `setPbrFeeHub` also callable by `PlayerSetRegistry` (lifecycle SoT).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract FeeRouter is Initializable, AddressBook, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------
    //  Internal Constants
    // --------------------------------------------

    /// @dev 100% in WAD for `feeSplit` rows.
    uint256 internal constant WAD = 1e18;

    /// @dev Denominator for post-Rehype split (95% of gross trading fee lands here).
    uint256 internal constant FEE_SPLIT_DENOM = 95;

    /// @dev Bonding integrator numerator → gross 5:10:85 (Doppler : HP : redistrib).
    uint256 internal constant BONDING_INTEGRATOR_SHARE_NUM = 10;

    /// @dev Graduated / inactive integrator numerator → gross 5:5:90 (Doppler : HP : redistrib).
    uint256 internal constant SPOT_INTEGRATOR_SHARE_NUM = 5;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    /// @notice Registry used to enumerate domestic PBR fee hubs when unsupported
    ITournamentRegistry public tournamentRegistry;

    /// @notice Player identity associated with this FeeRouter proxy
    bytes32 public playerId;

    /// @notice League `PbrFeeHub`; zero = unsupported / OOF even-split for the remainder
    address public pbrFeeHub;

    /// @notice Integrator (`HP_TREASURY`) — bonding 10% / spot 5% of gross trading fees
    address public integrator;

    /// @notice Local cache of `PlayerSetRegistry` status (drives integrator share).
    PlayerStatus public status;

    /// @notice Minimum ETH balance before auto-relay on `receive` (default 0.0001 ether at init)
    uint256 public minRelay;

    /// @dev Post-integrator destinations (must include `pbrFeeHub` when it is set).
    address[] private _redistributionHubs;

    /// @dev WAD shares aligned with `_redistributionHubs` (sum must equal `WAD`).
    uint256[] private _feeSplit;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Initializes per-market proxy storage. Called once via BeaconProxy constructor data.
     * @param playerId_ Player identity associated with this FeeRouter.
     * @param pbrFeeHub_ League `PbrFeeHub` (zero = unsupported even-split).
     */
    function initialize(bytes32 playerId_, address pbrFeeHub_) external initializer {
        if (playerId_ == bytes32(0)) revert Errors.ZeroId();

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));

        address tournamentRegistry_ = _getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY));
        address integrator_ = _getAddress(_addressKey(Addresses.HP_TREASURY));
        if (integrator_ == address(0)) revert Errors.ZeroAddress();

        playerId = playerId_;
        minRelay = 0.0001 ether;
        integrator = integrator_;
        status = PlayerStatus.BONDING;

        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);

        _setPbrFeeHub(pbrFeeHub_);
    }

    // --------------------------------------------
    //  Receive / relay
    // --------------------------------------------

    /// @notice Accepts ETH and best-effort relays fees to integrator + redistribution hubs.
    /// @dev Never reverts on destination failure so Rehype buyback transfers cannot be bricked.
    ///      Accrues until `balance >= minRelay`, then the full balance is relayed.
    receive() external payable nonReentrant {
        _tryRelay();
    }

    /// @dev Auto-path gate for `receive`: only relay once balance meets `minRelay`.
    function _tryRelay() internal {
        uint256 bal = address(this).balance;
        if (bal == 0 || bal < minRelay) return;
        _relay(bal);
    }

    /// @dev Integrator cut from `status`, then remainder by `feeSplit` / OOF even-split.
    function _relay(uint256 amount) internal {
        if (amount == 0) return;

        uint256 integratorAmount = (amount * _integratorShareNum()) / FEE_SPLIT_DENOM;
        uint256 remainder = amount - integratorAmount;

        if (integratorAmount != 0) {
            _send(integrator, integratorAmount);
        }

        if (remainder == 0) return;

        uint256 hubCount = _redistributionHubs.length;
        if (hubCount != 0) {
            uint256 distributed;
            for (uint256 i; i < hubCount; ++i) {
                uint256 leg = (remainder * _feeSplit[i]) / WAD;
                if (i == hubCount - 1) leg = remainder - distributed;
                distributed += leg;
                _send(_redistributionHubs[i], leg);
            }
            return;
        }

        // Unsupported / no configured hubs: even-split remainder across domestic fee hubs
        address[] memory hubs = tournamentRegistry.getAllDomesticPbrFeeHubs();
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

    // --------------------------------------------
    //  Recover
    // --------------------------------------------

    /// @notice Relays the full ETH balance (bypasses `minRelay`).
    function forward() external nonReentrant {
        _relay(address(this).balance);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function redistributionHubs() external view returns (address[] memory) {
        return _redistributionHubs;
    }

    function feeSplit() external view returns (uint256[] memory) {
        return _feeSplit;
    }

    /// @notice Integrator numerator over `FEE_SPLIT_DENOM` (10 bonding / 5 otherwise).
    function integratorShareNum() external view returns (uint256) {
        return _integratorShareNum();
    }

    function _integratorShareNum() internal view returns (uint256) {
        return status == PlayerStatus.BONDING ? BONDING_INTEGRATOR_SHARE_NUM : SPOT_INTEGRATOR_SHARE_NUM;
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /**
     * @notice Syncs local `PlayerStatus` cache (bonding vs spot integrator share).
     * @dev Callable by `Orchestrator` (owner) or `PlayerSetRegistry`. Sweeps queued ETH.
     */
    function setStatus(PlayerStatus status_) external nonReentrant {
        _checkStatusCaller();
        _setStatus(status_);
    }

    function _checkStatusCaller() internal view {
        if (msg.sender == owner()) return;
        if (msg.sender == _getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY))) return;
        revert Errors.Unauthorized();
    }

    function _setStatus(PlayerStatus status_) internal {
        PlayerStatus previous = status;
        if (previous == status_) return;

        status = status_;
        emit Events.StatusUpdated(playerId, previous, status_);
        _relay(address(this).balance);
    }

    /**
     * @notice Recovers accidental ERC20 balances (e.g. player-token dust).
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Events.TokenRescued(token, to, amount);
    }

    /**
     * @notice Updates the minimum ETH balance required before auto-relay on `receive`.
     */
    function setMinRelay(uint256 minRelay_) external onlyOwner nonReentrant {
        uint256 previous = minRelay;
        minRelay = minRelay_;
        emit Events.MinRelayUpdated(playerId, previous, minRelay_);
        _tryRelay();
    }

    /**
     * @notice Updates league `PbrFeeHub` and resets redistribution to `{ hub } / { WAD }` (or clears if zero).
     * @dev Pass zero when the market is unsupported / has no league.
     *      Callable by owner or `PlayerSetRegistry` (ChangedLeague SoT).
     */
    function setPbrFeeHub(address newHub) external nonReentrant {
        _checkStatusCaller();
        _setPbrFeeHub(newHub);
        _relay(address(this).balance);
    }

    /**
     * @notice Updates integrator (`HP_TREASURY` role) and sweeps queued ETH.
     */
    function setIntegrator(address newIntegrator) external onlyOwner nonReentrant {
        if (newIntegrator == address(0)) revert Errors.ZeroAddress();
        if (newIntegrator == address(this)) revert Errors.InvalidDestination();

        address previous = integrator;
        integrator = newIntegrator;
        emit Events.IntegratorUpdated(playerId, previous, newIntegrator);
        _relay(address(this).balance);
    }

    /**
     * @notice Sets post-integrator redistribution destinations and WAD shares.
     * @dev `hubs.length == splits.length`, splits sum to `WAD`, and `pbrFeeHub` must be listed
     *      when `pbrFeeHub != 0`. Reverts if `pbrFeeHub == 0` (use OOF path / set hub first).
     */
    function setRedistribution(address[] calldata hubs, uint256[] calldata splits) external onlyOwner nonReentrant {
        _setRedistribution(hubs, splits);
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

        if (newHub == address(0)) {
            delete _redistributionHubs;
            delete _feeSplit;
            emit Events.RedistributionUpdated(playerId, new address[](0), new uint256[](0));
            return;
        }

        address[] memory hubs = new address[](1);
        hubs[0] = newHub;
        uint256[] memory splits = new uint256[](1);
        splits[0] = WAD;
        _setRedistribution(hubs, splits);
    }

    function _setRedistribution(address[] memory hubs, uint256[] memory splits) internal {
        uint256 length = hubs.length;
        if (length == 0) revert Errors.EmptyRedistribution();
        if (length != splits.length) revert Errors.LengthMismatch();

        address requiredHub = pbrFeeHub;
        if (requiredHub == address(0)) revert Errors.PbrFeeHubRequired();

        uint256 totalShares;
        bool foundPbrHub;
        for (uint256 i; i < length; ++i) {
            address hub = hubs[i];
            if (hub == address(0) || hub == address(this)) revert Errors.InvalidDestination();
            if (hub.code.length == 0) revert Errors.DestinationNotContract();
            if (splits[i] == 0) revert Errors.InvalidFeeSplit();

            for (uint256 j; j < i; ++j) {
                if (hubs[j] == hub) revert Errors.DuplicateRedistributionHub(hub);
            }

            if (hub == requiredHub) foundPbrHub = true;
            totalShares += splits[i];
        }

        if (!foundPbrHub) revert Errors.PbrFeeHubMissing(requiredHub);
        if (totalShares != WAD) revert Errors.InvalidFeeSplitTotal(totalShares);

        delete _redistributionHubs;
        delete _feeSplit;
        for (uint256 i; i < length; ++i) {
            _redistributionHubs.push(hubs[i]);
            _feeSplit.push(splits[i]);
        }

        emit Events.RedistributionUpdated(playerId, hubs, splits);
    }
}
