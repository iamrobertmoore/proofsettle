# ProofSettle

**A settlement rail that pays for off-chain AI compute only when two independent proofs, of two
different kinds, agree inside a single transaction.**

Built for BUIDL CTC 2026 Fall, AI track. Solo entry.

**Live page: [proofsettle.pages.dev](https://proofsettle.pages.dev)**. It reads Creditcoin in your
browser and re-runs every check, including the hardware attestation, without asking you to trust
anything written here.

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

## Deployed, live, on testnet

| Contract | Chain | Address |
|---|---|---|
| `ComputeJobEscrow` | Ethereum Sepolia | [`0xaF89A479E20890fDfFa4DeaDd3b5A2f7957b1E40`](https://sepolia.etherscan.io/address/0xaF89A479E20890fDfFa4DeaDd3b5A2f7957b1E40) |
| `EnclaveRegistry` | Creditcoin CC3 testnet | [`0xAc014b7Df7f9b2dA343d895F22a392c655338bFb`](https://creditcoin-testnet.blockscout.com/address/0xAc014b7Df7f9b2dA343d895F22a392c655338bFb) |
| `ComputeCredit` | Creditcoin CC3 testnet | [`0x43872Caef4b8286D93d155e34e602C0Aa3a78Eee`](https://creditcoin-testnet.blockscout.com/address/0x43872Caef4b8286D93d155e34e602C0Aa3a78Eee) |
| `ComputeSettlement` | Creditcoin CC3 testnet | [`0x010C1F801d5FAE37FD43C9B21025fE579dCC1F06`](https://creditcoin-testnet.blockscout.com/address/0x010C1F801d5FAE37FD43C9B21025fE579dCC1F06) |
| `EvmV1Decoder` | Creditcoin CC3 testnet | [`0xaF89A479E20890fDfFa4DeaDd3b5A2f7957b1E40`](https://creditcoin-testnet.blockscout.com/address/0xaF89A479E20890fDfFa4DeaDd3b5A2f7957b1E40) |

`EvmV1Decoder` is Gluwa's own decoding library from `@gluwa/usc-contracts`, deployed separately and
linked into `ComputeSettlement`, because it exposes public functions. It is on Creditcoin at the
same address as the escrow is on Sepolia, which is not a mistake: `CREATE` derives an address from
the deployer and its nonce alone, so one fresh wallet's first deployment on two chains lands on the
same address on both.

The wiring is not asserted, it is read back. `script/deploy-creditcoin.sh` reads every link off
chain after deploying and refuses to report success if any of it disagrees. Repeat the reads
yourself in three commands:

```bash
RPC=https://rpc.cc3-testnet.creditcoin.network
cast call 0x43872Caef4b8286D93d155e34e602C0Aa3a78Eee "minter()(address)"      --rpc-url $RPC
cast call 0x010C1F801d5FAE37FD43C9B21025fE579dCC1F06 "SOURCE_ESCROW()(address)" --rpc-url $RPC
cast call 0x010C1F801d5FAE37FD43C9B21025fE579dCC1F06 "SOURCE_CHAIN_KEY()(uint64)" --rpc-url $RPC
```

The first must return the settlement address, so nothing but settlement can mint the credit. The
second must return the Sepolia escrow, so no other contract's events can be presented as payment.
The third must return `1`, the Attestcoin chain key for Sepolia, read from the protocol's own
`ChainInfo` precompile rather than assumed.

`cast code` at each address returns bytecode identical to what `forge build` produces from this
repo, apart from three expected differences: the constructor immutables, the four sites in
`ComputeSettlement` holding the linked library address, and the trailing solc metadata hash, which
encodes compilation paths and so varies by machine.

## What this does not do

**The registry does not verify hardware attestation on chain.** Verifying an AMD SEV or Google
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

**[proofsettle.pages.dev](https://proofsettle.pages.dev)** is a self-contained page that reads
Creditcoin directly in your browser and re-runs every check the settlement contract ran. No backend,
no API key, no account. The source is `site/index.html`, and opening that file locally does the same
thing.

It is prefilled with a real settlement. Change the job id and it will check a different one, or tell
you plainly that there is nothing there.

It also does the one check the chain cannot do. Verifying a hardware attestation on chain is not
affordable, so the page fetches the enclave's attestation token and Google's live signing keys,
verifies the RS256 signature with WebCrypto, and then checks that the container image digest inside
the token is the same measurement the registry has bound on chain. That join is the whole system in
one screen: Creditcoin says which build was permitted, Google says which build actually ran, and
your browser confirms they are the same one.

```bash
node site/test-attestation.mjs
```

drives exactly that path in a real browser against a token it signs itself, then breaks it four
ways: a tampered signature, an image that does not match the registry, a debug image, and an
absent token. A page that accepts a valid attestation and also accepts a tampered one has told you
nothing, so the test is written to prove it can fail.

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

Measuring it also turned up an error in Gluwa's own tutorial, which tells developers a faucet claim
buys nine oracle queries. Priced from eight transactions through their minter, the real figure is
closer to four hundred thousand. Reported upstream at
[ccnext-testnet-bridge-examples#30](https://github.com/gluwa/ccnext-testnet-bridge-examples/pull/30).

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

## One settlement, end to end, on the live network

A real job, paid for on Ethereum Sepolia, settled on Creditcoin against the Attestcoin oracle, with
the result signed inside an attested Confidential Space enclave. Both transactions are public.

| | |
|---|---|
| Payment | [`0x9f6c9980…f33e1`](https://sepolia.etherscan.io/tx/0x9f6c9980eea0878b4eba27c677fc8add83dd32fc5c2185dbe76506cce35f33e1) on Sepolia, block 11,558,244, tx index 175 |
| Settlement | [`0xc77cf096…1426a`](https://creditcoin-testnet.blockscout.com/tx/0xc77cf096bc552f1c9eb2d1f407bf11e211aad58708325a23f92915c05621426a) on Creditcoin, block 5,366,783 |
| Job id | `0xbd3c16183f8a976424135c8b43344ae65a2a590fa125bdc276ff755ea8125c3a` |
| Enclave | `0xC7561c7e2809346fAffDf3B344FD921FDF98F65f`, measurement `0xc0a8e85a53c13a607b108683cd75ad896047a2b526d8ef64065bb27aac1396d0` |
| Cost to settle | 468,426 gas at 0.5 gwei, so 0.000234 CTC |

The four logs that transaction emitted are the whole argument in order, and anyone can read them
off chain:

1. `TransactionVerified(1, 11558244, 175)` from the Attestcoin verifier precompile at
   `0x…0FD2`. The protocol itself, not this project, attesting that the Sepolia payment is real.
2. `ProofConsumed(queryId, 11558244, 175)` from `ComputeSettlement`, marking that query spent, so
   the same proof cannot settle a second time.
3. `JobSettled(jobId, provider, enclave, …)` carrying the enclave signing key that the registry
   confirmed was permitted by *the buyer's own policy*, taken from the proven Sepolia event.
4. `Transfer(0x0, provider, 1e15)` from `ComputeCredit`, matching the 0.001 ETH locked on Sepolia
   and nothing more.

Both proofs were checked in that single transaction. Neither half could have settled without the
other.

## And here it is refusing

Success is the easy half. A second job was created where the buyer demanded a **different** enclave
build, the same enclave answered it, and the settlement contract rejected it on a public chain:

| | |
|---|---|
| Refused settlement | [`0xda7d9942…894af`](https://creditcoin-testnet.blockscout.com/tx/0xda7d994268a841fcd1a5a7a3d9366e8e4027501f635fdcc20bfb91ddd9d894af), block 5,367,004, status 0, 410,858 gas |
| Reason | `EnclaveNotAccepted(0x29f228be…, 0xC7561c7e…)` |

That error names both halves of the disagreement: the build the buyer demanded, and the key that
actually signed. Note which way round it is. **The build the buyer asked for there was the weaker
one**, the unattested development key from earlier in the day, and the attested enclave's answer was
refused anyway. The contract holds no opinion about which build is better. It enforces the one the
buyer named, and nothing else.

The refusal is mined rather than simulated on purpose. A local revert proves nothing to anyone who
was not at the keyboard.

**The enclave is real.** The measurement bound on chain is the container image digest itself, so
there is no indirection to take on trust: pull the image, read its digest, compare. The
Google-signed attestation token that asserts it is committed at `enclave/attestation.jwt`, and

```bash
node enclave/verify-token.mjs enclave/attestation.jwt
```

verifies it against Google's published keys and prints what it actually claims: `GCP_AMD_SEV`,
secure boot on, and `dbgstat: disabled-since-boot`, which means a production Confidential Space
image rather than the debug one. The token expires, which is worth saying plainly: an expired token
is a historical record of what was running, not a live proof that it still is.

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
