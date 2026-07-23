// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";

import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@events/vaults/VaultsEvents.sol";
import { RoundSchedule } from "@types/TournamentTypes.sol";
import { RoundState, RoundStatus } from "@types/vaults/VaultTypes.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { IPlayerVault } from "@interfaces/vaults/IPlayerVault.sol";

/**
 * @title PbrTreasury
 * @notice Single-tournament PBR pot: fee accrual, lock / snapshot / settle, pull claims.
 * @dev One deployment per `tournamentId`. Fees arrive from `PbrFeeHub` (or directly).
 *
 *      Access:
 *      - `CATEGORY_THREE` (`Automator`): `settle`.
 *      - `CATEGORY_THREE` or `CATEGORY_TWO` (`MaintenanceTimelock`): `registerVault` /
 *        `unregisterVault` (automator path + manual repair).
 *
 *      Vault registration is the source of truth for this tournament's participants: each
 *      register/unregister also syncs `PlayerSetRegistry` active-tournament flags.
 *
 *      Crank: `lock()` → `snapshotBatch()` → `settle(...)`.
 *      Wrap: lock of `finalRound` sets `tradingRound = 1`; settle advances `seasonId`.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrTreasury is Initializable, AccessControl, ReentrancyGuard, IPbrTreasury {
    // --------------------------------------------
    //  Internal Constants
    // --------------------------------------------

    uint256 public constant SNAPSHOT_BATCH_SIZE = 50;

    /// @notice Share of `rewardsR` frozen into each non-final round (remainder rolls forward).
    uint256 public constant LOCK_BPS = 8000;

    // --------------------------------------------
    //  Storage
    // --------------------------------------------

    ITournamentRegistry public immutable tournamentRegistry;
    IPlayerSetRegistry public immutable playerSetRegistry;

    bytes32 public tournamentId;

    uint16 public seasonId;
    uint32 public activeRound;
    uint32 public tradingRound;

    /// @notice Accruing pot for `tradingRound` (pre-freeze)
    uint256 public rewardsR;

    /// @notice Accruing + frozen-but-unpaid allocation accounting
    uint256 public totalRewardsR;

    mapping(uint16 season => mapping(uint32 roundNumber => RoundState)) private _rounds;
    mapping(uint16 season => mapping(uint32 roundNumber => mapping(address vault => uint256))) public vaultPoints;

    mapping(address vault => bool) public isVault;
    address[] private _vaults;
    mapping(address vault => uint256) private _vaultIndex; // 1-based

    uint256 public snapshotCursor;
    bool public snapshotPending;

    // --------------------------------------------
    //  Access
    // --------------------------------------------

    /// @dev ConstitutionalTimelock (cat-1) for initialization.
    /// @dev MaintenanceTimelock (cat-2) for manual overrides.
    /// @dev Automator (cat-3) for per-tournament data upserts.
    modifier onlyAdmin() {
        address sender = _msgSender();
        if (
            !hasRole(Roles.CATEGORY_ONE, sender) && !hasRole(Roles.CATEGORY_TWO, sender)
                && !hasRole(Roles.CATEGORY_THREE, sender)
        ) {
            revert Errors.Unauthorized();
        }
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address tournamentRegistry_, address playerSetRegistry_) {
        if (tournamentRegistry_ == address(0) || playerSetRegistry_ == address(0)) revert Errors.ZeroAddress();
        tournamentRegistry = ITournamentRegistry(tournamentRegistry_);
        playerSetRegistry = IPlayerSetRegistry(playerSetRegistry_);
        _disableInitializers();
    }

    /**
     * @param automator_ `Automator` — `CATEGORY_THREE`.
     * @param maintenanceTimelock_ `MaintenanceTimelock` — `CATEGORY_TWO`.
     * @param dao_ Aragon DAO — `DEFAULT_ADMIN_ROLE`.
     * @param deployTournament_ `DeployTournament` — `CATEGORY_THREE` (bootstrap vault registration).
     * @param tournamentId_ Sole tournament this treasury serves.
     * @param initialSeason_ Starting season (e.g. 2025).
     */
    function initialize(
        address automator_,
        address maintenanceTimelock_,
        address dao_,
        address deployTournament_,
        bytes32 tournamentId_,
        uint16 initialSeason_
    ) external initializer {
        if (
            automator_ == address(0) || maintenanceTimelock_ == address(0) || dao_ == address(0)
                || deployTournament_ == address(0)
        ) {
            revert Errors.ZeroAddress();
        }
        if (tournamentId_ == bytes32(0)) revert Errors.ZeroId();
        if (initialSeason_ == 0) revert Errors.ZeroSeason();

        tournamentId = tournamentId_;
        seasonId = initialSeason_;
        activeRound = 1;
        tradingRound = 1;

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_ONE, deployTournament_);
        _grantRole(Roles.CATEGORY_TWO, maintenanceTimelock_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
    }

    receive() external payable nonReentrant {
        if (msg.value == 0) return;
        rewardsR += msg.value;
        totalRewardsR += msg.value;
        emit Events.FeesReceived(msg.value);
    }

    // --------------------------------------------
    //  Player Vault Registration
    // --------------------------------------------

    /// @notice Bulk `registerVault` for tournament bootstrap.
    function registerVaults(address[] calldata vaults) external onlyAdmin {
        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            _registerVault(vaults[i]);
        }
    }

    /// @notice Bulk `unregisterVault` (e.g. knockout eliminations after round ingest).
    function unregisterVaults(address[] calldata vaults) external onlyAdmin {
        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            _unregisterVault(vaults[i]);
        }
    }

    function _registerVault(address vault) internal {
        if (vault == address(0)) revert Errors.ZeroAddress();
        if (vault.code.length == 0) revert Errors.UnknownVault(vault);
        if (isVault[vault]) revert Errors.VaultAlreadyRegistered(vault);
        if (playerSetRegistry.playerIdOfVault(vault) == bytes32(0)) revert Errors.UnknownVault(vault);

        isVault[vault] = true;
        _vaults.push(vault);
        _vaultIndex[vault] = _vaults.length;
        emit Events.VaultRegistered(vault);

        playerSetRegistry.addActiveTournamentForVault(vault, tournamentId);
    }

    function _unregisterVault(address vault) internal {
        if (!isVault[vault]) revert Errors.UnknownVault(vault);

        uint256 index0 = _vaultIndex[vault] - 1;
        uint256 last = _vaults.length - 1;
        if (index0 != last) {
            address moved = _vaults[last];
            _vaults[index0] = moved;
            _vaultIndex[moved] = index0 + 1;
        }
        _vaults.pop();
        delete _vaultIndex[vault];
        isVault[vault] = false;
        emit Events.VaultUnregistered(vault);

        playerSetRegistry.removeActiveTournamentForVault(vault, tournamentId);
    }

    // --------------------------------------------
    //  mwStartTime
    // --------------------------------------------

    /// @notice Freeze a share of `rewardsR` into the active round when published and due.
    /// @dev Non-final rounds lock `LOCK_BPS` (80%); the final round freezes 100%. Remainder stays in `rewardsR`.
    function lock() external {
        if (tradingRound != activeRound) revert Errors.NothingDue();

        uint16 season = seasonId;
        uint32 roundNumber = activeRound;
        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.None) {
            revert Errors.BadRoundStatus(season, roundNumber, round.status, RoundStatus.None);
        }

        bytes32 tid = tournamentId;
        if (!tournamentRegistry.isRoundPublished(tid, season, roundNumber)) revert Errors.NothingDue();

        RoundSchedule memory schedule = tournamentRegistry.getRound(tid, season, roundNumber);
        if (block.timestamp < schedule.startTime) revert Errors.NothingDue();

        uint32 finalRound = tournamentRegistry.getFinalRound(tid, season);
        if (finalRound == 0) revert Errors.NothingDue();

        uint256 pot = rewardsR;
        uint256 R = roundNumber >= finalRound ? pot : Math.mulDiv(pot, LOCK_BPS, 10_000);
        rewardsR = pot - R;

        round.status = RoundStatus.Locked;
        round.R = R;
        round.startTime = schedule.startTime;
        round.endTime = schedule.endTime;

        tradingRound = roundNumber >= finalRound ? 1 : roundNumber + 1;
        snapshotCursor = 0;
        snapshotPending = true;

        emit Events.RoundLocked(season, roundNumber, R, round.startTime, round.endTime, tradingRound);
    }

    /// @notice Page vault snapshots for the locked active round (50 per call).
    function snapshotBatch() external returns (uint256 processed, bool done) {
        if (!snapshotPending) revert Errors.NothingToSnapshot();

        uint16 season = seasonId;
        uint32 roundNumber = activeRound;
        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.Locked) {
            revert Errors.BadRoundStatus(season, roundNumber, round.status, RoundStatus.Locked);
        }

        uint256 length = _vaults.length;
        uint256 cursor = snapshotCursor;
        if (cursor >= length) {
            snapshotPending = false;
            emit Events.SnapshotBatchProgress(season, roundNumber, cursor, true);
            return (0, true);
        }

        uint256 end = cursor + SNAPSHOT_BATCH_SIZE;
        if (end > length) end = length;

        bytes32 tid = tournamentId;
        for (uint256 i = cursor; i < end;) {
            address vault = _vaults[i];
            IPlayerVault playerVault = IPlayerVault(vault);
            if (playerVault.snapIdOf(tid, season, roundNumber) == 0) {
                uint256 snapId = playerVault.snapshot(tid, season, roundNumber);
                emit Events.VaultSnapshotted(season, roundNumber, vault, snapId);
            }
            unchecked {
                ++i;
                ++processed;
            }
        }

        snapshotCursor = end;
        done = end >= length;
        if (done) snapshotPending = false;
        emit Events.SnapshotBatchProgress(season, roundNumber, end, done);
    }

    // --------------------------------------------
    //  mwEndTime
    // --------------------------------------------

    function settle(
        address[] calldata vaults,
        uint256[] calldata mwPoints,
        uint256 adjTotalPoints
    ) external onlyRole(Roles.CATEGORY_THREE) {
        if (vaults.length != mwPoints.length) revert Errors.LengthMismatch();
        if (adjTotalPoints == 0) revert Errors.ZeroMAdj();

        uint16 season = seasonId;
        uint32 roundNumber = activeRound;
        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.Locked) {
            revert Errors.BadRoundStatus(season, roundNumber, round.status, RoundStatus.Locked);
        }
        if (block.timestamp < round.endTime) {
            revert Errors.RoundNotEnded(season, roundNumber, round.endTime, block.timestamp);
        }

        uint256 length = vaults.length;
        for (uint256 i; i < length; ++i) {
            if (!isVault[vaults[i]]) revert Errors.UnknownVault(vaults[i]);
            vaultPoints[season][roundNumber][vaults[i]] = mwPoints[i];
        }

        round.M_adj = adjTotalPoints;
        round.status = RoundStatus.Claimable;
        snapshotPending = false;

        uint32 finalRound = tournamentRegistry.getFinalRound(tournamentId, season);
        if (roundNumber >= finalRound && finalRound != 0) {
            activeRound = 1;
            uint16 newSeason = season + 1;
            seasonId = newSeason;
            emit Events.SeasonWrapped(season, newSeason);
        } else {
            activeRound = tradingRound;
        }

        emit Events.RoundSettled(season, roundNumber, adjTotalPoints, length);
    }

    // --------------------------------------------
    //  Distribution
    // --------------------------------------------

    function payClaim(
        uint16 season,
        uint32 roundNumber,
        address user,
        uint256 s,
        uint256 S
    ) external nonReentrant returns (uint256 payout) {
        if (!isVault[msg.sender]) revert Errors.UnknownVault(msg.sender);
        if (user == address(0)) revert Errors.ZeroAddress();

        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.Claimable) {
            revert Errors.BadRoundStatus(season, roundNumber, round.status, RoundStatus.Claimable);
        }
        if (s == 0 || S == 0 || round.R == 0) revert Errors.NothingToClaim();

        uint256 m = vaultPoints[season][roundNumber][msg.sender];
        if (m == 0) revert Errors.NothingToClaim();

        payout = Math.mulDiv(Math.mulDiv(round.R, m, round.M_adj), s, S);
        if (payout == 0) revert Errors.NothingToClaim();

        uint256 newPaid = round.paid + payout;
        if (newPaid > round.R) revert Errors.InsufficientRoundFunds();

        round.paid = newPaid;
        totalRewardsR -= payout;

        (bool ok,) = user.call{ value: payout }("");
        if (!ok) revert Errors.TransferFailed();

        emit Events.ClaimPaid(season, roundNumber, msg.sender, user, payout);
    }

    // --------------------------------------------
    //  External View
    // --------------------------------------------

    function getRound(uint16 season, uint32 roundNumber) external view returns (RoundState memory) {
        return _rounds[season][roundNumber];
    }

    function getVaultPoints(uint16 season, uint32 roundNumber, address vault) external view returns (uint256) {
        return vaultPoints[season][roundNumber][vault];
    }

    function getVaults() external view returns (address[] memory) {
        return _vaults;
    }

    function getCursors() external view returns (uint16 season, uint32 active, uint32 trading) {
        return (seasonId, activeRound, tradingRound);
    }

    function previewClaim(
        uint16 season,
        uint32 roundNumber,
        address vault,
        uint256 s,
        uint256 S
    ) external view returns (uint256 payout) {
        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.Claimable || s == 0 || S == 0 || round.R == 0) return 0;
        uint256 m = vaultPoints[season][roundNumber][vault];
        if (m == 0) return 0;
        payout = Math.mulDiv(Math.mulDiv(round.R, m, round.M_adj), s, S);
        uint256 remaining = round.R - round.paid;
        if (payout > remaining) payout = remaining;
    }
}
