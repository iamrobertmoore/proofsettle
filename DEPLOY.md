# Deploy and operate ProofSettle

The published deployment is testnet only. Current public addresses and transaction evidence are in `site/deployments.json`, `site/release-v2.json` and `site/demo.json`. The browser reads these exact files.

## Reproduce the environment

Use Node.js 22+, Yarn 1.x, Foundry 1.2.3, Python 3 and Chromium. Install dependencies as described in the README. Copy `.env.example` to `.env`, add throwaway testnet keys and fund them on Sepolia and CC3. Never commit `.env` or wallet keys.

`DEPLOYER_PRIVATE_KEY` deploys and enrolls. `WORKER_PRIVATE_KEY` submits Creditcoin proofs. `RETURN_RELAYER_PRIVATE_KEY` must match the source escrow's immutable `settlementRelayer`; when omitted, the deployment key is used. That return key is explicitly trusted by the source contract.

## Contracts

Deploy a Sepolia `ComputeJobEscrow`, then a Creditcoin `EvmV1Decoder` library, `EnclaveRegistry`, `ComputeCredit` and `ComputeSettlement`. Settlement constructor arguments are source chain key, registry, receipt token and source escrow. Link the decoder library, then call `ComputeCredit.setMinter(settlement)` once.

The existing scripts provide the first-deployment sequence:

```sh
forge create src/ComputeJobEscrow.sol:ComputeJobEscrow --broadcast --rpc-url "$SOURCE_CHAIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
# Record SOURCE_ESCROW_ADDRESS in .env.
forge create node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder --broadcast --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"
# Record DECODER_ADDRESS in .env.
./script/deploy-creditcoin.sh
./script/verify-contracts.sh
```

Load `.env` into the shell before these commands (`set -a; source .env; set +a`). `forge script` cannot simulate this CC3 endpoint's headers reliably; these scripts use direct deployment calls and readbacks instead.

`script/deploy-v2.mjs` is the **recorded v1→v2 migration**, reusing this project's existing registry and decoder. It saves a resumable public deployment log and privately backs up `.env`; it is not a generic redeploy command. Do not delete the log and rerun it unless intentionally starting another release. Deployment transactions must be checked before retrying uncertain RPC sends.

## Confidential Space

Use the existing Google setup scripts with your project ID. Build the image, run it locally, verify standard cryptography against ethers, verify amd64 execution, and push a single-platform image:

```sh
PROJECT_ID=your-project TAG=v2 ./enclave/deploy/20-build.sh
PROJECT_ID=your-project TAG=v2 FAMILIES=confidential-space ./enclave/deploy/30-launch.sh
./enclave/deploy/40-register.sh
```

The launch script resolves the registry tag to an immutable image reference and compares the launched digest to Google's signed `submods.container.image_digest`. The signed token is the authoritative measurement source. Docker manifest and config digests are distinct; do not substitute one for the other.

Enrollment requires production debug status, secure boot, and both the signing and encryption keys in Google's `eat_nonce`. The registrar verifies Google's signature and writes the measurement/key binding. The token is saved both at `enclave/attestation.jwt` and a content-addressed path under `site/attestations/`. That stable evidence path must be included when publishing.

**Lifecycle limit:** keys are generated at process startup. The prototype registry cannot rotate a key under the same measurement. A restart must be detected and handled as a deliberate release/recovery operation; do not register a silently changed key as though it were the old identity.

The firewall limits enclave ingress. Permit the worker through the project's internal network or a narrowly scoped worker source address. The browser never contacts the enclave directly; its input travels in the source payment.

## Worker and return payment

```sh
npx tsx worker/settle.ts once <actual-sepolia-payment-hash>
npx tsx worker/settle.ts watch
```

The watch service persists discovered jobs **before processing** in `.worker-state.json`. Failed jobs remain pending and are retried; one failure does not erase a later job. Set `WORKER_FROM_BLOCK` only when intentionally selecting a starting point. Back up state before changing deployment addresses.

A typical systemd service uses the repository as its working directory, runs `npx tsx worker/settle.ts watch`, restarts on failure and loads the private environment only on the worker. Run a single writer per funded account to avoid nonce races. Protect the return-relayer key; unlike the proof-submission role it has source-chain authority.

After Creditcoin settlement the return leg waits 30 seconds, checks payer/provider/amount and the conserved split, finalizes once on Sepolia, then withdraws to the recorded recipients. A retry on an already-settled job also retries its return leg. An unset/incorrect return key fails visibly.

## Synthetic examples

`script/demo-v2.mjs accepted`, `wrong-build` and `rejected` create intentionally synthetic 0.001 ETH testnet payments. They publish **only disposable answer keys**, never a wallet key. Each mode refuses to overwrite its existing evidence file. Use the printed source transaction with the worker; wrong-build additionally takes `--expect-refusal`.

Do not publish real records or private answer keys. The public synthetic fixture is specifically labelled as such.

## Site and stable deck link

```sh
node deck/build-deck.mjs
node deck/render.mjs
./script/build-site.sh
npx wrangler pages deploy _site --project-name proofsettle --branch main
```

Update `deck/facts.json` from actual verified evidence before rendering. Rendering checks all slide bounds and fails on overflow. Inspect the rendered PDF visually as well.

**Keep `ProofSettle-deck.pdf` at the site root.** Its public URL remains `https://proofsettle.pages.dev/ProofSettle-deck.pdf`. Keep the existing Cloudflare project and production branch. Verify the live file hash and all walkthrough links after deployment.

## Release checks

Run `npm run judge:verify`, check CI, verify explorer source, follow the homepage into a fresh buyer order, inspect the judging appendix’s five live checks, open its synthetic reference answer, and check mobile layout. Confirm the worker service is active and reading the new deployment. Archive superseded evidence explicitly; never mix a new enclave identity with an old example in the default walkthrough.
