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

The data never touches either chain in the clear. The applicant's record leaves the buyer's
browser sealed to an encryption key that was generated inside the enclave and is named in its
attestation, and it rides inside the payment transaction itself. The answer comes back sealed to
a one-time key only that browser holds, riding inside the settlement transaction. What the chains
carry is two commitments, `inputHash` and `resultHash`, and the buyer can open the answer and check
it hashes to what the contract recorded. Nothing in between, the worker included, can read the
record or the decision.

## Why this is not another bridge

The Attestcoin tutorials teach one shape: burn a token on a source chain, prove it, mint on
Creditcoin. A proof carries a fact, and the fact triggers an action.

Here the proven event carries **policy**. `ComputeSettlement` holds no allowlist of acceptable
enclaves. It reads `requiredMeasurement` out of the proven Sepolia event and enforces that against
a second, unrelated cryptographic system. Change what the buyer asked for on Sepolia and the
settlement rule on Creditcoin changes with it, with no redeploy and no admin key.

That is the difference between cross-chain data delivery and cross-chain business logic.

## How the Attestcoin Protocol is used

Four ways, all of them load-bearing rather than decorative.

**The verifier precompile at `0x…0FD2` is the only thing that establishes the payment.** `settle`
hands it the raw Sepolia transaction bytes, the Merkle proof and the continuity proof, and acts on
nothing until it says yes. There is no relayer, no signed message from me, no allowlist of
payers.

**The proven transaction carries policy and data, not just a fact.** `requiredMeasurement`,
`modelHash` and `inputHash` are read out of the proven `JobCreated` event and enforced against the
enclave's signature. The sealed applicant record rides in the same transaction's calldata, behind
the ABI-encoded arguments where the decoder ignores it, so the enclave receives its input through
the same proof that pays for it. Two forge tests pin that the compiled decoder accepts the trailing
bytes on both `createJob` and `settle`.

**The `ChainInfo` precompile at `0x…0fd3` is read, not assumed.** The Sepolia chain key (1) comes
from it at deploy time, the attested height comes from it while the worker and the desk page wait
for a payment's block to land, and the verifier page reads it in the browser.

**The worker builds its own proofs.** `@gluwa/usc-sdk`'s `RawProofBuilder` runs against a plain
Sepolia RPC, with a block provider that falls back to per-transaction receipts when the node has
no `eth_getBlockReceipts`. On the 24 August payment in this README it produced a proof **byte-identical**
to the hosted Proof Builder's, in 92 seconds against 0.7. The hosted builder is the fallback, so
the rail keeps settling if the service is down, and the comparison is reproducible with
`RAW_PROOF_LIVE=1 node worker/test/raw-proof.live.mjs`.

Writability, the return leg that would carry a settlement receipt back to Sepolia, is documented
by Gluwa as "currently under third-party testing and audits" and is not on testnet, so it is not
used here. The return path is a labelled conventional relayer; see below.

### What this leaves behind for other Attestcoin builders

The precompile proves that a transaction was in a block. It does not, by design, say whether the
transaction succeeded, which contract emitted the event you care about, whether you have counted
it before, or what it is bound to; a dApp may legitimately want to prove a failed transaction.
Everything above that line is the consumer's job, and four pieces of that job here are written to
be lifted out and reused:

- **`AttestcoinProven.sol`**, the base that consumes a proof exactly once, treats a `false` from the
  verifier as a failure rather than only the revert, checks the receipt status, and pins the
  emitter. Its eleven guarantees each have a test and a mutation that proves the test can fail.
- **`worker/block-provider.ts`**, a block provider for the SDK's raw proof builder that works
  against nodes without `eth_getBlockReceipts`, with the live byte-for-byte comparison against the
  hosted builder that shows it is safe to depend on.
- **The calldata rider** (`enclave/envelope.mjs`, `withTrailer` and `fromTrailer`), a way to carry
  sealed or plain data inside a transaction that an Attestcoin proof will later cover, without
  changing the contract that receives it. Pinned against the compiled ABI decoder for both static
  and dynamic argument lists.
- **`script/measure.ts`**, a complete-coverage scan of the verifier precompile's use on CC3 that
  anyone building on the protocol can rerun, and the tutorial wording it corrected, sent upstream
  on 26 August and kept on [my fork](https://github.com/iamrobertmoore/attestcoin-protocol-examples/blob/patch-1/hello-bridge/README.md) since the upstream repository went offline.

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

The three contracts I wrote are **verified on Blockscout**, so those links resolve to Solidity
rather than bytecode, the events decode by name, and the refusal transaction shows its revert
reason in full: `EnclaveNotAccepted(bytes32 requiredMeasurement, address recovered)` with both
values named. Republish after any redeploy with `./script/verify-contracts.sh`, which reads the
constructor arguments back off the chain rather than trusting a local file.

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
Creditcoin. Writability, which would carry a settlement receipt back out, is documented at
[docs.attestcoin.org](https://docs.attestcoin.org) as "currently under third-party testing and
audits" and is not on testnet, which the protocol team confirmed at the kickoff AMA along with
the advice that a conventional return path is right in the meantime. The relayer releases through
late August did not change the documented status. So the return leg is a plainly labelled conventional
relayer, and writability is the roadmap step that removes the last trusted component.

**Development runs unattested unless you point it at a real enclave.** With `ENCLAVE_URL` unset the
worker derives a development signer and a development encryption key from one local secret, runs
the same model and the same refusal logic in process, and prints a warning on every run saying so.
A silent fallback would let a demo appear to prove hardware attestation while proving nothing at
all, which is the exact failure this project exists to make visible.

**The enclave is not verified by the chain, and the model is not a product.** The registry binds
what the registrar verified; the attestation is checked by whoever holds the evidence, which the
page makes easy. And the scorer is a small published logistic model over synthetic weights, there
to make "the exact model you named is the one that ran" a checkable claim rather than to underwrite
anyone.

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

## The desk: buy one decision and watch it settle

**[proofsettle.pages.dev/desk.html](https://proofsettle.pages.dev/desk.html)** is the buyer's side.
It reads the enclave's published identity (`site/enclave.json`) and checks it in the browser
against the registry and against Google's live keys, including that the two enclave keys appear as
nonces in the attestation token when the build supports that. You pick or type an applicant
record, watch its commitment update, choose which build you will accept, pay 0.001 Sepolia ETH
through MetaMask with the sealed record riding inside the payment, and then watch the page read
every step off the two chains: mined on Sepolia, attested on Creditcoin, settled, and finally the
answer opened with the one-time key the page generated when you paid and checked against the
result hash on chain.

Choose the previous, revoked build instead and the page finds the reverted settlement on
Blockscout, replays it, and decodes `EnclaveNotAccepted` by name. That is the rail refusing to your
face.

The whole flow is driven in a real browser by `node site/test-desk.mjs`: the real enclave server,
the real envelope cryptography on both sides (WebCrypto in the page, Node in the enclave), a
stubbed wallet, and the two chains replayed from what they would say. Five scenarios, thirty-six
checks, including a resume from a reload with only the saved key and an enclave refusal that rides
in the clear.

## Inside the enclave

`enclave/` is what runs inside Google Confidential Space on AMD SEV, with no runtime dependencies,
because a supply chain is a poor thing to put inside a trust boundary.

At boot it generates two keys: a secp256k1 signing key and an X25519 encryption key. It asks the
Confidential Space launcher for its attestation token with both public keys as nonces, so the
token Google signs names the keys and not only the image (`eat_nonce`). A build that cannot reach
the launcher socket falls back to the file token and says so in `/identity` as `nonceBound: false`;
the verifier page and the register script report which one they got rather than assuming.

The model is inside the image. `enclave/model.json` is a small logistic scorer over eight features
a lender can compute from mobile money and supplier records, weighted towards behaviour rather
than length of history because a thin file is the case it exists for. Its hash is
`keccak256` of its canonical JSON, published in `/identity`, and it is the `modelHash` a buyer
names in the payment. A payment naming any other model is refused, signed, and settled as
Rejected so the buyer's claim comes straight back. The same goes for a record that does not open,
does not hash to the commitment, or does not fit the model: five refusal reasons, each tested.

The envelope is X25519 with an ephemeral key, HKDF-SHA256, AES-256-GCM, with the job id in the
associated data of the result so an answer cannot be re-addressed to another job. The buyer's side
is thirty lines of WebCrypto in the desk page and `worker/seal-input.mjs` for the command line;
`worker/open-result.mjs` opens a settled job's answer off the chain and checks its hash.

The model is deliberately modest and says so in its own description. The point is not its quality.
It is that the exact model the buyer named is the one that ran, inside the exact build the buyer
named, and that a hardware attestation and a public chain both say so.

## Measuring the ground before building on it

Before building on a protocol it is worth knowing how it is being used, so I measured it rather
than guessing, and published the tool so anyone can. Two scans, each of every event the verifier
precompile emitted on CC3 testnet across 100,000 blocks, about 17.4 days, with complete coverage
and no sampling: one on 23 August, before most of the hackathon field had deployed, and one on 10
September, the day before this was submitted.

| | 23 August | 10 September |
|---|---|---|
| Transactions carrying a proof | 10,035 | **38,982** |
| Contracts that called the verifier | 142 | **284** |
| Share of traffic from the two busiest | 93.79% | **92.17%** |
| Contracts with a single sending address | 134 of 142 | **260 of 284** |
| Most distinct senders on one contract | 11 | **15**, the Attestcoin tutorial's own minter |

The final fortnight of the hackathon doubled the number of contracts and quadrupled the
transactions. The pattern is what a testnet in its testing phase looks like: two automated
callers carry most of the volume, and most contracts are exercised by the address that deployed
them. That is useful to know when designing for it, for example in choosing to build proofs
locally with a hosted fallback rather than assuming the hosted service is always the fast path.
The current figures are in `site/measurement.json`.

Measuring it also showed that the Hello Bridge tutorial's faucet note, which budgets a claim at nine
oracle queries, predates the current fee schedule: priced from eight transactions through the
tutorial's own minter, a claim covers closer to four hundred thousand. I sent the corrected wording
upstream on 26 August as pull request 30 against `gluwa/ccnext-testnet-bridge-examples`. That
repository was taken offline on 11 September, so the change is linked from
[my fork, branch `patch-1`](https://github.com/iamrobertmoore/attestcoin-protocol-examples/blob/patch-1/hello-bridge/README.md).

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

**51 tests.** Every guarantee has a paired negative test, because a suite that only walks the happy
path proves nothing about the guarantee.

Six are worth calling out.

**`test_accepts_a_sealed_record_appended_after_the_arguments`** and
**`test_settles_with_a_sealed_result_appended_after_the_arguments`.** The sealed record and the
sealed answer ride behind the ABI-encoded arguments of `createJob` and `settle`. That the decoder
ignores trailing calldata is a property of the compiled contract, not of the ABI specification, so
both are pinned against the real bytecode with low-level calls.

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

### Everything a judge can run

```bash
npm run judge:verify
```

One command, no key, no account. It runs the contract tests and the mutation check, the enclave
tests (every refusal path, the sealed round trip, determinism), the worker's calldata tests, the
launch-decision test for the deployment scripts, the three browser suites, verifies the committed
attestation token against Google's live keys, and then reads the live state back off Creditcoin:
the registry binding for the build the site names, the example settlement, the oracle's attested
height, and that the previous build is no longer what the signer is bound to. A stage whose tool is
missing is reported as a skip by name, never as a pass.

## Settled, sealed, on the live network

Three jobs on 10 September 2026, through enclave 1.2.0 with the record sealed in and the answer
sealed out. Every transaction is public.

**One from the command line**, the thin-file applicant, sealed by `script/first-settlement.sh`
and opened afterwards with `worker/open-result.mjs`:

| | |
|---|---|
| Payment | [`0xcc8283fc…8ac1ce`](https://sepolia.etherscan.io/tx/0xcc8283fc167cf6ad4ce66b19b20e84a3640cb10c191cbdb58b461f6c978ac1ce) on Sepolia, block 11,673,891, tx index 75, with a 264 byte sealed record behind the arguments |
| Settlement | [`0xef8191d1…166eb2`](https://creditcoin-testnet.blockscout.com/tx/0xef8191d1e33a8963e6c3d9c80d661b2159b10d0d28f08c93cf4628d51d166eb2) on Creditcoin, block 5,462,683, 486,430 gas, with a 926 byte sealed answer behind the arguments |
| Job id | `0xb5b56cc8d8ee6c826e22b689a8b146b3e6f48e3d4e90650008080f391b9102a7` |
| Result hash | `0x7f0eaaf88f72dc473a8037461707f7e32ab3954b3eef348701f1835e9c3dedd5`, and the opened answer hashes to it: `approve`, probability 0.755146 |
| Enclave | `0x986fb1b97e1ae22585a8c9f80d6f44bfc2e884dd`, measurement `0xea75311ddf00a6514edcb8d35cd9de829a46f2ad7d2dcc3987a4d73c2c91b741` |
| Proof | Built by the worker itself, 8 siblings and 10 continuity roots, not fetched from the hosted builder |

**One from the desk**, paid from an ordinary MetaMask wallet in a browser, with the answer opened
in that browser and nowhere else:

| | |
|---|---|
| Payment | [`0xda683013…d2da99`](https://sepolia.etherscan.io/tx/0xda6830136c8ae625f6943a3e70158c699cb05bbf94324ab93bcba100b5d2da99) on Sepolia, block 11,674,495 |
| Settlement | [`0xbfe84268…597f6`](https://creditcoin-testnet.blockscout.com/tx/0xbfe84268a6f80f0ca2262eefb7f33ec7bd52b6eb9001c03a2742e3a63f2597f6) on Creditcoin, block 5,463,175, 484,638 gas |
| Job id | `0x34c210a108481772dac755f9b46863a293daee5b2e14db9718fa41936a45d487` |
| Watch it | [proofsettle.pages.dev/desk?tx=0xda6830…](https://proofsettle.pages.dev/desk.html?tx=0xda6830136c8ae625f6943a3e70158c699cb05bbf94324ab93bcba100b5d2da99) reads every step off both chains. The answer itself opens only in the browser that paid, which is the point. |

The four logs a settlement emits are the whole argument in order, and anyone can read them off
chain:

1. `TransactionVerified(1, 11673891, 75)` from the Attestcoin verifier precompile at `0x…0FD2`.
   The protocol itself, not this project, attesting that the Sepolia payment is real.
2. `ProofConsumed(queryId, 11673891, 75)` from `ComputeSettlement`, marking that query spent, so
   the same proof cannot settle a second time.
3. `JobSettled(jobId, provider, enclave, …)` carrying the enclave signing key that the registry
   confirmed was permitted by *the buyer's own policy*, taken from the proven Sepolia event.
4. `Transfer(0x0, provider, 1e15)` from `ComputeCredit`, matching the 0.001 ETH locked on Sepolia
   and nothing more.

Both proofs were checked in that single transaction. Neither half could have settled without the
other.

The first settlement ever made on this rail, on 24 August through enclave 1.1.0 before the model
and the envelope existed, is [`0xc77cf096…1426a`](https://creditcoin-testnet.blockscout.com/tx/0xc77cf096bc552f1c9eb2d1f407bf11e211aad58708325a23f92915c05621426a)
for job `0xbd3c1618…25c3a`. It still verifies on the page.

## And here it is refusing

Success is the easy half. **The third job demanded the previous build**, 1.1.0, which I had
revoked that morning with the reason on chain
([`0xa1d4eb78…058c9`](https://creditcoin-testnet.blockscout.com/tx/0xa1d4eb78ac1eb49b73db338f66badf49e0872a26ea726a6242e03681f92058c9),
"superseded by proofsettle-enclave/1.2.0: model inside the image, sealed input and output, keys
generated inside the enclave"). The live 1.2.0 enclave opened the record, scored it and signed
anyway. The settlement contract read the buyer's requirement out of the proven payment and refused
the signature by name, on a public chain:

| | |
|---|---|
| Payment | [`0x0316007e…f34bc2`](https://sepolia.etherscan.io/tx/0x0316007e407533b2252f2a40fbeb31ac1bc67d9836ad69c2d1c09c89bef34bc2) on Sepolia, block 11,674,182, demanding measurement `0xc0a8e85a…96d0` |
| Refused settlement | [`0xaab7768b…ccb87a`](https://creditcoin-testnet.blockscout.com/tx/0xaab7768bc58f7968def2d0a68d530f8b15269e8374a8b56ab112c3e78fccb87a), block 5,462,957, status 0, 416,682 gas |
| Reason | `EnclaveNotAccepted(0xc0a8e85a…96d0, 0x986fb1b9…884dd)` |
| Job id | `0x74f22866ce424a2eca10524468661cb000bedde997efac956300e7a98726ef96` |

That error names both halves of the disagreement: the build the buyer demanded, and the key that
actually signed. The contract holds no opinion about which build is better or newer. It enforces
the one the buyer named, and nothing else. The buyer's claim stays in the Sepolia escrow and is
reclaimable after the refund delay.

The refusal is mined rather than simulated on purpose. A local revert proves nothing to anyone who
was not at the keyboard. The first refusal on this rail, on 24 August, where the buyer demanded an
unattested development key and the attested 1.1.0 enclave was refused for it, is
[`0xda7d9942…894af`](https://creditcoin-testnet.blockscout.com/tx/0xda7d994268a841fcd1a5a7a3d9366e8e4027501f635fdcc20bfb91ddd9d894af).

**The enclave is real.** The measurement bound on chain is the container image digest itself, so
there is no indirection to take on trust: pull the image, read its digest, compare. The
Google-signed attestation token that asserts it is committed at `enclave/attestation.jwt`, and

```bash
node enclave/verify-token.mjs enclave/attestation.jwt
```

verifies it against Google's published keys and prints what it actually claims: `GCP_AMD_SEV`,
secure boot on, `dbgstat: disabled-since-boot`, which means a production Confidential Space image
rather than the debug one, and an `eat_nonce` claim carrying the enclave's signing key and
encryption key, so Google's signature covers the keys and not only the image. The token expires, which is worth saying plainly: an expired token
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
test/        51 tests, plus the fixtures taken from the live prover and the real enclave
script/      deployment, the reproducible measurement, and judge-verify.sh
worker/      the off-chain worker that watches, builds raw proofs and settles; seal and open CLIs
enclave/     the attested compute service: model, envelope, server, Dockerfile, deploy scripts, tests
site/        the verifier page, the desk, and their browser suites
```

## Deploying

See `DEPLOY.md`.

## Licence

MIT.
