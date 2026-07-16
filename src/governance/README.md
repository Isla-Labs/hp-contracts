# Governance-2 — Aragon DAO integration

Initial package for HighPotential protocol governance on Base. Replaces the sketch stubs in
`src/governance/` with executable contracts wired for:

1. **Class 1 (ZK / data)** — proof-gated immediate execution  
2. **Class 2 (ops)** — short-delay scheduled batches (Security Council / Multisig)  
3. **Class 3 (constitutional)** — long OZ timelock owned by the Aragon DAO (upgrades, vkeys)

Full design: [`../governance/plan/governancePlan.md`](../governance/plan/governancePlan.md)  
Related: `.architecture/trustlessPpm.md`, `.architecture/trustlessEligibility.md`

## Layout

```text
governance-2/
├── aragon/
│   ├── AragonBaseAddresses.sol   # pinned OSx framework addresses on Base
│   └── IDAO.sol                  # minimal DAO.execute interface
├── core/
│   ├── GovernanceTypes.sol       # Action + DecisionClass
│   ├── IProofVerifier.sol        # ZK / attestation plug-in point
│   └── DelayedBatchExecutor.sol  # schedule / execute / executeWithProof
├── constitutional/
│   └── ConstitutionalTimelock.sol  # OZ TimelockController for Class 3
└── executors/
    ├── LifecycleExecutor.sol     # player deploy / transfer / discontinue
    ├── TournamentExecutor.sol    # league / cup topology
    ├── ActivityExecutor.sol      # matchweek + vault activity
    └── UpdateAuthority.sol       # ADMIN/UPDATE + Doppler migrate sync
```

Remapping: `@governance/=src/governance-2/`

## Topology (Day One target)

```text
Aragon DAO (Base DAOFactory)
  ├─ Multisig plugin     → Class 2 propose / emergency cancel
  ├─ TokenVoting plugin  → Class 3 (when token ready)
  └─ owns
       ├─ ConstitutionalTimelock   → beacon / proxy / vkey admin
       └─ DEFAULT_ADMIN_ROLE on
            LifecycleExecutor · TournamentExecutor · ActivityExecutor · UpdateAuthority
                 │                    │                    │                   │
                 └──────── protocol roles (LIFECYCLE / DEPLOYER / ACTIVITY / UPDATE) ──┘
```

Protocol contracts (`PlayerSetRegistry`, `TournamentRegistry`, `FeeRouter` factories, …) should
initialize with:

- `admin_` / beacon owner = **DAO** or **ConstitutionalTimelock** (Class 3 surfaces)
- role holders = the matching **executor** addresses

## Paths

| Path | API | When |
|---|---|---|
| Delayed ops | `schedule` → wait `minDelay` → `execute` | Class 2; transitional Class 1 |
| ZK / data | `setProofVerifier` + `executeWithProof` | Class 1 once guests exist |
| Cancel | `cancel` (`CANCELLER_ROLE`) | Council veto during delay |
| Constitutional | `ConstitutionalTimelock.schedule/execute` | Upgrades, criteria, vkeys |

`EXECUTOR_ROLE` is granted to `address(0)` by default (open keepers), matching OZ TimelockController.

## Bootstrap sketch

1. `DAOFactory.createDao` on Base (`AragonBaseAddresses.DAO_FACTORY`) with Multisig plugin.  
2. Deploy `ConstitutionalTimelock(minDelay, [dao], [address(0)], dao)`.  
3. Deploy four executors with `admin_ = dao`.  
4. DAO `execute`: grant each executor `PROPOSER_ROLE` to Multisig-operated proposer (or to DAO
   itself if proposals always go DAO → executor.schedule), grant protocol roles, transfer beacons.  
5. Later: `setProofVerifier` on Lifecycle / Activity; shrink Multisig propose surface.

## Legacy

`src/governance/*.sol` stubs are superseded by this package. Keep
`src/governance/plan/governancePlan.md` as the living design doc until moved here.
