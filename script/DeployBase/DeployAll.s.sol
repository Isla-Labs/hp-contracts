// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { console2 as console } from "forge-std/console2.sol";

import { AddressKeys as Keys } from "@base/global/libraries/addresses/AddressKeys.sol";
import { EligibilityVerifier } from "@data/eligibility/EligibilityVerifier.sol";
import { SquadStore } from "@data/eligibility/SquadStore.sol";
import { MigrationListener } from "@data/markets/MigrationListener.sol";
import { RoundManager } from "@data/matchweeks/RoundManager.sol";
import { PbrHistorical } from "@data/performances/PbrHistorical.sol";
import { PbrSettle } from "@data/performances/PbrSettle.sol";
import { ConstitutionalTimelock } from "@governance/ConstitutionalTimelock.sol";
import { StakeVesting } from "@governance/StakeVesting.sol";
import { LifecycleManager } from "@initializers/lifecycle/LifecycleManager.sol";
import { DopplerConfig } from "@initializers/markets/base/DopplerConfig.sol";
import { MarketInitializer } from "@initializers/markets/MarketInitializer.sol";
import { TournamentInitializer } from "@initializers/tournaments/TournamentInitializer.sol";
import { FeeRouterFactory } from "@markets/factories/FeeRouterFactory.sol";
import { PbrFeeHubFactory } from "@markets/factories/PbrFeeHubFactory.sol";
import { PlayerSetRegistry } from "@registries/PlayerSetRegistry.sol";
import { TournamentRegistry } from "@registries/TournamentRegistry.sol";
import { AddressProvider } from "@src/AddressProvider.sol";
import { Orchestrator } from "@src/Orchestrator.sol";
import { PbrTreasuryFactory } from "@vaults/factories/PbrTreasuryFactory.sol";
import { PlayerVaultFactory } from "@vaults/factories/PlayerVaultFactory.sol";

import { DeployHandoff } from "../utils/DeployHandoff.sol";
import { DeployRoutersLogic } from "../utils/DeployRoutersLogic.sol";
import { HpDeployBase } from "../utils/HpDeployBase.sol";

/**
 * @title DeployAll
 * @notice One-shot Base Sepolia core bootstrap including routers + ConstitutionalTimelock handoff.
 * @dev Flow:
 *      1) Deploy AddressProvider (deployer = temporary DEFAULT_ADMIN)
 *      2) Seed Preconfig (treasury, multisig, Doppler, Automata, oracle, …)
 *      3) ConstitutionalTimelock → TIMELOCK (beacon upgrade authority for factories)
 *      4) Orchestrator → registries → StakeVesting → factories
 *      5) DopplerConfig + initializers + data plane + PbrSettle
 *      6) Deploy + register zAMM stack, StakeRouter, TradeRouter
 *      7) Soft handoff checks → transfer AddressProvider DEFAULT_ADMIN → ConstitutionalTimelock
 *
 *      Env: PRIVATE_KEY; optional OWNER_ADDRESS / DAO_ADDRESS (hpMultisig for CT proposer);
 *           optional TIMELOCK_MIN_DELAY (default 5 minutes on testnet; `0` → CT DEFAULT_MIN_DELAY).
 *      Make: `make deploy-base-sepolia-all` (optional `FORGE_FLAGS="-vvvv"`)
 */
contract DeployAll is HpDeployBase, DeployHandoff, DeployRoutersLogic {
    struct CoreDeployment {
        address addressProvider;
        address constitutionalTimelock;
        address orchestrator;
        address tournamentRegistry;
        address playerSetRegistry;
        address stakeVesting;
        address feeRouterFactory;
        address playerVaultFactory;
        address pbrTreasuryFactory;
        address pbrFeeHubFactory;
        address dopplerConfig;
        address tournamentInitializer;
        address marketInitializer;
        address lifecycleManager;
        address migrationListener;
        address roundManager;
        address squadStore;
        address eligibilityVerifier;
        address pbrHistorical;
        address pbrSettle;
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
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(5 minutes));
        console.log("=== DeployAll ===");
        console.log("chainId", context.chainId);
        console.log("deployer", deployer);
        console.log("owner (CT proposer / multisig)", owner);
        console.log("TIMELOCK_MIN_DELAY", minDelay);

        vm.startBroadcast(privateKey);

        d.addressProvider = address(new AddressProvider(deployer));
        AddressProvider ap = AddressProvider(payable(d.addressProvider));
        _setConfigAddress(context, "address_provider", d.addressProvider);
        console.log("ADDRESS_PROVIDER", d.addressProvider);

        _seedPreconfig(ap, context.preconfig);

        // Beacon upgrade authority: factories read TIMELOCK at construction.
        d.constitutionalTimelock = address(new ConstitutionalTimelock(owner, minDelay));
        _set(ap, Keys.TIMELOCK, d.constitutionalTimelock);
        console.log("CONSTITUTIONAL_TIMELOCK", d.constitutionalTimelock);

        d = _deployAndRegister(ap, d);

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
        _handoffPreTransfer(deployer);

        ap.transferDefaultAdmin(d.constitutionalTimelock);
        console.log("AddressProvider DEFAULT_ADMIN -> ConstitutionalTimelock", d.constitutionalTimelock);

        _handoffPostTransfer(d.constitutionalTimelock);

        vm.stopBroadcast();

        console.log("=== DeployAll complete - paste into .env ===");
        console.log("ADDRESS_PROVIDER", d.addressProvider);
        console.log("CONSTITUTIONAL_TIMELOCK", d.constitutionalTimelock);
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
        _set(ap, Keys.HP_MULTISIG, p.hpMultisig);
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
    //  Deploy + register (all immutable)
    // -------------------------------------------------------------------------

    function _deployAndRegister(AddressProvider ap, CoreDeployment memory d) internal returns (CoreDeployment memory) {
        console.log("--- deploy immutable core ---");
        address apAddr = address(ap);

        d.orchestrator = address(new Orchestrator(apAddr, 0));
        _set(ap, Keys.ORCHESTRATOR, d.orchestrator);

        d.tournamentRegistry = address(new TournamentRegistry(apAddr));
        d.playerSetRegistry = address(new PlayerSetRegistry(apAddr));
        _set(ap, Keys.TOURNAMENT_REGISTRY, d.tournamentRegistry);
        _set(ap, Keys.PLAYER_SET_REGISTRY, d.playerSetRegistry);

        // Needs HP_TREASURY + HP_MULTISIG on AP (roles + default beneficiaries).
        d.stakeVesting = address(new StakeVesting(apAddr));
        _set(ap, Keys.STAKE_VESTING, d.stakeVesting);

        // Factories need TIMELOCK on AP (beacon owner); Oracle consumers bind CVM_ROUTER.
        d.feeRouterFactory = address(new FeeRouterFactory(apAddr));
        d.pbrFeeHubFactory = address(new PbrFeeHubFactory(apAddr));
        d.playerVaultFactory = address(new PlayerVaultFactory(apAddr));
        d.pbrTreasuryFactory = address(new PbrTreasuryFactory(apAddr));
        _set(ap, Keys.FEE_ROUTER_FACTORY, d.feeRouterFactory);
        _set(ap, Keys.PBR_FEE_HUB_FACTORY, d.pbrFeeHubFactory);
        _set(ap, Keys.PLAYER_VAULT_FACTORY, d.playerVaultFactory);
        _set(ap, Keys.PBR_TREASURY_FACTORY, d.pbrTreasuryFactory);

        d.dopplerConfig = address(new DopplerConfig(apAddr));
        d.tournamentInitializer = address(new TournamentInitializer(apAddr));
        d.marketInitializer = address(new MarketInitializer(apAddr));
        d.lifecycleManager = address(new LifecycleManager(apAddr));
        d.migrationListener = address(new MigrationListener(apAddr, 0));
        _set(ap, Keys.DOPPLER_CONFIG, d.dopplerConfig);
        _set(ap, Keys.TOURNAMENT_INITIALIZER, d.tournamentInitializer);
        _set(ap, Keys.MARKET_INITIALIZER, d.marketInitializer);
        _set(ap, Keys.LIFECYCLE_MANAGER, d.lifecycleManager);
        _set(ap, Keys.MIGRATION_LISTENER, d.migrationListener);

        d.roundManager = address(new RoundManager(apAddr, 0));
        d.squadStore = address(new SquadStore(apAddr, 0));
        // Ctor picks Sepolia 1m / mainnet DEFAULT_COOLDOWN via chainid.
        d.eligibilityVerifier = address(new EligibilityVerifier(apAddr));
        d.pbrHistorical = address(new PbrHistorical(apAddr));
        d.pbrSettle = address(new PbrSettle(apAddr));
        _set(ap, Keys.ROUND_MANAGER, d.roundManager);
        _set(ap, Keys.SQUAD_STORE, d.squadStore);
        _set(ap, Keys.ELIGIBILITY_VERIFIER, d.eligibilityVerifier);
        _set(ap, Keys.PBR_HISTORICAL, d.pbrHistorical);
        _set(ap, Keys.PBR_SETTLE, d.pbrSettle);

        console.log("ORCHESTRATOR", d.orchestrator);
        console.log("STAKE_VESTING", d.stakeVesting);
        console.log("FEE_ROUTER_FACTORY", d.feeRouterFactory);
        console.log("PBR_FEE_HUB_FACTORY", d.pbrFeeHubFactory);
        console.log("PLAYER_VAULT_FACTORY", d.playerVaultFactory);
        console.log("PBR_TREASURY_FACTORY", d.pbrTreasuryFactory);
        console.log("DOPPLER_CONFIG", d.dopplerConfig);
        console.log("TOURNAMENT_INITIALIZER", d.tournamentInitializer);
        console.log("MARKET_INITIALIZER", d.marketInitializer);
        console.log("LIFECYCLE_MANAGER", d.lifecycleManager);
        console.log("MIGRATION_LISTENER", d.migrationListener);
        console.log("ROUND_MANAGER", d.roundManager);
        console.log("SQUAD_STORE", d.squadStore);
        console.log("ELIGIBILITY_VERIFIER", d.eligibilityVerifier);
        console.log("PBR_HISTORICAL", d.pbrHistorical);
        console.log("PBR_SETTLE", d.pbrSettle);

        return d;
    }

    // -------------------------------------------------------------------------
    //  Persist
    // -------------------------------------------------------------------------

    function _persistOutputs(DeployContext memory context, CoreDeployment memory d) internal {
        _setConfigAddress(context, "constitutional_timelock", d.constitutionalTimelock);
        _setConfigAddress(context, "orchestrator", d.orchestrator);
        _setConfigAddress(context, "tournament_registry", d.tournamentRegistry);
        _setConfigAddress(context, "player_set_registry", d.playerSetRegistry);
        _setConfigAddress(context, "stake_vesting", d.stakeVesting);
        _setConfigAddress(context, "fee_router_factory", d.feeRouterFactory);
        _setConfigAddress(context, "player_vault_factory", d.playerVaultFactory);
        _setConfigAddress(context, "pbr_treasury_factory", d.pbrTreasuryFactory);
        _setConfigAddress(context, "pbr_fee_hub_factory", d.pbrFeeHubFactory);
        _setConfigAddress(context, "doppler_config", d.dopplerConfig);
        _setConfigAddress(context, "tournament_initializer", d.tournamentInitializer);
        _setConfigAddress(context, "market_initializer", d.marketInitializer);
        _setConfigAddress(context, "lifecycle_manager", d.lifecycleManager);
        _setConfigAddress(context, "migration_listener", d.migrationListener);
        _setConfigAddress(context, "round_manager", d.roundManager);
        _setConfigAddress(context, "squad_store", d.squadStore);
        _setConfigAddress(context, "eligibility_verifier", d.eligibilityVerifier);
        _setConfigAddress(context, "pbr_historical", d.pbrHistorical);
        _setConfigAddress(context, "pbr_settle", d.pbrSettle);
    }
}
