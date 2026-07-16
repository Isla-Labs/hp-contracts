# HighPotential × Aragon OSx Governance Plan

**Status:** Draft v1 — integration sketch  
**Scope:** How the protocol’s operational executors, ZK/data pipelines, and upgrade surfaces attach to an Aragon OSx DAO on Base.  
**Related:** `.architecture/trustlessPpm.md`, `.architecture/trustlessEligibility.md`, `contracts/src/governance-2/` (implementation)

---

## 1. Design principle

The DAO is the **root permission and constitutional layer**. It is **not** the weekly operator.

| Layer | Job | Mechanism |
|---|---|---|
| **A — Apply the rules** | Settlement, eligibility, activity, Doppler migrate-when-ready | ZK proofs / attested data → permissionless or role-gated executors |
| **B — Operate the topology** | League/cup wiring, season calendars, rare ops | Short-delay executors owned by the DAO |
| **C — Change the rules** | Proxy/beacon upgrades, vkeys, criteria, fee params, roles | Aragon plugins → DAO `execute` → long delay |

Failure mode for integrity checks (PPM, eligibility): **stall, never silent corruption**.  
Failure mode for constitutional changes: **public delay + veto window**, never silent upgrade.

---

## 2. Why Aragon OSx

Aragon OSx matches this split:

- **DAO contract** = treasury + `PermissionManager` (who may act as the DAO).
- **Plugins** = opt-in decision engines that hold `EXECUTE_PERMISSION_ID` on the DAO.
- Multiple governance plugins can coexist (e.g. Multisig for ops, TokenVoting for upgrades).
- Progressive decentralization = **swap/install plugins and re-grant permissions**, not redeploy protocol contracts.

References:

- [Setting up a DAO](https://docs.aragon.org/osx-contracts/1.x/guide-set-up-dao/)
- [Plugins](https://docs.aragon.org/osx-contracts/1.x/core/plugins.html)
- [Token Voting](https://docs.aragon.org/token-voting/1.x)

---

## 3. Target topology

```text
┌─────────────────────────────────────────────────────────────────┐
│                     Aragon OSx DAO (Base)                        │
│  PermissionManager · treasury · ROOT / EXECUTE permissions       │
└───────────────┬─────────────────────────────┬───────────────────┘
                │                             │
     ┌──────────▼──────────┐       ┌──────────▼──────────┐
     │ Multisig plugin     │       │ TokenVoting plugin  │
     │ (Security Council)  │       │ (constitutional)    │
     │ short/medium delay  │       │ long delay          │
     └──────────┬──────────┘       └──────────┬──────────┘
                │  DAO.execute(actions[])     │
                └──────────────┬──────────────┘
                               │
              ┌────────────────▼────────────────┐
              │     ProtocolGovernanceHub       │
              │  (optional thin router /        │
              │   TimelockController façade)    │
              └───┬─────────┬─────────┬─────────┘
                  │         │         │
     ┌────────────▼──┐ ┌────▼────┐ ┌──▼──────────────────┐
     │ UpdateAuthority│ │ Role    │ │ Upgrade owners      │
     │ (ADMIN paths)  │ │ admin   │ │ beacons / proxies   │
     └───────┬────────┘ └────┬────┘ └──────────┬─────────┘
             │               │                 │
   ┌─────────▼───────────────▼─────────────────▼─────────┐
   │              Protocol surface (AccessControl)         │
   │  PlayerSetRegistry · TournamentRegistry · FeeRouter   │
   │  PbrFeeHub · factories · PPMVerifier · CriteriaRegistry│
   │  MatchweekRegistry · AssetRegistry · …                │
   └───────────────────────┬───────────────────────────────┘
                           │ roles granted at deploy / by DAO
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
 LifecycleExecutor   TournamentExecutor   ActivityExecutor
 (LIFECYCLE_ROLE)    (DEPLOYER_ROLE)      (ACTIVITY_ROLE)
        │                  │                  │
        └────────── ZK / data preconditions ──┘
              (increasingly trustless over time)
```

**Naming note:** current stubs are `*Timelock.sol`. Prefer renaming to `*Executor` (or keep Timelock only where an OZ `TimelockController` delay is real). Filename typo: `LifecyleTimelock.sol` → `LifecycleTimelock.sol` / `LifecycleExecutor.sol`.

---

## 4. Decision classes → Aragon path

### Class 1 — Automated / ZK (no vote)

These must **not** require DAO proposals under normal operation.

| Action | Preconditions | Executor | Delay |
|---|---|---|---|
| PPM settlement → PBR distribute | zkVM proof + DON digests + challenge window | `PPMVerifier` → `PBRTreasury` | Challenge window (hours) |
| Player market deploy | Eligibility proof vs `CriteriaRegistry` + digest archive | `LifecycleExecutor` / `MarketFactory` | Optional short public delay |
| Discontinuation / wind-down | Discontinuation proof (stiffer guardrails) | `LifecycleExecutor` | Longer challenge + optional council veto |
| Vault activity add/remove | Attested squad / tournament membership | `ActivityExecutor` | Short / none |
| Doppler migrate-when-ready | Onchain curve readiness predicates | Permissionless or `UpdateAuthority` keeper | None (or sync registry fix) |
| Matchweek fixture publish | Pre-kickoff public schedule | `ActivityExecutor` or dedicated registry writer | None before kickoff; governed amend only |

DAO involvement: owns vkeys, criteria, pause switches, and dispute resolution — not each event.

### Class 2 — Operational (Multisig plugin)

Rare or topology-changing ops that are not yet fully ZK-gated, or that wire new tournaments.

| Action | Today’s role / stub | Proposed path |
|---|---|---|
| Register domestic hub + deploy `PbrFeeHub` | `TournamentTimelock` → `DEPLOYER_ROLE` | Multisig → DAO.execute → `TournamentExecutor` (or direct role grant to executor) |
| Create tournament / open season / upsert rounds | `DEPLOYER_ROLE` | Same |
| Add cup treasury to league hub | `TournamentTimelock` notes | Same |
| Hub / treasury address corrections | `TournamentRegistry.ADMIN_ROLE` | Multisig only (sensitive) |
| `PbrFeeHub` continental weights / international toggle | `ADMIN_ROLE` | Multisig + medium delay (economic) |
| Fixture registry amend before `mwEndTime` | Governed path in PPM design | Multisig + events for watchers |
| Challenge / dispute resolution | PPM open decision | Multisig (later: specialized dispute plugin) |
| Emergency pause / rescue | `FeeRouter.ADMIN_ROLE`, etc. | Multisig with **no** long delay; log + post-mortem |

### Class 3 — Constitutional (TokenVoting plugin)

Irreversible or trust-assumption-changing actions.

| Action | Surface |
|---|---|
| Upgrade `UpgradeableBeacon` impl (FeeRouter, PbrFeeHub, …) | Beacon `owner` = DAO (or DAO-owned timelock) |
| Upgrade Transparent / UUPS proxies (registries, verifiers) | Proxy admin / owner = DAO |
| Rotate PPM / eligibility verification keys | `PPMVerifier` / lifecycle verifier |
| Change `CriteriaRegistry` thresholds / windows | Eligibility constitution |
| AssetRegistry provider-epoch root migration | Identity constitution |
| Digest-scheme epoch changes | Canonical fetch constitution |
| Change fee-split constants that alter PBR economics | FeeRouter / FeeHub / treasury params (if elevated) |
| Install/uninstall Aragon plugins; change voting settings | Meta-governance |
| Re-assign `DEFAULT_ADMIN_ROLE` / role admins on protocol contracts | Permission constitution |
| Mint / inflate governance token (if any) | Membership |

**Do not** use player market tokens as governance tokens (staking / PBR conflict). Use a dedicated `ERC20Votes` governance token (or wrap only that token).

---

## 5. Mapping existing protocol roles to the DAO

Current AccessControl surfaces (as implemented / sketched):

| Contract | Role | Intended holder today | Aragon end-state |
|---|---|---|---|
| `PlayerSetRegistry` | `DEFAULT_ADMIN_ROLE` | Multisig / admin | **DAO** (sole role admin) |
| | `LIFECYCLE_ROLE` | LifecycleTimelock | `LifecycleExecutor` (DAO-owned) |
| | `ACTIVITY_ROLE` | ActivityTimelock | `ActivityExecutor` |
| | `UPDATE_ROLE` | UpdateAuthority + Lifecycle | `UpdateAuthority` + Lifecycle (primary) |
| `TournamentRegistry` | `DEFAULT_ADMIN_ROLE` / `ADMIN_ROLE` | Multisig | **DAO** as admin; Multisig plugin executes via DAO |
| | `DEPLOYER_ROLE` | TournamentTimelock | `TournamentExecutor` |
| `FeeRouter` (per beacon proxy) | `ADMIN_ROLE` | Factory `admin_` | DAO or `UpdateAuthority` |
| | `LIFECYCLE_ROLE` | LifecycleTimelock | `LifecycleExecutor` |
| `FeeRouterFactory.beacon` | Ownable | `admin_` | **DAO** |
| `PbrFeeHub` / factory beacon | `ADMIN_ROLE` / Ownable | `admin_` | **DAO** (+ Multisig for weight ops via execute) |
| Future: `PPMVerifier`, `CriteriaRegistry`, `MatchweekRegistry`, `AssetRegistry` | Admin / vkey / root setters | Timelock + multisig (docs) | DAO constitutional path |

### Permission bootstrap rule

At deploy / DAO creation:

1. Create Aragon DAO on Base; install **Multisig** (and optionally temporary **Admin** plugin for bootstrap only).
2. Deploy protocol with `admin_ = DAO` (or a single `ProtocolGovernanceHub` whose admin is the DAO).
3. Grant executor contracts their operational roles.
4. Grant Multisig (and later TokenVoting) `EXECUTE_PERMISSION_ID` on the DAO.
5. **Revoke** bootstrap Admin plugin after handoff.
6. Never leave EOAs as `DEFAULT_ADMIN_ROLE` on production registries/beacons.

Aragon actions are encoded as `Action[]` (`to`, `value`, `data`) executed by the DAO. Protocol contracts should therefore treat the **DAO address** (or the hub it owns) as the admin — not the Multisig plugin address.

---

## 6. Executor contracts (Layer B)

Keep the four governance stubs, but clarify responsibilities:

### 6.1 `LifecycleExecutor` (ex-`LifecycleTimelock`)

Bundles player lifecycle calls that must stay atomic:

- Deploy Doppler market (standard params) + `FeeRouter` + `PlayerVault` + AT stubs  
- Register `PlayerSet` + vault registries on treasuries  
- League transfer: `setPbrFeeHub`, remove/add vault on treasuries, `setLeagueId`  
- Discontinuation: delist fee hub, vaults inactive/withdraw-only  

**Evolution:** entrypoint becomes `executeWithProof(bytes proof, bytes publicInputs)` once `trustlessEligibility.md` guests land. Until then: Multisig schedules calldata through DAO → executor, with public delay.

**Doppler migration:** prefer **not** stuffing migrate into Lifecycle. Either:

- permissionless `migrateIfReady(playerId)` on a keeper module, or  
- `UpdateAuthority` keepers for registry sync after external migrate  

Lifecycle only performs the initial deploy + registry wiring.

### 6.2 `TournamentExecutor` (ex-`TournamentTimelock`)

- Deploy `PbrFeeHub` / `PbrTreasury` / `MatchweekManager` for new leagues/cups  
- `TournamentRegistry.registerHub` / `createTournament` / season + rounds  
- Wire cup treasuries into hubs  

Still human-gated at launch (product decisions: which competitions). Later: optional proofs for “season calendar matches attested fixture set.”

### 6.3 `ActivityExecutor` (ex-`ActivityTimelock`)

- Daily: MatchweekManager start/end, fixture lists → `MatchweekRegistry`  
- Weekly: vault activity status per tournament (`ACTIVITY_ROLE` on `PlayerSetRegistry`)  

Target: ZK/DON-attested squad membership; executor becomes proof-gated.

### 6.4 `UpdateAuthority`

Catch-all **ADMIN / UPDATE** paths that are not lifecycle bundles:

- Doppler ready → migrate + `PlayerSetRegistry.setDopplerData`  
- Registry repair if migrate and registry diverge  
- `FeeRouter.setAtFunding`, non-upgrade parameter tweaks  
- Token rescue (consider splitting rescue to Multisig-only via DAO for clearer audit trail)

Day-one: Multisig proposes → delay → execute.  
Later: keepers for pure onchain predicates; Multisig retains pause/rescue.

---

## 7. Delays (one size does not fit all)

| Path | Suggested delay | Rationale |
|---|---|---|
| PPM challenge window | Hours | Stall settlement; selective disclosure |
| Eligibility deploy | 0–24h public notice | Mostly trustless; watchers verify proof |
| Eligibility discontinue | 48h–7d + optional council veto | Moves liquidity; irreversible |
| Operational Multisig execute | 24–72h | Topology changes visible onchain |
| Emergency pause / rescue | 0 | Safety over ceremony |
| TokenVoting upgrades / vkeys / criteria | 7–14d after success | Watcher / exit window |
| Meta-governance (plugin swap) | ≥ upgrade delay | Prevent governance capture races |

Delays can be implemented as:

1. **OZ `TimelockController`** owned by the DAO (classic), or  
2. **Proposal/execution delays inside Aragon plugins** + an extra protocol-side delay only where needed (discontinuation, upgrades).

Prefer: DAO owns one `TimelockController` for Class 3; Class 1 uses challenge windows; Class 2 uses Multisig proposal delay.

---

## 8. Aragon plugin configuration (launch → mature)

### Phase 0 — Bootstrap (pre-mainnet / first weeks)

| Plugin | Config |
|---|---|
| Admin (temporary) | Deployer/ops EOA for install + role wiring |
| Multisig | n-of-m Security Council (e.g. 3/5 → 4/7) |
| TokenVoting | **Not yet**, or installed with execution disabled until token distribution |

Handoff checklist: DAO = `DEFAULT_ADMIN_ROLE` + beacon owner; Admin plugin uninstalled; Multisig can execute.

### Phase 1 — Mainnet Day One

| Plugin | Scope |
|---|---|
| Multisig | Class 2 ops, disputes, emergency, fixture amends |
| TokenVoting | Class 3 only (upgrades, vkeys, criteria, meta) — if token ready |
| Optional AddresslistVoting | Larger contributor set without token |

Governance token requirements (when TokenVoting is live):

- `ERC20Votes` (snapshots + delegation)  
- Separate from player ERC20s  
- Quorum sized for Base voter apathy (start conservative; prefer failure-to-pass over capture)  
- Proposal threshold non-trivial  

### Phase 2 — Progressive trust minimization

- Lifecycle / Activity entrypoints require ZK proofs; Multisig loses routine propose rights for those paths  
- Multisig retains: emergency, dispute, tournament product launches, pause  
- TokenVoting remains sole path for upgrades + algorithm constitution  
- Optional: custom Aragon **condition** contracts (e.g. “execute upgrade only if `TimelockController` eta passed” — usually redundant if timelock is the target)

### Phase 3 — Optional advanced plugins

- Optimistic governance for low-risk param tweaks  
- Custom “ProofExecutor” plugin that may call DAO.execute only when a verifier attests (usually unnecessary if executors are already proof-gated outside Aragon)  
- SubDAOs later (e.g. league-specific ops) — **out of scope** for Day One

---

## 9. Integration with trustless PPM & eligibility

From `trustlessPpm.md` / `trustlessEligibility.md`, governance **must** own:

| Governed object | Class | Plugin |
|---|---|---|
| PPM guest vkey | 3 | TokenVoting + long delay |
| Eligibility / discontinuation guest vkeys | 3 | TokenVoting |
| `CriteriaRegistry` thresholds | 3 | TokenVoting (or Multisig+long delay until token) |
| `AssetRegistry` new-epoch root | 3 | TokenVoting |
| Digest-scheme epoch | 3 | TokenVoting |
| `MatchweekRegistry` amend | 2 | Multisig |
| Challenge dispute resolution | 2 | Multisig |
| Pause settlement / lifecycle | 2 emergency | Multisig, delay 0 |

Explicit non-goals for Aragon:

- Voting on each matchweek’s `m` / `M_adj`  
- Voting on each eligible player deploy  
- Voting on routine activity flips  

Those paths stay proof/data-gated. The DAO’s job is to make the **verifier and criteria** trustworthy.

---

## 10. Upgrade & proxy ownership matrix

| Upgradeable surface | Mechanism | Owner after handoff |
|---|---|---|
| `FeeRouter` logic | Shared `UpgradeableBeacon` | DAO (via TokenVoting → execute → `beacon.upgradeTo`) |
| `PbrFeeHub` logic | Shared `UpgradeableBeacon` | DAO |
| `PlayerSetRegistry` / `TournamentRegistry` | Transparent or UUPS (as chosen) | DAO / ProxyAdmin held by DAO |
| `PPMVerifier` / lifecycle verifiers | Prefer immutable verifier + replaceable vkey slot; or UUPS | DAO |
| Factories | Usually immutable; change by deploying new factory + DAO rewires roles | DAO rewires |

**Beacon upgrade is a Class 3 action** — it atomically changes every market FeeRouter. Encode as a single DAO proposal with clear calldata decoding in the UI (ERC-7730 clear signing for any offchain signing UX).

---

## 11. Security council (Multisig) charter

Suggested powers:

1. Execute Class 2 actions through the DAO.  
2. Pause PPM distribution, lifecycle deploys, and fee routing in emergencies.  
3. Resolve PPM challenges when selective disclosure is insufficient.  
4. **Veto or cancel** TokenVoting-passed upgrades during the timelock (optional but recommended for early seasons).  
5. Cannot silently upgrade beacons without the constitutional delay (veto ≠ bypass).

Member ops (add/remove council): TokenVoting or supermajority Multisig with delay — decide before launch.

---

## 12. Treasury

Aragon DAO holds:

- Governance token treasury (if any)  
- Protocol-owned fee skim (if not fully routed to PBR)  
- Dispute bonds / challenge deposits (if introduced)  
- Emergency reserves  

PBR Rewards Treasury (`PBRTreasury`) remains **protocol accounting**, not the Aragon treasury — do not conflate yield pots with DAO spending. DAO may still govern **parameters** that feed those pots.

---

## 13. Implementation roadmap

### Step A — Spec freeze (this doc)

- [ ] Confirm Class 1/2/3 tables  
- [ ] Confirm delay numbers  
- [ ] Confirm governance token strategy (Phase 0 Multisig-only vs Day-One TokenVoting)  
- [ ] Confirm Security Council veto on upgrades  

### Step B — Protocol wiring

- [ ] Implement `LifecycleExecutor`, `TournamentExecutor`, `ActivityExecutor`, `UpdateAuthority` (replace stubs)  
- [ ] Standardize: `admin_` / `DEFAULT_ADMIN_ROLE` = DAO (or `ProtocolGovernanceHub`)  
- [ ] Transfer beacon ownership to DAO in deploy scripts  
- [ ] Add pause switches where emergency Multisig needs them  
- [ ] Align role names in comments (`UPDATE_ROLE` vs obsolete `ADMIN_ROLE` docs in `PlayerSetRegistry`)  

### Step C — Aragon deploy (Base)

- [ ] Verify OSx + Multisig + TokenVoting plugin repo availability on Base  
- [ ] Create DAO via Aragon app or `DAOFactory` script  
- [ ] Install Multisig; configure members / thresholds  
- [ ] Install TokenVoting when token ready; grant `EXECUTE` only for Class 3 targets (process/social; enforce via proposal templates + optional target allowlist contract)  
- [ ] Encode handoff Actions: `grantRole`, `transferOwnership`, revoke deployer roles  

### Step D — Trustless surfaces

- [ ] `PPMVerifier` admin = DAO; vkey rotation = TokenVoting path  
- [ ] `CriteriaRegistry` admin = DAO  
- [ ] Migrate Lifecycle/Activity to proof-gated entrypoints  
- [ ] Shrink Multisig’s routine surface over time  

### Step E — Ops & UX

- [ ] Proposal templates (upgrade beacon, rotate vkey, open season, pause)  
- [ ] Watcher runbooks for timelock / challenge windows  
- [ ] ERC-7730 descriptors for any EOA/council signing  
- [ ] Public dashboard: queued Actions, role holders, beacon impls, pinned vkeys  

---

## 14. Open decisions

1. **Governance token at launch?** Multisig-only Day One vs TokenVoting live for upgrades.  
2. **Security Council veto** on TokenVoting-timelocked upgrades: yes/no, and duration.  
3. **Single `TimelockController` vs plugin-native delays** for Class 3.  
4. **`ProtocolGovernanceHub`:** worth an extra contract for allowlisting targets, or DAO.execute directly to protocol?  
5. **Discontinuation:** Multisig veto in addition to ZK proof? (Recommended early.)  
6. **Aragon on Base:** confirm deployed OSx framework addresses and plugin repos for the target network; fallback is OZ Governor + Timelock with the same Class split if OSx Base support is incomplete.  
7. **SubDAOs / per-league councils:** defer.  
8. **Fee parameter changes** (`PbrFeeHub` weights): Class 2 (council) or Class 3 (token)? Recommend Class 3 if they materially move EST/PBR; Class 2 if purely operational routing.  

---

## 15. Summary

```text
Aragon DAO
  ├─ TokenVoting (+ long timelock) → upgrades, vkeys, criteria, meta-governance
  ├─ Multisig (+ short delay / 0 for emergency) → ops, disputes, pause, early veto
  └─ owns roles on → Lifecycle / Tournament / Activity / UpdateAuthority executors
                       which increasingly require ZK/data proofs (Layer A)
```

**Compatibility verdict:** the current role + timelock sketch is Aragon-compatible if the DAO becomes root admin/beacon owner, executors remain the hot path, and token voting is reserved for systematic overhauls — not eligibility or weekly PBR.
)
