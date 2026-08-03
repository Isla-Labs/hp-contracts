// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { Checkpoints } from "@openzeppelin/utils/structs/Checkpoints.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@events/vaults/VaultsEvents.sol";
import { RoundStatus } from "@types/vaults/VaultTypes.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IReferralRegistry } from "@interfaces/IReferralRegistry.sol";
import { IStakedToken } from "@interfaces/vaults/IStakedToken.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";

/**
 * @title PlayerVault
 * @notice Stake custody + per-(tournament, season, round) snapshots; claims against each tournament treasury.
 * @dev Snapshot callers must be `TournamentRegistry.getPbrTreasury(tournamentId)`.
 *      Stake/unstake syncs `VaultData.isUtilized` on `PlayerSetRegistry` when `totalStaked`
 *      crosses zero. Vault must already be registered via `addVaultData`.
 *      `Orchestrator` (owner) may pause/unpause user stake and claim flows and toggle
 *      `isActive` for lifecycle support / discontinuation (or manual repair).
 *
 *      Referral boost (optional `REFERRAL_REGISTRY`): claim weights use
 *      `s_eff / S_adj` with a per-user 50k eligible-stake cap and BPS factor frozen at snapshot.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVault is Initializable, AddressBook, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Checkpoints for Checkpoints.Trace160;

    // --------------------------------------------
    //  Constants
    // --------------------------------------------

    uint256 public constant BOOST_CAP = 50_000 ether;

    uint16 public constant BPS_BASE = 10_000;
    uint16 public constant BPS_MAX = 11_000;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ITournamentRegistry public tournamentRegistry;
    IPlayerSetRegistry public playerSetRegistry;

    bytes32 public playerId;
    address public playerToken;
    address public stToken;
    uint256 public totalStaked;

    /// @notice Sum of per-user effective stake weights (boosted eligible + unboosted excess).
    uint256 public totalEffectiveStaked;

    /// @notice Latest stToken snapshot id created by this vault (0 if none).
    uint256 public latestSnapId;

    /// @notice When false, new stakes are rejected (unsupported / discontinued market).
    bool public isActive;

    mapping(bytes32 tournamentId => mapping(uint16 seasonId => mapping(uint32 roundNumber => uint256 snapId))) public
        snapIdOf;
    mapping(address user => mapping(uint256 word => uint256)) public claimedWords;

    /// @notice Frozen `S_adj` at each stToken snapshot id.
    mapping(uint256 snapId => uint256 effectiveSupply) public effectiveSupplyAt;

    /// @dev Boost BPS checkpoints keyed by stToken snap id applicability
    ///      (`push(latestSnapId + 1, bps)` so changes apply only to future snaps).
    mapping(address user => Checkpoints.Trace160) private _boostBpsTrace;

    struct RoundKey {
        bytes32 tournamentId;
        uint16 seasonId;
        uint32 roundNumber;
    }

    RoundKey[] private _snapRounds;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Resolves registries from `AddressProvider`; market ids stay explicit.
     * @param playerId_ Player identity associated with this vault.
     * @param playerToken_ Underlying player ERC20.
     * @param stToken_ Bound staked-token share receipt.
     */
    function initialize(bytes32 playerId_, address playerToken_, address stToken_) external initializer {
        if (playerToken_ == address(0) || stToken_ == address(0)) revert Errors.ZeroAddress();
        if (playerId_ == bytes32(0)) revert Errors.ZeroId();

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));

        address tournamentRegistry_ = _getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY));
        address playerSetRegistry_ = _getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY));

        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        playerId = playerId_;
        playerToken = playerToken_;
        stToken = stToken_;
        isActive = true;
    }

    // --------------------------------------------
    //  Pause (owner)
    // --------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------
    //  Lifecycle (owner)
    // --------------------------------------------

    /**
     * @notice Mark the vault as supported or unsupported for new stakes.
     * @dev Unstake and claim remain available when inactive.
     */
    function setActive(bool active_) external onlyOwner {
        isActive = active_;
        emit Events.ActiveUpdated(playerId, active_);
    }

    // --------------------------------------------
    //  Referral boost
    // --------------------------------------------

    /**
     * @notice Pull `boostBps` from `ReferralRegistry` into this vault for `user`.
     * @dev Permissionless. Applies to future snapshots only (checkpoint key = latestSnapId + 1).
     *      Call after tier changes, or rely on auto-pull during stake/unstake.
     */
    function syncBoost(address user) external nonReentrant {
        if (user == address(0)) revert Errors.ZeroAddress();
        _pullBoost(user);
    }

    // --------------------------------------------
    //  Stake / Unstake
    // --------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (!isActive) revert Errors.VaultInactive();
        if (amount == 0) revert Errors.ZeroAmount();

        address user = msg.sender;
        _pullBoost(user);

        uint256 oldBal = IStakedToken(stToken).balanceOf(user);
        IERC20(playerToken).safeTransferFrom(user, address(this), amount);
        IStakedToken(stToken).mint(user, amount);

        uint256 previous = totalStaked;
        uint256 next = previous + amount;
        totalStaked = next;
        _applyBalanceDelta(user, oldBal, oldBal + amount);
        _syncUtilization(previous, next);

        emit Events.Staked(user, amount, next);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.ZeroAmount();

        address user = msg.sender;
        uint256 bal = IStakedToken(stToken).balanceOf(user);
        if (amount > bal) revert Errors.InsufficientStake();
        if (bal - amount < _lockedBalance(user)) revert Errors.MatchweekLock();

        _pullBoost(user);

        IStakedToken(stToken).burn(user, amount);
        IERC20(playerToken).safeTransfer(user, amount);

        uint256 previous = totalStaked;
        uint256 next = previous - amount;
        totalStaked = next;
        _applyBalanceDelta(user, bal, bal - amount);
        _syncUtilization(previous, next);

        emit Events.Unstaked(user, amount, next);
    }

    // --------------------------------------------
    //  mwStartTime
    // --------------------------------------------

    /// @dev Not pausable — settlement crank must still snapshot while user flows are halted.
    function snapshot(bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber) external returns (uint256 snapId) {
        address treasury = tournamentRegistry.getPbrTreasury(tournamentId_);
        if (treasury == address(0) || msg.sender != treasury) revert Errors.OnlyTournamentTreasury();
        if (snapIdOf[tournamentId_][seasonId_][roundNumber] != 0) {
            revert Errors.AlreadySnapshotted(tournamentId_, seasonId_, roundNumber);
        }

        snapId = IStakedToken(stToken).snapshot();
        snapIdOf[tournamentId_][seasonId_][roundNumber] = snapId;
        latestSnapId = snapId;
        effectiveSupplyAt[snapId] = totalEffectiveStaked;
        _snapRounds.push(RoundKey({ tournamentId: tournamentId_, seasonId: seasonId_, roundNumber: roundNumber }));

        emit Events.SnapshotTaken(
            tournamentId_,
            seasonId_,
            roundNumber,
            snapId,
            IStakedToken(stToken).totalSupplyAt(snapId),
            totalEffectiveStaked
        );
    }

    // --------------------------------------------
    //  Claim
    // --------------------------------------------

    function claim(
        bytes32 tournamentId_,
        uint16 seasonId_,
        uint32 roundNumber
    ) external nonReentrant whenNotPaused returns (uint256) {
        return _claim(msg.sender, tournamentId_, seasonId_, roundNumber, true);
    }

    function claimAll() external nonReentrant whenNotPaused returns (uint256 totalPayout) {
        address user = msg.sender;
        uint256 length = _snapRounds.length;
        for (uint256 i; i < length; ++i) {
            RoundKey memory key = _snapRounds[i];
            uint256 snapId = snapIdOf[key.tournamentId][key.seasonId][key.roundNumber];
            if (snapId == 0 || _isClaimed(user, snapId)) continue;

            address treasuryAddr = tournamentRegistry.getPbrTreasury(key.tournamentId);
            if (treasuryAddr == address(0)) continue;

            IPbrTreasury treasury = IPbrTreasury(treasuryAddr);
            if (treasury.getRound(key.seasonId, key.roundNumber).status != RoundStatus.Claimable) continue;

            totalPayout += _claim(user, key.tournamentId, key.seasonId, key.roundNumber, false);
        }
    }

    // --------------------------------------------
    //  External View
    // --------------------------------------------

    function lockedBalance(address user) external view returns (uint256) {
        return _lockedBalance(user);
    }

    function snapRoundCount() external view returns (uint256) {
        return _snapRounds.length;
    }

    function snapRoundAt(uint256 index)
        external
        view
        returns (bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber)
    {
        RoundKey memory key = _snapRounds[index];
        return (key.tournamentId, key.seasonId, key.roundNumber);
    }

    /// @notice Latest synced boost BPS for `user` (10_000 if never synced).
    function boostBpsOf(address user) external view returns (uint16) {
        return _latestBoostBps(user);
    }

    /// @notice Boost BPS frozen for claims against `snapId`.
    function boostBpsAt(address user, uint256 snapId) external view returns (uint16) {
        return _boostBpsAt(user, snapId);
    }

    /// @notice Effective stake weight for `user`'s current balance and synced boost.
    function effectiveStakeOf(address user) external view returns (uint256) {
        return _effectiveStake(IStakedToken(stToken).balanceOf(user), _latestBoostBps(user));
    }

    /// @notice Pure helper: effective weight for `amount` at `bps` with the 50k cap.
    function previewEffectiveStake(uint256 amount, uint16 bps) external pure returns (uint256) {
        return _effectiveStake(amount, bps);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    /// @dev Notify registry when utilization flips at the zero-stake boundary.
    function _syncUtilization(uint256 previousTotal, uint256 newTotal) internal {
        if (previousTotal == 0 && newTotal > 0) {
            playerSetRegistry.updateUtilization(true);
        } else if (previousTotal > 0 && newTotal == 0) {
            playerSetRegistry.updateUtilization(false);
        }
    }

    function _claim(
        address user,
        bytes32 tournamentId_,
        uint16 seasonId_,
        uint32 roundNumber,
        bool revertOnEmpty
    ) internal returns (uint256 payout) {
        uint256 snapId = snapIdOf[tournamentId_][seasonId_][roundNumber];
        if (snapId == 0) revert Errors.NoSnapshot(tournamentId_, seasonId_, roundNumber);
        if (_isClaimed(user, snapId)) revert Errors.AlreadyClaimed();

        address treasuryAddr = tournamentRegistry.getPbrTreasury(tournamentId_);
        if (treasuryAddr == address(0)) revert Errors.UnknownTournamentTreasury(tournamentId_);

        IPbrTreasury treasury = IPbrTreasury(treasuryAddr);
        uint256 s = IStakedToken(stToken).balanceOfAt(user, snapId);
        uint256 S = effectiveSupplyAt[snapId];
        if (S == 0) {
            // Pre-boost snaps / empty effective accounting — fall back to raw supply.
            S = IStakedToken(stToken).totalSupplyAt(snapId);
        }
        uint256 m = treasury.getVaultPoints(seasonId_, roundNumber, address(this));

        if (s == 0 || S == 0 || m == 0) {
            _setClaimed(user, snapId);
            if (revertOnEmpty) revert Errors.NothingToClaim();
            return 0;
        }

        uint256 sEff = _effectiveStake(s, _boostBpsAt(user, snapId));

        _setClaimed(user, snapId);
        payout = treasury.payClaim(seasonId_, roundNumber, user, sEff, S);
        emit Events.Claimed(user, tournamentId_, seasonId_, roundNumber, payout);
    }

    function _lockedBalance(address user) internal view returns (uint256 locked) {
        uint256 length = _snapRounds.length;
        for (uint256 i; i < length; ++i) {
            RoundKey memory key = _snapRounds[i];
            address treasuryAddr = tournamentRegistry.getPbrTreasury(key.tournamentId);
            if (treasuryAddr == address(0)) continue;

            if (IPbrTreasury(treasuryAddr).getRound(key.seasonId, key.roundNumber).status != RoundStatus.Locked) {
                continue;
            }

            uint256 snapBal =
                IStakedToken(stToken).balanceOfAt(user, snapIdOf[key.tournamentId][key.seasonId][key.roundNumber]);
            if (snapBal > locked) locked = snapBal;
        }
    }

    function _isClaimed(address user, uint256 snapId) internal view returns (bool) {
        return (claimedWords[user][snapId >> 8] & (uint256(1) << (snapId & 0xff))) != 0;
    }

    function _setClaimed(address user, uint256 snapId) internal {
        claimedWords[user][snapId >> 8] |= uint256(1) << (snapId & 0xff);
    }

    /// @dev Optional registry: missing address ⇒ no boost (BPS_BASE).
    function _referralRegistry() internal view returns (address) {
        return addressProvider.get(_addressKey(Addresses.REFERRAL_REGISTRY));
    }

    function _pullBoost(address user) internal {
        address reg = _referralRegistry();
        uint16 newBps = BPS_BASE;
        if (reg != address(0)) {
            newBps = IReferralRegistry(reg).boostBps(user);
            if (newBps < BPS_BASE || newBps > BPS_MAX) revert Errors.InvalidBoostBps(newBps);
        }

        uint16 oldBps = _latestBoostBps(user);
        if (newBps == oldBps) return;

        uint256 bal = IStakedToken(stToken).balanceOf(user);
        totalEffectiveStaked = totalEffectiveStaked - _effectiveStake(bal, oldBps) + _effectiveStake(bal, newBps);

        // Applies from the next snapshot onward (stToken ids start at 1).
        _boostBpsTrace[user].push(uint96(latestSnapId + 1), uint160(newBps));
        emit Events.BoostSynced(user, newBps, totalEffectiveStaked);
    }

    function _applyBalanceDelta(address user, uint256 oldBal, uint256 newBal) internal {
        uint16 bps = _latestBoostBps(user);
        totalEffectiveStaked = totalEffectiveStaked - _effectiveStake(oldBal, bps) + _effectiveStake(newBal, bps);
    }

    function _latestBoostBps(address user) internal view returns (uint16) {
        uint256 latest = _boostBpsTrace[user].latest();
        if (latest == 0) return BPS_BASE;
        return uint16(latest);
    }

    function _boostBpsAt(address user, uint256 snapId) internal view returns (uint16) {
        uint256 value = _boostBpsTrace[user].upperLookupRecent(uint96(snapId));
        if (value == 0) return BPS_BASE;
        return uint16(value);
    }

    /**
     * @dev First `BOOST_CAP` tokens get `bps`; remainder at 1.0×.
     *      `s_eff = eligible * bps / BPS_BASE + (amount - eligible)`.
     */
    function _effectiveStake(uint256 amount, uint16 bps) internal pure returns (uint256) {
        if (amount == 0) return 0;
        if (bps <= BPS_BASE) return amount;

        uint256 eligible = amount > BOOST_CAP ? BOOST_CAP : amount;
        uint256 excess = amount - eligible;
        return excess + Math.mulDiv(eligible, bps, BPS_BASE);
    }
}
