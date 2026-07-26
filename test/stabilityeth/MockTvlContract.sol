// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { IAppDeployerAuth } from "@stabilityeth/interfaces/IAppDeployerAuth.sol";

/// @dev Minimal TVL target for AppRegistry deployer auth tests.
contract MockTvlContract is IAppDeployerAuth {
    address public immutable override appDeployer;

    constructor(
        address appDeployer_
    ) {
        appDeployer = appDeployer_;
    }
}
