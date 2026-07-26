// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title IAppDeployerAuth
 * @notice TVL contracts registered in `AppRegistry` must expose their deployer for auth.
 */
interface IAppDeployerAuth {
    /// @notice Address that deployed this contract (must match the AppRegistry registrar)
    function appDeployer() external view returns (address);
}
