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
import { IStakedToken } from "@interfaces/vaults/IStakedToken.sol";

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
    /// @notice Non-final rounds lock this share of `rewardsR` (remainder carries forward).
    uint256 public constant LOCK_BPS = 8000;
    /// @notice Final round locks this share so a seed remains for offseason / next season.
    uint256 public constant FINAL_LOCK_BPS = 9500;

    ITournamentRegistry public tournamentRegistry;
    IPlayerSetRegistry public playerSetRegistry;

    bytes32 public tournamentId;

    uint16 public seasonStartYear;
    uint32 public activeRound;
    uint32 public tradingRound;

    uint256 public rewardsR;
    uint256 public totalRewardsR;

    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => RoundState)) private _rounds;
    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => mapping(address vault => uint256))) public
        vaultPoints;

    mapping(address vault => bool) public isVault;
    address[] private _vaults;
    mapping(address vault => uint256) private _vaultIndex; // 1-based

    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => address[])) private _utilizedVaults;
    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => mapping(address vault => bool))) private
        _isUtilized;
    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => mapping(address vault => uint256))) private
        _utilizedIndex; // 1-based

    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => mapping(bytes32 fixtureId => bool))) private
        _fixtureExpected;
    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => mapping(bytes32 fixtureId => bool))) private
        _fixtureSettled;
    mapping(uint16 seasonStartYear => mapping(uint32 roundNumber => mapping(bytes32 fixtureId => bytes32))) public
        fixtureDigestOf;

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

    function initialize(bytes32 tournamentId_, uint16 initialSeasonStartYear_) external initializer {
        if (tournamentId_ == bytes32(0)) revert Errors.ZeroId();
        if (initialSeasonStartYear_ == 0) revert Errors.ZeroSeason();

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
        address pbrSettle_ = addressProvider.get(_addressKey(Addresses.PBR_SETTLE));
        if (pbrSettle_ != address(0)) pbrSettle = pbrSettle_;

        tournamentRegistry = ITournamentRegistry(_getAddress(_addressKey(Addresses.TOURNAMENT_REGISTRY)));
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));

        tournamentId = tournamentId_;
        seasonStartYear = initialSeasonStartYear_;
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

    function syncRegisterVault(address vault_) external onlyTournamentRegistry {
        if (vault_ == address(0)) revert Errors.ZeroAddress();
        if (isVault[vault_]) revert Errors.VaultAlreadyRegistered(vault_);

        isVault[vault_] = true;
        _vaults.push(vault_);
        _vaultIndex[vault_] = _vaults.length;
        emit Events.VaultRegistered(vault_);

        uint256 S = IPlayerVault(vault_).totalStaked();
        if (S > 0) {
            (uint16 seasonStartYear_, uint32 roundNumber_) = _stakeTarget();
            _setUtilized(seasonStartYear_, roundNumber_, vault_, true);
            IPlayerVault(vault_).noteUtilizedRound(tournamentId, seasonStartYear_, roundNumber_);
        }
    }

    function syncUnregisterVault(address vault_) external onlyTournamentRegistry {
        if (!isVault[vault_]) revert Errors.UnknownVault(vault_);

        (uint16 seasonStartYear_, uint32 roundNumber_) = _stakeTarget();
        if (_isUtilized[seasonStartYear_][roundNumber_][vault_]) {
            _setUtilized(seasonStartYear_, roundNumber_, vault_, false);
        }

        uint256 index0 = _vaultIndex[vault_] - 1;
        uint256 last = _vaults.length - 1;
        if (index0 != last) {
            address moved = _vaults[last];
            _vaults[index0] = moved;
            _vaultIndex[moved] = index0 + 1;
        }
        _vaults.pop();
        delete _vaultIndex[vault_];
        isVault[vault_] = false;
        emit Events.VaultUnregistered(vault_);
    }

    /**
     * @notice Push live vault `S`. Updates utilized membership for the open stake-target round.
     * @dev Only registered vaults. While active round is Locked/SettlePending, writes go to `tradingRound`.
     *      Caller vault should `noteUtilizedRound` when `joined` (avoids reentrancy into vault stake).
     */
    function syncVaultStake(uint256 newTotalStaked_)
        external
        returns (uint16 seasonStartYear_, uint32 roundNumber_, bool joined_)
    {
        if (!isVault[msg.sender]) revert Errors.UnknownVault(msg.sender);
        (seasonStartYear_, roundNumber_) = _stakeTarget();

        bool was = _isUtilized[seasonStartYear_][roundNumber_][msg.sender];
        bool isUtil = newTotalStaked_ > 0;
        if (was != isUtil) {
            _setUtilized(seasonStartYear_, roundNumber_, msg.sender, isUtil);
            joined_ = isUtil;
        }
    }

    /// @dev Round that accepts live stake membership updates.
    function _stakeTarget() internal view returns (uint16 seasonStartYear_, uint32 roundNumber_) {
        seasonStartYear_ = seasonStartYear;
        uint32 active = activeRound;
        RoundStatus status = _rounds[seasonStartYear_][active].status;
        if (status == RoundStatus.None) {
            roundNumber_ = active;
        } else {
            // Locked / SettlePending / Claimable (briefly): build next trading round set.
            roundNumber_ = tradingRound;
        }
    }

    function _setUtilized(uint16 seasonStartYear_, uint32 roundNumber_, address vault_, bool utilized_) internal {
        if (utilized_) {
            if (_isUtilized[seasonStartYear_][roundNumber_][vault_]) return;
            _isUtilized[seasonStartYear_][roundNumber_][vault_] = true;
            _utilizedVaults[seasonStartYear_][roundNumber_].push(vault_);
            _utilizedIndex[seasonStartYear_][roundNumber_][vault_] =
            _utilizedVaults[seasonStartYear_][roundNumber_].length;
        } else {
            if (!_isUtilized[seasonStartYear_][roundNumber_][vault_]) return;
            uint256 index0 = _utilizedIndex[seasonStartYear_][roundNumber_][vault_] - 1;
            address[] storage list = _utilizedVaults[seasonStartYear_][roundNumber_];
            uint256 last = list.length - 1;
            if (index0 != last) {
                address moved = list[last];
                list[index0] = moved;
                _utilizedIndex[seasonStartYear_][roundNumber_][moved] = index0 + 1;
            }
            list.pop();
            delete _utilizedIndex[seasonStartYear_][roundNumber_][vault_];
            _isUtilized[seasonStartYear_][roundNumber_][vault_] = false;
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

        uint16 seasonStartYear_ = seasonStartYear;
        uint32 roundNumber_ = activeRound;
        RoundState storage round = _rounds[seasonStartYear_][roundNumber_];
        if (round.status != RoundStatus.None) {
            revert Errors.BadRoundStatus(seasonStartYear_, roundNumber_, round.status, RoundStatus.None);
        }

        bytes32 tid = tournamentId;
        if (!tournamentRegistry.isRoundPublished(tid, seasonStartYear_, roundNumber_)) revert Errors.NothingDue();

        RoundSchedule memory schedule = tournamentRegistry.getRound(tid, seasonStartYear_, roundNumber_);
        if (block.timestamp < schedule.startTime) revert Errors.NothingDue();

        uint32 finalRound = tournamentRegistry.getFinalRound(tid, seasonStartYear_);
        if (finalRound == 0) revert Errors.NothingDue();

        uint256 pot = rewardsR;
        uint256 lockBps = roundNumber_ >= finalRound ? FINAL_LOCK_BPS : LOCK_BPS;
        uint256 R = Math.mulDiv(pot, lockBps, 10_000);
        rewardsR = pot - R;

        round.status = RoundStatus.Locked;
        round.R = R;
        round.startTime = schedule.startTime;
        round.endTime = schedule.endTime;
        round.lockBlock = block.number == 0 ? 0 : uint64(block.number - 1);

        tradingRound = roundNumber_ >= finalRound ? 1 : roundNumber_ + 1;

        emit Events.RoundLocked(seasonStartYear_, roundNumber_, R, round.startTime, round.endTime, tradingRound);
    }

    // --------------------------------------------
    //  Settle (per-fixture zk)
    // --------------------------------------------

    function requestSettle() external returns (bytes32[] memory requestIds_) {
        address settle_ = pbrSettle;
        if (settle_ == address(0)) revert Errors.ZeroAddress();

        uint16 seasonStartYear_ = seasonStartYear;
        uint32 roundNumber_ = activeRound;
        RoundState storage round = _rounds[seasonStartYear_][roundNumber_];
        if (round.status != RoundStatus.Locked) {
            revert Errors.BadRoundStatus(seasonStartYear_, roundNumber_, round.status, RoundStatus.Locked);
        }
        if (block.timestamp < round.endTime) {
            revert Errors.RoundNotEnded(seasonStartYear_, roundNumber_, round.endTime, block.timestamp);
        }

        bytes32 utilizedHash = keccak256(abi.encode(_utilizedVaults[seasonStartYear_][roundNumber_]));
        round.status = RoundStatus.SettlePending;

        if (_utilizedVaults[seasonStartYear_][roundNumber_].length == 0) {
            round.M_adj = 0;
            round.fixturesExpected = 0;
            round.fixturesSettled = 0;
            emit Events.RoundSettleRequested(seasonStartYear_, roundNumber_, settle_, utilizedHash, 0);
            _openClaimable(seasonStartYear_, roundNumber_, round, 0);
            return requestIds_;
        }

        RoundSchedule memory schedule = tournamentRegistry.getRound(tournamentId, seasonStartYear_, roundNumber_);
        uint256 fixtureCount = schedule.fixtureIds.length;
        if (fixtureCount == 0) revert Errors.NoFixtures();

        round.fixturesExpected = uint32(fixtureCount);
        round.fixturesSettled = 0;
        for (uint256 i; i < fixtureCount;) {
            bytes32 fixtureId_ = schedule.fixtureIds[i];
            if (fixtureId_ == bytes32(0)) revert Errors.NoFixtures();
            _fixtureExpected[seasonStartYear_][roundNumber_][fixtureId_] = true;
            unchecked {
                ++i;
            }
        }

        requestIds_ = IPbrSettle(settle_).startRound(tournamentId, seasonStartYear_, roundNumber_, utilizedHash);
        emit Events.RoundSettleRequested(seasonStartYear_, roundNumber_, settle_, utilizedHash, uint32(fixtureCount));
    }

    function applyFixtureSettlement(
        bytes32 fixtureId_,
        bytes32 fixtureDigest_,
        address[] calldata vaults_,
        uint256[] calldata mwPoints_
    ) external onlyPbrSettle returns (bool done_) {
        if (fixtureId_ == bytes32(0) || fixtureDigest_ == bytes32(0)) {
            revert Errors.ZeroId();
        }
        if (vaults_.length != mwPoints_.length) revert Errors.LengthMismatch();
        if (vaults_.length > MAX_FIXTURE_PLAYERS) revert Errors.TooManyPlayers(vaults_.length);

        uint16 seasonStartYear_ = seasonStartYear;
        uint32 roundNumber_ = activeRound;
        RoundState storage round = _rounds[seasonStartYear_][roundNumber_];
        if (round.status != RoundStatus.SettlePending) {
            revert Errors.BadRoundStatus(seasonStartYear_, roundNumber_, round.status, RoundStatus.SettlePending);
        }
        if (!_fixtureExpected[seasonStartYear_][roundNumber_][fixtureId_]) revert Errors.UnknownFixture(fixtureId_);
        if (_fixtureSettled[seasonStartYear_][roundNumber_][fixtureId_]) {
            revert Errors.FixtureAlreadySettled(fixtureId_);
        }

        _fixtureSettled[seasonStartYear_][roundNumber_][fixtureId_] = true;
        fixtureDigestOf[seasonStartYear_][roundNumber_][fixtureId_] = fixtureDigest_;

        uint256 written;
        uint256 added;
        for (uint256 i; i < vaults_.length;) {
            address vault_ = vaults_[i];
            if (vault_ == address(0)) revert Errors.ZeroAddress();
            if (_isUtilized[seasonStartYear_][roundNumber_][vault_]) {
                uint256 m = mwPoints_[i];
                vaultPoints[seasonStartYear_][roundNumber_][vault_] += m;
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

        done_ = round.fixturesSettled >= round.fixturesExpected;
        emit Events.FixtureSettlementApplied(
            seasonStartYear_, roundNumber_, fixtureId_, fixtureDigest_, written, round.M_adj, done_
        );

        if (done_) {
            _openClaimable(
                seasonStartYear_, roundNumber_, round, _utilizedVaults[seasonStartYear_][roundNumber_].length
            );
        }
    }

    function _openClaimable(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        RoundState storage round,
        uint256 utilizedCount_
    ) internal {
        round.status = RoundStatus.Claimable;

        uint32 finalRound = tournamentRegistry.getFinalRound(tournamentId, seasonStartYear_);
        if (roundNumber_ >= finalRound && finalRound != 0) {
            activeRound = 1;
            uint16 nextYear = seasonStartYear_ + 1;
            seasonStartYear = nextYear;
            emit Events.SeasonWrapped(seasonStartYear_, nextYear);
        } else {
            activeRound = tradingRound;
        }

        emit Events.RoundSettled(seasonStartYear_, roundNumber_, round.M_adj, utilizedCount_);
        tournamentRegistry.flushPendingUnregisters(tournamentId);
    }

    // --------------------------------------------
    //  Claims
    // --------------------------------------------

    /**
     * @notice Vault-only PBR payout. Called by `PlayerVault.claim` / `claimAll`.
     * @dev `msg.sender` must hold `vaultPoints` for this round (valid after unregister).
     *      Loads `s`/`S` from the calling vault's stToken at `lockBlock`.
     */
    function payClaim(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        address user_
    ) external nonReentrant returns (uint256 payout_) {
        if (user_ == address(0)) revert Errors.ZeroAddress();

        uint256 m = vaultPoints[seasonStartYear_][roundNumber_][msg.sender];
        if (m == 0) revert Errors.UnknownVault(msg.sender);

        RoundState storage round = _rounds[seasonStartYear_][roundNumber_];
        if (round.status != RoundStatus.Claimable) {
            revert Errors.BadRoundStatus(seasonStartYear_, roundNumber_, round.status, RoundStatus.Claimable);
        }
        if (round.R == 0 || round.M_adj == 0) revert Errors.NothingToClaim();

        address stToken_ = IPlayerVault(msg.sender).stToken();
        uint64 lockBlock_ = round.lockBlock;
        uint256 s = IStakedToken(stToken_).balanceOfAt(user_, lockBlock_);
        uint256 S = IStakedToken(stToken_).totalSupplyAt(lockBlock_);
        if (s == 0 || S == 0) revert Errors.NothingToClaim();

        payout_ = Math.mulDiv(Math.mulDiv(round.R, m, round.M_adj), s, S);
        if (payout_ == 0) revert Errors.NothingToClaim();

        uint256 newPaid = round.paid + payout_;
        if (newPaid > round.R) revert Errors.InsufficientRoundFunds();

        round.paid = newPaid;
        totalRewardsR -= payout_;

        (bool ok,) = user_.call{ value: payout_ }("");
        if (!ok) revert Errors.TransferFailed();

        emit Events.ClaimPaid(seasonStartYear_, roundNumber_, msg.sender, user_, payout_);
    }

    // --------------------------------------------
    //  Views
    // --------------------------------------------

    function getRound(uint16 seasonStartYear_, uint32 roundNumber_) external view returns (RoundState memory) {
        return _rounds[seasonStartYear_][roundNumber_];
    }

    function getRoundClaimMeta(
        uint16 seasonStartYear_,
        uint32 roundNumber_
    ) external view returns (RoundStatus status_, uint64 lockBlock_) {
        RoundState storage round = _rounds[seasonStartYear_][roundNumber_];
        return (round.status, round.lockBlock);
    }

    function getVaultPoints(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        address vault_
    ) external view returns (uint256) {
        return vaultPoints[seasonStartYear_][roundNumber_][vault_];
    }

    function getVaults() external view returns (address[] memory) {
        return _vaults;
    }

    function getUtilizedVaults(uint16 seasonStartYear_, uint32 roundNumber_) external view returns (address[] memory) {
        return _utilizedVaults[seasonStartYear_][roundNumber_];
    }

    function isFixtureSettled(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        bytes32 fixtureId_
    ) external view returns (bool) {
        return _fixtureSettled[seasonStartYear_][roundNumber_][fixtureId_];
    }

    function getCursors() external view returns (uint16, uint32, uint32) {
        return (seasonStartYear, activeRound, tradingRound);
    }

    function previewClaim(
        uint16 seasonStartYear_,
        uint32 roundNumber_,
        address vault_,
        address user_
    ) external view returns (uint256 payout_) {
        RoundState storage round = _rounds[seasonStartYear_][roundNumber_];
        if (round.status != RoundStatus.Claimable || round.R == 0 || round.M_adj == 0) return 0;

        uint256 m = vaultPoints[seasonStartYear_][roundNumber_][vault_];
        if (m == 0) return 0;

        address stToken_ = IPlayerVault(vault_).stToken();
        uint64 lockBlock_ = round.lockBlock;
        uint256 s = IStakedToken(stToken_).balanceOfAt(user_, lockBlock_);
        uint256 S = IStakedToken(stToken_).totalSupplyAt(lockBlock_);
        if (s == 0 || S == 0) return 0;

        payout_ = Math.mulDiv(Math.mulDiv(round.R, m, round.M_adj), s, S);
        uint256 remaining = round.R - round.paid;
        if (payout_ > remaining) payout_ = remaining;
    }
}
