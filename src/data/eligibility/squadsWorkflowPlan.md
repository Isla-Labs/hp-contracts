# Squads Workflow Plan (eligibility-3)

Single CRE workflow (`cre/hp-v1/workflows/eligibility-store`), multiple handlers. Onchain `RunStatus` + events drive phase transitions; cron runs the steady-state loop when historical backfill is idle.

**Fully automated:** league/season advance is store-owned. CRE only syncs registry → RunBook, fetches SP, and re-enters SORT.

## Triggers

| Source | Event | CRE handler | Effect |
|---|---|---|---|
| TournamentRegistry | `DomesticLeagueCreated` | `onSyncLeague` | `SYNC_LEAGUE` — queue all seasons |
| TournamentRegistry | `SeasonOpened` | `onSyncLeague` | `SYNC_LEAGUE` — append new season if missing |
| EligibilityStore | `SeasonsQueued` / `SeasonReady` / `FetchContinue` | `onFetch` | `FETCH_TRANSIENT` |
| EligibilityStore | `TransientComplete` / `SortPage` | `onSort` | `SORT_TRANSIENT` |
| Cron | hourly | `onCurrentFetch` | gate + FETCH IDLE seasons |
| EligibilityStore | `HistoricalBackfillComplete` | **RoundManager** (other workflow) | fixtures / matchweeks |

## Per-season pipeline

1. Populate full `TransientReturn` (stay-on-page + `personsOffset`)
2. SORT upsert → `MinutesStore` (emit club/league changes)
3. SORT rebuild → `SquadList`
4. SORT removals → prior roster ∉ buffer → `_pendingLeftLeague`
5. Finalize: `year < current` → `ARTIFACT`; else `IDLE` + monotonic year tick (demote older IDLE)

## Decisions (locked)

| # | Topic | Decision |
|---|---|---|
| 1 | Work unit | Per `seasonId`. Never SORT partial. One `TransientReturn` slot. |
| 2 | Registry sync | CRE `SYNC_LEAGUE` reconciles TournamentRegistry → RunBook (queue or append). Append while idle → Current pass + `SeasonReady` immediately (no cron wait). |
| 3 | Year tick | On IDLE finalize with `year > current`: set `currentSeasonStartYear`, artifact older IDLE. |
| 4 | Cron candidates | All `IDLE` (non-ARTIFACT), not year-equality. |
| 5 | Stay-on-page | `personsOffset` cursor; advance `_pgNm` only when club drained. |
| 6 | Finalize | Auto on last SORT chunk. No `POPULATED` / `FINALIZE` phase. |
| 7 | RoundManager | `HistoricalBackfillComplete` after historical pass clears. |

## Workflow shape

```text
handlers:
  1. EVM Log  → DomesticLeagueCreated | SeasonOpened     → onSyncLeague
  2. EVM Log  → SeasonsQueued | SeasonReady | FetchContinue → onFetch
  3. EVM Log  → TransientComplete | SortPage             → onSort
  4. Cron     → hourly                                   → onCurrentFetch
```

Quota cost: **1** public workflow slot.

## Implementation status

1. ~~Types + store phase machine~~
2. ~~TournamentRegistry `DomesticLeagueCreated` + `getSeasonsOldestFirst`~~
3. ~~EligibilityVerifier concrete~~
4. ~~CRE `eligibility-store` skeleton (handlers wired)~~
5. Harden extract (DONE detection across SP pages) + tests
6. RoundManager subscriber for `HistoricalBackfillComplete`
7. Simulate + deploy
