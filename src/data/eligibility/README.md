# Eligibility

Per-league squad store, recency-weighted minutes score, and handoff into deploy / lifecycle waiting rooms.

Primary contract: `EligibilityVerifier.sol` (TransparentUpgradeableProxy via `.factories/EligibilityVerifierFactory.sol`).  
Thresholds: `config/EligibilityCriteria.sol` (`CATEGORY_ONE` updatable).  
Types: `@base/global/types/data/EligibilityTypes.sol`, `@base/global/types/governance/LifecycleTypes.sol`.

---

## Layout

| Path | Role |
|------|------|
| `EligibilityVerifier.sol` | CRE squad-fill receiver, minutes store, score + cohort routing |
| `config/EligibilityCriteria.sol` | GK / u21 / outfield / newTransfer thresholds + under-21 age |
| `.factories/EligibilityVerifierFactory.sol` | Shared impl + per-league TUP deploy |

Downstream (not in this folder):

| Contract | Role |
|----------|------|
| CRE `squad-fill` | Populate players, membership, name/symbol |
| `PpmVerifier` (todo) | Call `recordAppearances` with match minutes |
| `DopplerLocker` | Waiting room for **new** deploy cohorts |
| `TransferLocker` | Waiting room for **deactivate** / **reactivate** |

---

## Data model

Each tracked player has a `MinutesStore`:

- `earliestSeasonStartYear` — set once at squad-fill create (newTransfer / backFromLoan flag)
- `birthDate`, `expectedPosition`
- `seasonMinutes[]` — per-calendar rows (`seasonId`, appearances, mins by position)
- `weightedScoreWad` — written only by `verifyEligibility`
- `name` / `symbol` — optional CRE metadata (first fill only)

Squad membership (daily-active CRE path):

- `SquadList` per `clubId`
- `_playerClub[playerId]` — current club in this league’s latest sweep (`0` = none)
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
| Season DONE | `_finalizeLeagueRemovals` → enqueue `LeftLeague` to TransferLocker |

See `cre/hp-v1/workflows/squad-fill/README.md` for CRE layout and naming rules.

---

## Minutes ingest

`recordAppearances(seasonId, seasonStartYear, appearances)` — **PpmVerifier only**.

- Requires player already created by squad-fill
- Stores raw `Appearance[]` + position minutes
- Does **not** update `weightedScoreWad`

---

## Score (`verifyEligibility`)

Globally `rateLimited`. Anyone may page `verifyEligibility(offset, limit)`.

**Formula** (domestic league calendars for this verifier’s `leagueId` only):

```text
weightedScoreWad = Σ mins_i * 1e18 * λ^(G_now − G_i)
λ = 0.97

G(year, round) = Σ finalRound(y) for y ∈ [baseYear, year) + round
```

- `finalRound` from `TournamentRegistry` (cached in-tx)
- `G_now` from this league’s `PbrTreasury` cursors
- Seasons that are not `getSeasonId(leagueId, seasonStartYear)` are skipped (cups / other leagues / etc.)

Effective minutes for thresholds: `weightedScoreWad / 1e18`.

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
| CRE league-leaver (deployed, no club at DONE) | → TransferLocker `LeftLeague` |

Actual `PlayerSetRegistry` status changes happen later in TransferLocker (waiting room + manual review), not inside EligibilityVerifier.

Deploy eligibility priority: newTransfer (if `earliestSeasonStartYear == currentSeasonYear`) → GK → under-21 → outfield.

---

## Deployment notes

1. Factory `create(...)` with `dopplerLocker` + `transferLocker` addresses.
2. `DopplerLocker.setEligibilityVerifier(proxy)` and `TransferLocker.setEligibilityVerifier(proxy)`.
3. Size RateLimit `cooldown` for intended `verifyEligibility` page cadence.
4. One EligibilityVerifier instance per domestic `leagueId`.
