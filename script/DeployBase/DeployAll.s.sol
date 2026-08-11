// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { InitGuard } from "@base/abstract/InitGuard.sol";
import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { DopplerConfig } from "@deployments/assets/deploy/config/DopplerConfig.sol";
import { DopplerLocker } from "@deployments/assets/deploy/DopplerLocker.sol";
import { TransferLocker } from "@deployments/assets/transfer/TransferLocker.sol";
import { DeployTournament } from "@deployments/tournaments/DeployTournament.sol";
import { Orchestrator } from "@governance/Orchestrator.sol";
import { StakeVesting } from "@governance/StakeVesting.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PlayerSetRegistry } from "@registries/PlayerSetRegistry.sol";
import { TournamentRegistry } from "@registries/TournamentRegistry.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { DeployHandoff } from "../utils/DeployHandoff.sol";
import { DeployRoutersLogic } from "../utils/DeployRoutersLogic.sol";
import { HpDeployBase } from "../utils/HpDeployBase.sol";
import { ProxyUtils } from "../utils/ProxyUtils.sol";

/**
 * @title DeployAll
 * @notice One-shot Base Sepolia core bootstrap including routers.
 * @dev Flow:
 *      1) Deploy AddressProvider
 *      2) Seed Preconfig (treasury, Doppler, Automata, oracle, …)
 *      3) Deploy InitGuard shells + Orchestrator (deployer = DEFAULT_ADMIN)
 *      4) Register all protocol names on AP
 *      5) Initialize in dependency order
 *      6) Authorize DeployTournament + DopplerLocker + TransferLocker
 *      7) Deploy + register zAMM stack, StakeRouter, TradeRouter
 *      8) Handoff ProxyAdmins → Orchestrator (vault factories are immutable — no ProxyAdmin)
 *      9) Transfer Orchestrator DEFAULT_ADMIN → owner (multisig)
 *
 *      Env: PRIVATE_KEY; optional OWNER_ADDRESS / DAO_ADDRESS (default Preconfig.hpMultisig).
 *      Make: `make deploy-base-sepolia-all` (optional `FORGE_FLAGS="-vvvv"`)
 */
contract DeployAll is HpDeployBase, ProxyUtils, DeployHandoff, DeployRoutersLogic {
    struct CoreDeployment {
        address addressProvider;
        address orchestrator;
        address tournamentRegistry;
        address playerSetRegistry;
        address deployTournament;
        address stakeVesting;
        address feeRouterFactory;
        address playerVaultFactory;
        address pbrTreasuryFactory;
        address pbrFeeHubFactory;
        address dopplerConfig;
        address dopplerLocker;
        address transferLocker;
        address initGuard;
        address tournamentRegistryImpl;
        address playerSetRegistryImpl;
        address deployTournamentImpl;
        address stakeVestingImpl;
        address feeRouterFactoryImpl;
        address pbrFeeHubFactoryImpl;
        address dopplerConfigImpl;
        address dopplerLockerImpl;
        address transferLockerImpl;
        address zRouter;
        address zQuoterBase;
        address zQuoter;
        address stakeRouter;
        address tradeRouter;
    }

    function run() external returns (CoreDeployment memory d) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);

        _loadConfigForCurrentChain();
        DeployContext memory context = _deployContext();
        require(_isConfiguredTestnet(context.chainId), "DeployAll: expected testnet chain");

        address owner = _resolveOwner(context.preconfig);
        console.log("=== DeployAll ===");
        console.log("chainId", context.chainId);
        console.log("deployer", deployer);
        console.log("owner (final Orchestrator admin)", owner);

        vm.startBroadcast(privateKey);

        d.addressProvider = address(new AddressProvider(deployer));
        AddressProvider ap = AddressProvider(payable(d.addressProvider));
        _setConfigAddress(context, "address_provider", d.addressProvider);
        console.log("ADDRESS_PROVIDER", d.addressProvider);

        _seedPreconfig(ap, context.preconfig);

        d = _deployShells(ap, deployer, d);

        // Vault factory beacons are owned by TIMELOCK at construction. Bootstrap placeholder =
        // final owner until ConstitutionalTimelock is deployed and beacon ownership transferred.
        if (ap.getByName(Keys.TIMELOCK) == address(0)) {
            _set(ap, Keys.TIMELOCK, owner);
            console.log("TIMELOCK bootstrap placeholder (owner) - replace with ConstitutionalTimelock later");
        }

        d = _registerProtocol(ap, d);
        _initializeAll(d);
        _authorizeModules(d.orchestrator, d.deployTournament, d.dopplerLocker, d.transferLocker);

        RouterDeployment memory routers = _deployAndRegisterRouters(ap, d.orchestrator, deployer, context.chainId);
        d.zRouter = routers.zRouter;
        d.zQuoterBase = routers.zQuoterBase;
        d.zQuoter = routers.zQuoter;
        d.stakeRouter = routers.stakeRouter;
        d.tradeRouter = routers.tradeRouter;

        _persistOutputs(context, d);
        _persistRouterOutputs(context, routers);

        // DeployHandoff reads ADDRESS_PROVIDER from env.
        vm.setEnv("ADDRESS_PROVIDER", vm.toString(d.addressProvider));
        _handoff(deployer);

        // Multisig (or OWNER_ADDRESS) becomes sole Orchestrator admin after bootstrap auth.
        if (owner != deployer) {
            Orchestrator(d.orchestrator).transferDefaultAdmin(owner);
            console.log("Orchestrator DEFAULT_ADMIN ->", owner);
        }

        vm.stopBroadcast();

        console.log("=== DeployAll complete - paste into .env ===");
        console.log("ADDRESS_PROVIDER", d.addressProvider);
        console.log("ORCHESTRATOR", d.orchestrator);
        console.log("Z_ROUTER", d.zRouter);
        console.log("Z_QUOTER", d.zQuoter);
        console.log("STAKE_ROUTER", d.stakeRouter);
        console.log("TRADE_ROUTER", d.tradeRouter);
    }

    // -------------------------------------------------------------------------
    //  Seed
    // -------------------------------------------------------------------------

    function _seedPreconfig(AddressProvider ap, Preconfig memory p) internal {
        console.log("--- seed Preconfig ---");
        _set(ap, Keys.HP_TREASURY, p.hpTreasury);
        _set(ap, Keys.AUTOMATA_DCAP_ATTESTATION, p.automataDcapAttestation);
        _set(ap, Keys.AUTOMATA_PCCS_ROUTER, p.automataPccsRouter);
        _set(ap, Keys.CVM_COORDINATOR, p.cvmCoordinator);
        _set(ap, Keys.CVM_ROUTER, p.cvmRouter);
        _set(ap, Keys.DOPPLER_AIRLOCK, p.dopplerAirlock);
        _set(ap, Keys.DN404_FACTORY, p.dn404Factory);
        _set(ap, Keys.NO_OP_GOVERNANCE_FACTORY, p.noOpGovernanceFactory);
        _set(ap, Keys.LAUNCHPAD_GOVERNANCE_FACTORY, p.launchpadGovernanceFactory);
        _set(ap, Keys.DOPPLER_HOOK_INITIALIZER, p.dopplerHookInitializer);
        _set(ap, Keys.REHYPE_DOPPLER_HOOK_INITIALIZER, p.rehypeDopplerHookInitializer);
        _set(ap, Keys.DOPPLER_HOOK_MIGRATOR, p.dopplerHookMigrator);
        _set(ap, Keys.REHYPE_DOPPLER_HOOK_MIGRATOR, p.rehypeDopplerHookMigrator);

        // Optional: pre-seed an existing zRouter. If zero, routers step self-deploys the stack.
        if (p.zRouter != address(0)) _set(ap, Keys.Z_ROUTER, p.zRouter);
        if (p.creForwarder != address(0)) _set(ap, Keys.CRE_FORWARDER, p.creForwarder);
    }

    function _set(AddressProvider ap, string memory name, address addr) internal {
        if (addr == address(0)) revert(string.concat("zero Preconfig: ", name));
        ap.setName(name, addr);
        console.log(name, addr);
    }

    // -------------------------------------------------------------------------
    //  Deploy shells
    // -------------------------------------------------------------------------

    function _deployShells(
        AddressProvider ap,
        address deployer,
        CoreDeployment memory d
    ) internal returns (CoreDeployment memory) {
        console.log("--- deploy shells ---");
        address apAddr = address(ap);

        // Deployer holds DEFAULT_ADMIN through authorize + handoff; transferred to `owner` at end.
        d.orchestrator = address(new Orchestrator(deployer));

        InitGuard guard = new InitGuard();
        d.initGuard = address(guard);

        d.tournamentRegistry = _deployInitGuardProxy(guard, deployer);
        d.playerSetRegistry = _deployInitGuardProxy(guard, deployer);
        d.deployTournament = _deployInitGuardProxy(guard, deployer);
        d.stakeVesting = _deployInitGuardProxy(guard, deployer);
        d.feeRouterFactory = _deployInitGuardProxy(guard, deployer);
        d.pbrFeeHubFactory = _deployInitGuardProxy(guard, deployer);
        d.dopplerConfig = _deployInitGuardProxy(guard, deployer);
        d.dopplerLocker = _deployInitGuardProxy(guard, deployer);
        d.transferLocker = _deployInitGuardProxy(guard, deployer);

        // Impls after CVM_ROUTER is on AP (locker ctors bind it immutably).
        // Vault factories are immutable and constructed after ORCHESTRATOR is registered.
        d.tournamentRegistryImpl = address(new TournamentRegistry(apAddr));
        d.playerSetRegistryImpl = address(new PlayerSetRegistry(apAddr));
        d.deployTournamentImpl = address(new DeployTournament(apAddr));
        d.stakeVestingImpl = address(new StakeVesting(apAddr));
        d.feeRouterFactoryImpl = address(new FeeRouterFactory(apAddr));
        d.pbrFeeHubFactoryImpl = address(new PbrFeeHubFactory(apAddr));
        d.dopplerConfigImpl = address(new DopplerConfig(apAddr));
        d.dopplerLockerImpl = address(new DopplerLocker(apAddr));
        d.transferLockerImpl = address(new TransferLocker(apAddr));

        return d;
    }

    // -------------------------------------------------------------------------
    //  Register
    // -------------------------------------------------------------------------

    function _registerProtocol(AddressProvider ap, CoreDeployment memory d)
        internal
        returns (CoreDeployment memory)
    {
        console.log("--- register protocol ---");
        _set(ap, Keys.ORCHESTRATOR, d.orchestrator);

        // Immutable vault factories require TIMELOCK on AP at construction.
        d.playerVaultFactory = address(new PlayerVaultFactory(address(ap)));
        d.pbrTreasuryFactory = address(new PbrTreasuryFactory(address(ap)));
        console.log("PLAYER_VAULT_FACTORY", d.playerVaultFactory);
        console.log("PBR_TREASURY_FACTORY", d.pbrTreasuryFactory);

        _set(ap, Keys.TOURNAMENT_REGISTRY, d.tournamentRegistry);
        _set(ap, Keys.PLAYER_SET_REGISTRY, d.playerSetRegistry);
        _set(ap, Keys.DEPLOY_TOURNAMENT, d.deployTournament);
        _set(ap, Keys.STAKE_VESTING, d.stakeVesting);
        _set(ap, Keys.FEE_ROUTER_FACTORY, d.feeRouterFactory);
        _set(ap, Keys.PLAYER_VAULT_FACTORY, d.playerVaultFactory);
        _set(ap, Keys.PBR_TREASURY_FACTORY, d.pbrTreasuryFactory);
        _set(ap, Keys.PBR_FEE_HUB_FACTORY, d.pbrFeeHubFactory);
        _set(ap, Keys.DOPPLER_CONFIG, d.dopplerConfig);
        _set(ap, Keys.DOPPLER_LOCKER, d.dopplerLocker);
        _set(ap, Keys.TRANSFER_LOCKER, d.transferLocker);
        return d;
    }

    // -------------------------------------------------------------------------
    //  Initialize
    // -------------------------------------------------------------------------

    function _initializeAll(CoreDeployment memory d) internal {
        console.log("--- initialize ---");

        // 1) Registries (cross-resolve)
        _upgradeAndCall(
            d.tournamentRegistry, d.tournamentRegistryImpl, abi.encodeCall(TournamentRegistry.initialize, ())
        );
        _upgradeAndCall(d.playerSetRegistry, d.playerSetRegistryImpl, abi.encodeCall(PlayerSetRegistry.initialize, ()));

        // 2) Factories (vault factories are immutable — already constructed)
        _upgradeAndCall(d.feeRouterFactory, d.feeRouterFactoryImpl, abi.encodeCall(FeeRouterFactory.initialize, ()));
        _upgradeAndCall(d.pbrFeeHubFactory, d.pbrFeeHubFactoryImpl, abi.encodeCall(PbrFeeHubFactory.initialize, ()));

        // 3) StakeVesting (needs registry + HP_TREASURY)
        _upgradeAndCall(d.stakeVesting, d.stakeVestingImpl, abi.encodeCall(StakeVesting.initialize, ()));

        // 4) DopplerConfig (needs factories + StakeVesting + Doppler modules)
        _upgradeAndCall(d.dopplerConfig, d.dopplerConfigImpl, abi.encodeCall(DopplerConfig.initialize, ()));

        // 5) Lockers
        _upgradeAndCall(d.dopplerLocker, d.dopplerLockerImpl, abi.encodeCall(DopplerLocker.initialize, ()));
        _upgradeAndCall(d.transferLocker, d.transferLockerImpl, abi.encodeCall(TransferLocker.initialize, ()));

        // 6) DeployTournament (needs treasury + fee-hub factories)
        _upgradeAndCall(d.deployTournament, d.deployTournamentImpl, abi.encodeCall(DeployTournament.initialize, ()));
    }

    // -------------------------------------------------------------------------
    //  Authorize + persist
    // -------------------------------------------------------------------------

    function _authorizeModules(
        address orchestrator,
        address deployTournament,
        address dopplerLocker,
        address transferLocker
    ) internal {
        Orchestrator orch = Orchestrator(orchestrator);
        orch.addAuthorizedContract(deployTournament);
        orch.addAuthorizedContract(dopplerLocker);
        orch.addAuthorizedContract(transferLocker);
        console.log("AUTHORIZED_CONTRACT on Orchestrator:");
        console.log("  DEPLOY_TOURNAMENT", deployTournament);
        console.log("  DOPPLER_LOCKER", dopplerLocker);
        console.log("  TRANSFER_LOCKER", transferLocker);
    }

    function _persistOutputs(DeployContext memory context, CoreDeployment memory d) internal {
        _setConfigAddress(context, "orchestrator", d.orchestrator);
        _setConfigAddress(context, "tournament_registry", d.tournamentRegistry);
        _setConfigAddress(context, "player_set_registry", d.playerSetRegistry);
        _setConfigAddress(context, "deploy_tournament", d.deployTournament);
        _setConfigAddress(context, "stake_vesting", d.stakeVesting);
        _setConfigAddress(context, "fee_router_factory", d.feeRouterFactory);
        _setConfigAddress(context, "player_vault_factory", d.playerVaultFactory);
        _setConfigAddress(context, "pbr_treasury_factory", d.pbrTreasuryFactory);
        _setConfigAddress(context, "pbr_fee_hub_factory", d.pbrFeeHubFactory);
        _setConfigAddress(context, "doppler_config", d.dopplerConfig);
        _setConfigAddress(context, "doppler_locker", d.dopplerLocker);
        _setConfigAddress(context, "transfer_locker", d.transferLocker);
    }
}
