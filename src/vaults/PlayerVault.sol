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
 * @notice Stake custody; mirrors `S` to cached active treasuries; claims use `lockBlock` checkpoints.
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

    struct RoundKey {
        bytes32 tournamentId;
        address treasury;
        uint16 seasonStartYear;
        uint32 roundNumber;
    }

    RoundKey[] private _utilizedRounds;
    mapping(bytes32 tournamentId => mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => bool))) private
        _notedRound;

    struct ActiveTreasury {
        bytes32 tournamentId;
        address treasury;
    }

    /// @dev Live membership for stake/unstake fan-out (updated by TournamentRegistry).
    ActiveTreasury[] private _activeTreasuries;
    mapping(address treasury => uint256) private _activeTreasuryIndex; // 1-based
    /// @dev Survives unregister so historical `claim(tournamentId, …)` still resolves.
    mapping(bytes32 tournamentId => address treasury) private _treasuryOf;

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
        _syncTreasuries(next);

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
        _syncTreasuries(next);

        emit Events.Unstaked(user, amount, next);
    }

    /// @inheritdoc IPlayerVault
    function noteUtilizedRound(bytes32 tournamentId_, uint16 seasonStartYear_, uint32 roundNumber) external {
        if (_activeTreasuryIndex[msg.sender] == 0) revert Errors.OnlyTournamentTreasury();
        if (_treasuryOf[tournamentId_] != msg.sender) revert Errors.OnlyTournamentTreasury();
        _noteRound(tournamentId_, seasonStartYear_, roundNumber, msg.sender);
    }

    // --------------------------------------------
    //  Claim
    // --------------------------------------------

    function claim(
        bytes32 tournamentId_,
        uint16 seasonStartYear_,
        uint32 roundNumber
    ) external nonReentrant whenNotPaused returns (uint256) {
        address treasuryAddr = _treasuryOf[tournamentId_];
        if (treasuryAddr == address(0)) revert Errors.UnknownTournamentTreasury(tournamentId_);
        return _claim(msg.sender, tournamentId_, treasuryAddr, seasonStartYear_, roundNumber, true);
    }

    function claimAll() external nonReentrant whenNotPaused returns (uint256) {
        return _claimAll(msg.sender);
    }

    // --------------------------------------------
    //  External views
    // --------------------------------------------

    function lockedBalance(address user) external view returns (uint256) {
        return _lockedBalance(user);
    }

    function utilizedRoundCount() external view returns (uint256) {
        return _utilizedRounds.length;
    }

    function utilizedRoundAt(uint256 index)
        external
        view
        returns (bytes32 tournamentId_, address treasury, uint16 seasonStartYear_, uint32 roundNumber)
    {
        RoundKey memory key = _utilizedRounds[index];
        return (key.tournamentId, key.treasury, key.seasonStartYear, key.roundNumber);
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

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _syncUtilization(uint256 previousTotal, uint256 newTotal) internal {
        if (previousTotal == 0 && newTotal > 0) {
            playerSetRegistry.updateUtilization(true);
        } else if (previousTotal > 0 && newTotal == 0) {
            playerSetRegistry.updateUtilization(false);
        }
    }

    function _syncTreasuries(uint256 newTotalStaked) internal {
        uint256 n = _activeTreasuries.length;
        for (uint256 i; i < n;) {
            ActiveTreasury memory link = _activeTreasuries[i];
            (uint16 year, uint32 roundNumber, bool joined) = IPbrTreasury(link.treasury).syncVaultStake(newTotalStaked);
            if (joined) _noteRound(link.tournamentId, year, roundNumber, link.treasury);
            unchecked {
                ++i;
            }
        }
    }

    function _noteRound(bytes32 tournamentId_, uint16 seasonStartYear_, uint32 roundNumber, address treasury) internal {
        if (_notedRound[tournamentId_][seasonStartYear_][roundNumber]) return;
        _notedRound[tournamentId_][seasonStartYear_][roundNumber] = true;
        _utilizedRounds.push(
            RoundKey({
                tournamentId: tournamentId_,
                treasury: treasury,
                seasonStartYear: seasonStartYear_,
                roundNumber: roundNumber
            })
        );
    }

    function _claimAll(address user) internal returns (uint256 totalPayout) {
        uint256 length = _utilizedRounds.length;
        for (uint256 i; i < length;) {
            RoundKey memory key = _utilizedRounds[i];
            address treasuryAddr = key.treasury;
            if (treasuryAddr == address(0)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            (RoundStatus status, uint64 lockBlock) =
                IPbrTreasury(treasuryAddr).getRoundClaimMeta(key.seasonStartYear, key.roundNumber);
            if (status != RoundStatus.Claimable) {
                unchecked {
                    ++i;
                }
                continue;
            }

            uint256 claimKey = _claimKey(key.tournamentId, key.seasonStartYear, key.roundNumber);
            if (_isClaimed(user, claimKey)) {
                unchecked {
                    ++i;
                }
                continue;
            }

            totalPayout += _claimWithMeta(
                user, key.tournamentId, treasuryAddr, key.seasonStartYear, key.roundNumber, lockBlock, claimKey, false
            );
            unchecked {
                ++i;
            }
        }
    }

    function _claim(
        address user,
        bytes32 tournamentId_,
        address treasuryAddr,
        uint16 seasonStartYear_,
        uint32 roundNumber,
        bool revertOnEmpty
    ) internal returns (uint256 payout) {
        if (!_notedRound[tournamentId_][seasonStartYear_][roundNumber]) {
            revert Errors.RoundNotUtilized(tournamentId_, seasonStartYear_, roundNumber);
        }

        uint256 claimKey = _claimKey(tournamentId_, seasonStartYear_, roundNumber);
        if (_isClaimed(user, claimKey)) revert Errors.AlreadyClaimed();

        (, uint64 lockBlock) = IPbrTreasury(treasuryAddr).getRoundClaimMeta(seasonStartYear_, roundNumber);
        payout = _claimWithMeta(
            user, tournamentId_, treasuryAddr, seasonStartYear_, roundNumber, lockBlock, claimKey, revertOnEmpty
        );
    }

    function _claimWithMeta(
        address user,
        bytes32 tournamentId_,
        address treasuryAddr,
        uint16 seasonStartYear_,
        uint32 roundNumber,
        uint64 lockBlock,
        uint256 claimKey,
        bool revertOnEmpty
    ) internal returns (uint256 payout) {
        uint256 s = IStakedToken(stToken).balanceOfAt(user, lockBlock);
        uint256 S = IStakedToken(stToken).totalSupplyAt(lockBlock);
        uint256 m = IPbrTreasury(treasuryAddr).getVaultPoints(seasonStartYear_, roundNumber, address(this));

        if (s == 0 || S == 0 || m == 0) {
            _setClaimed(user, claimKey);
            if (revertOnEmpty) revert Errors.NothingToClaim();
            return 0;
        }

        _setClaimed(user, claimKey);
        payout = IPbrTreasury(treasuryAddr).payClaim(seasonStartYear_, roundNumber, user);
        emit Events.Claimed(user, tournamentId_, seasonStartYear_, roundNumber, payout);
    }

    function _lockedBalance(address user) internal view returns (uint256 locked) {
        uint256 length = _utilizedRounds.length;
        for (uint256 i; i < length; ++i) {
            RoundKey memory key = _utilizedRounds[i];
            address treasuryAddr = key.treasury;
            if (treasuryAddr == address(0)) continue;

            (RoundStatus status, uint64 lockBlock) =
                IPbrTreasury(treasuryAddr).getRoundClaimMeta(key.seasonStartYear, key.roundNumber);
            if (status != RoundStatus.Locked && status != RoundStatus.SettlePending) continue;

            uint256 cutBal = IStakedToken(stToken).balanceOfAt(user, lockBlock);
            if (cutBal > locked) locked = cutBal;
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
