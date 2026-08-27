#!/usr/bin/env bash
#
# Publish the deployed contracts' source on Blockscout, so a stranger clicking an address sees
# Solidity rather than bytecode.
#
#   ./script/verify-contracts.sh          (from the repo root)
#
# This matters more than it looks. Without it the explorer shows our own events as raw topics, so
# the four events that make the settlement argument read as lines of hex. Gluwa's BlockProver is
# verified, which is why its TransactionVerified event decodes and ours do not.
#
# Constructor arguments are read back off the chain rather than reconstructed from .env. The first
# version of this script rebuilt them from environment variables and failed immediately, because
# the deploy script derives the deployer address from the private key at run time and never writes
# it anywhere. Reading the deployed contract is both simpler and harder to get wrong: for
# ComputeSettlement every argument is stored in an immutable, so what comes back cannot be anything
# other than what went in.
#
# Blockscout needs no API key. The compiler settings come from foundry.toml, which forge reads
# itself: solc 0.8.30, optimizer on, 200 runs, evm_version shanghai.

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

command -v forge >/dev/null 2>&1 || fail "forge not found on PATH"
command -v cast  >/dev/null 2>&1 || fail "cast not found on PATH"
[ -f .env ] || fail "no .env in $here"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${CREDITCOIN_RPC_URL:=https://rpc.cc3-testnet.creditcoin.network}"
: "${ENCLAVE_REGISTRY_ADDRESS:=}"
: "${COMPUTE_CREDIT_ADDRESS:=}"
: "${SETTLEMENT_ADDRESS:=}"
: "${DECODER_ADDRESS:=}"
: "${REGISTRAR_ARG:=}"

# deployments.json is committed and is the same source the public page reads, so it is a better
# fallback than nothing when .env has drifted.
from_deployments() {
    [ -f site/deployments.json ] || return 0
    sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" site/deployments.json
}
[ -n "$SETTLEMENT_ADDRESS" ]       || SETTLEMENT_ADDRESS="$(from_deployments settlement)"
[ -n "$ENCLAVE_REGISTRY_ADDRESS" ] || ENCLAVE_REGISTRY_ADDRESS="$(from_deployments enclaveRegistry)"
[ -n "$COMPUTE_CREDIT_ADDRESS" ]   || COMPUTE_CREDIT_ADDRESS="$(from_deployments computeCredit)"

[ -n "$SETTLEMENT_ADDRESS" ]       || fail "no settlement address, in .env or site/deployments.json"
[ -n "$ENCLAVE_REGISTRY_ADDRESS" ] || fail "no enclave registry address, in .env or site/deployments.json"
[ -n "$COMPUTE_CREDIT_ADDRESS" ]   || fail "no compute credit address, in .env or site/deployments.json"
[ -n "$DECODER_ADDRESS" ]          || fail "DECODER_ADDRESS is empty in .env, and ComputeSettlement cannot be verified without the library it was linked against"

rpc() { cast call "$1" "$2" --rpc-url "$CREDITCOIN_RPC_URL"; }

say "Reading the constructor arguments back off the chain"

# ComputeSettlement stores all four in immutables, so these are exactly what it was built with.
CHAIN_KEY="$(rpc "$SETTLEMENT_ADDRESS" 'SOURCE_CHAIN_KEY()(uint64)')"
REGISTRY_ARG="$(rpc "$SETTLEMENT_ADDRESS" 'REGISTRY()(address)')"
CREDIT_ARG="$(rpc "$SETTLEMENT_ADDRESS" 'CREDIT()(address)')"
ESCROW_ARG="$(rpc "$SETTLEMENT_ADDRESS" 'SOURCE_ESCROW()(address)')"

# EnclaveRegistry's registrar is mutable, so the current value is only the constructor argument if
# it was never transferred. Say so rather than assuming it.
CURRENT_REGISTRAR="$(rpc "$ENCLAVE_REGISTRY_ADDRESS" 'registrar()(address)')"
REGISTRAR="${REGISTRAR_ARG:-$CURRENT_REGISTRAR}"

info "chain key          $CHAIN_KEY"
info "registry           $REGISTRY_ARG"
info "credit             $CREDIT_ARG"
info "source escrow      $ESCROW_ARG"
info "registrar          $REGISTRAR"
info "decoder library    $DECODER_ADDRESS"

# Lowercased with tr rather than ${var,,}: macOS ships bash 3.2, where that expansion is a syntax
# error, and this script has to run on the machine it is written for.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
if [ "$(lower "$REGISTRY_ARG")" != "$(lower "$ENCLAVE_REGISTRY_ADDRESS")" ]; then
    fail "the settlement contract points at registry $REGISTRY_ARG, not $ENCLAVE_REGISTRY_ADDRESS. One of them is stale, and verifying against the wrong one will not match."
fi

if [ -z "$REGISTRAR_ARG" ]; then
    warn "registrar read from the chain. If it was ever transferred with transferRegistrar, this is"
    warn "the current holder rather than the constructor argument, and EnclaveRegistry will not"
    warn "verify. In that case pass the original: REGISTRAR_ARG=0x... $0"
fi

CHAIN_ID=102031
VERIFIER_URL="${BLOCKSCOUT_API:-https://creditcoin-testnet.blockscout.com/api/}"
LIB_LINK="node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder:$DECODER_ADDRESS"

failures=0
verify() {
    local address="$1" target="$2"; shift 2
    say "$target"
    info "$address"
    if forge verify-contract "$address" "$target" \
        --chain-id "$CHAIN_ID" \
        --verifier blockscout \
        --verifier-url "$VERIFIER_URL" \
        --watch "$@"
    then
        info "published"
    else
        warn "did not verify. Not fatal: the other contracts are independent."
        failures=$((failures + 1))
    fi
}

verify "$ENCLAVE_REGISTRY_ADDRESS" src/EnclaveRegistry.sol:EnclaveRegistry \
    --constructor-args "$(cast abi-encode 'constructor(address)' "$REGISTRAR")"

verify "$COMPUTE_CREDIT_ADDRESS" src/ComputeCredit.sol:ComputeCredit

verify "$SETTLEMENT_ADDRESS" src/ComputeSettlement.sol:ComputeSettlement \
    --libraries "$LIB_LINK" \
    --constructor-args "$(cast abi-encode 'constructor(uint64,address,address,address)' \
        "$CHAIN_KEY" "$REGISTRY_ARG" "$CREDIT_ARG" "$ESCROW_ARG")"

say "Check them"
info "https://creditcoin-testnet.blockscout.com/address/$SETTLEMENT_ADDRESS?tab=contract"
info "https://creditcoin-testnet.blockscout.com/address/$ENCLAVE_REGISTRY_ADDRESS?tab=contract"
info "https://creditcoin-testnet.blockscout.com/address/$COMPUTE_CREDIT_ADDRESS?tab=contract"

if [ "$failures" -gt 0 ]; then
    cat <<'MSG'

Some did not verify. The usual causes, in order of likelihood:

  1. The verifier URL. Blockscout instances differ on the trailing form. Try:
       BLOCKSCOUT_API=https://creditcoin-testnet.blockscout.com/api? ./script/verify-contracts.sh

  2. The library link on ComputeSettlement. It must be the address the contract was linked against
     at deployment, which is DECODER_ADDRESS in .env.

  3. The registrar, if EnclaveRegistry was the one that failed. See the warning above.

Nothing here touches the chain. Verification only publishes source, so a failure costs nothing and
can be retried as often as you like.
MSG
    exit 1
fi

say "All three published. The explorer now decodes our own events by name."
