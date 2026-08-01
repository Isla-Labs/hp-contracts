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

# CVM oracle bus (MockDstackApp + MockAttestationVerifier by default).
# Optional: COMPOSE_HASH=0x… (bytes32) to allowlist at deploy — or run
# oracle-sepolia-add-compose after Phala prints the real compose_hash.
deploy-base-sepolia-oracle:
	@forge script script/oracle/DeployOracle.s.sol:DeployOracle \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	@echo "Wrote deployments/base-sepolia-oracle.json"
	@echo "Next: allowlist Phala compose_hash via make oracle-sepolia-add-compose COMPOSE_HASH=0x…"

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
	deploy-base-sepolia-oracle oracle-sepolia-add-compose \
	install build test coverage fmt fmt-check
