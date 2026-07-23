-include .env
export

# Deployment history (requires bun)
generate-history:
	@bun run ./deployments/cli.ts --output history

# ---------------------------------------------------------------------------
# Base mainnet
# ---------------------------------------------------------------------------

deploy-base:
	@forge script script/DeployBase/DeployBase.s.sol:DeployAll \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-core:
	@forge script script/DeployBase/DeployBase.s.sol:DeployCoreStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

# ---------------------------------------------------------------------------
# Base Sepolia
# ---------------------------------------------------------------------------

deploy-base-sepolia:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployAll \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

deploy-base-sepolia-core:
	@forge script script/DeployBase/DeployBaseSepolia.s.sol:DeployCoreStack \
		--private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--verify --verifier-url "$(VERIFIER_URL)$(CHAIN_ID_BASE_SEPOLIA)" --etherscan-api-key $(ETHERSCAN_API_KEY) \
		--broadcast --slow
	$(MAKE) generate-history

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

.PHONY: generate-history deploy-base deploy-base-core deploy-base-sepolia deploy-base-sepolia-core \
	install build test coverage fmt fmt-check
