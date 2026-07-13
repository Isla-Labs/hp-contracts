# HighPotential

This repository contains the core smart contracts for [HighPotential](https://epl.highpotential.io/).

## Protocol access vs. API access

These contracts are the protocol. Interacting with them onchain (directly,
via a self-hosted UI, MetaMask/viem, or any other client) is not gated by
HighPotential middleware credentials.

**The public HTTP API (`api.highpotential.io`) exposes free, rate-limited
data reads and authenticated account/exchange surfaces.** Calling that API
(or forking the UI that uses it) is not a license to use the protocol beyond
what the contracts and applicable law / product Terms already allow.
Programmatic trading credentials, when issued, are separate secret keys for
server-side use — not browser-visible deployment keys.

A fuller self-hosting and middleware spec will live with the open-source
frontend documentation when that repo is published.

## Deployments

Latest deployments can be found [here](./Deployments.md) and historical deployment logs for Base and Base Sepolia can be found in the [deployments](./deployments/) folder.

## Attribution

HighPotential builds on the [Doppler](https://github.com/whetstoneresearch/doppler) Protocol for liquidity bootstrapping and migration, which interacts with [Uniswap V4](https://github.com/Uniswap/v4-core) under the hood. You can learn more about Doppler's mechanics in their [documentation](https://docs.doppler.lol/) or [whitepaper](https://github.com/whetstoneresearch/docs/blob/main/whitepapers/doppler/Dutch_auction_Dynamic_Bonding_Curves.pdf).

## Contact

The primary security contact for HighPotential is security@islalabs.co.
