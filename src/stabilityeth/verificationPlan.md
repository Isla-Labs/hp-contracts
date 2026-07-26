# SETH App Verification Plan

Offchain verification of TVL contract ownership before (or as part of) `AppRegistry` registration.

## Goal

Prove that the **app identity** submitting registration controls the **TVL target contracts** CRE will measure — without relying on a forgeable onchain `appDeployer()` claim alone.

Identity we want to bind:

| Term | Meaning |
|------|---------|
| **App identity** | Address that owns the registry row and the app’s `Minter` (registrar) |
| **Immediate creator** | Address that executed `CREATE` / `CREATE2` for the TVL contract (EOA or factory) |
| **Root deployer (EOA)** | First EOA walking up the deploy chain from the TVL contract |
| **Admin / proxy owner** | Optional secondary signal for upgradeable systems (not a substitute for creator) |

**Optimal match:** `app identity == root deployer (first EOA in the deploy chain)`.  
**Also supported:** `app identity == immediate creator` when that creator is an EOA, or when the app registers **as the factory** (factory is the app identity).

---

## Why this is offchain

The EVM does not expose “who deployed this address?” on the contract after creation.

Explorers (Etherscan / Basescan) show **Contract Creator** by indexing:

1. Creation txs (`receipt.contractAddress` when `to` is empty)
2. Internal `CREATE` / `CREATE2` from traces (factory deploys)

Verification must do the same class of lookup: **address → creation record → creator chain**, via explorer API, our indexer, or a CRE workflow.

Do **not** trust the applicant to supply `creationTx` unchecked — always resolve `address → creation` from the index.

---

## Creator resolution

### Immediate creator

From the creation record for address `C`:

- `creator` = address that performed the create
- `txHash`, `blockNumber`, `timestamp`
- `createType` = `CREATE` | `CREATE2` (when available from traces)

### Root deployer (first EOA)

Walk upward until an EOA:

```text
C₀ = TVL contract
Cᵢ₊₁ = immediate creator of Cᵢ
stop when Cₖ has no code (EOA)  →  rootDeployer = Cₖ
cap depth (e.g. 8) to avoid pathological factory stacks
```

If the walk ends on a contract (e.g. immutable singleton factory with no further create history), treat as **unresolved root** → fail or require manual / factory-allowlist path.

### Acceptance rules (handle both cases)

Accept registration of TVL set `T` for applicant `A` if **for every** `t ∈ T`:

1. **EOA path (preferred):** `rootDeployer(t) == A`, or  
2. **Factory-as-app path:** `immediateCreator(t) == A` and `A` is a contract (app identity is the factory), or  
3. **Allowlisted factory path (optional):** `immediateCreator(t)` ∈ `FactoryAllowlist` and `rootDeployer(t) == A`

Reject if any `t` fails, is already bound to another app, or has no creation record.

---

## CREATE2, proxies, redeploys — edge cases

### What “creator” means

`msg.sender` at creation is recorded **only in that creation transaction’s execution** (as the creating account in the create op). It is **not** stored on the deployed contract unless the bytecode writes it (immutable / constructor arg / `appDeployer()`).

So for verification we use the **indexer’s creation record**, not a runtime `msg.sender` on `register`.

### CREATE2

- Address = `f(factory, salt, initCodeHash)`. Same address can theoretically be **reused after selfdestruct** on some historical fork rules; on modern post-dencun / deployer practice this is rare but still plan for it.
- **Same address, new code** after a destroy+redeploy: creation history may show **multiple** create events. Policy:
  - Prefer the **latest** creation that resulted in the **current** `extcodehash`
  - Require `extcodehash` at verification time == codehash observed at that creation (or at a confirmed block)
  - If multiple creates exist for one address, flag for manual review

### Proxies

Typical stack:

```text
EOA → ProxyFactory → Proxy (TVL address users care about)
                 ↘ Implementation (logic)
```

| Address registered as TVL | Creator signal | Notes |
|---------------------------|----------------|--------|
| **Proxy** | Factory or EOA that deployed the proxy | Usually correct TVL surface (balances live here) |
| **Implementation** | Often a different deployer / multisig | Usually **wrong** for TVL; balances aren’t here |
| **Beacon / factory** | Infra deployer | Rarely the right TVL target |

Rules of thumb:

- Register **proxy / instance** addresses that hold or account for TVL — not shared implementations — unless CRE’s TVL recipe explicitly needs the impl.
- Creator of a proxy is often a **factory**, so **root EOA walk** (or factory-allowlist + root EOA) is the right check; immediate creator alone will fail most real apps.
- **Proxy admin / Ownable / AccessControl** can be a **supporting** signal (“does `A` control upgrades?”) but must not replace creator checks: admin can be transferred; creator cannot.

Optional hardening after creator match:

- If proxy is EIP-1967, read `admin` / `owner` and require `A` is admin **or** admin is a multisig whose known owners include `A` (offchain / allowlisted). Soft-fail → manual review rather than hard reject in v1.

### “Is msg.sender registered at any point?”

Only in these senses:

1. **Creation tx:** creating account is in the trace (what explorers call Contract Creator).
2. **If the app used our factory later:** `AppRegistry` / `MinterFactory` records `app → minter` — that is the **registrar**, not proof they created prior TVL contracts.
3. **Constructor-stored deployer:** optional onchain helper (`appDeployer()`), useful as a fast filter, **insufficient alone**.

Timings help glue (1) and the applicant:

- Creation `timestamp` / `block` must be **≤** verification time (always).
- Optional: creation must be **≥** some protocol launch time (ignore ancient spam addresses).
- Optional: applicant `A` must have sent the creation tx **or** be root EOA of that tx’s deploy chain (already covered).
- For upgradeable proxies: note **proxy creation time** vs **implementation creation time**; TVL binding should key off the **proxy** creation chain unless specified otherwise.

### Redeploys / metamorphic patterns

- Detect multiple creation traces for one address → manual review.
- Detect `extcodehash` change since last verified binding → freeze TVL eligibility until re-verify.
- Disallow registering addresses with **empty code** at verification time.

---

## Recommended process

### Phase A — Request (applicant)

1. Applicant chooses app identity `A` (EOA or factory contract they control).
2. Submits TVL addresses `[t…]` (and optionally claimed creation txs — ignored unless they match the index).
3. Status: `PendingVerification`.

### Phase B — Resolve (indexer / CRE)

For each `t`:

1. Confirm `extcodesize(t) > 0` and record `extcodehash`.
2. Fetch creation record (explorer `getcontractcreation` or internal index).
3. Compute `immediateCreator`, `rootDeployer`, create type, block, time.
4. Classify path: EOA / factory-as-app / allowlisted-factory.
5. Emit a verification report (structured JSON for CRE or Automator).

### Phase C — Decide

- Auto-approve if all addresses pass acceptance rules and no flags.
- Manual review if: deep factory stack, multiple creates, CREATE2 reuse flags, proxy admin ≠ `A`, mixed root deployers across the set, etc.
- Reject otherwise.

### Phase D — Onchain finalize

**Decided:** `AppRegistry.register` / `addTvlContracts` / `removeTvlContract` are `onlyOwner`.
Owner is the DAO (or a dedicated verifier key controlled by the verification frontend).

After offchain approval, owner submits:

1. `register(rootDeployer, [t…])` — creates `appId`, binds TVL set, deploys `Minter` (mapped to `appId`), seeds `rootDeployer` as 100% beneficiary, or  
2. `addTvlContracts(appId, [t…])` — extends an existing app’s verified set.

Post-register, **`rootDeployer`** may `setBeneficiaries(appId, …)` (shares sum to 10_000 bps). Any beneficiary may call `Minter.claim()` for that `appId`’s yield (PBR wiring TBD). Beneficiaries cannot mutate TVL or `appId`.

Applicants never finalize verification onchain themselves; they submit claims through the verification UI.

### Phase E — Ongoing

- CRE TVL jobs only read **active + verified** bindings.
- Re-verify on `extcodehash` change, proxy admin change (if monitored), or scheduled refresh.
- Owner/`setAppActive(false)` remains the emergency off switch.

---

## Implications for current contracts

| Surface | Role |
|---------|------|
| Offchain / CRE verification + dedicated UI | Source of truth for creator / root EOA; apps file claims here |
| `AppRegistry` owner (DAO / verifier) | `register` / `addTvlContracts` / `removeTvlContract` / `setAppActive` |
| `IAppDeployerAuth` | Optional offchain hint only — **not** required onchain at finalize |
| `Minter` | App income / wrap UX after registration; `s` from mint volume |

Keep `Minter` attribution (`totalMinted` / `s`) independent: mint path auth stays “allowlisted minter for app `A`”; TVL auth is only about which addresses enter `m/M_adj`.

## PBR settle / claim (implemented shape)

See [`pbrCadence.md`](./pbrCadence.md).

- **5m scores CRE** → `PBRScoreOracle` (raw observations, **onchain** decay).
- **Daily distribute CRE** → `PBRTreasury` (pull fees, snapshot oracle, open epoch).
- Mint stats on `AppRegistry`: `totalMinted` / `netMinted`; `netMinted == 0` clears scores / skips settle.
- Claims: `Minter.claim` / `claimAll` + bitmap `(appId, beneficiary, epochId)`.

---

## Indexer / CRE data shape (suggested)

Per TVL address:

```text
address
chainId
extcodehash
creationTx
creationBlock
creationTimestamp
immediateCreator
immediateCreatorIsContract
rootDeployer
deployDepth
createType          // CREATE | CREATE2 | UNKNOWN
proxyHint           // none | eip1967 | beacon | gnosisSafe | unknown
proxyAdmin          // optional
flags[]             // MULTI_CREATE, CODEHASH_MISMATCH, DEEP_STACK, ...
acceptancePath      // ROOT_EOA | FACTORY_AS_APP | ALLOWLISTED_FACTORY
```

Per request:

```text
applicant
tvlAddresses[]
reports[]
decision            // approve | reject | manual
decidedAt
```

---

## Edge-case checklist

- [ ] EOA direct deploy → root EOA == applicant  
- [ ] EOA → factory → proxy → root EOA == applicant  
- [ ] Applicant **is** the factory contract  
- [ ] Allowlisted factory (CreateX, Safe, etc.) + root EOA == applicant  
- [ ] Reject registering shared implementation as TVL by mistake  
- [ ] Reject / review CREATE2 address with multiple creation events  
- [ ] Reject empty code / EOAs as TVL targets  
- [ ] Mixed root deployers in one request → reject or split apps  
- [ ] Contract already bound to another app  
- [ ] Re-verify on codehash change after approval  

---

## Open decisions

1. **App identity type:** allow only EOAs, or also factory contracts as `A`? (Recommendation: both.)  
2. **Factory allowlist:** global protocol list vs per-request manual approve.  
3. **Proxy admin check:** v1 off / soft flag / hard require.  
4. **Finalize mechanism:** Automator tx vs CRE report consumer vs EIP-712 verifier signature.  
5. **Depth cap** for root-EOA walk and behaviour when unresolved.  
6. **Owner keying:** multisig DAO vs dedicated verifier EOA vs timelock — and whether ownership later moves to `ConstitutionalTimelock`.

---

## References

- Current stubs: `AppRegistry.sol`, `Minter.sol`, `MinterFactory.sol`, `SETH.sol`
- Explorer parallel: Basescan/Etherscan contract creation index (`getcontractcreation`)
- Related HP pattern: CRE-attested onchain writes (eligibility / PBR), permissioned Automator finalize
