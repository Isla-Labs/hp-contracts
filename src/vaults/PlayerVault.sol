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
import { TournamentData } from "@types/registries/PlayerSetTypes.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IStakedToken } from "@interfaces/vaults/IStakedToken.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { IPlayerVault } from "@interfaces/vaults/IPlayerVault.sol";

/**
 * @title PlayerVault
 * @notice Stake custody; mirrors `S` to active treasuries; claims use `lockBlock` checkpoints.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVault is Initializable, AddressBook, Ownable, Pausable, ReentrancyGuard, IPlayerVault {
    using SafeERC20 for IERC20;

    ITournamentRegistry public tournamentRegistry;
    IPlayerSetRegistry public playerSetRegistry;

    bytes32 public playerId;
    address public playerToken;
    address public stToken;
    uint256 public totalStaked;

    bool public isActive;

    mapping(address user => mapping(uint256 word => uint256)) public claimedWords;

    struct RoundKey {
        bytes32 tournamentId;
        uint16 seasonId;
        uint32 roundNumber;
    }

    RoundKey[] private _utilizedRounds;
    mapping(bytes32 tournamentId => mapping(uint16 seasonId => mapping(uint32 roundNumber => bool))) private
        _notedRound;

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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setActive(bool active_) external {
        _checkLifecycleCaller();
        isActive = active_;
        emit Events.ActiveUpdated(playerId, active_);
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
    function noteUtilizedRound(bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber) external {
        address treasury = tournamentRegistry.getPbrTreasury(tournamentId_);
        if (treasury == address(0) || msg.sender != treasury) revert Errors.OnlyTournamentTreasury();
        _noteRound(tournamentId_, seasonId_, roundNumber);
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
        uint256 length = _utilizedRounds.length;
        for (uint256 i; i < length; ++i) {
            RoundKey memory key = _utilizedRounds[i];
            address treasuryAddr = tournamentRegistry.getPbrTreasury(key.tournamentId);
            if (treasuryAddr == address(0)) continue;
            if (IPbrTreasury(treasuryAddr).getRound(key.seasonId, key.roundNumber).status != RoundStatus.Claimable) {
                continue;
            }
            if (_isClaimed(user, _claimKey(key.tournamentId, key.seasonId, key.roundNumber))) continue;
            totalPayout += _claim(user, key.tournamentId, key.seasonId, key.roundNumber, false);
        }
    }

    function lockedBalance(address user) external view returns (uint256) {
        return _lockedBalance(user);
    }

    function utilizedRoundCount() external view returns (uint256) {
        return _utilizedRounds.length;
    }

    function utilizedRoundAt(uint256 index)
        external
        view
        returns (bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber)
    {
        RoundKey memory key = _utilizedRounds[index];
        return (key.tournamentId, key.seasonId, key.roundNumber);
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
        TournamentData memory data = playerSetRegistry.getTournamentData(playerId);
        uint256 n = data.activeTournaments.length;
        for (uint256 i; i < n;) {
            bytes32 tid = data.activeTournaments[i];
            address treasuryAddr = tournamentRegistry.getPbrTreasury(tid);
            if (treasuryAddr != address(0)) {
                (uint16 season, uint32 roundNumber, bool joined) =
                    IPbrTreasury(treasuryAddr).syncVaultStake(newTotalStaked);
                if (joined) _noteRound(tid, season, roundNumber);
            }
            unchecked {
                ++i;
            }
        }
    }

    function _noteRound(bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber) internal {
        if (_notedRound[tournamentId_][seasonId_][roundNumber]) return;
        _notedRound[tournamentId_][seasonId_][roundNumber] = true;
        _utilizedRounds.push(RoundKey({ tournamentId: tournamentId_, seasonId: seasonId_, roundNumber: roundNumber }));
    }

    function _claim(
        address user,
        bytes32 tournamentId_,
        uint16 seasonId_,
        uint32 roundNumber,
        bool revertOnEmpty
    ) internal returns (uint256 payout) {
        if (!_notedRound[tournamentId_][seasonId_][roundNumber]) {
            revert Errors.RoundNotUtilized(tournamentId_, seasonId_, roundNumber);
        }

        uint256 claimKey = _claimKey(tournamentId_, seasonId_, roundNumber);
        if (_isClaimed(user, claimKey)) revert Errors.AlreadyClaimed();

        address treasuryAddr = tournamentRegistry.getPbrTreasury(tournamentId_);
        if (treasuryAddr == address(0)) revert Errors.UnknownTournamentTreasury(tournamentId_);

        IPbrTreasury treasury = IPbrTreasury(treasuryAddr);
        uint64 lockBlock = treasury.getRound(seasonId_, roundNumber).lockBlock;
        uint256 s = IStakedToken(stToken).balanceOfAt(user, lockBlock);
        uint256 S = IStakedToken(stToken).totalSupplyAt(lockBlock);
        uint256 m = treasury.getVaultPoints(seasonId_, roundNumber, address(this));

        if (s == 0 || S == 0 || m == 0) {
            _setClaimed(user, claimKey);
            if (revertOnEmpty) revert Errors.NothingToClaim();
            return 0;
        }

        _setClaimed(user, claimKey);
        payout = treasury.payClaim(seasonId_, roundNumber, user, s, S);
        emit Events.Claimed(user, tournamentId_, seasonId_, roundNumber, payout);
    }

    function _lockedBalance(address user) internal view returns (uint256 locked) {
        uint256 length = _utilizedRounds.length;
        for (uint256 i; i < length; ++i) {
            RoundKey memory key = _utilizedRounds[i];
            address treasuryAddr = tournamentRegistry.getPbrTreasury(key.tournamentId);
            if (treasuryAddr == address(0)) continue;

            RoundStatus status = IPbrTreasury(treasuryAddr).getRound(key.seasonId, key.roundNumber).status;
            if (status != RoundStatus.Locked && status != RoundStatus.SettlePending) continue;

            uint64 lockBlock = IPbrTreasury(treasuryAddr).getRound(key.seasonId, key.roundNumber).lockBlock;
            uint256 cutBal = IStakedToken(stToken).balanceOfAt(user, lockBlock);
            if (cutBal > locked) locked = cutBal;
        }
    }

    function _claimKey(bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(tournamentId_, seasonId_, roundNumber)));
    }

    function _isClaimed(address user, uint256 claimKey) internal view returns (bool) {
        return (claimedWords[user][claimKey >> 8] & (uint256(1) << (claimKey & 0xff))) != 0;
    }

    function _setClaimed(address user, uint256 claimKey) internal {
        claimedWords[user][claimKey >> 8] |= uint256(1) << (claimKey & 0xff);
    }
}
