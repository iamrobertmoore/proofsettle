# Deploying ProofSettle

Two chains, in this order, because the Creditcoin half needs the Sepolia address.

Every command below is safe to paste as-is. There are no inline `#` comments on command lines,
because zsh parses those interactively.

## 0. Prerequisites

```bash
yarn install
forge install foundry-rs/forge-std --no-git
cp .env.example .env
```

Fill in `DEPLOYER_PRIVATE_KEY` with a throwaway key from `cast wallet new`, then fund it:

- **Sepolia ETH:** https://cloud.google.com/application/web3/faucet/ethereum/sepolia
- **CC3 testnet CTC:** the `#token-faucet` channel on https://discord.gg/Gu43zTfmtc, with
  `/faucet address: 0xYOURADDRESS`. 100 CTC per 24 hours, which is roughly 9 oracle queries.

Confirm the pipeline is healthy before spending any of it:

```bash
npx tsx script/measure.ts 6000
```

## 1. Sepolia

```bash
source .env
forge script script/Deploy.s.sol:DeploySepolia --rpc-url $SOURCE_CHAIN_RPC_URL --broadcast
```

Put the printed address into `.env` as `SOURCE_ESCROW_ADDRESS`, then `source .env` again.

## 2. The decoder library on Creditcoin

`EvmV1Decoder` exposes public functions, so it deploys separately and gets linked.

```bash
forge create --broadcast \
    --rpc-url $CREDITCOIN_RPC_URL \
    --private-key $DEPLOYER_PRIVATE_KEY \
    node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder
```

Keep the address it prints.

## 3. Creditcoin

```bash
forge script script/Deploy.s.sol:DeployCreditcoin \
    --rpc-url $CREDITCOIN_RPC_URL \
    --broadcast \
    --libraries node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder:DECODER_ADDRESS
```

Substitute the decoder address from step 2. The script reads the wiring back off chain and
fails if any of it did not take, rather than trusting the transaction receipts.

Put the three printed addresses into `.env`, and into `site/deployments.json` so the public
verifier page prefills them.

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
source .env
forge script script/Deploy.s.sol:RegisterEnclave --rpc-url $CREDITCOIN_RPC_URL --broadcast
```

The script reads `isActiveSigner` back and fails if the registration did not take effect.

## 6. Run it

```bash
npx tsx worker/settle.ts watch
```

Then create a job on Sepolia and watch it settle. Attestation adds 7 to 9 minutes, measured, so
create the job before you start filming anything.
