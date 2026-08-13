// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeployHandoff } from "../utils/DeployHandoff.sol";

/**
 * @title HandoffToTimelock
 * @notice Standalone: transfer AddressProvider `DEFAULT_ADMIN_ROLE` → AP `TIMELOCK`.
 * @dev Requires `ADDRESS_PROVIDER` env and deployer still holding DEFAULT_ADMIN (or already CT).
 *      Prefer `DeployAll` / `DeployHandoffStack` for full bootstrap; use this for recovery paths.
 */
contract HandoffToTimelock is DeployHandoff {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        _handoff(deployer);
        vm.stopBroadcast();
    }
}
