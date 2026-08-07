// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Ownable } from "@openzeppelin/access/Ownable.sol";
import { Initializable } from "@openzeppelin/proxy/utils/Initializable.sol";
import { ReentrancyGuard } from "@openzeppelin/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

import { AddressBook } from "@base/abstract/AddressBook.sol";
import { AddressKeys as Addresses } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DeploymentsErrors as Errors } from "@errors/governance/DeploymentsErrors.sol";
import { DeploymentsEvents as Events } from "@events/governance/DeploymentsEvents.sol";

/**
 * @title ExcessSupplyLocker
 * @notice Global receiver for Doppler Launchpad excess supply (`initialSupply - numTokensToSell`).
 * @dev Wired as `LaunchpadGovernanceFactory` “timelock” / excess recipient via
 *      `governanceFactoryData = abi.encode(excessSupplyLocker)`.
 *
 *      Foundation only: holds per-asset balances for later AdvancedTrade short-supply splits
 *      (timelocks / prerequisites — not implemented here).
 *
 *      Access: `Orchestrator` (owner) for rescue / future distribute paths.
 *
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */
contract ExcessSupplyLocker is Initializable, AddressBook, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @param addressProvider_ Canonical `AddressProvider` (implementation immutable).
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address addressProvider_) AddressBook(addressProvider_) Ownable(msg.sender) {
        _disableInitializers();
    }

    /// @notice Ownership → Orchestrator.
    function initialize() external initializer {
        _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
    }

    /// @notice ERC20 balance of `token` held by this locker.
    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Owner escape hatch / ops move (AdvancedTrade inventory wiring later).
     * @param token ERC20 to pull from this contract.
     * @param to Recipient.
     * @param amount Amount to transfer.
     */
    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert Errors.ZeroAddress();
        if (amount == 0) return;
        IERC20(token).safeTransfer(to, amount);
        emit Events.ExcessTokenRescued(token, to, amount);
    }
}
