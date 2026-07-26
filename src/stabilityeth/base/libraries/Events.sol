// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Beneficiary } from "@stabilityeth/AppRegistry.sol";

library SethEvents {
    // --------------------------------------------
    //  AppRegistry
    // --------------------------------------------
    event AppRegistered(
        bytes32 indexed appId,
        address indexed rootDeployer,
        address indexed minter,
        address[] tvlContracts
    );
    event TvlContractsAdded(bytes32 indexed appId, address[] tvlContracts);
    event TvlContractRemoved(bytes32 indexed appId, address indexed tvlContract);
    event AppActiveUpdated(bytes32 indexed appId, bool active);
    event BeneficiariesUpdated(bytes32 indexed appId, Beneficiary[] beneficiaries);
    event PbrTreasuryUpdated(address indexed pbrTreasury);
    event MintRecorded(bytes32 indexed appId, uint256 amount, uint256 totalMinted_, uint256 netMinted_);
    event BurnRecorded(bytes32 indexed appId, uint256 amount, uint256 totalMinted_, uint256 netMinted_);  
}
