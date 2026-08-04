// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeployOrchestrator } from "../utils/DeployOrchestrator.sol";
import { DeployRegistries } from "../utils/DeployRegistries.sol";
import { DeployDeployTournament } from "../utils/DeployDeployTournament.sol";
import { DeployData } from "../utils/DeployData.sol";
import { DeployLockers } from "../utils/DeployLockers.sol";
import { DeployFactories } from "../utils/DeployFactories.sol";
import { DeployHandoff } from "../utils/DeployHandoff.sol";

/// @notice Base mainnet — Orchestrator.
contract DeployOrchestratorStack is DeployOrchestrator {
    function run() external returns (address orchestrator) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envOr("OWNER_ADDRESS", vm.envAddress("DAO_ADDRESS"));

        vm.startBroadcast(privateKey);
        orchestrator = _deployOrchestrator(owner, deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — TournamentRegistry + PlayerSetRegistry.
contract DeployRegistriesStack is DeployRegistries {
    function run() external returns (RegistryDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployRegistries(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — DeployTournament.
contract DeployDeployTournamentStack is DeployDeployTournament {
    function run() external returns (DeployTournamentDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envOr("OWNER_ADDRESS", vm.envAddress("DAO_ADDRESS"));

        vm.startBroadcast(privateKey);
        d = _deployDeployTournament(owner, deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — RoundManager (data).
contract DeployDataStack is DeployData {
    function run() external returns (DataDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployData(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — DopplerLocker + TransferLocker.
contract DeployLockersStack is DeployLockers {
    function run() external returns (LockerDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployLockers(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — market / vault factories.
contract DeployFactoriesStack is DeployFactories {
    function run() external returns (FactoryDeployment memory f) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        f = _deployFactories(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — AP + ProxyAdmin handoff to Orchestrator.
contract DeployHandoffStack is DeployHandoff {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        _handoff(deployer);
        vm.stopBroadcast();
    }
}
