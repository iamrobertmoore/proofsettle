#!/usr/bin/env bash
#
# Set up and start one end to end settlement.
#
#   ./script/first-settlement.sh        (from the repo root)
#
# What it does, in order:
#
#   1 and 2. Settles which signer is in play and confirms the registry agrees.
#
#      With ENCLAVE_URL set, that is a real Confidential Space enclave, already registered by
#      enclave/deploy/40-register.sh under the digest of its own image. This checks the enclave is
#      answering, that it is answering as the key that was registered, and that the binding is
#      still live.
#
#      With ENCLAVE_URL unset, it makes a local development key instead and registers it under a
#      measurement whose preimage says exactly that, in plain words, on a public chain.
#
#   3. Makes a provider address to be paid, if there is not one already.
#   4. Creates a job on Sepolia, locking payment and stating which enclave the buyer will accept.
#      That requirement follows whichever signer is live, because the settlement contract enforces
#      what the buyer asked for and nothing else.
#   5. Prints the command that settles it.
#
# It does not run the worker. That takes 7 to 9 minutes waiting for the Attestcoin oracle to
# attest the Sepolia block, so it belongs in its own terminal where you can watch it.
#
# Safe to re-run. Steps 1 to 3 are skipped once done. Step 4 creates a new job every time, which
# is what you want: each run is a fresh end to end proof.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/.."

say()  { printf '%s\n' "$*"; }
fail() { printf '\n%s\n' "ERROR: $*" >&2; exit 1; }

command -v cast >/dev/null 2>&1 || fail "cast not found on PATH."
[ -f .env ] || fail "No .env in $(pwd)."

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DEPLOYER_PRIVATE_KEY:=}"
: "${CREDITCOIN_RPC_URL:=}"
: "${SOURCE_CHAIN_RPC_URL:=}"
: "${SOURCE_ESCROW_ADDRESS:=}"
: "${ENCLAVE_REGISTRY_ADDRESS:=}"
: "${SETTLEMENT_ADDRESS:=}"
: "${DEV_ENCLAVE_PRIVATE_KEY:=}"
: "${PROVIDER_ADDRESS:=}"
: "${ENCLAVE_URL:=}"
: "${ENCLAVE_MEASUREMENT:=}"
: "${ENCLAVE_SIGNING_KEY:=}"
: "${JOB_VALUE:=0.001ether}"

for v in DEPLOYER_PRIVATE_KEY CREDITCOIN_RPC_URL SOURCE_CHAIN_RPC_URL \
         SOURCE_ESCROW_ADDRESS ENCLAVE_REGISTRY_ADDRESS SETTLEMENT_ADDRESS; do
    eval "val=\${$v}"
    [ -n "$val" ] || fail "$v is empty in .env"
done

put_env() {
    local key="$1" value="$2" tmp replaced=0 line
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%=*}" = "$key" ] && [ "${line#\#}" = "$line" ]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
            replaced=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < .env
    if [ "$replaced" -eq 0 ]; then printf '%s=%s\n' "$key" "$value" >> "$tmp"; fi
    mv "$tmp" .env
}

BUYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"

# --- 1 and 2. whichever signer is in play, and its registration ------------------------------
#
# Two modes, and the job's requiredMeasurement follows whichever is live:
#
#   ENCLAVE_URL set    a real Confidential Space enclave, already registered by
#                      enclave/deploy/40-register.sh under the digest of its own image.
#   ENCLAVE_URL unset  a local development key, registered here under a measurement whose
#                      preimage says so in plain words, on a public chain.
#
# The buyer states requiredMeasurement when they pay on Sepolia, and the settlement contract
# enforces exactly that, so this has to match what the worker will actually use.

if [ -n "$ENCLAVE_URL" ]; then
    say "1/4 real enclave at $ENCLAVE_URL"

    # || true so an unreachable enclave reaches the message below rather than dying on
    # pipefail with curl's exit code and no explanation.
    live_signer="$(curl -sf --max-time 10 "${ENCLAVE_URL}/identity" \
        | sed -n 's/.*"signer":"\([^"]*\)".*/\1/p' || true)"
    [ -n "$live_signer" ] || fail "could not reach ${ENCLAVE_URL}/identity. Is the VM still up?"
    say "    signer $live_signer"

    [ -n "${ENCLAVE_MEASUREMENT:-}" ] \
        || fail "ENCLAVE_URL is set but ENCLAVE_MEASUREMENT is not. Run ./enclave/deploy/40-register.sh first."

    lc() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
    [ "$(lc "$live_signer")" = "$(lc "${ENCLAVE_SIGNING_KEY:-}")" ] \
        || fail "the enclave is answering as $live_signer but .env has ENCLAVE_SIGNING_KEY=${ENCLAVE_SIGNING_KEY:-unset}. The enclave derives a fresh key every boot, so if it restarted, re-run ./enclave/deploy/40-register.sh."

    active="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "isActiveSigner(bytes32,address)(bool)" \
        "$ENCLAVE_MEASUREMENT" "$live_signer" --rpc-url "$CREDITCOIN_RPC_URL")"
    [ "$active" = "true" ] \
        || fail "that signer is not an active signer for $ENCLAVE_MEASUREMENT. Run ./enclave/deploy/40-register.sh."

    say "2/4 registered and active in EnclaveRegistry"
    say "    measurement $ENCLAVE_MEASUREMENT"
    say "    isActiveSigner read back: $active"
else
    if [ -z "$DEV_ENCLAVE_PRIVATE_KEY" ]; then
        say "1/4 making a development signing key"
        DEV_ENCLAVE_PRIVATE_KEY="$(cast wallet new | awk '/Private key:/ {print $3}')"
        [ -n "$DEV_ENCLAVE_PRIVATE_KEY" ] || fail "could not generate a key"
        put_env DEV_ENCLAVE_PRIVATE_KEY "$DEV_ENCLAVE_PRIVATE_KEY"
    else
        say "1/4 development signing key already in .env"
    fi

    DEV_SIGNER="$(cast wallet address --private-key "$DEV_ENCLAVE_PRIVATE_KEY")"
    say "    signer $DEV_SIGNER"

    # There is no attested code here, so the measurement is the hash of a string that says exactly
    # that, and it goes on a public chain where anyone can read it. When a real image exists it
    # registers under its own digest, and this one keeps saying what it always said.
    DEV_LABEL="proofsettle.development-signer.v1 NOT-ATTESTED"
    DEV_EVIDENCE_URI="urn:proofsettle:development-signer:not-attested"

    ENCLAVE_MEASUREMENT="$(cast keccak "$DEV_LABEL")"
    ENCLAVE_SIGNING_KEY="$DEV_SIGNER"
    ENCLAVE_EVIDENCE_HASH="$(cast keccak "$DEV_EVIDENCE_URI")"
    ENCLAVE_EVIDENCE_URI="$DEV_EVIDENCE_URI"

    put_env ENCLAVE_MEASUREMENT   "$ENCLAVE_MEASUREMENT"
    put_env ENCLAVE_SIGNING_KEY   "$ENCLAVE_SIGNING_KEY"
    put_env ENCLAVE_EVIDENCE_HASH "$ENCLAVE_EVIDENCE_HASH"
    put_env ENCLAVE_EVIDENCE_URI  "$ENCLAVE_EVIDENCE_URI"

    active="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "isActiveSigner(bytes32,address)(bool)" \
        "$ENCLAVE_MEASUREMENT" "$DEV_SIGNER" --rpc-url "$CREDITCOIN_RPC_URL")"

    if [ "$active" = "true" ]; then
        say "2/4 already registered in EnclaveRegistry"
    else
        say "2/4 registering it in EnclaveRegistry"
        cast send "$ENCLAVE_REGISTRY_ADDRESS" "register(bytes32,address,bytes32,string)" \
            "$ENCLAVE_MEASUREMENT" "$DEV_SIGNER" "$ENCLAVE_EVIDENCE_HASH" "$ENCLAVE_EVIDENCE_URI" \
            --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" >/dev/null
        active="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "isActiveSigner(bytes32,address)(bool)" \
            "$ENCLAVE_MEASUREMENT" "$DEV_SIGNER" --rpc-url "$CREDITCOIN_RPC_URL")"
        [ "$active" = "true" ] || fail "registration did not take effect"
    fi
    say "    measurement $ENCLAVE_MEASUREMENT"
    say "    isActiveSigner read back: $active"
fi

# --- 3. somebody to pay ----------------------------------------------------------------------

if [ -z "$PROVIDER_ADDRESS" ]; then
    say "3/4 making a provider address"
    out="$(cast wallet new)"
    PROVIDER_ADDRESS="$(printf '%s' "$out" | awk '/Address:/ {print $2}')"
    PROVIDER_PRIVATE_KEY="$(printf '%s' "$out" | awk '/Private key:/ {print $3}')"
    put_env PROVIDER_ADDRESS     "$PROVIDER_ADDRESS"
    put_env PROVIDER_PRIVATE_KEY "$PROVIDER_PRIVATE_KEY"
else
    say "3/4 provider address already in .env"
fi
say "    provider $PROVIDER_ADDRESS"

# --- 4. create the job on Sepolia ---------------------------------------------------------------

MODEL_HASH="$(cast keccak "llama-3.1-8b-instruct")"
INPUT_HASH="$(cast keccak "proofsettle demo prompt, $(cast block-number --rpc-url "$SOURCE_CHAIN_RPC_URL")")"

sep_bal="$(cast balance "$BUYER_ADDRESS" --rpc-url "$SOURCE_CHAIN_RPC_URL")"
say ""
say "4/4 creating a job on Sepolia"
say "    buyer    $BUYER_ADDRESS, $(cast from-wei "$sep_bal") ETH"
say "    value    $JOB_VALUE"
say "    model    $MODEL_HASH"
say "    input    $INPUT_HASH"

logf="$(mktemp)"
if ! cast send "$SOURCE_ESCROW_ADDRESS" \
        "createJob(address,bytes32,bytes32,bytes32)" \
        "$PROVIDER_ADDRESS" "$ENCLAVE_MEASUREMENT" "$MODEL_HASH" "$INPUT_HASH" \
        --value "$JOB_VALUE" \
        --rpc-url "$SOURCE_CHAIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" \
        --json >"$logf" 2>&1; then
    say ""
    say "cast send failed:"
    sed 's/^/    /' "$logf"
    rm -f "$logf"
    exit 1
fi

TX_HASH="$(grep -Eo '"transactionHash" *: *"0x[0-9a-fA-F]{64}"' "$logf" | grep -Eo '0x[0-9a-fA-F]{64}' | tail -1 || true)"
STATUS="$(grep -Eo '"status" *: *"?0x[0-9a-fA-F]+' "$logf" | grep -Eo '0x[0-9a-fA-F]+' | tail -1 || true)"
BLOCK="$(grep -Eo '"blockNumber" *: *"?0x[0-9a-fA-F]+' "$logf" | grep -Eo '0x[0-9a-fA-F]+' | tail -1 || true)"
rm -f "$logf"

[ -n "$TX_HASH" ] || fail "the job transaction was sent but I could not read its hash back. Check Sepolia for $BUYER_ADDRESS before re-running, so you do not pay twice."
[ "$STATUS" = "0x1" ] || fail "job transaction $TX_HASH did not succeed (status $STATUS)"

put_env DEMO_JOB_TX "$TX_HASH"

say "    tx       $TX_HASH"
if [ -n "$BLOCK" ]; then say "    block    $((BLOCK))"; fi
say "    https://sepolia.etherscan.io/tx/$TX_HASH"

# --- what to run next ------------------------------------------------------------------------

say ""
say "Job created and paid for. Now settle it on Creditcoin:"
say ""
say "    npx tsx worker/settle.ts once $TX_HASH"
say ""
say "That waits for the Attestcoin oracle to attest the Sepolia block the payment landed in,"
say "which is 7 to 9 minutes, then submits the inclusion proof and the signed verdict together"
say "in one Creditcoin transaction. It prints every stage as it goes."
say ""
if [ -n "$ENCLAVE_URL" ]; then
    say "The worker will call the enclave over HTTP, so no unattested warning appears. It is not true."
else
    say "It will warn loudly that the signer is unattested. That warning is correct and deliberate."
fi
