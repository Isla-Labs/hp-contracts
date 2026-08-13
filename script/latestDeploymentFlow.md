# Core deployment flow

Canonical bootstrap for HighPotential protocol contracts on Base / Base Sepolia.

**Rule:** constructors take `AddressProvider` (via `AddressBook`). Dependencies are resolved from AP at call time. Core modules are **immutable** (`new` + register). Only the oracle CVM pair remains Transparent Upgradeable Proxy.

**Access model:**
- `AddressProvider` `DEFAULT_ADMIN_ROLE` → temporary deployer, then **`ConstitutionalTimelock`**
- Factory `UpgradeableBeacon` owners → AP `TIMELOCK` (**ConstitutionalTimelock**) at factory construction
- `Orchestrator` → entry surface gated by AP `HP_MULTISIG` (and soft `ELIGIBILITY_VERIFIER`); no AccessControl admin / `execute` path

---

## Preferred testnet order

```bash
make deploy-base-sepolia-oracle    # 1) CVM coordinator + router (JSON)
make deploy-base-sepolia-all       # 2) core + routers + AP admin → ConstitutionalTimelock
```

Optional redeploy routers only: `make deploy-base-sepolia-routers` (requires deployer still holding AP admin).

### DeployAll (step 2)

Script: [`DeployAll.s.sol`](DeployBase/DeployAll.s.sol)  
Config / Preconfig: [`deployments.config.toml`](../deployments.config.toml)

Order inside DeployAll:

1. Deploy AddressProvider (deployer = temporary `DEFAULT_ADMIN`)
2. Seed Preconfig (treasury, multisig, Doppler, Automata, oracle, …)
3. Deploy **ConstitutionalTimelock** → register `TIMELOCK` (default `TIMELOCK_MIN_DELAY` = 5 minutes on Sepolia)
4. Orchestrator → registries → StakeVesting
5. Factories (beacons owned by TIMELOCK)
6. DopplerConfig + TournamentInitializer + MarketInitializer + LifecycleManager + MigrationListener
7. Data plane: RoundManager, SquadStore, EligibilityVerifier, PbrHistorical, PbrSettle
8. Routers (zAMM + StakeRouter + TradeRouter) via direct `setName`
9. Soft handoff checks → `transferDefaultAdmin(ConstitutionalTimelock)`

Passthrough Doppler / Rehype addresses in the TOML before broadcasting. Staged make targets remain for partial redeploys.

---

## 1. Deploy AddressProvider

- Deploy `AddressProvider` with the deployer EOA as temporary admin.
- Persist `ADDRESS_PROVIDER` in `.env` and the staging address book.

**Script:** `DeployAddressProvider.s.sol`  
**Make:** `make deploy-base-sepolia-address-provider` / `make deploy-base-address-provider`

---

## 2. Deploy Oracle set

Oracle must exist before consumers that bind `CVM_ROUTER` in the constructor.

| Contract | AddressProvider name |
|---|---|
| `CvmCoordinator` (TUP) | `CVM_COORDINATOR` |
| `CvmRouter` (TUP) | `CVM_ROUTER` |

**Script:** `script/oracle/DeployOracle.s.sol`  
**Make:** `make deploy-base-sepolia-oracle`

> Prefer registering `CVM_*` on AP as soon as proxies exist. Oracle ProxyAdmins stay with OWNER out of band.

---

## 3. Deploy ConstitutionalTimelock (before factories)

| Contract | Name key | Notes |
|---|---|---|
| `ConstitutionalTimelock` | `TIMELOCK` | Multisig = proposer/canceller; open executors. Sepolia default delay 5m; mainnet staged uses `0` → 7 days |

**Make:** `deploy-base-sepolia-timelock` / `deploy-base-timelock`

---

## 4. Deploy core contracts

### Access / ops

| Contract | Name key | Notes |
|---|---|---|
| `Orchestrator` | `ORCHESTRATOR` | `constructor(ap, cooldown)`; admin = `HP_MULTISIG` |
| `TournamentInitializer` | `TOURNAMENT_INITIALIZER` | Topology create; factories gated to this |
| `MarketInitializer` | `MARKET_INITIALIZER` | Replaces DopplerLocker; Sepolia shorter queue waits |
| `LifecycleManager` | `LIFECYCLE_MANAGER` | Replaces TransferLocker; Sepolia `queueWait=5m` |
| `MigrationListener` | `MIGRATION_LISTENER` | Bonding → spot graduation sync |

### Registries / vesting

| Contract | Name key |
|---|---|
| `TournamentRegistry` | `TOURNAMENT_REGISTRY` |
| `PlayerSetRegistry` | `PLAYER_SET_REGISTRY` |
| `StakeVesting` | `STAKE_VESTING` |

### Factories (beacon owner = TIMELOCK)

| Contract | Name key |
|---|---|
| `FeeRouterFactory` | `FEE_ROUTER_FACTORY` |
| `PlayerVaultFactory` | `PLAYER_VAULT_FACTORY` |
| `PbrTreasuryFactory` | `PBR_TREASURY_FACTORY` |
| `PbrFeeHubFactory` | `PBR_FEE_HUB_FACTORY` |
| `DopplerConfig` | `DOPPLER_CONFIG` |

### Data plane

| Contract | Name key | Notes |
|---|---|---|
| `RoundManager` | `ROUND_MANAGER` | `0` cooldown → 1h default |
| `SquadStore` | `SQUAD_STORE` | `0` cooldown → 1h default |
| `EligibilityVerifier` | `ELIGIBILITY_VERIFIER` | Ctor-only; Sepolia 1m / else 1h |
| `PbrHistorical` | `PBR_HISTORICAL` | Binds `CVM_ROUTER` |
| `PbrSettle` | `PBR_SETTLE` | Binds `CVM_ROUTER` |

**Staged make order (Sepolia):**  
`address-provider` → `timelock` → `orchestrator` → `registries` → `stake-vesting` → `factories` → `tournament-initializer` → `initializers` → `data` → `pbr-settle` → `routers` → `handoff`

---

## 5. AddressProvider registration checklist

```
TIMELOCK
ORCHESTRATOR
TOURNAMENT_REGISTRY
PLAYER_SET_REGISTRY
STAKE_VESTING
FEE_ROUTER_FACTORY
PLAYER_VAULT_FACTORY
PBR_TREASURY_FACTORY
PBR_FEE_HUB_FACTORY
DOPPLER_CONFIG
TOURNAMENT_INITIALIZER
MARKET_INITIALIZER
LIFECYCLE_MANAGER
MIGRATION_LISTENER
ROUND_MANAGER
SQUAD_STORE
ELIGIBILITY_VERIFIER
PBR_HISTORICAL
PBR_SETTLE
STAKE_ROUTER
TRADE_ROUTER
Z_ROUTER
Z_QUOTER
```

Plus Preconfig: `HP_*`, `CVM_*`, Doppler modules, Automata, …

---

## Post-bootstrap handoff

1. **AddressProvider `DEFAULT_ADMIN_ROLE` → ConstitutionalTimelock**  
   (`DeployAll` end, `DeployHandoffStack`, or [`HandoffToTimelock.s.sol`](DeployBase/HandoffToTimelock.s.sol))

2. Further AP mutations go through Timelock schedule/execute (multisig proposes).

3. Oracle ProxyAdmins remain with OWNER until explicitly moved.

---

## Ownership model (summary)

```
HP Multisig
  ├── PROPOSER / CANCELLER on ConstitutionalTimelock
  │     ├── AddressProvider DEFAULT_ADMIN_ROLE
  │     └── UpgradeableBeacon.owner (via TIMELOCK at factory ctor)
  └── Orchestrator onlyAdmin / onlyDeployer (HP_MULTISIG + soft ELIGIBILITY_VERIFIER)

Open execution on ConstitutionalTimelock (address(0) executor)
Oracle TUP ProxyAdmins → OWNER (out of band)
```

---

## Script map (Base Sepolia)

| Step | Make target |
|---|---|
| **One-shot core bootstrap** | `deploy-base-sepolia-all` |
| AddressProvider | `deploy-base-sepolia-address-provider` |
| Oracle | `deploy-base-sepolia-oracle` |
| ConstitutionalTimelock | `deploy-base-sepolia-timelock` |
| Orchestrator | `deploy-base-sepolia-orchestrator` |
| Registries | `deploy-base-sepolia-registries` |
| StakeVesting | `deploy-base-sepolia-stake-vesting` |
| Factories | `deploy-base-sepolia-factories` |
| TournamentInitializer | `deploy-base-sepolia-tournament-initializer` |
| Market/Lifecycle/Migration | `deploy-base-sepolia-initializers` |
| Data plane | `deploy-base-sepolia-data` |
| PbrSettle | `deploy-base-sepolia-pbr-settle` |
| Routers | `deploy-base-sepolia-routers` |
| Handoff → CT | `deploy-base-sepolia-handoff` |

Mainnet mirrors use `deploy-base-*` without `-sepolia` (timelock default delay `0` → 7 days).
