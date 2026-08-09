// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/utils/math/Math.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { VaultsErrors as Errors } from "@errors/vaults/VaultsErrors.sol";
import { VaultsEvents as Events } from "@events/vaults/VaultsEvents.sol";
import { RoundSchedule } from "@types/registries/TournamentTypes.sol";
import { RoundState, RoundStatus } from "@types/vaults/VaultTypes.sol";
import { ITournamentRegistry } from "@interfaces/ITournamentRegistry.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { IPbrSettle } from "@interfaces/data/IPbrSettle.sol";
import { IPbrTreasury } from "@interfaces/vaults/IPbrTreasury.sol";
import { IPlayerVault } from "@interfaces/vaults/IPlayerVault.sol";

/**
 * @title PbrTreasury
 * @notice Single-tournament PBR pot: O(1) lock / per-fixture zk settle / pull claims.
 * @dev Crank: `lockVaults` → `requestSettle` → `applyFixtureSettlement`* → Claimable.
 *      Vaults push live `S` via `syncVaultStake`; cut-off is `lockBlock` on stToken checkpoints.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract PbrTreasury is Initializable, AddressBook, Ownable, ReentrancyGuard, IPbrTreasury {
    uint256 public constant MAX_FIXTURE_PLAYERS = 32;
    uint256 public constant LOCK_BPS = 8000;

    ITournamentRegistry public tournamentRegistry;
    IPlayerSetRegistry public playerSetRegistry;

    bytes32 public tournamentId;

    uint16 public seasonId;
    uint32 public activeRound;
    uint32 public tradingRound;

    uint256 public rewardsR;
    uint256 public totalRewardsR;

    mapping(uint16 season => mapping(uint32 roundNumber => RoundState)) private _rounds;
    mapping(uint16 season => mapping(uint32 roundNumber => mapping(address vault => uint256))) public vaultPoints;

    mapping(address vault => bool) public isVault;
    address[] private _vaults;
    mapping(address vault => uint256) private _vaultIndex; // 1-based

    mapping(uint16 season => mapping(uint32 roundNumber => address[])) private _utilizedVaults;
    mapping(uint16 season => mapping(uint32 roundNumber => mapping(address vault => bool))) private _isUtilized;
    mapping(uint16 season => mapping(uint32 roundNumber => mapping(address vault => uint256))) private _utilizedIndex; // 1-based

    mapping(uint16 season => mapping(uint32 roundNumber => mapping(bytes32 fixtureId => bool))) private _fixtureExpected;
    mapping(uint16 season => mapping(uint32 roundNumber => mapping(bytes32 fixtureId => bool))) private _fixtureSettled;
    mapping(uint16 season => mapping(uint32 roundNumber => mapping(bytes32 fixtureId => bytes32))) public fixtureDigestOf;

    address public pbrSettle;

    modifier onlyTournamentRegistry() {
        if (msg.sender != address(tournamentRegistry)) revert Errors.Unauthorized();
        _;
    }

    modifier onlyPbrSettle() {
        if (msg.sender != pbrSettle) revert Errors.Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(bytes32 tournamentId_, uint16 initialSeason_) external initializer {
        if (tournamentId_ == bytes32(0)) revert Errors.ZeroId();
        if (initialSeason_ == 0) revert Errors.ZeroSeason();

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        address pbrSettle_ = addressProvider.get(_addressKey(Addresses.PBR_SETTLE));
        if (pbrSettle_ != address(0)) pbrSettle = pbrSettle_;

        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));

        tournamentId = tournamentId_;
        seasonId = initialSeason_;
        activeRound = 1;
        tradingRound = 1;
    }

    receive() external payable nonReentrant {
        if (msg.value == 0) return;
        rewardsR += msg.value;
        totalRewardsR += msg.value;
        emit Events.FeesReceived(msg.value);
    }

    // --------------------------------------------
    //  Vault cache
    // --------------------------------------------

    function syncRegisterVault(address vault) external onlyTournamentRegistry {
        if (vault == address(0)) revert Errors.ZeroAddress();
        if (isVault[vault]) revert Errors.VaultAlreadyRegistered(vault);

        isVault[vault] = true;
        _vaults.push(vault);
        _vaultIndex[vault] = _vaults.length;
        emit Events.VaultRegistered(vault);

        uint256 S = IPlayerVault(vault).totalStaked();
        if (S > 0) {
            (uint16 season, uint32 roundNumber) = _stakeTarget();
            _setUtilized(season, roundNumber, vault, true);
            IPlayerVault(vault).noteUtilizedRound(tournamentId, season, roundNumber);
        }
    }

    function syncUnregisterVault(address vault) external onlyTournamentRegistry {
        if (!isVault[vault]) revert Errors.UnknownVault(vault);

        (uint16 season, uint32 roundNumber) = _stakeTarget();
        if (_isUtilized[season][roundNumber][vault]) {
            _setUtilized(season, roundNumber, vault, false);
        }

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
    }

    /**
     * @notice Push live vault `S`. Updates utilized membership for the open stake-target round.
     * @dev Only registered vaults. While active round is Locked/SettlePending, writes go to `tradingRound`.
     *      Caller vault should `noteUtilizedRound` when `joined` (avoids reentrancy into vault stake).
     */
    function syncVaultStake(uint256 newTotalStaked)
        external
        returns (uint16 season, uint32 roundNumber, bool joined)
    {
        if (!isVault[msg.sender]) revert Errors.UnknownVault(msg.sender);
        (season, roundNumber) = _stakeTarget();

        bool was = _isUtilized[season][roundNumber][msg.sender];
        bool isUtil = newTotalStaked > 0;
        if (was != isUtil) {
            _setUtilized(season, roundNumber, msg.sender, isUtil);
            joined = isUtil;
        }
    }

    /// @dev Round that accepts live stake membership updates.
    function _stakeTarget() internal view returns (uint16 season, uint32 roundNumber) {
        season = seasonId;
        uint32 active = activeRound;
        RoundStatus status = _rounds[season][active].status;
        if (status == RoundStatus.None) {
            roundNumber = active;
        } else {
            // Locked / SettlePending / Claimable (briefly): build next trading round set.
            roundNumber = tradingRound;
        }
    }

    function _setUtilized(uint16 season, uint32 roundNumber, address vault, bool utilized) internal {
        if (utilized) {
            if (_isUtilized[season][roundNumber][vault]) return;
            _isUtilized[season][roundNumber][vault] = true;
            _utilizedVaults[season][roundNumber].push(vault);
            _utilizedIndex[season][roundNumber][vault] = _utilizedVaults[season][roundNumber].length;
        } else {
            if (!_isUtilized[season][roundNumber][vault]) return;
            uint256 index0 = _utilizedIndex[season][roundNumber][vault] - 1;
            address[] storage list = _utilizedVaults[season][roundNumber];
            uint256 last = list.length - 1;
            if (index0 != last) {
                address moved = list[last];
                list[index0] = moved;
                _utilizedIndex[season][roundNumber][moved] = index0 + 1;
            }
            list.pop();
            delete _utilizedIndex[season][roundNumber][vault];
            _isUtilized[season][roundNumber][vault] = false;
        }
    }

    // --------------------------------------------
    //  Lock
    // --------------------------------------------

    /**
     * @notice Freeze rewards and stake cut-off for the active round.
     * @dev O(1): sets `lockBlock = block.number - 1` (or 0 on genesis). Utilized set is already mirrored.
     */
    function lockVaults() external {
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
        round.lockBlock = block.number == 0 ? 0 : uint64(block.number - 1);

        tradingRound = roundNumber >= finalRound ? 1 : roundNumber + 1;

        emit Events.RoundLocked(season, roundNumber, R, round.startTime, round.endTime, tradingRound);
    }

    // --------------------------------------------
    //  Settle (per-fixture zk)
    // --------------------------------------------

    function requestSettle() external returns (bytes32[] memory requestIds) {
        address settle_ = pbrSettle;
        if (settle_ == address(0)) revert Errors.ZeroAddress();

        uint16 season = seasonId;
        uint32 roundNumber = activeRound;
        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.Locked) {
            revert Errors.BadRoundStatus(season, roundNumber, round.status, RoundStatus.Locked);
        }
        if (block.timestamp < round.endTime) {
            revert Errors.RoundNotEnded(season, roundNumber, round.endTime, block.timestamp);
        }

        bytes32 utilizedHash = keccak256(abi.encode(_utilizedVaults[season][roundNumber]));
        round.status = RoundStatus.SettlePending;

        if (_utilizedVaults[season][roundNumber].length == 0) {
            round.M_adj = 0;
            round.fixturesExpected = 0;
            round.fixturesSettled = 0;
            emit Events.RoundSettleRequested(season, roundNumber, settle_, utilizedHash, 0);
            _openClaimable(season, roundNumber, round, 0);
            return requestIds;
        }

        RoundSchedule memory schedule = tournamentRegistry.getRound(tournamentId, season, roundNumber);
        uint256 fixtureCount = schedule.fixtureIds.length;
        if (fixtureCount == 0) revert Errors.NoFixtures();

        round.fixturesExpected = uint32(fixtureCount);
        round.fixturesSettled = 0;
        for (uint256 i; i < fixtureCount;) {
            bytes32 fixtureId = schedule.fixtureIds[i];
            if (fixtureId == bytes32(0)) revert Errors.NoFixtures();
            _fixtureExpected[season][roundNumber][fixtureId] = true;
            unchecked {
                ++i;
            }
        }

        requestIds = IPbrSettle(settle_).startRound(tournamentId, season, roundNumber, utilizedHash);
        emit Events.RoundSettleRequested(season, roundNumber, settle_, utilizedHash, uint32(fixtureCount));
    }

    function applyFixtureSettlement(
        bytes32 fixtureId,
        bytes32 fixtureDigest,
        address[] calldata vaults,
        uint256[] calldata mwPoints
    ) external onlyPbrSettle returns (bool done) {
        if (fixtureId == bytes32(0) || fixtureDigest == bytes32(0)) revert Errors.ZeroId();
        if (vaults.length != mwPoints.length) revert Errors.LengthMismatch();
        if (vaults.length > MAX_FIXTURE_PLAYERS) revert Errors.TooManyPlayers(vaults.length);

        uint16 season = seasonId;
        uint32 roundNumber = activeRound;
        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.SettlePending) {
            revert Errors.BadRoundStatus(season, roundNumber, round.status, RoundStatus.SettlePending);
        }
        if (!_fixtureExpected[season][roundNumber][fixtureId]) revert Errors.UnknownFixture(fixtureId);
        if (_fixtureSettled[season][roundNumber][fixtureId]) revert Errors.FixtureAlreadySettled(fixtureId);

        _fixtureSettled[season][roundNumber][fixtureId] = true;
        fixtureDigestOf[season][roundNumber][fixtureId] = fixtureDigest;

        uint256 written;
        uint256 added;
        for (uint256 i; i < vaults.length;) {
            address vault = vaults[i];
            if (vault == address(0)) revert Errors.ZeroAddress();
            if (_isUtilized[season][roundNumber][vault]) {
                uint256 m = mwPoints[i];
                vaultPoints[season][roundNumber][vault] += m;
                added += m;
                unchecked {
                    ++written;
                }
            }
            unchecked {
                ++i;
            }
        }

        round.M_adj += added;
        unchecked {
            ++round.fixturesSettled;
        }

        done = round.fixturesSettled >= round.fixturesExpected;
        emit Events.FixtureSettlementApplied(
            season, roundNumber, fixtureId, fixtureDigest, written, round.M_adj, done
        );

        if (done) {
            _openClaimable(season, roundNumber, round, _utilizedVaults[season][roundNumber].length);
        }
    }

    function _openClaimable(
        uint16 season,
        uint32 roundNumber,
        RoundState storage round,
        uint256 utilizedCount
    ) internal {
        round.status = RoundStatus.Claimable;

        uint32 finalRound = tournamentRegistry.getFinalRound(tournamentId, season);
        if (roundNumber >= finalRound && finalRound != 0) {
            activeRound = 1;
            uint16 newSeason = season + 1;
            seasonId = newSeason;
            emit Events.SeasonWrapped(season, newSeason);
        } else {
            activeRound = tradingRound;
        }

        emit Events.RoundSettled(season, roundNumber, round.M_adj, utilizedCount);
        tournamentRegistry.flushPendingUnregisters(tournamentId);
    }

    // --------------------------------------------
    //  Claims
    // --------------------------------------------

    function payClaim(
        uint16 season,
        uint32 roundNumber,
        address user,
        uint256 s,
        uint256 S
    ) external nonReentrant returns (uint256 payout) {
        if (user == address(0)) revert Errors.ZeroAddress();

        RoundState storage round = _rounds[season][roundNumber];
        if (round.status != RoundStatus.Claimable) {
            revert Errors.BadRoundStatus(season, roundNumber, round.status, RoundStatus.Claimable);
        }
        if (s == 0 || S == 0 || round.R == 0 || round.M_adj == 0) revert Errors.NothingToClaim();

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
    //  Views
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

    function getUtilizedVaults(uint16 season, uint32 roundNumber) external view returns (address[] memory) {
        return _utilizedVaults[season][roundNumber];
    }

    function isFixtureSettled(uint16 season, uint32 roundNumber, bytes32 fixtureId) external view returns (bool) {
        return _fixtureSettled[season][roundNumber][fixtureId];
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
        if (round.status != RoundStatus.Claimable || s == 0 || S == 0 || round.R == 0 || round.M_adj == 0) return 0;
        uint256 m = vaultPoints[season][roundNumber][vault];
        if (m == 0) return 0;
        payout = Math.mulDiv(Math.mulDiv(round.R, m, round.M_adj), s, S);
        uint256 remaining = round.R - round.paid;
        if (payout > remaining) payout = remaining;
    }
}