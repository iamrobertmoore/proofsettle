#!/usr/bin/env bash
#
# Register an attested enclave build against its signing key, without forge script.
#
#   ./script/register-enclave.sh   (from the repo root)
#
# Same reason as deploy-creditcoin.sh: forge script cannot run against CC3 at all, because CC3
# block headers have no prevrandao and forge builds a local EVM from the chain head before it
# executes anything. This is script/Deploy.s.sol:RegisterEnclave in cast, read-back check included.
#
# Reads ENCLAVE_MEASUREMENT, ENCLAVE_SIGNING_KEY, ENCLAVE_EVIDENCE_HASH and ENCLAVE_EVIDENCE_URI
# from .env. Safe to re-run: if the key is already active for that measurement it does nothing.

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

: "${CREDITCOIN_RPC_URL:=}"
: "${DEPLOYER_PRIVATE_KEY:=}"
: "${ENCLAVE_REGISTRY_ADDRESS:=}"
: "${ENCLAVE_MEASUREMENT:=}"
: "${ENCLAVE_SIGNING_KEY:=}"
: "${ENCLAVE_EVIDENCE_HASH:=}"
: "${ENCLAVE_EVIDENCE_URI:=}"

for v in CREDITCOIN_RPC_URL DEPLOYER_PRIVATE_KEY ENCLAVE_REGISTRY_ADDRESS \
         ENCLAVE_MEASUREMENT ENCLAVE_SIGNING_KEY ENCLAVE_EVIDENCE_HASH ENCLAVE_EVIDENCE_URI; do
    eval "val=\${$v}"
    [ -n "$val" ] || fail "$v is empty in .env"
done

say "Registering enclave"
say "  registry     $ENCLAVE_REGISTRY_ADDRESS"
say "  measurement  $ENCLAVE_MEASUREMENT"
say "  signing key  $ENCLAVE_SIGNING_KEY"
say "  evidence     $ENCLAVE_EVIDENCE_URI"
say ""

already="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "isActiveSigner(bytes32,address)(bool)" \
    "$ENCLAVE_MEASUREMENT" "$ENCLAVE_SIGNING_KEY" --rpc-url "$CREDITCOIN_RPC_URL")"

if [ "$already" = "true" ]; then
    say "Already registered and active, nothing to do."
else
    cast send "$ENCLAVE_REGISTRY_ADDRESS" "register(bytes32,address,bytes32,string)" \
        "$ENCLAVE_MEASUREMENT" "$ENCLAVE_SIGNING_KEY" "$ENCLAVE_EVIDENCE_HASH" "$ENCLAVE_EVIDENCE_URI" \
        --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" >/dev/null
fi

confirmed="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "isActiveSigner(bytes32,address)(bool)" \
    "$ENCLAVE_MEASUREMENT" "$ENCLAVE_SIGNING_KEY" --rpc-url "$CREDITCOIN_RPC_URL")"

measurement_of="$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "measurementOf(address)(bytes32)" \
    "$ENCLAVE_SIGNING_KEY" --rpc-url "$CREDITCOIN_RPC_URL")"

say ""
say "  isActiveSigner   $confirmed"
say "  measurementOf    $measurement_of"

[ "$confirmed" = "true" ] || fail "Registration did not take effect."

say ""
say "Registration confirmed by reading the registry back, not assumed."
