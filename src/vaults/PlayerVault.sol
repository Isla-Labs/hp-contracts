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
import { OutstandingClaim, RoundStatus } from "@types/vaults/VaultTypes.sol";
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

    // --------------------------------------------
    //  Config
    // --------------------------------------------

    bytes32 public playerId;
    address public playerToken;
    address public stToken;
    uint256 public totalStaked;

    bool public isActive;

    mapping(address user => mapping(uint256 word => uint256)) public claimedWords;

    struct ActiveTreasury {
        bytes32 tournamentId;
        address treasury;
    }

    /// @dev Live membership for stake/unstake fan-out (updated by TournamentRegistry).
    ActiveTreasury[] private _activeTreasuries;
    mapping(address treasury => uint256) private _activeTreasuryIndex; // 1-based
    /// @dev Survives unregister so historical `claim(tournamentId, …)` still resolves.
    mapping(bytes32 tournamentId => address treasury) private _treasuryOf;
    /// @dev Reverse of `_treasuryOf` (kept after unlink).
    mapping(address treasury => bytes32 tournamentId) private _tournamentIdOf;
    /// @dev Append-only treasuries ever linked.
    address[] private _knownTreasuries;
    mapping(address treasury => bool) private _isKnownTreasury;

    /// @dev Lazy cache of claimable rounds this vault participated in (filled on refresh / claim).
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
    //  Stake / Unstake
    // --------------------------------------------

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (!isActive) revert Errors.VaultInactive();
        if (amount == 0) revert Errors.ZeroAmount();

        address user = msg.sender;
        IERC20(playerToken).safeTransferFrom(user, address(this), amount);
        IStakedToken(stToken).mint(user, amount);

        uint256 previous = totalStaked;
        uint256 next = previous + amount;
        totalStaked = next;
        _syncUtilization(previous, next);

        emit Events.Staked(user, amount, next);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.ZeroAmount();

        address user = msg.sender;
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

    /// @notice Advance per-treasury scan tips and cache rounds with a non-zero vault reward share.
    function refreshClaimable() external nonReentrant {
        _syncClaimableCache();
    }

    /// @notice Sync cache, then pay each cached round where caller had cut-off stake.
    function claim() external nonReentrant whenNotPaused returns (uint256) {
        _syncClaimableCache();
        return _claimFromCache(msg.sender);
    }

    // --------------------------------------------
    //  External views
    // --------------------------------------------

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

    /**
     * @notice Claimable rounds with a non-zero payout preview for `user` (UI helper).
     * @dev Uses lazy cache + ephemeral tip discovery (no writes). Call `refreshClaimable` to persist tips.
     */
    function outstandingClaims(address user) external view returns (OutstandingClaim[] memory out) {
        OutstandingClaim[] memory buf = new OutstandingClaim[](_outstandingBufSize());
        uint256 n = _collectFromCache(user, buf, 0);

        uint256 tLen = _knownTreasuries.length;
        for (uint256 t; t < tLen;) {
            n = _collectFromTipEphemeral(user, _knownTreasuries[t], buf, n);
            unchecked {
                ++t;
            }
        }

        out = new OutstandingClaim[](n);
        for (uint256 i; i < n;) {
            out[i] = buf[i];
            unchecked {
                ++i;
            }
        }
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

        if (tip.nextRound == 0) {
            if (season > 0) {
                uint32 prevFinal = tournamentRegistry.getFinalRound(tid, season - 1);
                if (prevFinal > 0) {
                    (uint32 next,, bool blocked) = _scanRangePersist(treasuryAddr, treasury, season - 1, 1, prevFinal);
                    if (blocked) {
                        _scanTip[treasuryAddr] = ScanTip({ season: season - 1, nextRound: next });
                        return;
                    }
                }
            }
            tip = ScanTip({ season: season, nextRound: 1 });
        }

        while (tip.season < season) {
            uint32 tipFinal = tournamentRegistry.getFinalRound(tid, tip.season);
            if (tipFinal == 0) break;
            if (tip.nextRound <= tipFinal) {
                (uint32 next,, bool blocked) =
                    _scanRangePersist(treasuryAddr, treasury, tip.season, tip.nextRound, tipFinal);
                tip.nextRound = next;
                if (blocked) {
                    _scanTip[treasuryAddr] = tip;
                    return;
                }
            }
            unchecked {
                tip.season += 1;
            }
            tip.nextRound = 1;
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
        for (uint256 i; i < length;) {
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
        if (payout == 0) return 0;

        _setClaimed(user, claimKey);
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

    function _outstandingBufSize() internal view returns (uint256) {
        uint256 n = _cachedRounds.length + 8;
        uint256 tLen = _knownTreasuries.length;
        for (uint256 t; t < tLen;) {
            (, uint32 active,) = IPbrTreasury(_knownTreasuries[t]).getCursors();
            ScanTip memory tip = _scanTip[_knownTreasuries[t]];
            if (tip.nextRound > 0 && active >= tip.nextRound) n += (active - tip.nextRound + 1);
            else n += 8;
            unchecked {
                ++t;
            }
        }
        if (n == 0) n = 1;
        return n;
    }

    function _collectFromCache(address user, OutstandingClaim[] memory buf, uint256 n) internal view returns (uint256) {
        uint256 length = _cachedRounds.length;
        for (uint256 i; i < length;) {
            CachedRound memory row = _cachedRounds[i];
            bytes32 tid = _tournamentIdOf[row.treasury];
            uint256 preview = _userPreview(user, tid, row);
            if (preview > 0 && n < buf.length) {
                buf[n] = OutstandingClaim({
                    tournamentId: tid,
                    seasonStartYear: row.seasonStartYear,
                    roundNumber: row.roundNumber,
                    previewPayout: preview
                });
                unchecked {
                    ++n;
                }
            }
            unchecked {
                ++i;
            }
        }
        return n;
    }

    /// @dev View-only tip discovery so outstandingClaims stays correct before `refreshClaimable`.
    function _collectFromTipEphemeral(
        address user,
        address treasuryAddr,
        OutstandingClaim[] memory buf,
        uint256 n
    ) internal view returns (uint256) {
        IPbrTreasury treasury = IPbrTreasury(treasuryAddr);
        bytes32 tid = _tournamentIdOf[treasuryAddr];
        (uint16 season, uint32 active,) = treasury.getCursors();
        ScanTip memory tip = _scanTip[treasuryAddr];

        uint16 scanSeason = tip.nextRound == 0 ? season : tip.season;
        uint32 from = tip.nextRound == 0 ? 1 : tip.nextRound;

        if (tip.nextRound == 0 && season > 0) {
            uint32 prevFinal = tournamentRegistry.getFinalRound(tid, season - 1);
            if (prevFinal > 0) {
                n = _scanRangeEphemeral(user, treasury, tid, season - 1, 1, prevFinal, buf, n);
            }
        }

        if (scanSeason < season) {
            uint32 tipFinal = tournamentRegistry.getFinalRound(tid, scanSeason);
            if (tipFinal >= from) {
                n = _scanRangeEphemeral(user, treasury, tid, scanSeason, from, tipFinal, buf, n);
            }
            for (uint16 s = scanSeason + 1; s < season;) {
                uint32 midFinal = tournamentRegistry.getFinalRound(tid, s);
                if (midFinal > 0) n = _scanRangeEphemeral(user, treasury, tid, s, 1, midFinal, buf, n);
                unchecked {
                    ++s;
                }
            }
            from = 1;
            scanSeason = season;
        }

        if (scanSeason == season && active >= from) {
            n = _scanRangeEphemeral(user, treasury, tid, season, from, active, buf, n);
        }
        return n;
    }

    function _scanRangeEphemeral(
        address user,
        IPbrTreasury treasury,
        bytes32 tournamentId_,
        uint16 seasonStartYear_,
        uint32 fromRound,
        uint32 toRound,
        OutstandingClaim[] memory buf,
        uint256 n
    ) internal view returns (uint256) {
        for (uint32 r = fromRound; r <= toRound;) {
            if (_cachedRoundIndex[address(treasury)][seasonStartYear_][r] == 0) {
                (RoundStatus status, uint64 lockBlock) = treasury.getRoundClaimMeta(seasonStartYear_, r);
                if (status == RoundStatus.Locked || status == RoundStatus.SettlePending) break;
                if (
                    status == RoundStatus.Claimable && IStakedToken(stToken).totalSupplyAt(lockBlock) > 0
                        && treasury.hasPayableVaultShare(seasonStartYear_, r, address(this))
                ) {
                    CachedRound memory row = CachedRound({
                        treasury: address(treasury),
                        seasonStartYear: seasonStartYear_,
                        roundNumber: r,
                        lockBlock: lockBlock
                    });
                    uint256 preview = _userPreview(user, tournamentId_, row);
                    if (preview > 0 && n < buf.length) {
                        buf[n] = OutstandingClaim({
                            tournamentId: tournamentId_,
                            seasonStartYear: seasonStartYear_,
                            roundNumber: r,
                            previewPayout: preview
                        });
                        unchecked {
                            ++n;
                        }
                    }
                }
            }
            unchecked {
                ++r;
            }
        }
        return n;
    }

    /// @dev UI helper: cached/ephemeral rows are already vault-payable; gate on user stake then preview.
    function _userPreview(address user, bytes32 tournamentId_, CachedRound memory row) internal view returns (uint256) {
        uint256 claimKey = _claimKey(tournamentId_, row.seasonStartYear, row.roundNumber);
        if (_isClaimed(user, claimKey)) return 0;
        if (IStakedToken(stToken).balanceOfAt(user, row.lockBlock) == 0) return 0;
        return IPbrTreasury(row.treasury).previewClaim(row.seasonStartYear, row.roundNumber, address(this), user);
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
