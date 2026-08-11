# Core deployment flow

Canonical bootstrap for HighPotential protocol contracts on Base / Base Sepolia.

**Rule:** constructors take `AddressProvider` (via `AddressBook`). Dependencies and ownership are resolved only in `initialize`, after names exist on the provider. Orchestrator is the Ownable owner of protocol contracts; the EOA (later Safe) holds `DEFAULT_ADMIN_ROLE` on Orchestrator and calls through `Orchestrator.execute`.

---

## Preferred testnet order

```bash
make deploy-base-sepolia-oracle    # 1) CVM coordinator + router (JSON)
make deploy-base-sepolia-all       # 2) core + routers + handoff
```

Optional redeploy routers only: `make deploy-base-sepolia-routers`.

### DeployAll (step 2)

Script: [`DeployAll.s.sol`](DeployBase/DeployAll.s.sol)  
Config / Preconfig: [`deployments.config.toml`](../deployments.config.toml) (treasury, multisig, Doppler, Automata, oracle, `uniswap_v4_pool_manager`, optional z_*)

Order inside DeployAll:

1. Deploy AddressProvider  
2. Seed Preconfig (incl. existing oracle) onto AP  
3. Deploy InitGuard shells + Orchestrator (+ StakeVesting)  
4. Register all protocol names  
5. Initialize: registries → factories → StakeVesting → DopplerConfig → lockers → DeployTournament  
6. Authorize DeployTournament + DopplerLocker  
7. **Routers** (pre-handoff, direct `setName`): zAMM stack + StakeRouter + TradeRouter  
8. Handoff AP + ProxyAdmins → Orchestrator  

**Routers step** (shared with [`DeployRoutersLogic`](utils/DeployRoutersLogic.sol)):

- Base Sepolia zAMM self-deploy when `z_router` / `z_quoter` / `z_quoter_base` are all zero (`src/routers/base-sepolia/`):
  1. `ZRouter` → 2. `ZQuoterBase` → 3. `ZQuoter` (SDK address)
- Registers `Z_ROUTER`, `Z_QUOTER`, `STAKE_ROUTER`, `TRADE_ROUTER`
- Requires `uniswap_v4_pool_manager` in TOML (TradeRouter ctor)
- Backend: point zamm SDK at written `z_quoter` / `z_router`

Passthrough Doppler / Rehype addresses in the TOML before broadcasting. Staged make targets below remain for partial redeploys.

---

## 1. Deploy AddressProvider

- Deploy `AddressProvider` with the deployer EOA as temporary owner.
- Persist `ADDRESS_PROVIDER` in `.env` and the staging address book.
- Deployer keeps AP ownership until final handoff (step after init).

**Script:** `DeployAddressProvider.s.sol`  
**Make:** `make deploy-base-sepolia-address-provider` / `make deploy-base-address-provider`

---

## 2. Deploy Oracle set

Oracle must exist before lockers / consumers that bind `CVM_ROUTER` (immutable on impl).

| Contract | AddressProvider name |
|---|---|
| `CvmCoordinator` (TUP) | `CVM_COORDINATOR` |
| `CvmRouter` (TUP) | `CVM_ROUTER` |
| Attestation verifier (Automata or mock) | (not always named; coordinator holds ref) |

Optional / out-of-band: Automata DCAP constants, Phala compose-hash allowlist.

**Register** `CVM_COORDINATOR` + `CVM_ROUTER` on AddressProvider as soon as proxies exist (AP is already live from step 1).

**Script:** `script/oracle/DeployOracle.s.sol`  
**Make:** `make deploy-base-sepolia-oracle`

> Oracle proxies are a special case: they initialize with explicit constructor/init args (owner, verifier, router config) rather than resolving everything from AddressBook. Prefer Orchestrator (or the eventual Safe) as oracle Ownable owner when wiring production ownership.

---

## 3. Deploy all other contracts

Deploy upgradeable shells (InitGuard → Transparent proxy) and implementations. Prefer **register-before-init** within each batch; defer `initialize` when a contract’s AddressBook deps are not yet on AP.

### Access / ops

| Contract | Name key | Notes |
|---|---|---|
| `Orchestrator` | `ORCHESTRATOR` | Not upgradeable; `constructor(admin)` grants `DEFAULT_ADMIN_ROLE` |
| `DeployTournament` | `DEPLOY_TOURNAMENT` | Proxy only here; **init deferred** until factories are registered |
| | | Grant `AUTHORIZED_CONTRACT` on Orchestrator to the DeployTournament proxy |

### Registries

| Contract | Name key |
|---|---|
| `TournamentRegistry` | `TOURNAMENT_REGISTRY` |
| `PlayerSetRegistry` | `PLAYER_SET_REGISTRY` |

### Lockers

| Contract | Name key | Notes |
|---|---|---|
| `DopplerLocker` | `DOPPLER_LOCKER` | Impl ctor reads `CVM_ROUTER` from AP (immutable) |
| `TransferLocker` | `TRANSFER_LOCKER` | |

### Factories

| Contract | Name key |
|---|---|
| `FeeRouterFactory` | `FEE_ROUTER_FACTORY` |
| `PlayerVaultFactory` | `PLAYER_VAULT_FACTORY` |
| `PbrTreasuryFactory` | `PBR_TREASURY_FACTORY` |
| `PbrFeeHubFactory` | `PBR_FEE_HUB_FACTORY` |

### Data (in progress)

| Contract | Name key | Status |
|---|---|---|
| `RoundManager` | `ROUND_MANAGER` | Live |
| `EligibilityStore` | `ELIGIBILITY_STORE` | In progress |
| `EligibilityVerifier` | `ELIGIBILITY_VERIFIER` | In progress |
| `PpmVerifier` / `PbrSettle` / CRE forwarder | respective keys | In progress |

**Make (current staged scripts):**  
`orchestrator` → `registries` → `deploy-tournament` → `data` → `lockers` → `factories`

---

## 4. Ensure AddressProvider has all contracts registered

Every name in `AddressKeys.sol` that this environment uses must resolve to a non-zero address before dependents initialize.

Minimum for a working markets / tournament bootstrap:

```
ORCHESTRATOR
CVM_COORDINATOR
CVM_ROUTER
TOURNAMENT_REGISTRY
PLAYER_SET_REGISTRY
DEPLOY_TOURNAMENT
DOPPLER_LOCKER
TRANSFER_LOCKER
ROUND_MANAGER
FEE_ROUTER_FACTORY
PLAYER_VAULT_FACTORY
PBR_TREASURY_FACTORY
PBR_FEE_HUB_FACTORY
```

Keys are `keccak256(bytes(name))` — see `AddressKeys.sol` / `HP8453` / `HP84532`.

Staging helper: `npm run script:set-address` (when a name was missed).

---

## 5. Initialize via AddressBook (deps + ownership → Orchestrator)

For each AddressBook contract, `initialize` (or `initialize(...)` with only instance-specific params):

1. Resolve required addresses with `_getAddress(_addressKey(...))`.
2. Transfer Ownable ownership to `ORCHESTRATOR`.
3. Never pass Orchestrator / registry / factory addresses as long-lived wiring from the deploy script when they already live on AP.

### Typical `initialize` shape

```solidity
function initialize() external initializer {
    // resolve deps from AddressProvider
    // ...
    _transferOwnership(_getAddress(_addressKey(Addresses.ORCHESTRATOR)));
}
```

### Init order constraints

| Contract | When to initialize | Resolves |
|---|---|---|
| Registries | After both registry names + `ORCHESTRATOR` on AP | Cross-registry + Orchestrator |
| RoundManager | After `ORCHESTRATOR` + `TOURNAMENT_REGISTRY` | Orchestrator |
| Lockers | After `ORCHESTRATOR` (+ registries for TransferLocker; `CVM_ROUTER` already in DopplerLocker ctor) | Orchestrator / registries |
| Factories | After `ORCHESTRATOR` on AP | Orchestrator (+ deploy beacon impls) |
| **DeployTournament** | **After** treasury + fee-hub factory names on AP | Orchestrator, TournamentRegistry, factories; sets `factoriesConfigured` |

Beacon / CREATE3 **instances** (`PbrTreasury`, `PbrFeeHub`, `FeeRouter`, `PlayerVault`) are initialized by factories at market/tournament create time — not in this protocol bootstrap.

### Privileged calls after init

- Admin (EOA / Safe) → `Orchestrator.execute(target, 0, calldata)`.
- Modules with `AUTHORIZED_CONTRACT` (e.g. DeployTournament) may also `execute` for nested factory/registry writes.
- Tournament bootstrap: `Orchestrator.execute(DeployTournament, deploy(params))`.

---

## Post-bootstrap handoff

After all inits succeed:

1. **ProxyAdmin + AddressProvider ownership → Orchestrator**  
   (`DeployHandoff` / `make deploy-base-sepolia-handoff`).  
   Oracle ProxyAdmins may remain with OWNER out of band until explicitly moved.

2. **Orchestrator admin → Safe** (when ready)  
   `Orchestrator.transferDefaultAdmin(safe)` — atomic grant + revoke of `DEFAULT_ADMIN_ROLE`.  
   No need to retouch per-contract Ownable owners.

3. Finish oracle allowlists / compose hashes / router config as needed.

---

## Ownership model (summary)

```
Safe / EOA
  └── DEFAULT_ADMIN_ROLE on Orchestrator
        ├── execute / executeBatch  →  protocol Ownable targets
        └── AUTHORIZED_CONTRACT modules (DeployTournament, …)
              └── nested execute → factories / registries / hubs

AddressProvider.owner  →  Orchestrator (after handoff)
ProxyAdmin.owner       →  Orchestrator (protocol TUPs; after handoff)
Contract.owner         →  Orchestrator (set in initialize)
```

---

## Script map (Base Sepolia)

| Step | Make target |
|---|---|
| **One-shot core bootstrap** | `deploy-base-sepolia-all` |
| 1 AddressProvider | `deploy-base-sepolia-address-provider` |
| 2 Oracle | `deploy-base-sepolia-oracle` |
| 3–5 Orchestrator | `deploy-base-sepolia-orchestrator` |
| 3–5 Registries | `deploy-base-sepolia-registries` |
| 3 DeployTournament proxy + authorize | `deploy-base-sepolia-deploy-tournament` |
| 3–5 RoundManager | `deploy-base-sepolia-data` |
| 3–5 Lockers | `deploy-base-sepolia-lockers` |
| 3–5 Factories (+ DeployTournament init) | `deploy-base-sepolia-factories` |
| Handoff | `deploy-base-sepolia-handoff` |

Mainnet mirrors use `deploy-base-*` without `-sepolia`.

> Staged scripts today may register and initialize in the same broadcast for a given stack. That is fine as long as **all AddressBook dependencies for that contract are already on AP before its `initialize` runs**. DeployTournament is the explicit deferred-init example (proxy in one step, `initialize` in the factories step).
