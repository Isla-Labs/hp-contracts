# SETH PBR cadence

## Separation of concerns

| Cadence | CRE workflow | Contract | Responsibility |
|---------|--------------|----------|----------------|
| ~5 minutes | scores | `PBRScoreOracle` | Raw TVL + `totalMinted` observations → **onchain** EWMA / decay |
| Daily | distribute | `PBRTreasury` | Pull SETH fees → snapshot oracle scores → open claimable epoch |

Each consumer has its own `expectedWorkflowId` / forwarder binding.

## Score update (5m)

CRE reads `AppRegistry` (TVL targets, `totalMinted`, `netMinted`) and pushes:

```text
ObservationReport { appIds, tvlRaw, totalMintedObserved }
```

Oracle:

- `m' = decayBps*m + (1e4-decayBps)*tvlRaw` (EWMA)
- `s' = decayBps*s/1e4 + ΔtotalMinted`
- `netMinted == 0` → clear `m`,`s` (no TVL-only yield)

## Daily distribute

CRE pushes:

```text
DistributeReport { epochId, appIds }
```

Treasury pulls pending fees, snapshots `oracle.getScores` for eligible apps, locks `R`, opens claims.

`I_app = R * m/M_adj * s/S_adj`, then × beneficiary `shareBps`.

Beneficiaries use `Minter.claim(epochId)` or `Minter.claimAll(fromEpoch)`.
