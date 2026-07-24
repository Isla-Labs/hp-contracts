# Access (governance privilege stack)

Three-tier access for HighPotential protocol actions. Human / DAO paths go through Aragon into timelocks; automated paths go through `Automator`.

Role ids live in `@base/global/libraries/roles/AccessRoles.sol` (`CATEGORY_ONE` / `TWO` / `THREE`). Protocol contracts grant those roles to the contracts in this folder — not to EOAs or voting plugins directly.

---

## Layout

```text
governance/access/
├── README.md
├── cat-1/
│   └── ConstitutionalTimelock.sol   # long-delay constitutional executor
├── cat-2/
│   └── MaintenanceTimelock.sol      # short-delay ops executor
└── cat-3/
    └── Automator.sol                # allowlisted automation relay
```

---

## Tiers

| Tier | Contract | Default delay | Holds on targets | Typical use |
|------|----------|---------------|------------------|-------------|
| **cat-1** | `ConstitutionalTimelock` | 7 days | `CATEGORY_ONE`, proxy/beacon ownership | Upgrades, fee-split constitution, criteria (`EligibilityCriteria`, Doppler config), tournament registration, Automator allowlist |
| **cat-2** | `MaintenanceTimelock` | 1 day | `CATEGORY_TWO` | Manual upkeep: sweeps, pause/resume, status fixes, treasury/router repairs — **not** upgrades or constitutional fee changes |
| **cat-3** | `Automator` | none | `msg.sender` on targets that grant it `CATEGORY_THREE` | Data-driven / keeper relays (matchweeks, Doppler ops, future TransferLocker confirms, etc.) |

---

## Call paths

```text
Multisig / TokenVoting / VE plugins
        │
        ▼
   Aragon DAO.execute(...)
        │
        ├─► ConstitutionalTimelock.schedule[Batch]
        │         │ after minDelay → anyone execute
        │         ▼
        │   msg.sender = ConstitutionalTimelock
        │   → CATEGORY_ONE / upgrade authority on targets
        │
        └─► MaintenanceTimelock.schedule[Batch]
                  │ after minDelay → anyone execute
                  ▼
            msg.sender = MaintenanceTimelock
            → CATEGORY_TWO on targets

ConstitutionalTimelock (CATEGORY_ONE on Automator)
        │ addAutomator / removeAutomator
        ▼
Automator.executeAutomation(target, value, data)
        │ msg.sender ∈ verifiedCallers
        │ target ∈ destinationsOf[caller]
        ▼
msg.sender = Automator → target's own access control
        (typically CATEGORY_THREE / sole-writer granted only to Automator)
```

**Timelocks:** OZ `TimelockController`. Aragon DAO is sole `PROPOSER_ROLE` / `CANCELLER_ROLE`. Execution is open (`EXECUTOR_ROLE` on `address(0)`). Targets always see the timelock as `msg.sender`.

**Automator:** OZ `AccessControl` only for DAO (`DEFAULT_ADMIN_ROLE`) and cat-1 (`CATEGORY_ONE`) admin of the allowlists. **Verified callers** and **per-caller destinations** are `EnumerableSet`s (not AccessControl roles). Cat-1 `addAutomator(caller, destinations)` / `addDestination` / `removeDestination` manage them. Day-one: EV → DopplerLocker + TransferLocker. Vault membership writes go to `TournamentRegistry` (SoT), which syncs each treasury's local vault cache.

---

## Wiring notes

1. Day-one: pass Aragon DAO as timelock `admin` for bootstrap; later renounce so delay/role changes go through the timelock itself.
2. Grant `CATEGORY_ONE` on config contracts (e.g. `EligibilityCriteria`, Doppler config) to `ConstitutionalTimelock`.
3. Grant `CATEGORY_TWO` on ops surfaces to `MaintenanceTimelock`.
4. Grant `CATEGORY_THREE` on registries / treasuries / etc. to `Automator` (not to individual keepers).
5. DeployCore creates the EV InitGuard proxy early and seeds it as Automator's day-one verified caller. DeployData upgrades that proxy.
6. Additional verified callers: cat-1 `addAutomator(caller)`.
7. Waiting-room lockers: `setAutomator(Automator)` for enqueue; DopplerLocker also `setEligibilityVerifier(EV)` as metadata oracle only.

---

## Related

- Role constants: `contracts/src/base/global/libraries/roles/AccessRoles.sol`
- Interfaces: `IAutomator`, `IDAO` under `@base/global/interfaces/governance/`
- Eligibility handoff docs: `contracts/src/data/eligibility/README.md`
