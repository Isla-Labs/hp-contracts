# Open CVM Oracle Registration (Option C)

**Status:** Onchain core + CVM worker — **hybrid phase**: Phala Base-mainnet KMS/DstackApp + Sepolia mock oracle bus (`make deploy-base-sepolia-oracle`)  
**Depends on:** `CvmCoordinator`, `CvmRouter`, Phala Onchain KMS / `DstackApp`, `IAttestationVerifier` (Mock / Automata), CDP paymaster for UserOps

---

## Goal

Anyone can spin up a CVM running our approved compose and join as an oracle transmitter **without per-node DAO approval**.

DAO / governance only sets **policy** (allowed `composeHash` on Coordinator + `DstackApp`). Registration itself is cryptographic and permissionless.

---

## Trust split (do not collapse these)

| Layer | Contract / system | What it proves |
|---|---|---|
| Boot / keys | Phala Onchain KMS + `DstackApp` | Only allowlisted `composeHash` (+ device policy) can receive app keys |
| Transmitter join | `CvmCoordinator.registerOracle(bytes)` + `IAttestationVerifier` | EOA `T` was bound inside a fresh TEE quote whose claim `composeHash` is in policy |
| Fulfill | `CvmRouter` → `isOracle` | Active, unexpired, compose still allowed (or break-glass) |

**Latest-compose enforcement:** `setAttestationComposeAllowed(v1, false)` (or `removeComposeHash`) makes every v1 registration fail `isOracle` **immediately**, even if the CVM never restarts. TTL forces periodic re-attest under current policy.

---

## Onchain surface (shipped)

| Piece | Path |
|---|---|
| Coordinator | `CvmCoordinator.sol` |
| Verifier interface | `IAttestationVerifier` |
| Mock verifier (tests) | `attestation/MockAttestationVerifier.sol` |
| Automata verifier | `attestation/AutomataAttestationVerifier.sol` |
| Report-data helpers | `attestation/AttestationLib.sol` |
| Tests | `test/oracle/CvmCoordinator.t.sol` |

### Permissionless

```solidity
registerOracle(bytes calldata attestation) // → verifier.verify → policy + TTL upsert
```

### Break-glass (CATEGORY_ONE)

```solidity
registerOracleBreakglass(deviceId, transmitter) // composeHash=0, expiresAt=max
addCvm(deviceId, transmitter)                 // also addDevice on DstackApp
```

### Governance

```solidity
addComposeHash / removeComposeHash   // DstackApp + attestation policy
setAttestationComposeAllowed(h, bool) // policy-only (instant isOracle revoke)
setAttestationVerifier(addr)
setRegistrationTtl(ttl)
```

### `isOracle` rules

1. `active`  
2. `block.timestamp <= expiresAt`  
3. if `composeHash != 0` → `_composeAllowed[composeHash]`  

---

## CVM packing (operator side)

Implemented in repo root `oracle/` (Phala compose worker):

1. Generate **ephemeral** secp256k1 **owner** key in TEE (not shared `getKey` app wallet).  
2. Derive ERC-4337 **SimpleAccount**; `AttestationClaim.transmitter` = smart account address.  
3. Build `AttestationClaim { transmitter, deviceId, composeHash, nonce, quotedAt }`.  
4. `report_data = AttestationLib.encodeReportData(claim)` → dstack `getQuote` (`ATTESTATION_MODE=automata`).  
5. Automata: `abi.encode(claim, rawQuote)` → `registerOracle` UserOp (CDP paymaster).  
   Mock/Sepolia: `abi.encode(claim)` only (`ATTESTATION_MODE=mock` + `MockAttestationVerifier`).  
6. Re-attest before TTL (and after every compose policy rotation).

Deploy helper: `contracts/script/oracle/DeployOracle.s.sol` → `deployments/base-sepolia-oracle.json`.

---

## Key identity landmine

`getKey(path)` is `(app_id, path)` — shared across replicas. **Do not** use it as per-node transmitter for an open set. Use ephemeral keys bound in quote `report_data`.

---

## Deploy notes

1. Deploy `AutomataAttestationVerifier(dcapAddr, maxQuoteAge)` with network Automata DCAP entrypoint.  
2. Deploy `CvmCoordinator(dao, constitutional, dstackApp, verifier, ttl)`.  
3. Transfer `DstackApp` ownership → Coordinator.  
4. DAO: `addComposeHash(H)` (boot + policy).  
5. Open compute: `setAllowAnyDevice(true)` when ready; else cat-1 `addDevice`.  
6. Keep break-glass until Automata quote offsets are validated on real Phala quotes.

---

## Still open / follow-ups

- ~~Confirm TDX Quote V4 REPORTDATA offset against live Phala quotes~~ — validated: header 48 + body offset 520 (=568).  
- Optional ZK-DCAP path + full RTMR3 compose replay in-guest.  
- Sybil bond / stake.  
- Registration prune helper for expired set members (view already denies them).

---

## Refs

- [Understanding Onchain KMS](https://docs.phala.com/phala-cloud/key-management/understanding-onchain-kms)
- [Automata DCAP Attestation](https://docs.ata.network/tee-overview/tee-verifiers/intel-sgx-tdx-dcap/automata-dcap-attestation)
- [Phala Trust Center](https://docs.phala.com/dstack/trust-center-technical)
