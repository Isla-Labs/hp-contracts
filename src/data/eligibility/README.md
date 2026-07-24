# Eligibility

Per-league squad store, recency-weighted minutes score, and handoff into deploy / lifecycle waiting rooms.

Primary contract: `EligibilityVerifier.sol` (TransparentUpgradeableProxy via `script/utils/DeployData.sol`).  
Thresholds: `config/EligibilityCriteria.sol` (`CATEGORY_ONE` updatable).  
Types: `@base/global/types/data/EligibilityTypes.sol`, `@base/global/types/governance/LifecycleTypes.sol`.

---

## Layout

| Path | Role |
|------|------|
| `EligibilityVerifier.sol` | Score sync + cohort routing (via Automator) |
| `base/EligibilityStore.sol` | CRE squad-fill + PPM minutes store |
| `base/EligibilityCriteria.sol` | GK / u21 / outfield / newTransfer thresholds + under-21 age |

Downstream (not in this folder):

| Contract | Role |
|----------|------|
| CRE `squad-fill` | Populate players, membership, name/symbol |
| `PpmVerifier` (todo) | Call `recordAppearances` with match minutes |
| `Automator` | Cat-3 relay + caller→target routes (EV → lockers) |
| `DopplerLocker` | Waiting room for **new** deploy cohorts (`msg.sender` = Automator) |
| `TransferLocker` | Waiting room for **deactivate** / **reactivate** (`msg.sender` = Automator) |

---

## Data model

Each tracked player has a `MinutesStore`:

- `earliestSeasonStartYear` — set once at squad-fill create (newTransfer / backFromLoan flag)
- `birthDate`, `expectedPosition`
- `minsByPosition[14]` — career minutes by position (all comps ingested on this EV)
- `weightedScoreWad` + `lastScoreGlobalRound` — incremental score (PPM ingest + idle decay on verify)
- `name` / `symbol` — optional CRE metadata (first fill only)

Squad membership (daily-active CRE path):

- `SquadList` per `clubId`
- `_playerClub[playerId]` — current club in this league’s latest sweep (`0` = none)
- Club sync uses transient set membership (`O(prev + squad)`); identical ordered squads skip rewrite
- League-leavers finalized at season `SQUAD_FILL_PAGE_DONE` → TransferLocker

---

## CRE: squad-fill → `_processReport`

Pinned by `expectedWorkflowId` (KeystoneForwarder → `onReport`).

Report ABI = `SquadFillReport` field order:

```text
seasonId, seasonStartYear, pageFetched, nextPage,
playerIds, birthDates, clubId, squadPlayerIds,
metaPlayerIds, names, symbols
```

| Phase | Behaviour |
|-------|-----------|
| Historical / first-fill | Create untracked players; attach name/symbol; no membership |
| Recurring (daily-active, already swept once) | Membership overwrite; creates without strings; quiet pages backfill metadata |
| Season DONE | `_finalizeLeagueRemovals` → stage `_pendingLeftLeague` (no Automator call) |
| `verifyEligibility` | Drains `_pendingLeftLeague` → TransferLocker `LeftLeague` via Automator |

See `cre/hp-v1/workflows/squad-fill/README.md` for CRE layout and naming rules.

---

## Minutes ingest

`recordAppearances(seasonId, seasonStartYear, appearances)` — **PpmVerifier only**.

- Requires player already created by squad-fill
- Updates career `minsByPosition` / `expectedPosition` (all comps in the batch; cheap argmax)
- **Domestic league only:** incrementally updates `weightedScoreWad` as of each appearance’s global round
- Batch `seasonId` / `seasonStartYear` are score filters only (not stored per season)
- Per-match rows are **not** persisted

---

## Score

**Formula** (same as full replay; maintained incrementally):

```text
S(G) = Σ mins_i * 1e18 * λ^(G − G_i)
λ = 0.97

G(year, round) = Σ finalRound(y) for y ∈ [baseYear, year) + round
```

| Path | Behaviour |
|------|-----------|
| `recordAppearances` (league season) | Decay aggregate to appearance `G`, add mins; set `lastScoreGlobalRound` |
| `verifyEligibility` | Decay aggregate `lastScoreGlobalRound` → `G_now` when needed (skips no-op players) |

- `G_now` from this league’s `PbrTreasury` cursors
- Non-league calendars update position aggregates only (no score)

Effective minutes for thresholds: `weightedScoreWad / 1e18` (after verify decay).

### `verifyEligibility`

Globally `rateLimited`. Anyone may page `verifyEligibility(offset, limit)`.

### Thresholds (defaults)

| Cohort | Effective minutes |
|--------|-------------------|
| Goalkeeper | 361 |
| Under-21 | 181 |
| Outfield | 901 |
| New transfer / back from loan (deploy only) | 1 |

Under-21 age default: 21. Continuity checks **omit** the newTransfer shortcut.

### Cohort routing

| State | Outcome |
|-------|---------|
| Not in registry + eligible | → DopplerLocker (`goalkeepers` / `under21` / `outfield` / `newTransfers`) |
| In registry, not `INACTIVE`, below continuity | → TransferLocker `ContinuityUnderThreshold` |
| In registry, `INACTIVE`, above continuity | → TransferLocker `Reactivate` |
| CRE league-leaver (deployed, no club at DONE) | staged → next `verifyEligibility` → TransferLocker `LeftLeague` |

Actual `PlayerSetRegistry` status changes happen later in TransferLocker (waiting room + manual review), not inside EligibilityVerifier.

Deploy eligibility priority: newTransfer (if `earliestSeasonStartYear == currentSeasonYear`) → GK → under-21 → outfield.

---

## Deployment notes

1. DeployCore: `setAutomator(Automator)` on both lockers.
2. DeployData: EV `initialize(..., automator, dopplerLocker, transferLocker, ...)`.
3. `DopplerLocker.setEligibilityVerifier(EV)` — metadata oracle only.
4. Automator: grant EV `CATEGORY_THREE` + `setRoutes(EV → DopplerLocker, TransferLocker)`.
5. Size RateLimit `cooldown` for intended `verifyEligibility` page cadence.
6. One EligibilityVerifier instance per domestic `leagueId`.
