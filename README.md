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

### Access (`src/governance/access`)

Three-tier privilege stack: cat-1 `ConstitutionalTimelock` (7d), cat-2 `MaintenanceTimelock` (1d), cat-3 `Automator`. Aragon DAO proposes into timelocks; keepers relay through Automator.

See [`src/governance/access/README.md`](./src/governance/access/README.md).

### Eligibility (`src/data/eligibility`)

Squad-first store, CRE squad-fill intake, weighted minutes score, handoff to DopplerLocker (new markets) and TransferLocker (deactivate / reactivate).

See [`src/data/eligibility/README.md`](./src/data/eligibility/README.md).

### Markets & vaults

- **FeeRouter / PbrFeeHub** — trading fee routing into rewards
- **PbrTreasury / PlayerVault / StakedToken** — matchweek distribution and staking
- **DopplerLocker / TransferLocker** — deploy and lifecycle waiting rooms

### Registries

- **PlayerSetRegistry** — token / Doppler / vault / status per player
- **TournamentRegistry** — seasons, calendars, treasury wiring

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
| Eligibility | `EligibilityVerifier`, `EligibilityCriteria` | Squad store + score + cohort handoff |
| Deploy / lifecycle | `DopplerLocker`, `TransferLocker` | Waiting rooms for markets and status |
| Markets | `FeeRouter`, `PbrFeeHub` | Fee collection and hub splits |
| Vaults | `PbrTreasury`, `PlayerVault`, `StakedToken` | Rewards and staking |
| Registries | `PlayerSetRegistry`, `TournamentRegistry` | Canonical onchain indexes |

Latest deployments can be found [here](./Deployments.md) and historical deployment logs can be found in the [deployments](./deployments/) folder.

## Protocol access vs. API access

These contracts are the protocol. Interacting with them onchain (directly, via a self-hosted UI, MetaMask/viem, or any other client) is not gated by HighPotential middleware credentials.

**The public HTTP API (`api.highpotential.io`) exposes free, rate-limited data reads and authenticated account/exchange surfaces.** Calling that API (or forking the UI that uses it) is not a license to use the protocol beyond what the contracts and applicable law / product Terms already allow. Programmatic trading credentials, when issued, are separate secret keys for server-side use — not browser-visible deployment keys.

## Getting Started

Install Foundry: `curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup`

```bash
forge build
forge test
forge fmt
```

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
test/
script/
```

## Attribution

HighPotential builds on the [Doppler](https://github.com/whetstoneresearch/doppler) Protocol for liquidity bootstrapping and migration ([docs](https://docs.doppler.lol/), [whitepaper](https://github.com/whetstoneresearch/docs/blob/main/whitepapers/doppler/Dutch_auction_Dynamic_Bonding_Curves.pdf)).

## Security

The primary security contact is security@islalabs.co.

## Disclaimer

*These smart contracts and testing suite are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of anything provided herein or through related user interfaces. This repository and related code may not be fully audited and as such there can be no assurance anything will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk.*

## License

See [LICENSE](./LICENSE) for more details (AGPL-3.0).
