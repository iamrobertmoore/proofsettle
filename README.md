# ProofSettle

**Private compute. Verifiable payment.** A buyer-controlled settlement rail on Creditcoin: Attestcoin proves a Sepolia payment and its policy; a measured enclave signs the exact request and sealed answer. Both must agree before Creditcoin authorizes settlement.

[Verify a real run](https://proofsettle.pages.dev/#evidence) · [Open the synthetic answer](https://proofsettle.pages.dev/desk.html?demo=1) · [Buyer desk](https://proofsettle.pages.dev/desk.html) · [Deck](https://proofsettle.pages.dev/ProofSettle-deck.pdf) · [DoraHacks](https://dorahacks.io/buidl/48538)

Built by **Robert Moore**, solo, for Creditcoin BUIDL 2026 Fall. Public testnet implementation, MIT licensed. No customer traction or production security audit claimed.

## Start here: two minutes, no wallet

1. Open the [live evidence walkthrough](https://proofsettle.pages.dev/#evidence). It independently reads Sepolia and Creditcoin for payment, request binding, delivered ciphertext, original ETH payout and a mined wrong-build refusal.
2. [Open the example answer](https://proofsettle.pages.dev/desk.html?demo=1). This deliberately public synthetic example publishes a disposable answer key. Ordinary buyer sessions keep that key in the paying browser.
3. Use the [detailed verifier](https://proofsettle.pages.dev/verify.html#check) to inspect the registry, replay protection, split and Google-signed enrollment evidence.

The [evidence manifest](site/demo.json) and [deployment addresses](site/deployments.json) are the same files the site reads. Explorer links expose the actual transactions. A green homepage check is a fresh RPC read, not a saved screenshot.

## The customer and the product

A small lender needs a model's decision but cannot disclose the applicant's record to an unknown compute provider. ProofSettle seals that record to a measured workload and makes payment conditional on verifiable service completion.

The demo uses eight synthetic financial-behaviour features and a small deterministic logistic model. It demonstrates the settlement protocol, **not validated underwriting**. It requires no GPU. The longer-term use case is externally supplied private computation where the buyer needs both payment and execution guarantees. See [the model card](MODEL_CARD.md).

A successfully computed `decline` still pays the provider. Applicant decisions are private model outputs; `Accepted`, `Rejected` and `Partial` in the contract describe the **compute service**, not applicant eligibility.

## How the protocol works

1. **Seal and pay on Sepolia.** The browser randomizes the input commitment with a fresh nonce, encrypts the record using X25519 + HKDF-SHA256 + AES-256-GCM, and appends the envelope to `createJob`. The escrow emits payer, provider, amount, required image measurement, model hash, input hash, envelope hash and a one-day settlement deadline.
2. **Prove the source event.** The worker constructs a proof with `RawProofBuilder` from source receipts and headers. It waits for Creditcoin's attested source height. A hosted builder is an optional fallback; neither builder is an authority.
3. **Run inside the measured enclave.** The enclave checks model and plaintext commitments, executes the model, encrypts the accepted answer to the buyer's return key and signs the request and exact delivery commitments.
4. **Check both proofs in one Creditcoin transaction.** The settlement contract verifies inclusion and continuity, pins the escrow emitter, reads the buyer's policy, checks the deadline, matches both commitments and recovers the registered enclave signer. Replay protection and every failure roll back atomically.
5. **Release the original payment.** A **fixed, explicitly trusted return relayer** reads the Creditcoin split after a 30-second confirmation lag and finalizes the Sepolia escrow. Permissionless `withdrawFor` can then send ETH only to the recorded recipients. This is not production Attestcoin writability.

### What Attestcoin contributes

`ComputeSettlement` extends [`AttestcoinProven`](src/AttestcoinProven.sol):

- The native verifier at `0x0000000000000000000000000000000000000FD2` supplies `calculateTxIndex` for the replay key and `verifyAndEmit` for inclusion and continuity. Returning `false` is a failure, as is reverting.
- `EvmV1Decoder` decodes the proven EVM transaction receipt. The contract requires successful source execution, identifies `JobCreated` by its exact signature, and rejects every emitter except its immutable source escrow.
- The proof carries **policy**: the required build and request commitments come from the buyer's payment. The settlement has no independent admin-editable buyer-policy allowlist. The enclave registry still has a trusted registrar.
- ChainInfo at `0x0000000000000000000000000000000000000FD3` supplies attested source height. Source chain key is pinned to `1` for Sepolia.

### Exact request and delivery binding (v2)

```text
requestHash = keccak256(abi.encode(modelHash, inputHash, envelopeHash))
deliveryHash = keccak256(actual delivery bytes appended to settlement)

signed digest = keccak256(abi.encode(
  "proofsettle.result.v2", destinationChainId, settlementAddress,
  jobId, resultHash, serviceOutcome, scoreBps, requestHash, deliveryHash
))
```

The return key is inside the encrypted envelope. Swapping it changes `envelopeHash` and therefore `requestHash`. A real enclave signature over a substitute request cannot settle the original payment. Omitting or replacing the signed answer payload fails `DeliveryMismatch`.

The trailer is `payload || uint32_be(length) || "PSE1"`. Source and destination contracts hash the actual trailer payload. The normal Solidity arguments still decode. The accepted response is encrypted; rejected requests carry a public, non-sensitive error reason.

## Trust and limits

| Component | What is trusted or established |
|---|---|
| Attestcoin / Creditcoin | Native source-proof verification, chain consensus and finality assumptions |
| Google + confidential hardware | Enrollment evidence for the image and both enclave keys; not continuous runtime monitoring |
| Registry registrar | Verifies enrollment and binds/revokes the measurement-to-signing-key record |
| Proof worker | Cannot forge the source proof or enclave signature; can delay or withhold submission |
| Return relayer | **Trusted by Sepolia to report the correct Creditcoin split.** Its fixed key can misallocate escrow if compromised |
| Browser | Holds the plaintext and answer key; the web origin, device and wallet must be trusted |
| Model | Fixed published demonstrator; no fairness, predictive-quality or real-world underwriting validation |

Public chains contain **addresses, amounts, commitments and ciphertext**, not only hashes. The input hash is randomized by a nonce inside the encrypted record to discourage dictionary attacks on low-entropy synthetic features. Length and timing metadata are visible.

The source contract allows settlement within one day and a payer timeout refund after 30 days. Finalized and refunded states are mutually exclusive. If the relayer never finalizes, the buyer can eventually refund; the provider bears that return-leg availability risk. The confirmation lag is an operational precaution, not a consensus proof.

`ComputeCredit` retains its contract name for continuity but issues **PSR non-transferable historical receipts**. They are not redeemable money, transferable claims or independent evidence of ETH withdrawal.

Enrollment is permanent per image measurement in this prototype. Restarting the same image with a new ephemeral key requires a new registry/release strategy. Production work includes key rotation, recovery, independent security review and a verified return path. See [SECURITY.md](SECURITY.md).

## Verify locally

Requirements: Node.js 22+, Yarn 1.x, Foundry 1.2.3, Python 3, and Chromium for the browser suites. No wallet key is needed for verification.

```sh
git clone https://github.com/iamrobertmoore/proofsettle.git
cd proofsettle
yarn install --frozen-lockfile
forge install foundry-rs/forge-std --no-git
npx playwright install chromium
npm run judge:verify
```

On Linux, use `npx playwright install --with-deps chromium` if system libraries are missing. `yarn install` also installs the enclave's separately pinned cryptography dependencies. `PW_CHROMIUM` can select an existing browser binary.

The verification command runs contract tests, mutation checks, enclave/worker tests, deployment-decision tests, browser suites, Google-token verification and live Creditcoin readbacks. It reports skipped browser checks explicitly if Chromium is absent. **CI installs Chromium and requires all browser suites.** Network outages can fail the live-readback stages without invalidating local test results.

Focused commands:

```sh
forge test
./script/mutation-check.sh
npm run test:enclave
npm run test:worker
npm run test:site
node enclave/verify-crypto.mjs
node enclave/verify-token.mjs enclave/attestation.jwt
```

### What the tests establish

**65 contract tests and 15 killed security mutations.** The suite deliberately breaks emitter pinning, registry checks, revocation, replay protection, false-return handling, source status, signature malleability, source-chain pinning, service splitting, outcome binding, conservation, request binding, delivery binding, deadlines and double-refund protection. Every mutation must fail its defending test.

Ten enclave integration tests run the real server outside confidential hardware and check identity, model determinism, encrypted round trips, refusal cases and request/delivery signature binding. Three calldata tests use compiled ABIs. Browser tests use explicit RPC/wallet fixtures and the real enclave process; they are not themselves testnet evidence. The separate live manifest and readbacks supply that evidence.

## Repository map

| Location | Purpose |
|---|---|
| [`src/`](src/) | Source escrow, native proof adapter, policy enforcement, registry and receipt accounting |
| [`enclave/`](enclave/) | Measured Node workload, pinned standard signing/hash libraries, encryption and model |
| [`worker/`](worker/) | Raw proof construction, durable pending-job queue, enclave client and trusted return leg |
| [`site/`](site/) | Overview, live walkthrough, buyer desk, verifier, evidence and ABIs |
| [`deck/`](deck/) | Editable HTML deck and PDF at the stable public filename |
| [`test/`](test/) | Solidity tests and real-server signature fixtures |
| [`DEPLOY.md`](DEPLOY.md) | Deployment, enrollment, service operation and site publishing |
| [`site/releases/v1/`](site/releases/v1/) | Superseded deployment identities; current examples use v2 |

## Next: validate a narrow pilot

The first target is one lender and one model provider, using synthetic data. Customer interviews and a design partner are next steps, not current traction. Measure successful delivery rate, proof latency, total cost and recovery behaviour. Validate a per-settlement service/integration fee before choosing pricing. Independent review and lifecycle/recovery work precede real borrower data or a production deployment.

The current proof is a working protocol and inspectable execution, not a claim that a market has already been won.
