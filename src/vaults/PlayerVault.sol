// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { Pausable } from "@openzeppelin/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AccessRoles as Roles } from "@base/global/libraries/roles/AccessRoles.sol";
import { VaultsErrors as Errors } from "@base/global/libraries/errors/VaultsErrors.sol";
import { VaultsEvents as Events } from "@base/global/libraries/events/VaultsEvents.sol";
import { RoundStatus } from "@base/global/types/VaultTypes.sol";
import { TournamentRegistry } from "@src/TournamentRegistry.sol";
import { IStakedToken } from "@base/global/interfaces/IStakedToken.sol";
import { PbrTreasury } from "@vaults/PbrTreasury.sol";

/**
 * @title PlayerVault
 * @notice Stake custody + per-(tournament, season, round) snapshots; claims against each tournament treasury.
 * @dev Snapshot callers must be `TournamentRegistry.getPbrTreasury(tournamentId)`.
 *      `DEFAULT_ADMIN_ROLE` (DAO) may pause/unpause user stake and claim flows.
 *      `CATEGORY_THREE` (`Automator`) or `CATEGORY_TWO` (`MaintenanceTimelock`) may toggle
 *      `isActive` for lifecycle support / discontinuation (or manual repair).
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PlayerVault is Initializable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    TournamentRegistry public tournamentRegistry;

    bytes32 public playerId;
    address public playerToken;
    address public stToken;
    uint256 public totalStaked;

    /// @notice When false, new stakes are rejected (unsupported / discontinued market).
    bool public isActive;

    mapping(bytes32 tournamentId => mapping(uint16 seasonId => mapping(uint32 roundNumber => uint256 snapId))) public
        snapIdOf;
    mapping(address user => mapping(uint256 word => uint256)) public claimedWords;

    struct RoundKey {
        bytes32 tournamentId;
        uint16 seasonId;
        uint32 roundNumber;
    }

    RoundKey[] private _snapRounds;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    /// @dev Automator (cat-3) or MaintenanceTimelock (cat-2) for lifecycle / manual repair.
    modifier onlyCategoryTwoOrThree() {
        address sender = _msgSender();
        if (!hasRole(Roles.CATEGORY_TWO, sender) && !hasRole(Roles.CATEGORY_THREE, sender)) {
            revert Errors.Unauthorized();
        }
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @param automator_ `Automator` — `CATEGORY_THREE`.
     * @param maintenanceTimelock_ `MaintenanceTimelock` — `CATEGORY_TWO`.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE` (pause / role admin).
     */
    function initialize(
        address automator_,
        address maintenanceTimelock_,
        address dao_,
        address tournamentRegistry_,
        bytes32 playerId_,
        address playerToken_,
        address stToken_
    ) external initializer {
        if (
            automator_ == address(0) || maintenanceTimelock_ == address(0) || dao_ == address(0)
                || tournamentRegistry_ == address(0) || playerToken_ == address(0) || stToken_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        if (playerId_ == bytes32(0)) revert Errors.ZeroId();

        tournamentRegistry = TournamentRegistry(tournamentRegistry_);
        playerId = playerId_;
        playerToken = playerToken_;
        stToken = stToken_;
        isActive = true;

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
        _grantRole(Roles.CATEGORY_TWO, maintenanceTimelock_);
    }

    // --------------------------------------------
    //  Pause (DEFAULT_ADMIN_ROLE)
    // --------------------------------------------

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // --------------------------------------------
    //  Lifecycle (CATEGORY_THREE)
    // --------------------------------------------

    /**
     * @notice Mark the vault as supported or unsupported for new stakes.
     * @dev Lifecycle automation (cat-3) or manual maintenance (cat-2).
     *      Unstake and claim remain available when inactive.
     */
    function setActive(bool active_) external onlyCategoryTwoOrThree {
        isActive = active_;
        emit Events.ActiveUpdated(playerId, active_);
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

        totalStaked += amount;
        emit Events.Staked(user, amount, totalStaked);
    }

    function unstake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert Errors.ZeroAmount();

        address user = msg.sender;
        uint256 bal = IStakedToken(stToken).balanceOf(user);
        if (amount > bal) revert Errors.InsufficientStake();
        if (bal - amount < _lockedBalance(user)) revert Errors.MatchweekLock();

        IStakedToken(stToken).burn(user, amount);
        IERC20(playerToken).safeTransfer(user, amount);

        totalStaked -= amount;
        emit Events.Unstaked(user, amount, totalStaked);
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
        _snapRounds.push(RoundKey({ tournamentId: tournamentId_, seasonId: seasonId_, roundNumber: roundNumber }));

        emit Events.SnapshotTaken(
            tournamentId_, seasonId_, roundNumber, snapId, IStakedToken(stToken).totalSupplyAt(snapId)
        );
    }

    // --------------------------------------------
    //  Claim
    // --------------------------------------------

    function claim(bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber)
        external
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
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

            PbrTreasury treasury = PbrTreasury(payable(treasuryAddr));
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

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    function _claim(address user, bytes32 tournamentId_, uint16 seasonId_, uint32 roundNumber, bool revertOnEmpty)
        internal
        returns (uint256 payout)
    {
        uint256 snapId = snapIdOf[tournamentId_][seasonId_][roundNumber];
        if (snapId == 0) revert Errors.NoSnapshot(tournamentId_, seasonId_, roundNumber);
        if (_isClaimed(user, snapId)) revert Errors.AlreadyClaimed();

        address treasuryAddr = tournamentRegistry.getPbrTreasury(tournamentId_);
        if (treasuryAddr == address(0)) revert Errors.UnknownTournamentTreasury(tournamentId_);

        PbrTreasury treasury = PbrTreasury(payable(treasuryAddr));
        uint256 s = IStakedToken(stToken).balanceOfAt(user, snapId);
        uint256 S = IStakedToken(stToken).totalSupplyAt(snapId);
        uint256 m = treasury.getVaultPoints(seasonId_, roundNumber, address(this));

        if (s == 0 || S == 0 || m == 0) {
            _setClaimed(user, snapId);
            if (revertOnEmpty) revert Errors.NothingToClaim();
            return 0;
        }

        _setClaimed(user, snapId);
        payout = treasury.payClaim(seasonId_, roundNumber, user, s, S);
        emit Events.Claimed(user, tournamentId_, seasonId_, roundNumber, payout);
    }

    function _lockedBalance(address user) internal view returns (uint256 locked) {
        uint256 length = _snapRounds.length;
        for (uint256 i; i < length; ++i) {
            RoundKey memory key = _snapRounds[i];
            address treasuryAddr = tournamentRegistry.getPbrTreasury(key.tournamentId);
            if (treasuryAddr == address(0)) continue;

            if (PbrTreasury(payable(treasuryAddr)).getRound(key.seasonId, key.roundNumber).status != RoundStatus.Locked)
            {
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
}
