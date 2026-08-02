-include .env
export

# Deployment history (requires bun)
generate-history:
	@bun run ./deployments/cli.ts --output history

# ---------------------------------------------------------------------------
# Base mainnet
# ---------------------------------------------------------------------------

deploy-base-core:
	@forge script script/DeployBase/DeployBase.s.sol:DeployCoreStack \
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

deploy-base-data:
	@forge script script/DeployBase/DeployBase.s.sol:DeployDataStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# ---------------------------------------------------------------------------
# Base Sepolia
# ---------------------------------------------------------------------------

deploy-base-sepolia-core:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployCoreStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-sepolia-factories:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployFactoriesStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-sepolia-data:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployDataStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# CVM oracle bus (upgradeable TUP proxies; MockAttestationVerifier by default).
# ProxyAdmin owner = DAO_ADDRESS (defaults to deployer). Optional: COMPOSE_HASH=0x…
# at deploy, or run oracle-sepolia-add-compose after Phala prints the real hash.
deploy-base-sepolia-oracle:
	@forge script script/oracle/DeployOracle.s.sol:DeployOracle \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	@echo "Wrote deployments/base-sepolia-oracle.json"
	@echo "Next: allowlist Phala compose_hash via make oracle-sepolia-add-compose COMPOSE_HASH=0x…"

# Upgrade coordinator logic in place (stable proxy from deployments/base-sepolia-oracle.json).
# Writes cvmCoordinatorImpl back to that file.
upgrade-base-sepolia-cvm-coordinator:
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json" && exit 1)
	@forge script script/oracle/UpgradeCvmCoordinator.s.sol:UpgradeCvmCoordinator \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow

# Upgrade router logic in place (stable proxy from deployments/base-sepolia-oracle.json).
# Seeds default per-job exclusives, writes cvmRouterImpl back to that file.
upgrade-base-sepolia-cvm-router:
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json" && exit 1)
	@forge script script/oracle/UpgradeCvmRouter.s.sol:UpgradeCvmRouter \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow

# Sync Phala CVM compose_hash onto the Sepolia coordinator attestation policy.
# Requires: COMPOSE_HASH=0x…64 hex chars, and deployments/base-sepolia-oracle.json
oracle-sepolia-add-compose:
	@test -n "$(COMPOSE_HASH)" || (echo "COMPOSE_HASH=0x… required" && exit 1)
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1)
	@COORD=$$(sed -n 's/.*"cvmCoordinator": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$COORD" || (echo "could not parse cvmCoordinator" && exit 1); \
		echo "addComposeHash $$COORD $(COMPOSE_HASH)"; \
		cast send "$$COORD" "addComposeHash(bytes32)" "$(COMPOSE_HASH)" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

# Tighten / loosen registration TTL (default deploy was 7d; prefer 1d with 4h re-attest).
# Usage: make oracle-sepolia-set-ttl TTL=86400
oracle-sepolia-set-ttl:
	@test -n "$(TTL)" || (echo "TTL=<seconds> required (e.g. 86400)" && exit 1)
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1)
	@COORD=$$(sed -n 's/.*"cvmCoordinator": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$COORD" || (echo "could not parse cvmCoordinator" && exit 1); \
		echo "setRegistrationTtl $$COORD $(TTL)"; \
		cast send "$$COORD" "setRegistrationTtl(uint64)" "$(TTL)" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

# Drop a compose hash from local attestation policy (instant isOracle revoke).
oracle-sepolia-remove-compose:
	@test -n "$(COMPOSE_HASH)" || (echo "COMPOSE_HASH=0x… required" && exit 1)
	@test -f deployments/base-sepolia-oracle.json || (echo "missing deployments/base-sepolia-oracle.json — deploy first" && exit 1)
	@COORD=$$(sed -n 's/.*"cvmCoordinator": "\([^"]*\)".*/\1/p' deployments/base-sepolia-oracle.json | head -1); \
		test -n "$$COORD" || (echo "could not parse cvmCoordinator" && exit 1); \
		echo "removeComposeHash $$COORD $(COMPOSE_HASH)"; \
		cast send "$$COORD" "removeComposeHash(bytes32)" "$(COMPOSE_HASH)" \
			--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

# Deploy TestData consumer against the live Sepolia CvmRouter.
# → deployments/base-sepolia-test-data.json
# Smoke (after CVM image understands CvmJob.TestFetch):
#   cast send $(jq -r .testData deployments/base-sepolia-test-data.json) \
#     "request(string)" "hello" --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)
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
	deploy-base-core deploy-base-factories deploy-base-data \
	deploy-base-sepolia-core deploy-base-sepolia-factories deploy-base-sepolia-data \
	deploy-base-sepolia-oracle upgrade-base-sepolia-cvm-coordinator upgrade-base-sepolia-cvm-router \
	oracle-sepolia-add-compose oracle-sepolia-remove-compose oracle-sepolia-set-ttl deploy-base-sepolia-test-data \
	install build test coverage fmt fmt-check
