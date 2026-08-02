# Open CVM Oracle Registration

**Status:** Hybrid — Phala Onchain KMS / `DstackApp` on **Ethereum**; `CvmCoordinator` + `CvmRouter` on **Base** (upgradeable Transparent proxies).  
**Depends on:** attestation verifier (Mock / Automata), CDP paymaster for UserOps

---

## Goal

Anyone can spin up a CVM running our approved compose and join as an oracle transmitter **without per-node DAO approval**.

DAO only sets **attestation policy** (`composeHash` allowlist on the Base coordinator). Phala boot policy on Ethereum is separate (Phala CLI / KMS).

---

## Trust split

| Layer | System | What it proves |
|---|---|---|
| Boot / keys | Phala Onchain KMS + `DstackApp` (**Ethereum**) | Only allowlisted compose can receive app keys |
| Transmitter join | `CvmCoordinator.registerOracle` + verifier (**Base**) | Transmitter bound in a fresh TEE quote under Base policy |
| Fulfill | `CvmRouter` → `isOracle` | Active, unexpired, compose still allowed (or break-glass) |

**Latest-compose enforcement:** `removeComposeHash` / `setAttestationComposeAllowed(h, false)` makes registrations on that hash fail `isOracle` immediately.

---

## Onchain surface

| Piece | Notes |
|---|---|
| `CvmCoordinator` | Registry only (no DstackApp ownership) |
| `CvmRouter` | Soft assignee (per-`CvmJob` exclusive) + request bus |
| Both | Behind `TransparentUpgradeableProxy`; ProxyAdmin owned by DAO/deployer |

### Permissionless

```solidity
registerOracle(bytes calldata attestation)
```

### Break-glass (CATEGORY_ONE)

```solidity
registerOracleBreakglass(deviceId, transmitter)
revokeOracle(transmitter)
```

### Governance (DAO)

```solidity
addComposeHash / removeComposeHash   // local _composeAllowed only
setAttestationComposeAllowed(h, bool)
setAttestationVerifier(addr)
setRegistrationTtl(ttl)
```

### `isOracle` rules

1. `active`  
2. `block.timestamp <= expiresAt`  
3. if `composeHash != 0` → `_composeAllowed[composeHash]`  

---

## Upgrades

Logic changes → deploy new implementation → `ProxyAdmin.upgradeAndCall` on the **same proxy address**.  
CVM sealed env (`CVM_COORDINATOR` / `CVM_ROUTER`) stays unchanged.

Scripts: `DeployOracle.s.sol`, `UpgradeCvmCoordinator.s.sol`, `UpgradeCvmRouter.s.sol`
(Makefile targets read/write `deployments/base-sepolia-oracle.json`).
