# ProofSettle

**A settlement rail that pays for off-chain AI compute only when two independent proofs, of two
different kinds, agree inside a single transaction.**

Built for BUIDL CTC 2026 Fall, AI track. Solo entry.

---

## What it does

A buyer pays for an AI inference on Ethereum Sepolia and, in the same transaction, names the
enclave build they are willing to accept. The inference runs in a TEE. The enclave signs the result
together with its verdict on the job.

A contract on Creditcoin then releases payment only if, in one transaction, it can verify:

1. **The payment happened.** A `JobCreated` event on Sepolia, proven through the Attestcoin
   Protocol's native verifier precompile. No relayer is trusted.
2. **The right enclave did the work.** A secp256k1 signature over the result, from a key the
   registry binds to exactly the measurement the buyer demanded.

Then the enclave's verdict decides where the money goes: accepted pays the provider, rejected
returns the buyer's claim, partial splits it.

Neither proof settles anything alone.

## Why this is not another bridge

The Attestcoin tutorials teach one shape: burn a token on a source chain, prove it, mint on
Creditcoin. A proof carries a fact, and the fact triggers an action.

Here the proven event carries **policy**. `ComputeSettlement` holds no allowlist of acceptable
enclaves. It reads `requiredMeasurement` out of the proven Sepolia event and enforces that against
a second, unrelated cryptographic system. Change what the buyer asked for on Sepolia and the
settlement rule on Creditcoin changes with it, with no redeploy and no admin key.

That is the difference between cross-chain data delivery and cross-chain business logic.

## Contracts

| Contract | Chain | What it does |
|---|---|---|
| `ComputeJobEscrow` | Sepolia | Locks payment, publishes the buyer's enclave policy as `JobCreated` |
| `EnclaveRegistry` | Creditcoin | Binds an enclave measurement to its signing key, with the evidence on chain |
| `ComputeSettlement` | Creditcoin | Verifies both proofs in one call, then acts on the verdict |
| `ComputeCredit` | Creditcoin | The settlement claim, mintable only by the settlement contract |
| `AttestcoinProven` | Creditcoin | Base: puts a proof to the verifier precompile and refuses to act on the same one twice |

Both proofs are checked inside `ComputeSettlement.settle`. Splitting them across two transactions
would have been easier, and would have made "neither half settles without the other" a property of
the off-chain worker rather than of the contract. A worker is not a guarantee.

## What this does not do

**The registry does not verify hardware attestation on chain.** Verifying an AMD SEV-SNP or Google
Confidential Space attestation means walking an X.509 chain and doing RSA against a vendor's key
distribution service. That is not feasible in the EVM at any sane gas price, and a contract that
claims to do it is worth reading very carefully.

What the registry does instead: it records the binding from measurement to signing key, records a
content hash of the attestation document that justifies it, and points at where that document can
be fetched. The contract enforces the **binding**. Whether the registrar was right to make that
binding is checkable by anyone holding the evidence, rather than taken on trust from this file.

**The rail is one-directional today.** Attestcoin carries attested data from other chains into
Creditcoin. Writability, which would carry a settlement receipt back out, is in final development
and explicitly out of scope for this season, as the protocol team confirmed at the kickoff AMA.
They also confirmed that a conventional return path is the right approach in the meantime, so the
return leg is a plainly labelled conventional relayer and writability is the roadmap step that
removes the last trusted component.

**Development runs unattested unless you point it at a real enclave.** With `ENCLAVE_URL` unset the
worker signs with a local development key and prints a warning on every run saying so. A silent
fallback would let a demo appear to prove hardware attestation while proving nothing at all, which
is the exact failure this project exists to make visible.

## Verify it yourself

`site/index.html` is a self-contained page that reads Creditcoin directly in your browser and
re-runs every check the settlement contract ran. No backend, no API key. It also carries the
measurement below.

## How much of the Attestcoin oracle is real application use

Before building on a protocol it is worth knowing who else is, so I measured it rather than
guessing. Every event the verifier precompile emitted on CC3 testnet across 100,000 blocks, about
17.4 days, with complete coverage and no sampling:

| | |
|---|---|
| Contracts that called the verifier | **142** |
| Share of traffic from just two of them | **93.79%** |
| Contracts with exactly one sending address | **134 of 142** |
| Most distinct senders on any one contract | **11**, on the Attestcoin tutorial's own minter |

Almost every contract using the oracle is exercised only by the address that deployed it. That is
builders testing their own work rather than users using it, and it is the headroom this project was
built for.

This says what was measured. It does not claim who operates any particular address. Reproduce it:

```bash
npx tsx script/measure.ts
```

The scan splits any block range the RPC times out on and retries the halves. A range that still
cannot be read is counted as **unscanned**, never as zero. The first version of that script
recorded a failed window as "0 events", which would have produced a confidently wrong picture
showing no activity where there was plenty.

## Tests

```bash
yarn install
forge install foundry-rs/forge-std --no-git
forge test
```

**49 tests.** Every guarantee has a paired negative test, because a suite that only walks the happy
path proves nothing about the guarantee.

Four are worth calling out.

**`test_reverts_when_the_event_came_from_an_impostor_escrow`.** Anyone can deploy their own escrow,
emit a perfectly well formed `JobCreated` naming themselves as provider for any amount, and obtain
a genuine Attestcoin proof of it. The proof is real. The settlement would be theft. Pinning the
emitter is what makes a true proof also a relevant one.

**`test_provider_cannot_upgrade_the_enclave_verdict`.** The verdict sits inside the signed digest,
so a provider holding a `Rejected` signature cannot present it as `Accepted`.

**`RealOracleBytes.t.sol`.** The synthetic transaction builder used by the settlement tests is
checked against `txBytes` taken from the live prover, decoded through the same `EvmV1Decoder` the
contract uses. If Gluwa change the encoding, that test goes red instead of the whole suite quietly
passing against a format that no longer exists.

**`EnclaveSignature.t.sol`.** The enclave signs in JavaScript with a hand-rolled keccak256 and ABI
encoder, because it carries no runtime dependencies. The contract recomputes the same digest in
Solidity. This test takes signatures the real enclave actually produced and proves both halves
agree. `enclave/verify-crypto.mjs` separately checks every primitive against ethers.

### Proving the tests can fail

```bash
./script/mutation-check.sh
```

Green tests are not evidence on their own. This removes one guarantee at a time from the source,
runs the test written to defend it, and checks that test actually goes red. **Eleven mutations, all
caught.**

| Mutation | Test that caught it |
|---|---|
| Drop the source escrow emitter check | `test_reverts_when_the_event_came_from_an_impostor_escrow` |
| Drop the enclave registry check | `test_reverts_when_an_unregistered_key_signed_the_result` |
| Accept a revoked enclave | `test_reverts_after_the_enclave_is_revoked` |
| Drop the replay guard | `test_reverts_when_the_same_proof_is_replayed` |
| Ignore the oracle returning false | `test_reverts_when_the_oracle_returns_false_without_reverting` |
| Settle on a reverted source transaction | `test_reverts_when_the_source_transaction_reverted` |
| Accept malleable signatures | `test_reverts_on_a_malleable_signature` |
| Accept a proof from any source chain | `test_reverts_on_a_proof_from_the_wrong_source_chain` |
| Let a rejected job pay the provider | `test_rejected_job_returns_the_claim_to_the_payer` |
| Drop the verdict from the signed digest | `test_provider_cannot_upgrade_the_enclave_verdict` |
| Let the partial split create value | `test_split_is_publicly_checkable_and_conserves_value` |

The script refuses to pass if a mutation target no longer exists in the source, so a refactor
cannot quietly turn a real check into a no-op.

## Prior art, declared

I have built attestation verification joined to a registry twice before: once against a Flare
on-chain registry, entirely in the browser, and once against a document store. The pattern is one I
understand rather than a codebase I pasted, and the Solidity here is written fresh for this
contract during the hackathon. Saying so is cheaper than having someone wonder.

## Verified against the live network

Everything below was checked against CC3 testnet, not read from documentation.

| | |
|---|---|
| CC3 testnet chain ID | 102031, average block time 15.02 s measured over 50,000 blocks |
| Verifier precompile | `0x0000000000000000000000000000000000000FD2` |
| ChainInfo precompile | `0x0000000000000000000000000000000000000fd3` |
| Sepolia source chain key | 1, read from the on-chain precompile rather than a config file |
| Attestation cadence | Batches of 10 Sepolia blocks every 113 to 123 s, so a lag of 7 to 9 minutes |
| Failure path | A corrupted merkle root reverts with "Merkle proof validation failed" |
| Prover endpoints | `prover.cc3-testnet…` and `proof-gen-api.cc3-testnet…` are aliases, confirmed identical |

That last row of the failure path matters as much as the others. A verifier that accepts a valid
proof and also accepts a corrupted one has told you nothing, so both were tested.

## Layout

```
src/         the contracts
test/        49 tests, plus the fixtures taken from the live prover and the real enclave
script/      deployment, and the reproducible measurement
worker/      the off-chain worker that watches, proves and settles
enclave/     the attested compute service, its Dockerfile and its Confidential Space scripts
site/        the public verify-it-yourself page
```

## Deploying

See `DEPLOY.md`.

## Licence

MIT.
