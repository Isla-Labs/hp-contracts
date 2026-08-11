// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Config } from "forge-std/Config.sol";
import { Script } from "forge-std/Script.sol";
import { StdConfig } from "forge-std/StdConfig.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { console2 as console } from "forge-std/console2.sol";

import { OracleDeployment } from "./OracleDeployment.sol";

/**
 * @title HpDeployBase
 * @notice Shared forge-std Config loader + Preconfig for HighPotential DeployAll.
 * @dev Modeled on Doppler `DeployBase`: TOML at `DEPLOYMENTS_CONFIG_PATH`, writes only on broadcast.
 */
abstract contract HpDeployBase is Script, Config, OracleDeployment {
    string internal constant DEPLOYMENTS_CONFIG_PATH = "./deployments.config.toml";
    string internal constant IS_TESTNET_KEY = "is_testnet";

    error MissingRequiredPreconfig(string key);
    error MissingOracleAddresses();

    /// @notice External / already-launched dependencies seeded onto AddressProvider before init.
    struct Preconfig {
        address hpTreasury;
        address hpMultisig;
        address zRouter;
        address creForwarder;
        address automataDcapAttestation;
        address automataPccsRouter;
        address cvmCoordinator;
        address cvmRouter;
        address dopplerAirlock;
        address dn404Factory;
        address noOpGovernanceFactory;
        address launchpadGovernanceFactory;
        address dopplerHookInitializer;
        address rehypeDopplerHookInitializer;
        address dopplerHookMigrator;
        address rehypeDopplerHookMigrator;
    }

    struct DeployContext {
        uint256 chainId;
        StdConfig config;
        Preconfig preconfig;
        address broadcaster;
        bool writeConfig;
    }

    /// @notice Loads the shared deployments config for the chain selected by forge CLI.
    function _loadConfigForCurrentChain() internal {
        _loadConfig(DEPLOYMENTS_CONFIG_PATH, true);
    }

    /// @notice Builds deploy context: chain config, Preconfig, broadcaster, write flag.
    function _deployContext() internal returns (DeployContext memory context) {
        uint256 chainId = block.chainid;
        require(config.exists(chainId, IS_TESTNET_KEY), "is_testnet is not configured");

        context = DeployContext({
            chainId: chainId,
            config: config,
            preconfig: _loadPreconfig(chainId),
            broadcaster: _resolveBroadcastSender(),
            writeConfig: _shouldWriteConfig()
        });
    }

    /// @notice Reads Preconfig from TOML; fills missing oracle addresses from the oracle JSON when present.
    function _loadPreconfig(uint256 chainId) internal view returns (Preconfig memory p) {
        p.hpTreasury = _requireConfigAddress(chainId, "hp_treasury");
        p.hpMultisig = _requireConfigAddress(chainId, "hp_multisig");
        p.automataDcapAttestation = _requireConfigAddress(chainId, "automata_dcap_attestation");
        p.automataPccsRouter = _requireConfigAddress(chainId, "automata_pccs_router");
        p.dopplerAirlock = _requireConfigAddress(chainId, "doppler_airlock");
        p.dn404Factory = _requireConfigAddress(chainId, "dn404_factory");
        p.noOpGovernanceFactory = _requireConfigAddress(chainId, "no_op_governance_factory");
        p.launchpadGovernanceFactory = _requireConfigAddress(chainId, "launchpad_governance_factory");
        p.dopplerHookInitializer = _requireConfigAddress(chainId, "doppler_hook_initializer");
        p.rehypeDopplerHookInitializer = _requireConfigAddress(chainId, "rehype_doppler_hook_initializer");
        p.dopplerHookMigrator = _requireConfigAddress(chainId, "doppler_hook_migrator");
        p.rehypeDopplerHookMigrator = _requireConfigAddress(chainId, "rehype_doppler_hook_migrator");

        p.zRouter = _optionalConfigAddress(chainId, "z_router");
        p.creForwarder = _optionalConfigAddress(chainId, "cre_forwarder");
        p.cvmCoordinator = _optionalConfigAddress(chainId, "cvm_coordinator");
        p.cvmRouter = _optionalConfigAddress(chainId, "cvm_router");

        if (p.cvmCoordinator == address(0) || p.cvmRouter == address(0)) {
            (address coordinator, address router) = _tryReadOracleJson();
            if (p.cvmCoordinator == address(0)) p.cvmCoordinator = coordinator;
            if (p.cvmRouter == address(0)) p.cvmRouter = router;
        }

        if (p.cvmCoordinator == address(0) || p.cvmRouter == address(0)) {
            revert MissingOracleAddresses();
        }
    }

    /// @notice Config writes are limited to broadcast runs so dry-runs do not mutate local TOML.
    function _shouldWriteConfig() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
    }

    function _isConfiguredTestnet(uint256 chainId) internal view returns (bool) {
        require(config.exists(chainId, IS_TESTNET_KEY), "is_testnet is not configured");
        return config.get(chainId, IS_TESTNET_KEY).toBool();
    }

    function _setConfigAddress(DeployContext memory context, string memory key, address value) internal {
        if (context.writeConfig) {
            context.config.set(context.chainId, key, value);
        }
    }

    function _setConfigAddress(string memory key, address value) internal {
        if (_shouldWriteConfig()) {
            config.set(key, value);
        }
    }

    function _requireConfigAddress(uint256 chainId, string memory key) internal view returns (address addr) {
        if (!config.exists(chainId, key)) revert MissingRequiredPreconfig(key);
        addr = config.get(chainId, key).toAddress();
        if (addr == address(0)) revert MissingRequiredPreconfig(key);
    }

    function _optionalConfigAddress(uint256 chainId, string memory key) internal view returns (address) {
        if (!config.exists(chainId, key)) return address(0);
        return config.get(chainId, key).toAddress();
    }

    function _tryReadOracleJson() internal view returns (address coordinator, address router) {
        if (!vm.isFile(ORACLE_DEPLOYMENT_PATH)) {
            console.log("Oracle JSON missing:", ORACLE_DEPLOYMENT_PATH);
            return (address(0), address(0));
        }
        string memory json = _readOracleDeployment();
        coordinator = _oracleCoordinator(json);
        router = _oracleRouter(json);
    }

    /// @notice Resolves the sender Foundry will use for default `vm.startBroadcast()` calls.
    function _resolveBroadcastSender() internal returns (address broadcaster) {
        vm.startBroadcast();
        (, broadcaster,) = vm.readCallers();
        vm.stopBroadcast();
    }

    /// @notice Orchestrator admin: OWNER_ADDRESS / DAO_ADDRESS env, else Preconfig hpMultisig.
    function _resolveOwner(Preconfig memory preconfig) internal view returns (address) {
        return vm.envOr("OWNER_ADDRESS", vm.envOr("DAO_ADDRESS", preconfig.hpMultisig));
    }
}
