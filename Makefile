-include .env
export

# Optional forge CLI flags, e.g. `make deploy-base-sepolia-all FORGE_FLAGS="-vvvv"`
FORGE_FLAGS ?=

# Deployment history (requires bun)
generate-history:
	@bun run ./deployments/cli.ts --output history

# ---------------------------------------------------------------------------
# Base mainnet — sequential isolated deploys
# ---------------------------------------------------------------------------

deploy-base-address-provider:
	@forge script script/DeployBase/DeployAddressProvider.s.sol:DeployAddressProvider \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-timelock:
	@forge script script/DeployBase/DeployBase.s.sol:DeployTimelockStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-orchestrator:
	@forge script script/DeployBase/DeployBase.s.sol:DeployOrchestratorStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-registries:
	@forge script script/DeployBase/DeployBase.s.sol:DeployRegistriesStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-stake-vesting:
	@forge script script/DeployBase/DeployBase.s.sol:DeployStakeVestingStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-factories:
	@forge script script/DeployBase/DeployBase.s.sol:DeployFactoriesStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-tournament-initializer:
	@forge script script/DeployBase/DeployBase.s.sol:DeployTournamentInitializerStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-initializers:
	@forge script script/DeployBase/DeployBase.s.sol:DeployInitializersStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-data:
	@forge script script/DeployBase/DeployBase.s.sol:DeployDataStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-pbr-settle:
	@forge script script/DeployBase/DeployBase.s.sol:DeployPbrSettleStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-handoff:
	@forge script script/DeployBase/DeployBase.s.sol:DeployHandoffStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# ---------------------------------------------------------------------------
# Base Sepolia — sequential isolated deploys
# ---------------------------------------------------------------------------

# Preferred testnet order:
#   1) make deploy-base-sepolia-oracle
#   2) make deploy-base-sepolia-all   (core + routers + CT handoff)
#
# One-shot bootstrap: AP → Preconfig → CT → core → routers → AP admin → CT.
# Requires oracle already launched (deployments.config.toml or deployments/base-sepolia-oracle.json).
# Passthrough Doppler/Rehype addresses in deployments.config.toml before broadcast.
# Also requires uniswap_v4_pool_manager (TradeRouter) and z_*=0 for zAMM self-deploy.
deploy-base-sepolia-all:
	@forge script script/DeployBase/DeployAll.s.sol:DeployAll \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow $(FORGE_FLAGS)
	$(MAKE) generate-history

# Optional: redeploy routers only against an existing AP (pre–timelock AP admin).
# Prefer deploy-base-sepolia-all for first bootstrap.
deploy-base-sepolia-routers:
	@forge script script/DeployBase/DeployRouters.s.sol:DeployRouters \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow $(FORGE_FLAGS)
	$(MAKE) generate-history

# 1) Oracle (registers CVM_* on AP when ADDRESS_PROVIDER set + owned by deployer)
deploy-base-sepolia-oracle:
	@forge script script/oracle/DeployOracle.s.sol:DeployOracle \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	@echo "Wrote deployments/base-sepolia-oracle.json"
	@echo "Next: allowlist Phala compose_hash via make oracle-sepolia-add-compose COMPOSE_HASH=0x…"

# 2) AddressProvider — paste ADDRESS_PROVIDER into .env (+ staging book)
deploy-base-sepolia-address-provider:
	@forge script script/DeployBase/DeployAddressProvider.s.sol:DeployAddressProvider \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 3) ConstitutionalTimelock → TIMELOCK (before factories)
deploy-base-sepolia-timelock:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployTimelockStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 4) Orchestrator
deploy-base-sepolia-orchestrator:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployOrchestratorStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 5) Registries
deploy-base-sepolia-registries:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployRegistriesStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 6) StakeVesting
deploy-base-sepolia-stake-vesting:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployStakeVestingStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 7) Factories (beacons owned by TIMELOCK)
deploy-base-sepolia-factories:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployFactoriesStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 8) TournamentInitializer
deploy-base-sepolia-tournament-initializer:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployTournamentInitializerStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 9) Market / lifecycle initializers + MigrationListener
deploy-base-sepolia-initializers:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployInitializersStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 10) Data plane
deploy-base-sepolia-data:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployDataStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 11) PbrSettle (also included in deploy-base-sepolia-all)
deploy-base-sepolia-pbr-settle:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployPbrSettleStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# 12) Handoff AddressProvider DEFAULT_ADMIN → ConstitutionalTimelock
deploy-base-sepolia-handoff:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployHandoffStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# Upgrade coordinator logic in place (stable proxy from deployments/base-sepolia-oracle.json).
upgrade-base-sepolia-cvm-coordinator:
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json" && exit 1)
	@forge script script/oracle/UpgradeCvmCoordinator.s.sol:UpgradeCvmCoordinator \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow

upgrade-base-sepolia-cvm-router:
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json" && exit 1)
	@forge script script/oracle/UpgradeCvmRouter.s.sol:UpgradeCvmRouter \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow

oracle-sepolia-add-compose:
	@test -n "$(COMPOSE_HASH)" || (echo "COMPOSE_HASH=0x… required" && exit 1)
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1)
	@COORD=$$(sed -n 's/.*"cvmCoordinator": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$COORD" || (echo "could not parse cvmCoordinator" && exit 1); \
		echo "addComposeHash $$COORD $(COMPOSE_HASH)"; \
		cast send "$$COORD" "addComposeHash(bytes32)" "$(COMPOSE_HASH)" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

oracle-sepolia-set-verifier:
	@VERIFIER="$(or $(VERIFIER),0xcA6AD7614f81C0803014cDddD2a1C13149996834)"; \
		test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1); \
		COORD=$$(sed -n 's/.*"cvmCoordinator": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$COORD" || (echo "could not parse cvmCoordinator" && exit 1); \
		echo "setAttestationVerifier $$COORD $$VERIFIER"; \
		cast send "$$COORD" "setAttestationVerifier(address)" "$$VERIFIER" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL); \
		echo "onchain:" $$(cast call "$$COORD" "attestationVerifier()(address)" --rpc-url $(BASE_SEPOLIA_RPC_URL))

oracle-sepolia-set-config:
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1)
	@ROUTER=$$(sed -n 's/.*"cvmRouter": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$ROUTER" || (echo "could not parse cvmRouter" && exit 1); \
		echo "updateConfig $$ROUTER (5000000,3600,5000)"; \
		cast send "$$ROUTER" "updateConfig((uint32,uint32,uint16))" "(5000000,3600,5000)" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL); \
		echo "onchain:" $$(cast call "$$ROUTER" "getConfig()(uint32,uint32,uint16)" --rpc-url $(BASE_SEPOLIA_RPC_URL))

oracle-sepolia-set-ttl:
	@test -n "$(TTL)" || (echo "TTL=<seconds> required (e.g. 86400)" && exit 1)
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1)
	@COORD=$$(sed -n 's/.*"cvmCoordinator": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$COORD" || (echo "could not parse cvmCoordinator" && exit 1); \
		echo "setRegistrationTtl $$COORD $(TTL)"; \
		cast send "$$COORD" "setRegistrationTtl(uint64)" "$(TTL)" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

oracle-sepolia-remove-compose:
	@test -n "$(COMPOSE_HASH)" || (echo "COMPOSE_HASH=0x… required" && exit 1)
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1)
	@COORD=$$(sed -n 's/.*"cvmCoordinator": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$COORD" || (echo "could not parse cvmCoordinator" && exit 1); \
		echo "removeComposeHash $$COORD $(COMPOSE_HASH)"; \
		cast send "$$COORD" "removeComposeHash(bytes32)" "$(COMPOSE_HASH)" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

deploy-base-sepolia-test-data:
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy oracle first" && exit 1)
	@ROUTER=$${CVM_ROUTER:-$$(sed -n 's/.*"cvmRouter": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1)}; \
		test -n "$$ROUTER" || (echo "could not parse cvmRouter" && exit 1); \
		echo "Deploying TestData → router $$ROUTER"; \
		CVM_ROUTER=$$ROUTER forge script script/oracle/DeployTestData.s.sol:DeployTestData \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
			--broadcast --slow

# ---------------------------------------------------------------------------
# Build & test
# ---------------------------------------------------------------------------

install:
	forge install

build:
	forge build

test:
	forge test --show-progress

coverage:
	forge coverage --ir-minimum --report lcov

fmt:
	forge fmt

fmt-check:
	forge fmt --check

.PHONY: generate-history \
	deploy-base-address-provider deploy-base-timelock deploy-base-orchestrator deploy-base-registries \
	deploy-base-stake-vesting deploy-base-factories deploy-base-tournament-initializer \
	deploy-base-initializers deploy-base-data deploy-base-pbr-settle deploy-base-handoff \
	deploy-base-sepolia-all deploy-base-sepolia-routers \
	deploy-base-sepolia-oracle deploy-base-sepolia-address-provider deploy-base-sepolia-timelock \
	deploy-base-sepolia-orchestrator deploy-base-sepolia-registries deploy-base-sepolia-stake-vesting \
	deploy-base-sepolia-factories deploy-base-sepolia-tournament-initializer \
	deploy-base-sepolia-initializers deploy-base-sepolia-data deploy-base-sepolia-pbr-settle \
	deploy-base-sepolia-handoff \
	upgrade-base-sepolia-cvm-coordinator upgrade-base-sepolia-cvm-router \
	oracle-sepolia-add-compose oracle-sepolia-remove-compose oracle-sepolia-set-verifier \
	oracle-sepolia-set-config oracle-sepolia-set-ttl deploy-base-sepolia-test-data \
	install build test coverage fmt fmt-check
