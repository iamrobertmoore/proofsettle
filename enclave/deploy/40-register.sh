#!/usr/bin/env bash
#
# Take the running enclave's attestation token, verify it, and register the binding on Creditcoin.
#
#   ./enclave/deploy/40-register.sh        (from the repo root)
#
# The measurement it registers is the container image digest out of the verified token, so the
# on-chain record points at a specific image and nothing else. Anyone can check it: pull the image
# reference, read its digest, compare. There is no indirection to take on trust.
#
# This does not use forge script. forge script cannot run against CC3 at all, because CC3 block
# headers carry no prevrandao and forge builds a local EVM from the chain head before it executes
# anything. See working notes, and script/register-enclave.sh.

set -euo pipefail

here="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$here"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

command -v cast >/dev/null 2>&1 || die "cast not found on PATH"
command -v node >/dev/null 2>&1 || die "node not found on PATH"
[ -f .env ] || die "no .env in $here"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${ENCLAVE_URL:=}"
: "${CREDITCOIN_RPC_URL:=}"
: "${DEPLOYER_PRIVATE_KEY:=}"
: "${ENCLAVE_REGISTRY_ADDRESS:=}"

[ -n "$ENCLAVE_URL" ] || die "ENCLAVE_URL is empty in .env. Run ./enclave/deploy/30-launch.sh first."
[ -n "$CREDITCOIN_RPC_URL" ] || die "CREDITCOIN_RPC_URL is empty in .env"
[ -n "$DEPLOYER_PRIVATE_KEY" ] || die "DEPLOYER_PRIVATE_KEY is empty in .env"
[ -n "$ENCLAVE_REGISTRY_ADDRESS" ] || die "ENCLAVE_REGISTRY_ADDRESS is empty in .env"

put_env() {
    local key="$1" value="$2" tmp replaced=0 line
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%=*}" = "$key" ] && [ "${line#\#}" = "$line" ]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"; replaced=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < .env
    if [ "$replaced" -eq 0 ]; then printf '%s=%s\n' "$key" "$value" >> "$tmp"; fi
    mv "$tmp" .env
}

say "1. Fetch the enclave's identity"
identity="$(curl -sf --max-time 10 "${ENCLAVE_URL}/identity")" || die "could not reach ${ENCLAVE_URL}/identity"

SIGNER="$(printf '%s' "$identity" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{const d=JSON.parse(b);process.stdout.write(d.signer??"")})')"
ATTESTED="$(printf '%s' "$identity" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{const d=JSON.parse(b);process.stdout.write(String(d.attested))})')"
printf '%s' "$identity" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{const d=JSON.parse(b);process.stdout.write(d.attestationToken??"")})' > enclave/attestation.jwt

[ -n "$SIGNER" ] || die "/identity returned no signer"
echo "  signer   $SIGNER"
echo "  attested $ATTESTED"

if [ "$ATTESTED" != "true" ]; then
    rm -f enclave/attestation.jwt
    die "the enclave reports attested:false, so there is no hardware attestation to register. Registering it anyway would be the exact overclaim this project argues against."
fi
[ -s enclave/attestation.jwt ] || die "attested:true but no token came back"
echo "  token    $(wc -c < enclave/attestation.jwt | tr -d ' ') bytes, saved to enclave/attestation.jwt"

say "2. Verify that token, against Google's published keys"
node enclave/verify-token.mjs enclave/attestation.jwt || die "the attestation token did not verify"

MEASUREMENT="$(node enclave/verify-token.mjs enclave/attestation.jwt | sed -n 's/^  ENCLAVE_MEASUREMENT=//p')"
EVIDENCE_HASH="$(node enclave/verify-token.mjs enclave/attestation.jwt | sed -n 's/^  ENCLAVE_EVIDENCE_HASH=//p')"
[ -n "$MEASUREMENT" ] || die "could not read a measurement out of the token"
[ -n "$EVIDENCE_HASH" ] || die "could not compute the evidence hash"

# Deliberately NOT ${ENCLAVE_EVIDENCE_URI:-...}. That variable is already in .env, left there by
# script/first-settlement.sh when it registered a development key, and inheriting it wrote
# "urn:proofsettle:development-signer:not-attested" into the on-chain record of a genuinely
# attested enclave. Registration is permanent in this registry, so that mistake cannot be edited
# afterwards. Default fresh every time, and override only through a variable that means it.
EVIDENCE_URI="${EVIDENCE_URI_OVERRIDE:-https://raw.githubusercontent.com/iamrobertmoore/proofsettle/main/enclave/attestation.jwt}"

case "$EVIDENCE_URI" in
    *not-attested*|*development-signer*)
        die "the evidence URI says this is a development signer, but the token says it is attested. Refusing to write that contradiction to a permanent record. Unset EVIDENCE_URI_OVERRIDE and run again." ;;
esac

say "3. Register the binding on Creditcoin"
echo "  registry     $ENCLAVE_REGISTRY_ADDRESS"
echo "  measurement  $MEASUREMENT"
echo "  signer       $SIGNER"
echo "  evidence     $EVIDENCE_URI"

put_env ENCLAVE_MEASUREMENT   "$MEASUREMENT"
put_env ENCLAVE_SIGNING_KEY   "$SIGNER"
put_env ENCLAVE_EVIDENCE_HASH "$EVIDENCE_HASH"
put_env ENCLAVE_EVIDENCE_URI  "$EVIDENCE_URI"

active="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "isActiveSigner(bytes32,address)(bool)" \
    "$MEASUREMENT" "$SIGNER" --rpc-url "$CREDITCOIN_RPC_URL")"

if [ "$active" = "true" ]; then
    # Do not print the URI we would have written and then skip writing it. That reads as though it
    # was registered with this value when the chain may hold something quite different, and this
    # registry is permanent, so the difference cannot be corrected in place.
    onchain="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" \
        "enclaveOf(bytes32)((bytes32,address,bytes32,string,uint64,uint64))" "$MEASUREMENT" \
        --rpc-url "$CREDITCOIN_RPC_URL" 2>/dev/null || true)"
    onchain_uri="$(printf '%s' "$onchain" | sed -n 's/.*"\(.*\)".*/\1/p')"
    echo "  already registered and active, nothing was written"
    echo "  evidence on chain  ${onchain_uri:-could not read it back}"
    if [ -n "$onchain_uri" ] && [ "$onchain_uri" != "$EVIDENCE_URI" ]; then
        echo ""
        echo "  WARNING: the record on chain does not carry the evidence URI above."
        echo "    on chain  $onchain_uri"
        echo "    intended  $EVIDENCE_URI"
        echo "  register() is permanent and a measurement cannot be re-registered. To correct it,"
        echo "  change the enclave so its image digest changes, launch that, and register the new"
        echo "  measurement. Revoke this one to record why it was superseded."
    fi
else
    cast send "$ENCLAVE_REGISTRY_ADDRESS" "register(bytes32,address,bytes32,string)" \
        "$MEASUREMENT" "$SIGNER" "$EVIDENCE_HASH" "$EVIDENCE_URI" \
        --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" >/dev/null \
        || die "the registration transaction failed"
fi

say "4. Read it back off chain"
confirmed="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "isActiveSigner(bytes32,address)(bool)" \
    "$MEASUREMENT" "$SIGNER" --rpc-url "$CREDITCOIN_RPC_URL")"
measurement_of="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "measurementOf(address)(bytes32)" \
    "$SIGNER" --rpc-url "$CREDITCOIN_RPC_URL")"

echo "  isActiveSigner  $confirmed"
echo "  measurementOf   $measurement_of"

[ "$confirmed" = "true" ] || die "registration did not take effect"
[ "$measurement_of" = "$MEASUREMENT" ] || die "the registry binds that signer to $measurement_of, not $MEASUREMENT"

cat <<EOF

Registration confirmed by reading the registry back, not assumed.

The attestation token is saved at enclave/attestation.jwt. Commit it: it is the evidence the
on-chain record points at, it contains no secrets, and anyone can re-run

    node enclave/verify-token.mjs enclave/attestation.jwt

and reach their own conclusion. It expires, which is fine and worth saying out loud: an expired
token is a historical record of what was running, not a live proof that it still is.

Next, settle a job through the real enclave:

    ./script/first-settlement.sh
    npx tsx worker/settle.ts once <the tx hash it prints>

With ENCLAVE_URL set, the worker calls the enclave instead of the development signer, and the
unattested warning stops appearing. That is the run worth filming.

EOF
