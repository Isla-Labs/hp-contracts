// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { IPlayerSetRegistry } from "@interfaces/IPlayerSetRegistry.sol";
import { AdvancedTradeData, VaultData } from "@types/registries/PlayerSetTypes.sol";
import { PlayerVault } from "@vaults/PlayerVault.sol";

import { StakeVestingErrors as Errors } from "@errors/governance/StakeVestingErrors.sol";
import { StakeVestingEvents as Events } from "@events/governance/StakeVestingEvents.sol";
import { Beneficiary, Position } from "@types/governance/StakeVestingTypes.sol";

/**
 * @title StakeVesting
 * @notice Global receiver for Doppler Launchpad excess (`initialSupply - numTokensToSell`).
 * @dev Wired as LaunchpadGovernance “timelock” via `governanceFactoryData = abi.encode(this)`.
 *
 *      Airlock transfers excess during `create` (before the vault exists). DopplerLocker then
 *      calls `allocate(token)` after `PlayerSetRegistry` has the vault:
 *        - 50% ringfenced as AdvancedTrade short-supply inventory (held here until AT ships)
 *        - 50% staked into the PlayerVault with a 4×25% unlock over 4 years (tranche 0 immediate)
 *
 *      Unlocked underlying and PBR ETH yield are distributed to a configurable beneficiary split.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract StakeVesting is Initializable, AddressBook, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    //  Config
    // -------------------------------------------------------------------------

    uint256 public constant WAD = 1e18;
    uint256 public constant TRANCHE_COUNT = 4;
    uint256 public constant TRANCHE_DURATION = 365 days;

    IPlayerSetRegistry public playerSetRegistry;

    Beneficiary[] private _beneficiaries;

    mapping(address token => Position) public positions;

    // -------------------------------------------------------------------------
    //  Initialization
    // -------------------------------------------------------------------------

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Resolve registry; default beneficiary = HP Treasury (100%); ownership → Orchestrator.
     */
    function initialize() external initializer {
        playerSetRegistry = IPlayerSetRegistry(_getAddress(_addressKey(Addresses.PLAYER_SET_REGISTRY)));

        address hpTreasury = _getAddress(_addressKey(Addresses.HP_TREASURY));
        if (hpTreasury == address(0)) revert Errors.ZeroAddress();

        address[] memory accounts = new address[](1);
        accounts[0] = hpTreasury;
        uint256[] memory sharesWad = new uint256[](1);
        sharesWad[0] = WAD;
        _setBeneficiaries(accounts, sharesWad);

        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
    }

    receive() external payable { }

    // -------------------------------------------------------------------------
    //  Admin
    // -------------------------------------------------------------------------

    /**
     * @notice Replace beneficiary split (`sharesWad` must sum to `WAD`).
     * @dev Applies to subsequent vested / PBR distributions (not retroactive to already-sent funds).
     */
    function setBeneficiaries(address[] calldata accounts, uint256[] calldata sharesWad) external onlyOwner {
        _setBeneficiaries(accounts, sharesWad);
    }

    /**
     * @notice Release full ringfenced AT inventory to the registry `advancedTradeVault`.
     * @dev Reverts if AT vault unset, reserve is zero, or ERC20 balance is below reserve.
     */
    function releaseAdvancedTrade(address token) external onlyOwner nonReentrant {
        if (token == address(0)) revert Errors.ZeroAddress();
        Position storage p = positions[token];
        if (!p.allocated) revert Errors.NotConfigured();

        uint256 amount = p.advancedTradeReserve;
        if (amount == 0) revert Errors.ZeroAmount();
        if (IERC20(token).balanceOf(address(this)) < amount) revert Errors.InsufficientExcessReserve();

        AdvancedTradeData memory at = playerSetRegistry.getAdvancedTradeData(p.playerId);
        address vault = at.advancedTradeVault;
        if (vault == address(0)) revert Errors.VaultMissing(p.playerId);

        p.advancedTradeReserve = 0;
        IERC20(token).safeTransfer(vault, amount);
        emit Events.AdvancedTradeReleased(token, vault, amount);
    }

    /**
     * @notice Owner escape hatch: send all free ERC20 balance of `token` → HP Treasury.
     * @dev Leaves `advancedTradeReserve` and `unlockedClaimable` untouched. Staked principal
     *      remains in the PlayerVault. Prefer `releaseAdvancedTrade` / `distributeUnlocked`.
     */
    function rescueToken(address token) external onlyOwner nonReentrant {
        if (token == address(0)) revert Errors.ZeroAddress();

        address hpTreasury = _getAddress(_addressKey(Addresses.HP_TREASURY));
        if (hpTreasury == address(0)) revert Errors.ZeroAddress();

        Position storage p = positions[token];
        uint256 free = IERC20(token).balanceOf(address(this)) - p.advancedTradeReserve - p.unlockedClaimable;
        if (free == 0) revert Errors.ZeroAmount();

        IERC20(token).safeTransfer(hpTreasury, free);
        emit Events.ExcessTokenRescued(token, hpTreasury, free);
    }

    // -------------------------------------------------------------------------
    //  Allocate (DopplerLocker → Orchestrator.execute)
    // -------------------------------------------------------------------------

    /**
     * @notice Split held excess 50/50: AT reserve + PlayerVault stake; unlock first vesting tranche.
     * @dev Requires vault already on `PlayerSetRegistry`. Idempotent guard per token.
     */
    function allocate(address token) external onlyOwner nonReentrant {
        if (token == address(0)) revert Errors.ZeroAddress();
        Position storage p = positions[token];
        if (p.allocated) return; // idempotent for DopplerLocker deploy retries
        if (_beneficiaries.length == 0) revert Errors.EmptyBeneficiaries();

        bytes32 playerId = playerSetRegistry.playerIdOfToken(token);
        if (playerId == bytes32(0)) revert Errors.NotConfigured();

        VaultData memory vd = playerSetRegistry.getVaultData(playerId);
        if (vd.playerVault == address(0)) revert Errors.VaultMissing(playerId);

        uint256 total = IERC20(token).balanceOf(address(this));
        if (total == 0) revert Errors.ZeroAmount();

        uint256 atAmount = total / 2;
        uint256 vaultAmount = total - atAmount;

        p.playerId = playerId;
        p.vault = vd.playerVault;
        p.advancedTradeReserve = atAmount;
        p.vaultPrincipal = vaultAmount;
        p.stakedRemaining = vaultAmount;
        p.unlockedClaimable = 0;
        p.allocatedAt = uint64(block.timestamp);
        p.nextTranche = 0;
        p.allocated = true;

        if (vaultAmount != 0) {
            IERC20(token).forceApprove(vd.playerVault, vaultAmount);
            PlayerVault(vd.playerVault).stake(vaultAmount);
            IERC20(token).forceApprove(vd.playerVault, 0);
        }

        emit Events.ExcessAllocated(token, playerId, atAmount, vaultAmount);

        _unlockMatured(token, p);
    }

    // -------------------------------------------------------------------------
    //  Vesting / yield
    // -------------------------------------------------------------------------

    /// @notice Unstake any mature tranches into `unlockedClaimable`.
    function unlock(address token) external nonReentrant {
        Position storage p = positions[token];
        if (!p.allocated) revert Errors.NotConfigured();
        uint256 before_ = p.nextTranche;
        _unlockMatured(token, p);
        if (p.nextTranche == before_) revert Errors.NothingToUnlock();
    }

    /// @notice Push `unlockedClaimable` to beneficiaries by share.
    function distributeUnlocked(address token) external nonReentrant {
        Position storage p = positions[token];
        uint256 amount = p.unlockedClaimable;
        if (amount == 0) revert Errors.ZeroAmount();
        p.unlockedClaimable = 0;
        _distributeToken(token, amount);
        emit Events.ExcessVestedDistributed(token, amount);
    }

    /// @notice Unlock mature tranches (if any) then distribute claimable underlying.
    function unlockAndDistribute(address token) external nonReentrant {
        Position storage p = positions[token];
        if (!p.allocated) revert Errors.NotConfigured();
        _unlockMatured(token, p);
        uint256 amount = p.unlockedClaimable;
        if (amount == 0) revert Errors.ZeroAmount();
        p.unlockedClaimable = 0;
        _distributeToken(token, amount);
        emit Events.ExcessVestedDistributed(token, amount);
    }

    /**
     * @notice Claim all claimable PBR for the staked position and split ETH to beneficiaries.
     */
    function claimPbr(address token) external nonReentrant returns (uint256 payout) {
        Position storage p = positions[token];
        if (!p.allocated || p.vault == address(0)) revert Errors.NotConfigured();

        uint256 before_ = address(this).balance;
        payout = PlayerVault(p.vault).claim();
        uint256 received = address(this).balance - before_;
        if (received == 0) return 0;

        _distributeEth(received);
        emit Events.ExcessPbrDistributed(token, received);
    }

    // -------------------------------------------------------------------------
    //  Views
    // -------------------------------------------------------------------------

    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function beneficiaries() external view returns (Beneficiary[] memory list) {
        list = _beneficiaries;
    }

    function trancheUnlockAt(address token, uint8 tranche) external view returns (uint256) {
        Position storage p = positions[token];
        if (!p.allocated || tranche >= TRANCHE_COUNT) return 0;
        return uint256(p.allocatedAt) + uint256(tranche) * TRANCHE_DURATION;
    }

    function pendingUnlock(address token) external view returns (uint256 amount) {
        Position storage p = positions[token];
        if (!p.allocated) return 0;
        uint8 i = p.nextTranche;
        while (i < TRANCHE_COUNT) {
            uint256 unlockAt = uint256(p.allocatedAt) + uint256(i) * TRANCHE_DURATION;
            if (block.timestamp < unlockAt) break;
            amount += _trancheAmount(p.vaultPrincipal, i);
            unchecked {
                ++i;
            }
        }
    }

    // -------------------------------------------------------------------------
    //  Internal
    // -------------------------------------------------------------------------

    function _unlockMatured(address token, Position storage p) private {
        while (p.nextTranche < TRANCHE_COUNT) {
            uint256 unlockAt = uint256(p.allocatedAt) + uint256(p.nextTranche) * TRANCHE_DURATION;
            if (block.timestamp < unlockAt) break;

            uint256 amount = _trancheAmount(p.vaultPrincipal, p.nextTranche);
            if (amount > p.stakedRemaining) amount = p.stakedRemaining;

            if (amount != 0) {
                PlayerVault(p.vault).unstake(amount);
                p.stakedRemaining -= amount;
                p.unlockedClaimable += amount;
            }

            emit Events.ExcessTrancheUnlocked(token, p.nextTranche, amount);
            unchecked {
                ++p.nextTranche;
            }
        }
    }

    function _trancheAmount(uint256 principal, uint8 tranche) private pure returns (uint256) {
        uint256 base_ = principal / TRANCHE_COUNT;
        if (tranche + 1 < TRANCHE_COUNT) return base_;
        return principal - base_ * (TRANCHE_COUNT - 1);
    }

    function _distributeToken(address token, uint256 amount) private {
        uint256 length = _beneficiaries.length;
        uint256 sent;
        for (uint256 i; i < length; ++i) {
            uint256 share = i + 1 == length ? amount - sent : (amount * _beneficiaries[i].shareWad) / WAD;
            if (share == 0) continue;
            sent += share;
            IERC20(token).safeTransfer(_beneficiaries[i].account, share);
        }
    }

    function _distributeEth(uint256 amount) private {
        uint256 length = _beneficiaries.length;
        uint256 sent;
        for (uint256 i; i < length; ++i) {
            uint256 share = i + 1 == length ? amount - sent : (amount * _beneficiaries[i].shareWad) / WAD;
            if (share == 0) continue;
            sent += share;
            (bool ok,) = _beneficiaries[i].account.call{ value: share }("");
            if (!ok) revert Errors.TransferFailed();
        }
    }

    function _setBeneficiaries(address[] memory accounts, uint256[] memory sharesWad) private {
        uint256 length = accounts.length;
        if (length == 0) revert Errors.EmptyBeneficiaries();
        if (length != sharesWad.length) revert Errors.LengthMismatch(length, sharesWad.length);
        _requireSharesSumToWad(sharesWad);

        delete _beneficiaries;
        for (uint256 i; i < length; ++i) {
            if (accounts[i] == address(0)) revert Errors.ZeroAddress();
            if (sharesWad[i] == 0) revert Errors.InvalidBeneficiaryShares();
            _beneficiaries.push(Beneficiary({ account: accounts[i], shareWad: sharesWad[i] }));
        }
        emit Events.ExcessBeneficiariesUpdated(length);
    }

    /// @dev Reverts unless `sharesWad` sums exactly to `WAD` (100%).
    function _requireSharesSumToWad(uint256[] memory sharesWad) private pure {
        uint256 total;
        uint256 length = sharesWad.length;
        for (uint256 i; i < length; ++i) {
            total += sharesWad[i];
        }
        if (total != WAD) revert Errors.InvalidBeneficiaryShares();
    }
}
