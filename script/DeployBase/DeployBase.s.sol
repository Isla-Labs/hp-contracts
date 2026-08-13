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

/// @notice Base mainnet — ConstitutionalTimelock → TIMELOCK (`0` → DEFAULT_MIN_DELAY 7 days).
contract DeployTimelockStack is DeployTimelock {
    function run() external returns (address timelock) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        address multisig = vm.envOr("OWNER_ADDRESS", vm.envAddress("DAO_ADDRESS"));
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(0));

        vm.startBroadcast(privateKey);
        timelock = _deployTimelock(multisig, deployer, minDelay);
        vm.stopBroadcast();
    }
}

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

/// @notice Base mainnet — StakeVesting.
contract DeployStakeVestingStack is DeployStakeVesting {
    function run() external returns (address stakeVesting) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        stakeVesting = _deployStakeVesting(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — TournamentInitializer.
contract DeployTournamentInitializerStack is DeployTournamentInitializer {
    function run() external returns (address tournamentInitializer) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        tournamentInitializer = _deployTournamentInitializer(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — RoundManager + SquadStore + EligibilityVerifier + PbrHistorical.
contract DeployDataStack is DeployData {
    function run() external returns (DataDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployData(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — DopplerConfig + MarketInitializer + LifecycleManager + MigrationListener.
contract DeployInitializersStack is DeployInitializers {
    function run() external returns (InitializerDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        d = _deployInitializers(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — market / vault factories (TIMELOCK must already be on AP).
contract DeployFactoriesStack is DeployFactories {
    function run() external returns (FactoryDeployment memory f) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        f = _deployFactories(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — immutable PbrSettle.
contract DeployPbrSettleStack is DeployPbrSettle {
    function run() external returns (address pbrSettle) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        pbrSettle = _deployPbrSettle(deployer);
        vm.stopBroadcast();
    }
}

/// @notice Base mainnet — transfer AddressProvider DEFAULT_ADMIN → ConstitutionalTimelock.
contract DeployHandoffStack is DeployHandoff {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        vm.startBroadcast(privateKey);
        _handoff(deployer);
        vm.stopBroadcast();
    }
}
