// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { TimelockController } from "@openzeppelin/governance/TimelockController.sol";
import { GovernanceErrors as Errors } from "@errors/governance/GovernanceErrors.sol";

/**
 * @title ConstitutionalTimelock
 * @notice Cat-1 long-delay executor for constitutional actions.
 * @dev Thin OZ `TimelockController` wrapper: HP Multisig as sole proposer/canceller,
 *      open execution (`address(0)` executor).
 */
contract ConstitutionalTimelock is TimelockController {
    /// @notice Default constitutional notice window.
    uint256 public constant DEFAULT_MIN_DELAY = 7 days;

    /**
     * @notice Deploys with the HP Multisig as sole proposer/canceller and open execution.
     * @param multisig HP Multisig address (`PROPOSER_ROLE`, `CANCELLER_ROLE`).
     * @param minDelay Delay in seconds between schedule and execute; `0` → `DEFAULT_MIN_DELAY`.
     */
    constructor(
        address multisig,
        uint256 minDelay
    )
        TimelockController(
            minDelay == 0 ? (block.chainid == 84_532 ? 5 minutes : DEFAULT_MIN_DELAY) : minDelay,
            _singleton(multisig), 
            _openExecutors(), multisig
        )
    {
        if (multisig == address(0)) revert Errors.ZeroAddress();
    }

    function _singleton(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }

    function _openExecutors() private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = address(0);
    }
}
