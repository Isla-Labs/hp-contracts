# RoundManager Plan (deferred)

> **Status:** Not the current focus. Full EligibilityStore / EligibilityVerifier flow first
> (`recordAppearances`, verify path, CRE `eligibility-store` hardening). Return here after that.

## Trigger from EligibilityStore

After the squads historical pass finishes all queued leagues and clears `pass` to `None`, EligibilityStore emits:

```solidity
event HistoricalBackfillComplete(uint16 runNumber, uint16 leagueCount);
```

Defined in `eligibility/types/EligibilityTypes.sol` (`SquadWorkflowEvents`).

**Intended consumer:** a separate CRE workflow (not `eligibility-store`) that wakes RoundManager’s fixture / matchweek formatting pipeline from a different StatsPerform endpoint (schedules / matchweeks — not squads).

| Property | Detail |
|---|---|
| Emitter | `EligibilityStore` / `EligibilityVerifier` |
| When | Historical backfill terminal (all queued leagues done); not after every Phase B cron cycle |
| CRE handler | RoundManager workflow only — **do not** wire into `eligibility-store` |
| Purpose | Bootstrap matchweek + fixture digests once squad membership / MinutesStore shells exist for the league(s) |

Re-emit is expected if a **new** league is later queued and historically backfilled (another complete historical pass). RoundManager / its CRE workflow should be idempotent per `(runNumber, league)` or equivalent.

## Scope (when we pick this up)

1. CRE log trigger on `HistoricalBackfillComplete` → pull season calendars from TournamentRegistry.
2. SP matchweek / fixtures endpoint via relay → format rounds + fixture ids.
3. Commit digests through `FixtureCommitment` → RoundManager apply path (existing congruence rules).
4. Recurring calendar updates (new `SeasonOpened` / round upserts) — separate from the one-shot historical wake; design alongside Automator `CATEGORY_THREE` calendar writes.

## Out of scope for now

- Implementing the RoundManager CRE workflow
- Changing RoundManager / FixtureCommitment apply semantics
- Coupling squads FETCH/SORT handlers to fixture ingest

## Dependency order

```text
EligibilityStore historical squads (SYNC → FETCH → SORT)
  → HistoricalBackfillComplete
  → RoundManager CRE (fixtures / matchweeks)   ← this plan
```

Eligibility `recordAppearances` (PPM → MinutesStore scores) is independent of this wake and should land before RoundManager CRE work.
