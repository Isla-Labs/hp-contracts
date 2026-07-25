// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { AccessControl } from "@openzeppelin/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { AccessRoles as Roles } from "@roles/AccessRoles.sol";
import { RegistryErrors as Errors } from "@errors/RegistryErrors.sol";
import { RegistryEvents as Events } from "@events/RegistryEvents.sol";
import { IReferralRegistry } from "@interfaces/IReferralRegistry.sol";

/**
 * @title ReferralRegistry
 * @notice Maps smart accounts to referral tiers (0–10) used as PBR stake-weight boosts.
 * @dev Each tier = +1% weight on eligible vault stake (see `PlayerVault`). Qualification
 *      indexing (who counts as a referred user) is applied offchain / by automator before
 *      calling `setTier`. Vaults read `boostBps` only.
 *      `boostsEnabled` is a global kill switch (default true): when false, `boostBps`
 *      returns 10_000 so every vault pulls 1.0× on the next sync/stake/unstake.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract ReferralRegistry is Initializable, AddressBook, AccessControl, IReferralRegistry {
    uint16 public constant BPS_BASE = 10_000;
    uint16 public constant BPS_PER_TIER = 100;
    uint8 public constant MAX_TIER = 10;

    /// @notice When false, `boostBps` returns 10_000 for all accounts (vaults become 1.0×).
    bool public boostsEnabled;

    mapping(address account => uint8 tier) private _tierOf;

    /// @dev Automator (cat-3) or MaintenanceTimelock (cat-2).
    modifier onlyCategoryTwoOrThree() {
        address sender = _msgSender();
        if (!hasRole(Roles.CATEGORY_TWO, sender) && !hasRole(Roles.CATEGORY_THREE, sender)) {
            revert Errors.NotAuthorized();
        }
        _;
    }

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) {
        _disableInitializers();
    }

    function initialize() external initializer {
        address automator_ = _getAddress(_addressKey(Addresses.AUTOMATOR));
        address maintenanceTimelock_ = _getAddress(_addressKey(Addresses.MAINTENANCE_TIMELOCK));
        address dao_ = _getAddress(_addressKey(Addresses.DAO));

        boostsEnabled = true;

        _grantRole(DEFAULT_ADMIN_ROLE, dao_);
        _grantRole(Roles.CATEGORY_THREE, automator_);
        _grantRole(Roles.CATEGORY_TWO, maintenanceTimelock_);
    }

    /**
     * @notice Global referral-boost kill switch.
     * @dev Cat-2 / cat-3. Does not rewrite vault checkpoints; each vault converges to 1.0×
     *      on the next `syncBoost` / stake / unstake pull of `boostBps`.
     */
    function setBoostsEnabled(bool enabled_) external onlyCategoryTwoOrThree {
        if (enabled_ == boostsEnabled) return;
        boostsEnabled = enabled_;
        emit Events.ReferralBoostsEnabledUpdated(enabled_);
    }

    /**
     * @notice Set referral tier for `account` (0–10).
     * @dev Automator (cat-3) after qualified-referral indexing.
     */
    function setTier(address account, uint8 tier) external onlyRole(Roles.CATEGORY_THREE) {
        if (account == address(0)) revert Errors.ZeroAddress();
        if (tier > MAX_TIER) revert Errors.InvalidReferralTier(tier, MAX_TIER);

        _tierOf[account] = tier;
        emit Events.ReferralTierUpdated(account, tier, _bps(tier));
    }

    /**
     * @notice Batch `setTier`.
     */
    function setTier(address[] calldata accounts, uint8[] calldata tiers) external onlyRole(Roles.CATEGORY_THREE) {
        uint256 len = accounts.length;
        if (len != tiers.length) revert Errors.LengthMismatch();

        for (uint256 i; i < len; ++i) {
            address account = accounts[i];
            uint8 tier = tiers[i];
            if (account == address(0)) revert Errors.ZeroAddress();
            if (tier > MAX_TIER) revert Errors.InvalidReferralTier(tier, MAX_TIER);

            _tierOf[account] = tier;
            emit Events.ReferralTierUpdated(account, tier, _bps(tier));
        }
    }

    function tierOf(address account) external view returns (uint8) {
        return _tierOf[account];
    }

    /// @inheritdoc IReferralRegistry
    function boostBps(address account) public view returns (uint16) {
        if (!boostsEnabled) return BPS_BASE;
        return _bps(_tierOf[account]);
    }

    function _bps(uint8 tier) private pure returns (uint16) {
        return BPS_BASE + uint16(tier) * BPS_PER_TIER;
    }
}
