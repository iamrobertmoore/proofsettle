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

# The buyer's policy. Normally this is whichever enclave is live, because that is the point: the
# job demands the build that will actually run it. Set REQUIRED_MEASUREMENT to demand a different
# one, which creates a job that cannot settle. That is not a mistake, it is the demonstration:
# the contract enforces what the buyer asked for and refuses everything else.
if [ -n "${REQUIRED_MEASUREMENT:-}" ]; then
    if [ "$REQUIRED_MEASUREMENT" = "$ENCLAVE_MEASUREMENT" ]; then
        fail "REQUIRED_MEASUREMENT is the same as the live enclave, so there is nothing to refuse."
    fi
    say ""
    say "    NOTE: this job will demand $REQUIRED_MEASUREMENT"
    say "    and the live enclave is  $ENCLAVE_MEASUREMENT"
    say "    so it is expected to be REFUSED on chain. Settle it with:"
    say "        npx tsx worker/settle.ts once THE_HASH --expect-refusal"
    ENCLAVE_MEASUREMENT="$REQUIRED_MEASUREMENT"
fi

# The model and the encryption key come from whoever will run the job: the enclave's /identity,
# or the development stand-in's, which derives the same shape of identity from its key. The
# applicant record is sealed to that key and rides inside the payment, exactly as the desk page
# does it in a browser; the chain only ever sees keccak256 of the record.
if [ -n "$ENCLAVE_URL" ]; then
    identity="$(curl -sf --max-time 10 "${ENCLAVE_URL}/identity")" || fail "could not reach ${ENCLAVE_URL}/identity"
else
    identity="$(npx tsx worker/dev-identity.ts)" || fail "could not derive the development identity"
fi
MODEL_HASH="$(printf '%s' "$identity" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(JSON.parse(b).modelHash??""))')"
ENC_KEY="$(printf '%s' "$identity" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(JSON.parse(b).encryptionPublicKey??""))')"
[ -n "$MODEL_HASH" ] || fail "the identity names no model hash. Is this an enclave build before 1.2.0? Rebuild and re-register."
[ -n "$ENC_KEY" ]    || fail "the identity has no encryption key, so there is nothing to seal the record to."

# The applicant. Override with SAMPLE_RECORD='{...}' to score somebody else.
# Not ${SAMPLE_RECORD:=...}: the default word inside that expansion goes through quote removal,
# which stripped every double quote out of the JSON and left seal-input.mjs a syntax error.
if [ -z "${SAMPLE_RECORD:-}" ]; then
    SAMPLE_RECORD='{"months_of_history":6,"inflows_per_month":14,"inflow_regularity":0.75,"avg_monthly_inflow_usd":300,"balance_volatility":0.4,"supplier_on_time_ratio":0.8,"prior_loans_repaid":0,"prior_loans_defaulted":0}'
fi
sealed="$(node worker/seal-input.mjs "$ENC_KEY" "$SAMPLE_RECORD")" || fail "could not seal the record"
INPUT_HASH="$(printf '%s' "$sealed" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(JSON.parse(b).inputHash))')"
SUFFIX="$(printf '%s' "$sealed" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(JSON.parse(b).calldataSuffix))')"
JOB_KEY="$(printf '%s' "$sealed" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>process.stdout.write(JSON.parse(b).ephemeralPrivateKey))')"

CALLDATA="$(cast calldata "createJob(address,bytes32,bytes32,bytes32)" \
    "$PROVIDER_ADDRESS" "$ENCLAVE_MEASUREMENT" "$MODEL_HASH" "$INPUT_HASH")${SUFFIX}"

sep_bal="$(cast balance "$BUYER_ADDRESS" --rpc-url "$SOURCE_CHAIN_RPC_URL")"
say ""
say "4/4 creating a job on Sepolia"
say "    buyer    $BUYER_ADDRESS, $(cast from-wei "$sep_bal") ETH"
say "    value    $JOB_VALUE"
say "    model    $MODEL_HASH"
say "    input    $INPUT_HASH  (keccak256 of the record; the record rides sealed, $(( ${#SUFFIX} / 2 )) bytes)"

logf="$(mktemp)"
if ! cast send "$SOURCE_ESCROW_ADDRESS" "$CALLDATA" \
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

put_env DEMO_JOB_TX  "$TX_HASH"
# The one-time key the answer comes back sealed to. Without it the settlement's result rider is
# just bytes; with it, worker/open-result.mjs turns it back into the decision.
put_env DEMO_JOB_KEY "$JOB_KEY"

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
say "Then open the sealed answer it carried, with the one-time key saved as DEMO_JOB_KEY:"
say ""
say "    node worker/open-result.mjs <jobId from the worker's output> \$DEMO_JOB_KEY"
say ""
if [ -n "$ENCLAVE_URL" ]; then
    say "The worker will call the enclave over HTTP, so no unattested warning appears. It is not true."
else
    say "It will warn loudly that the signer is unattested. That warning is correct and deliberate."
fi
