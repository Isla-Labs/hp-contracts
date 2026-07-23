[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-black.svg)](https://www.gnu.org/licenses/agpl-3.0) [![solidity](https://img.shields.io/badge/solidity-%5E0.8.34-black)](https://docs.soliditylang.org/en/v0.8.34/) [![Foundry](https://img.shields.io/badge/Built%20with-Foundry-000000.svg)](https://getfoundry.sh/)

# HighPotential

Core smart contracts for [HighPotential](https://epl.highpotential.io/) — a DeFi platform for investing in professional sports stars across any timeframe with Performance Based Returns (PBR).

Built for Base L2. Liquidity bootstrapping uses [Doppler](https://github.com/whetstoneresearch/doppler) (Uniswap V4 under the hood).

## Formula

PBR converts real-time player performance into variable yield for stakers at the end of each matchweek:

| Symbol | Description |
|--------|-------------|
| I | User income (staking yield from a vault in matchweek X) |
| R | Rewards Treasury (80% of trading fees) |
| m | Player matchweek points (PPM, real-time) |
| M_adj | Aggregate matchweek points (minus unsubscribed vaults) |
| s | User stake at matchweek cut-off |
| S | Total staked in the vault at cut-off |

```
I = R ⋅ (m / M_adj) ⋅ (s / S)
```

Eligibility for market deploy / PBR continuity uses a recency-weighted minutes score (domestic league only):

```
weightedScoreWad = Σ mins_i ⋅ 1e18 ⋅ λ^(G_now − G_i)    λ = 0.97
```

See [`src/data/eligibility/README.md`](./src/data/eligibility/README.md) for thresholds and cohort routing.

## Modules

HighPotential’s onchain surface splits into governance, CRE data intake, and markets/vaults (plus registries). Each area has a clear privilege or write path so automation, DAO proposals, and user staking do not collide.

### Governance

Three-tier privilege stack: cat-1 `ConstitutionalTimelock` (7d), cat-2 `MaintenanceTimelock` (1d), cat-3 `Automator`. Aragon DAO proposes into timelocks; keepers relay through Automator.

See [`src/governance/access/README.md`](./src/governance/access/README.md).

### Data

CRE-backed onchain data plane: eligibility (squad-fill, weighted minutes, DopplerLocker / TransferLocker handoff), matchweeks (fixture commitments, round apply), and PBR stats intake.

See [`src/data/eligibility/README.md`](./src/data/eligibility/README.md) for eligibility thresholds and cohort routing.

### Markets & vaults

Trading fees flow through `FeeRouter` / `PbrFeeHub` into `PbrTreasury`, which distributes matchweek yield to `PlayerVault` / `StakedToken` stakers. `DopplerLocker` and `TransferLocker` are the deploy and lifecycle waiting rooms; `PlayerSetRegistry` and `TournamentRegistry` are the canonical indexes for player markets and tournament topology.

## Features

- **PBR yield** — performance-proportional staking returns each matchweek
- **Soft-peg via demand** — static supply; relative performance drives rebalancing incentives
- **Doppler LBP** — shared launch parameters; migrate to Uniswap V4
- **CRE data plane** — squad-fill (and related workflows) write through Chainlink Keystone
- **Tiered governance** — constitutional / maintenance / automation separation

## Contracts

| Area | Examples | Description |
|------|----------|-------------|
| Access | `ConstitutionalTimelock`, `MaintenanceTimelock`, `Automator` | Privilege stack |
| Data | `EligibilityVerifier`, `FixtureCommitment`, `RoundManager` | CRE intake, eligibility, matchweeks |
| Deploy / lifecycle | `DopplerLocker`, `TransferLocker` | Waiting rooms for markets and status |
| Markets | `FeeRouter`, `PbrFeeHub` | Fee collection and hub splits |
| Vaults | `PbrTreasury`, `PlayerVault`, `StakedToken` | Rewards and staking |
| Registries | `PlayerSetRegistry`, `TournamentRegistry` | Canonical onchain indexes |

Latest deployments can be found [here](./Deployments.md) and historical deployment logs can be found in the [deployments](./deployments/) folder.

## Blueprint

```txt
lib
├─ forge-std
├─ doppler          — liquidity bootstrapping / Uniswap V4
└─ chainlink-evm    — CRE / Keystone receivers
src
├─ PlayerSetRegistry.sol
├─ TournamentRegistry.sol
├─ base/            — abstract receivers, types, interfaces, roles
├─ data/
│  ├─ eligibility/  — EligibilityVerifier (+ README)
│  ├─ matchweeks/
│  └─ pbr/
├─ governance/
│  ├─ access/       — cat-1 / cat-2 / cat-3 (+ README)
│  └─ deployments/  — DopplerLocker, TransferLocker, DeployTournament, …
├─ markets/         — FeeRouter, PbrFeeHub
└─ vaults/          — PbrTreasury, PlayerVault, StakedToken
script/
├─ DeployBase/      — Base + Base Sepolia
└─ utils/           — DeployCore, ProxyUtils (InitGuard bootstrap)
test/
deployments/        — history logs + cli.ts
```

## Attribution

### Doppler

HighPotential uses the [Doppler](https://github.com/whetstoneresearch/doppler) Protocol for liquidity bootstrapping and migration into Uniswap V4. Player markets launch through Doppler’s Airlock / initializer path, then graduate to concentrated liquidity once bonding conditions are met.

We integrate a **later Multicurve** release of Doppler (not the original single Dutch-auction bonding curve). Multicurve lets launches seed multiple contiguous price curves in one pool — the shape HighPotential uses for shared market-launch parameters. For the composable upstream protocol, see the canonical [Doppler](https://github.com/whetstoneresearch/doppler) repository.

Further reading:

- [Doppler documentation](https://docs.doppler.lol/)
- [Multicurve overview (PDF)](https://www.doppler.lol/multicurve.pdf)
- [Multicurve examples](https://docs.doppler.lol/reference/examples/multicurve)
- Original dynamic bonding-curve [whitepaper](https://github.com/whetstoneresearch/docs/blob/main/whitepapers/doppler/Dutch_auction_Dynamic_Bonding_Curves.pdf) (pre-Multicurve)

### Chainlink Runtime Environment (CRE)

Onchain player / matchweek data is delivered through the [Chainlink Runtime Environment (CRE)](https://docs.chain.link/cre): offchain workflows produce signed Keystone reports that `KeystoneForwarder` routes into HighPotential consumers (`CreReceiver` → e.g. `EligibilityVerifier`, fixture / PBR paths). CRE replaces the older Functions request/fulfill pull model with a push-based report consumer interface (`IReceiver.onReport`).

Further reading:

- [CRE documentation](https://docs.chain.link/cre)
- [Building CRE consumer contracts](https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts)
- [chainlink-evm CRE contracts](https://github.com/smartcontractkit/chainlink-evm/tree/develop/contracts/cre) (`IReceiver`, `KeystoneForwarder`)

## Security

The primary security contact is security@islalabs.co.

## Disclaimer

*These smart contracts and testing suite are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of anything provided herein or through related user interfaces. This repository and related code may not be fully audited and as such there can be no assurance anything will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk.*

## License

See [LICENSE](./LICENSE) for more details (AGPL-3.0).
