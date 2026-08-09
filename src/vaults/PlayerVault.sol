// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@events/vaults/VaultsEvents.sol";
import { RoundStatus } from "@types/vaults/VaultTypes.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IStakedToken } from "@interfaces/vaults/IStakedToken.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { IPlayerVault } from "@interfaces/vaults/IPlayerVault.sol";

/**
 * @title PlayerVault
 * @notice Stake custody; mirrors utilization to cached active treasuries; claims use `lockBlock` checkpoints.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVault is Initializable, AddressBook, Ownable, Pausable, ReentrancyGuard, IPlayerVault {
    using SafeERC20 for IERC20;

    ITournamentRegistry public tournamentRegistry;
    IPlayerSetRegistry public playerSetRegistry;

    address public stakeRouter;

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    bytes32 public playerId;
    address public playerToken;
    address public stToken;
    uint256 public totalStaked;

    bool public isActive;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    uint64 public constant SYNC_COOLDOWN = 1 days;
    uint64 public lastSyncClaimableCacheAt;

    mapping(address user => mapping(uint256 word => uint256)) public claimedWords;
    /// @dev Next `_cachedRounds` index to process for `user` (append-only cache; skips history on later claims).
    mapping(address user => uint256) public claimCursor;

    struct ActiveTreasury {
        bytes32 tournamentId;
        address treasury;
    }

    /// @dev Live membership for stake/unstake fan-out (updated by TournamentRegistry).
    ActiveTreasury[] private _activeTreasuries;
    mapping(address treasury => uint256) private _activeTreasuryIndex; // 1-based
    /// @dev Tournament → treasury; kept after unlink for `treasuryOf` discovery.
    mapping(bytes32 tournamentId => address treasury) private _treasuryOf;
    /// @dev Reverse of `_treasuryOf` (kept after unlink).
    mapping(address treasury => bytes32 tournamentId) private _tournamentIdOf;
    /// @dev Append-only treasuries ever linked.
    address[] private _knownTreasuries;
    mapping(address treasury => bool) private _isKnownTreasury;

    /// @dev Lazy cache of payable claimable rounds this vault participated in (filled on sync/claim).
    struct CachedRound {
        address treasury;
        uint16 seasonStartYear;
        uint32 roundNumber;
        uint64 lockBlock;
    }

    CachedRound[] private _cachedRounds;
    mapping(address treasury => mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => uint256))) private
        _cachedRoundIndex; // 1-based

    /// @dev Per-treasury scan tip: next round to inspect (0 = uninitialized). Stops on Locked/SettlePending.
    struct ScanTip {
        uint16 season;
        uint32 nextRound;
    }

    mapping(address treasury => ScanTip) private _scanTip;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(bytes32 playerId_, address playerToken_, address stToken_) external initializer {
        if (playerToken_ == address(0) || stToken_ == address(0)) revert Errors.ZeroAddress();
        if (playerId_ == bytes32(0)) revert Errors.ZeroId();

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));

        stakeRouter = _getAddress(_addressKey(Addresses.STAKE_ROUTER));

        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));
        
        playerId = playerId_;
        playerToken = playerToken_;
        stToken = stToken_;
        isActive = true;
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------
    //  Lifecycle
    // --------------------------------------------

    function setActive(bool active_) external {
        _checkLifecycleCaller();
        isActive = active_;
        emit Events.ActiveUpdated(playerId, active_);
    }

    /// @inheritdoc IPlayerVault
    function syncActiveTreasury(bytes32 tournamentId_, address treasury, bool active) external {
        if (msg.sender != address(tournamentRegistry)) revert Errors.Unauthorized();
        if (treasury == address(0)) revert Errors.ZeroAddress();
        if (tournamentId_ == bytes32(0)) revert Errors.ZeroId();

        if (active) {
            _treasuryOf[tournamentId_] = treasury;
            _tournamentIdOf[treasury] = tournamentId_;
            if (!_isKnownTreasury[treasury]) {
                _isKnownTreasury[treasury] = true;
                _knownTreasuries.push(treasury);
            }
            if (_activeTreasuryIndex[treasury] != 0) return;
            _activeTreasuries.push(ActiveTreasury({ tournamentId: tournamentId_, treasury: treasury }));
            _activeTreasuryIndex[treasury] = _activeTreasuries.length;
            emit Events.ActiveTreasuryUpdated(tournamentId_, treasury, true);
            return;
        }

        uint256 index1 = _activeTreasuryIndex[treasury];
        if (index1 == 0) return;

        uint256 index0 = index1 - 1;
        uint256 last = _activeTreasuries.length - 1;
        if (index0 != last) {
            ActiveTreasury memory moved = _activeTreasuries[last];
            _activeTreasuries[index0] = moved;
            _activeTreasuryIndex[moved.treasury] = index0 + 1;
        }
        _activeTreasuries.pop();
        delete _activeTreasuryIndex[treasury];
        emit Events.ActiveTreasuryUpdated(tournamentId_, treasury, false);
    }

    function _checkLifecycleCaller() internal view {
        if (msg.sender == owner()) return;
        if (msg.sender == _getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY))) return;
        revert Errors.Unauthorized();
    }

    // --------------------------------------------
    //  Router
    // --------------------------------------------

    /// @inheritdoc IPlayerVault
    /// @dev Pulls `playerToken` from `user` (user must approve this vault). Mint stToken to `user`.
    function stakeFor(address user, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != stakeRouter) revert Errors.Unauthorized();
        _stake(user, amount);
    }

    /// @inheritdoc IPlayerVault
    function unstakeFor(address user, uint256 amount) external nonReentrant whenNotPaused {
        if (msg.sender != stakeRouter) revert Errors.Unauthorized();
        _unstake(user, amount);
    }

    /// @inheritdoc IPlayerVault
    function claimFor(address user) external nonReentrant whenNotPaused returns (uint256) {
        if (msg.sender != stakeRouter) revert Errors.Unauthorized();
        return _claim(user);
    }

    // --------------------------------------------
    //  Stake / Unstake
    // --------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        _stake(msg.sender, amount);
    }

    function _stake(address user, uint256 amount) internal {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (!isActive) revert Errors.VaultInactive();
        if (amount == 0) revert Errors.ZeroAmount();

        IERC20(playerToken).safeTransferFrom(user, address(this), amount);
        IStakedToken(stToken).mint(user, amount);

        uint256 previous = totalStaked;
        uint256 next = previous + amount;
        totalStaked = next;
        _syncUtilization(previous, next);

        emit Events.Staked(user, amount, next);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        _unstake(msg.sender, amount);
    }

    function _unstake(address user, uint256 amount) internal {
        if (user == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) revert Errors.ZeroAmount();

        uint256 bal = IStakedToken(stToken).balanceOf(user);
        if (amount > bal) revert Errors.InsufficientStake();
        if (bal - amount < _lockedBalance(user)) revert Errors.MatchweekLock();

        IStakedToken(stToken).burn(user, amount);
        IERC20(playerToken).safeTransfer(user, amount);

        uint256 previous = totalStaked;
        uint256 next = previous - amount;
        totalStaked = next;
        _syncUtilization(previous, next);

        emit Events.Unstaked(user, amount, next);
    }

    // --------------------------------------------
    //  Claim
    // --------------------------------------------

    /// @notice Advance claimable-round cache for all known treasuries (permissionless keeper).
    /// @dev 24h cooldown on this entrypoint only; `claim()` still syncs without the gate.
    ///      `lastSyncClaimableCacheAt == 0` means never synced (not unix-epoch).
    function syncClaimableCache() external nonReentrant {
        uint64 last = lastSyncClaimableCacheAt;
        if (last != 0 && block.timestamp < uint256(last) + SYNC_COOLDOWN) {
            revert Errors.SyncCooldown();
        }
        _syncClaimableCache();
        lastSyncClaimableCacheAt = uint64(block.timestamp);
    }

    /// @notice Sync cache, then pay each cached round where caller had cut-off stake.
    function claim() external nonReentrant whenNotPaused returns (uint256) {
        return _claim(msg.sender);
    }

    function _claim(address user) internal returns (uint256) {
        if (user == address(0)) revert Errors.ZeroAddress();
        _syncClaimableCache();
        return _claimFromCache(user);
    }

    // --------------------------------------------
    //  Read
    // --------------------------------------------

    /// @notice ETH owed across cached claimable rounds for `user` (assumes a warm claimable cache).
    /// @dev Walks `_cachedRounds` from `claimCursor`; does not advance tips. Call `syncClaimableCache`
    ///      (or `claim`) first if keepers have not warmed the cache.
    function pendingRewards(address user) external view returns (uint256 total) {
        uint256 length = _cachedRounds.length;
        uint256 i = claimCursor[user];
        for (; i < length;) {
            CachedRound memory row = _cachedRounds[i];
            bytes32 tid = _tournamentIdOf[row.treasury];
            uint256 claimKey = _claimKey(tid, row.seasonStartYear, row.roundNumber);
            if (!_isClaimed(user, claimKey) && IStakedToken(stToken).balanceOfAt(user, row.lockBlock) > 0) {
                total += IPbrTreasury(row.treasury)
                    .previewClaim(row.seasonStartYear, row.roundNumber, address(this), user);
            }
            unchecked {
                ++i;
            }
        }
    }

    // --------------------------------------------
    //  External views
    // --------------------------------------------

    function stakedBalance(address user) external view returns (uint256) {
        return IStakedToken(stToken).balanceOf(user);
    }

    function lockedBalance(address user) external view returns (uint256) {
        return _lockedBalance(user);
    }

    function activeTreasuryCount() external view returns (uint256) {
        return _activeTreasuries.length;
    }

    function activeTreasuryAt(uint256 index) external view returns (bytes32 tournamentId_, address treasury) {
        ActiveTreasury memory link = _activeTreasuries[index];
        return (link.tournamentId, link.treasury);
    }

    function treasuryOf(bytes32 tournamentId_) external view returns (address) {
        return _treasuryOf[tournamentId_];
    }

    function cachedRoundCount() external view returns (uint256) {
        return _cachedRounds.length;
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    /// @dev On 0↔nonzero only: mirror utilization to PSR and all active treasuries.
    function _syncUtilization(uint256 previousTotal, uint256 newTotal) internal {
        bool wasUtilized = previousTotal > 0;
        bool isUtilized = newTotal > 0;
        if (wasUtilized == isUtilized) return;

        playerSetRegistry.updateUtilization(isUtilized);

        uint256 n = _activeTreasuries.length;
        for (uint256 i; i < n;) {
            IPbrTreasury(_activeTreasuries[i].treasury).syncUtilization(isUtilized);
            unchecked {
                ++i;
            }
        }
    }

    function _syncClaimableCache() internal {
        uint256 tLen = _knownTreasuries.length;
        for (uint256 t; t < tLen;) {
            _advanceTip(_knownTreasuries[t]);
            unchecked {
                ++t;
            }
        }
    }

    function _advanceTip(address treasuryAddr) internal {
        IPbrTreasury treasury = IPbrTreasury(treasuryAddr);
        bytes32 tid = _tournamentIdOf[treasuryAddr];
        (uint16 season, uint32 active,) = treasury.getCursors();
        ScanTip memory tip = _scanTip[treasuryAddr];

        (, uint16[] memory seasonYears) = tournamentRegistry.getSeasonsOldestFirst(tid);

        if (tip.nextRound == 0) {
            tip = ScanTip({ season: seasonYears.length == 0 ? season : seasonYears[0], nextRound: 1 });
        }

        // Past calendar seasons (strictly before the treasury cursor season).
        uint256 i;
        while (i < seasonYears.length && seasonYears[i] < tip.season) {
            unchecked {
                ++i;
            }
        }
        for (; i < seasonYears.length;) {
            uint16 y = seasonYears[i];
            if (y >= season) break;

            uint32 tipFinal = tournamentRegistry.getFinalRound(tid, y);
            if (tipFinal == 0) break;

            uint32 from = y == tip.season ? tip.nextRound : 1;
            if (from <= tipFinal) {
                (uint32 next,, bool blocked) = _scanRangePersist(treasuryAddr, treasury, y, from, tipFinal);
                tip = ScanTip({ season: y, nextRound: next });
                if (blocked) {
                    _scanTip[treasuryAddr] = tip;
                    return;
                }
            }

            unchecked {
                ++i;
            }
            tip = ScanTip({ season: i < seasonYears.length ? seasonYears[i] : season, nextRound: 1 });
        }

        // Current treasury season up to `active` (stops on Locked / SettlePending).
        if (tip.season < season) {
            tip = ScanTip({ season: season, nextRound: 1 });
        }
        if (tip.season == season && active > 0 && tip.nextRound <= active) {
            (uint32 next,, bool blocked) = _scanRangePersist(treasuryAddr, treasury, season, tip.nextRound, active);
            tip.nextRound = next;
            if (blocked) {
                _scanTip[treasuryAddr] = tip;
                return;
            }
        }
        _scanTip[treasuryAddr] = tip;
    }

    /// @dev `nextRound_` is the round to resume at; `blocked_` if stopped on Locked/SettlePending.
    function _scanRangePersist(
        address treasuryAddr,
        IPbrTreasury treasury,
        uint16 seasonStartYear_,
        uint32 fromRound,
        uint32 toRound
    ) internal returns (uint32 nextRound_, uint16, bool blocked_) {
        for (uint32 r = fromRound; r <= toRound;) {
            (RoundStatus status, uint64 lockBlock) = treasury.getRoundClaimMeta(seasonStartYear_, r);
            if (status == RoundStatus.Locked || status == RoundStatus.SettlePending) {
                return (r, seasonStartYear_, true);
            }
            if (
                status == RoundStatus.Claimable && IStakedToken(stToken).totalSupplyAt(lockBlock) > 0
                    && treasury.hasPayableVaultShare(seasonStartYear_, r, address(this))
            ) {
                _rememberRound(treasuryAddr, seasonStartYear_, r, lockBlock);
            }
            unchecked {
                ++r;
            }
        }
        return (toRound + 1, seasonStartYear_, false);
    }

    function _rememberRound(
        address treasuryAddr,
        uint16 seasonStartYear_,
        uint32 roundNumber,
        uint64 lockBlock
    ) internal {
        if (_cachedRoundIndex[treasuryAddr][seasonStartYear_][roundNumber] != 0) return;
        _cachedRounds.push(
            CachedRound({
                treasury: treasuryAddr,
                seasonStartYear: seasonStartYear_,
                roundNumber: roundNumber,
                lockBlock: lockBlock
            })
        );
        _cachedRoundIndex[treasuryAddr][seasonStartYear_][roundNumber] = _cachedRounds.length;
    }

    function _claimFromCache(address user) internal returns (uint256 totalPayout) {
        uint256 length = _cachedRounds.length;
        uint256 i = claimCursor[user];
        for (; i < length;) {
            CachedRound memory row = _cachedRounds[i];
            bytes32 tid = _tournamentIdOf[row.treasury];
            uint256 claimKey = _claimKey(tid, row.seasonStartYear, row.roundNumber);
            if (!_isClaimed(user, claimKey) && IStakedToken(stToken).balanceOfAt(user, row.lockBlock) > 0) {
                totalPayout += _payClaim(user, tid, row.treasury, row.seasonStartYear, row.roundNumber, claimKey);
            }
            unchecked {
                ++i;
            }
        }
        // Advance even for zero-payout / already-claimed rows so later claims only walk new cache entries.
        claimCursor[user] = length;
    }

    function _payClaim(
        address user,
        bytes32 tournamentId_,
        address treasuryAddr,
        uint16 seasonStartYear_,
        uint32 roundNumber,
        uint256 claimKey
    ) internal returns (uint256 payout) {
        payout = IPbrTreasury(treasuryAddr).payClaim(seasonStartYear_, roundNumber, user);
        _setClaimed(user, claimKey);
        if (payout == 0) return 0;

        emit Events.Claimed(user, tournamentId_, seasonStartYear_, roundNumber, payout);
    }

    function _lockedBalance(address user) internal view returns (uint256 locked) {
        uint256 n = _activeTreasuries.length;
        for (uint256 i; i < n;) {
            IPbrTreasury treasury = IPbrTreasury(_activeTreasuries[i].treasury);
            (uint16 seasonStartYear_, uint32 active,) = treasury.getCursors();
            (RoundStatus status, uint64 lockBlock) = treasury.getRoundClaimMeta(seasonStartYear_, active);
            if (status == RoundStatus.Locked || status == RoundStatus.SettlePending) {
                uint256 cutBal = IStakedToken(stToken).balanceOfAt(user, lockBlock);
                if (cutBal > locked) locked = cutBal;
            }
            unchecked {
                ++i;
            }
        }
    }

    function _claimKey(
        bytes32 tournamentId_,
        uint16 seasonStartYear_,
        uint32 roundNumber
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(tournamentId_, seasonStartYear_, roundNumber)));
    }

    function _isClaimed(address user, uint256 claimKey) internal view returns (bool) {
        return (claimedWords[user][claimKey >> 8] & (uint256(1) << (claimKey & 0xff))) != 0;
    }

    function _setClaimed(address user, uint256 claimKey) internal {
        claimedWords[user][claimKey >> 8] |= uint256(1) << (claimKey & 0xff);
    }
}
