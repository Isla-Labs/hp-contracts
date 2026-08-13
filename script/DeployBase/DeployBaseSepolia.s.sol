// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { DeployData } from "../utils/DeployData.sol";
import { DeployFactories } from "../utils/DeployFactories.sol";
import { DeployHandoff } from "../utils/DeployHandoff.sol";
import { DeployInitializers } from "../utils/DeployInitializers.sol";
import { DeployOrchestrator } from "../utils/DeployOrchestrator.sol";
import { DeployPbrSettle } from "../utils/DeployPbrSettle.sol";
import { DeployRegistries } from "../utils/DeployRegistries.sol";
import { DeployStakeVesting } from "../utils/DeployStakeVesting.sol";
import { DeployTimelock } from "../utils/DeployTimelock.sol";
import { DeployTournamentInitializer } from "../utils/DeployTournamentInitializer.sol";

/// @notice Base Sepolia — ConstitutionalTimelock → TIMELOCK (default minDelay 5 minutes).
contract DeployTimelockStack is DeployTimelock {
    function run() external returns (address timelock) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address multisig = vm.envOr("OWNER_ADDRESS", vm.envOr("DAO_ADDRESS", deployer));
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(5 minutes));

        vm.startBroadcast(privateKey);
        timelock = _deployTimelock(multisig, deployer, minDelay);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — Orchestrator (OWNER defaults to deployer).
contract DeployOrchestratorStack is DeployOrchestrator {
    function run() external returns (address orchestrator) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address owner = vm.envOr("OWNER_ADDRESS", vm.envOr("DAO_ADDRESS", deployer));

        vm.startBroadcast(privateKey);
        orchestrator = _deployOrchestrator(owner, deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — TournamentRegistry + PlayerSetRegistry.
contract DeployRegistriesStack is DeployRegistries {
    function run() external returns (RegistryDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployRegistries(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — StakeVesting.
contract DeployStakeVestingStack is DeployStakeVesting {
    function run() external returns (address stakeVesting) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        stakeVesting = _deployStakeVesting(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — TournamentInitializer.
contract DeployTournamentInitializerStack is DeployTournamentInitializer {
    function run() external returns (address tournamentInitializer) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        tournamentInitializer = _deployTournamentInitializer(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — RoundManager + SquadStore + EligibilityVerifier + PbrHistorical.
contract DeployDataStack is DeployData {
    function run() external returns (DataDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployData(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — DopplerConfig + MarketInitializer + LifecycleManager + MigrationListener.
contract DeployInitializersStack is DeployInitializers {
    function run() external returns (InitializerDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployInitializers(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — market / vault factories (TIMELOCK must already be on AP).
contract DeployFactoriesStack is DeployFactories {
    function run() external returns (FactoryDeployment memory f) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        f = _deployFactories(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — immutable PbrSettle (`CVM_ROUTER` + registries already on AP).
contract DeployPbrSettleStack is DeployPbrSettle {
    function run() external returns (address pbrSettle) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        pbrSettle = _deployPbrSettle(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base Sepolia — transfer AddressProvider DEFAULT_ADMIN → ConstitutionalTimelock.
contract DeployHandoffStack is DeployHandoff {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        _handoff(deployer);
        vm.stopBroadcast();
    }
}
