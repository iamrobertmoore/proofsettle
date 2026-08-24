# Deploying ProofSettle

Two chains, in this order, because the Creditcoin half needs the Sepolia address.

Every command below is safe to paste as-is. There are no inline `#` comments on command lines,
because zsh parses those interactively.

## 0. Prerequisites

**Pin Foundry to 1.2.3 first.** Foundry 1.7 cannot deserialize Creditcoin blocks: its provider
treats `mixHash` as required and CC3 does not send it, so every receipt poll fails and retries.
`forge create` survives it noisily, `forge script` can leave a half-finished deployment. Gluwa pin
the same version in their own examples.

```bash
foundryup -i v1.2.3
forge --version
```

Expect `forge 1.2.3`.

```bash
yarn install
forge install foundry-rs/forge-std --no-git
cp .env.example .env
```

Fill in `DEPLOYER_PRIVATE_KEY` with a throwaway key from `cast wallet new`, then fund it:

- **Sepolia ETH:** https://cloud.google.com/application/web3/faucet/ethereum/sepolia
- **CC3 testnet CTC:** the `#token-faucet` channel on https://discord.gg/Gu43zTfmtc, with
  `/faucet address: 0xYOURADDRESS`. 100 CTC per 24 hours, which is far more than this needs.
  Deploying the whole system costs about 0.003 CTC, and each settlement about 0.0002 CTC,
  measured against real settlements on chain rather than taken from the tutorial.

Confirm the pipeline is healthy before spending any of it:

```bash
npx tsx script/measure.ts 6000
```

## 1. Sepolia

```bash
set -a; source .env; set +a
forge script script/Deploy.s.sol:DeploySepolia --rpc-url $SOURCE_CHAIN_RPC_URL --broadcast
```

`set -a` matters. Plain `source .env` sets the variables in your shell without exporting them, and
`forge` runs as a child process, so it would see none of them.

Put the printed address into `.env` as `SOURCE_ESCROW_ADDRESS`, then run
`set -a; source .env; set +a` again.

## 2. The decoder library on Creditcoin

`EvmV1Decoder` exposes public functions, so it deploys separately and gets linked.

```bash
forge create --broadcast \
    --rpc-url $CREDITCOIN_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder
```

Put the address it prints into `.env` as `DECODER_ADDRESS`.

## 3. Creditcoin

```bash
./script/deploy-creditcoin.sh
```

That deploys `EnclaveRegistry`, `ComputeCredit` and `ComputeSettlement`, binds the minter, then
reads all six wiring facts back off chain and refuses to report success if any of them disagree.
It writes the addresses into `.env` and `site/deployments.json` as it goes, and it is safe to
re-run: anything already deployed is skipped, so a failure halfway through costs you one step.

**Why a shell script and not `forge script`.** `forge script` cannot run against CC3 at all.
Before it executes a line it builds a local EVM from the chain head, CC3 headers carry no
`prevrandao` value, and revm's header validation rejects the block:

```
Error: Failed to deploy script: EVM error; header validation error: `prevrandao` not set
```

`--skip-simulation` does not help, because the failure happens while forge is loading the script.
`forge create` and `cast` never build that local EVM, so they work, and `script/Deploy.s.sol` is
kept in the repo as the readable statement of what gets deployed and what gets checked.

## 4. The enclave

```bash
export PROJECT_ID=your-gcp-project
./enclave/deploy/20-build.sh
```

That script proves the enclave's crypto against a reference, boots the image locally and polls it,
pushes a single-platform image, and prints the config digest to allowlist. Then:

```bash
export IMAGE_REF=the-ref-20-build-printed
./enclave/deploy/30-launch.sh
```

It loops zones and machine types, and reads the launcher log rather than the serial log.

## 5. Register the enclave

Fetch `/identity` from the running enclave, verify the attestation token, then:

```bash
./script/register-enclave.sh
```

It reads `isActiveSigner` and `measurementOf` back from the registry and fails if the registration
did not take effect. Same reason as step 3 for it being a shell script rather than a `forge script`.

## 6. Run it

```bash
npx tsx worker/settle.ts watch
```

Then create a job on Sepolia and watch it settle. Attestation adds 7 to 9 minutes, measured, so
create the job before you start filming anything.
