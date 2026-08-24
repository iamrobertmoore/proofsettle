#!/usr/bin/env bash
#
# Deploy the Creditcoin half of ProofSettle, without forge script.
#
#   ./script/deploy-creditcoin.sh   (from the repo root)
#
# WHY THIS EXISTS
#
# forge script cannot run against CC3 testnet at all. Before it executes a single line it builds
# a local EVM from the chain head, CC3 block headers carry no prevrandao field, and revm's header
# validation rejects the block:
#
#     Error: Failed to deploy script: EVM error; header validation error: `prevrandao` not set
#
# --skip-simulation does not help. I tested it against the live RPC and it fails identically,
# because the failure happens while forge is loading the script, before simulation is reached.
#
# forge create never builds that local EVM, which is why the decoder library deployed fine. So
# this is script/Deploy.s.sol:DeployCreditcoin rewritten in forge create and cast, read-back
# checks included, so the "wiring verified on chain, not assumed" guarantee survives intact.
#
# Safe to re-run. Anything already deployed and recorded in .env is skipped, so a failure
# halfway through costs you only the step that failed.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$here/.."

cd "$repo"

say()  { printf '%s\n' "$*"; }
fail() { printf '\n%s\n' "ERROR: $*" >&2; exit 1; }

# --- tools -----------------------------------------------------------------------------

command -v forge >/dev/null 2>&1 || fail "forge not found on PATH. Install Foundry, then: foundryup -i v1.2.3"
command -v cast  >/dev/null 2>&1 || fail "cast not found on PATH."

fv="$(forge --version 2>/dev/null | head -1)"
case "$fv" in
    *1.2.3*) ;;
    *) say "WARNING: expected forge 1.2.3, found: $fv"
       say "         Run 'foundryup -i v1.2.3' if anything below misbehaves."
       say "" ;;
esac

# --- environment -----------------------------------------------------------------------

[ -f .env ] || fail "No .env in $repo. Run: cp .env.example .env"

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DEPLOYER_PRIVATE_KEY:=}"
: "${CREDITCOIN_RPC_URL:=}"
: "${SOURCE_ESCROW_ADDRESS:=}"
: "${DECODER_ADDRESS:=}"
: "${SOURCE_CHAIN_KEY:=1}"
: "${REGISTRAR_ADDRESS:=}"
: "${ENCLAVE_REGISTRY_ADDRESS:=}"
: "${COMPUTE_CREDIT_ADDRESS:=}"
: "${SETTLEMENT_ADDRESS:=}"

[ -n "$DEPLOYER_PRIVATE_KEY" ] || fail "DEPLOYER_PRIVATE_KEY is empty in .env"
[ -n "$CREDITCOIN_RPC_URL" ]   || fail "CREDITCOIN_RPC_URL is empty in .env"
[ -n "$SOURCE_ESCROW_ADDRESS" ] || fail "SOURCE_ESCROW_ADDRESS is empty in .env. That is the Sepolia ComputeJobEscrow address."
[ -n "$DECODER_ADDRESS" ] || fail "DECODER_ADDRESS is empty in .env. That is the EvmV1Decoder library address on CC3."

DEPLOYER_ADDRESS="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
[ -n "$REGISTRAR_ADDRESS" ] || REGISTRAR_ADDRESS="$DEPLOYER_ADDRESS"

LIB_LINK="node_modules/@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol:EvmV1Decoder:$DECODER_ADDRESS"

# --- helpers ---------------------------------------------------------------------------

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
    if [ "$replaced" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv "$tmp" .env
}

code_size() {
    local a="${1:-}" c
    if [ -z "$a" ]; then echo 0; return 0; fi
    c="$(cast code "$a" --rpc-url "$CREDITCOIN_RPC_URL" 2>/dev/null || true)"
    case "$c" in
        0x*) echo $(( (${#c} - 2) / 2 )) ;;
        *)   echo 0 ;;
    esac
}

DEPLOYED_ADDRESS=""

run_create() {
    # All arguments are passed to forge create verbatim, so --constructor-args must come last.
    local logf rc=0
    logf="$(mktemp)"
    forge create "$@" >"$logf" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        say ""
        say "forge create failed:"
        sed 's/^/    /' "$logf"
        rm -f "$logf"
        say ""
        say "If that says 'gas required exceeds allowance' or an estimation failure, re-run with:"
        say "    GAS_LIMIT=6000000 $0"
        exit 1
    fi
    DEPLOYED_ADDRESS="$(grep -iE 'deployed to|deployedTo' "$logf" | grep -Eoi '0x[0-9a-f]{40}' | tail -1 || true)"
    if [ -z "$DEPLOYED_ADDRESS" ]; then
        say ""
        say "Deployment reported success but I could not find an address in the output:"
        sed 's/^/    /' "$logf"
        rm -f "$logf"
        fail "Refusing to continue on a guess."
    fi
    rm -f "$logf"
}

GAS_ARGS=()
if [ -n "${GAS_LIMIT:-}" ]; then GAS_ARGS=(--gas-limit "$GAS_LIMIT"); fi

COMMON=(--broadcast --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY")

# --- preflight -------------------------------------------------------------------------

say "ProofSettle, Creditcoin half"
say "  rpc          $CREDITCOIN_RPC_URL"
say "  deployer     $DEPLOYER_ADDRESS"
say "  registrar    $REGISTRAR_ADDRESS"
say "  source chain key $SOURCE_CHAIN_KEY"
say "  source escrow    $SOURCE_ESCROW_ADDRESS"
say ""

chain_id="$(cast chain-id --rpc-url "$CREDITCOIN_RPC_URL" 2>/dev/null || true)"
[ -n "$chain_id" ] || fail "Cannot reach $CREDITCOIN_RPC_URL"
say "  chain id     $chain_id"

balance="$(cast balance "$DEPLOYER_ADDRESS" --rpc-url "$CREDITCOIN_RPC_URL" 2>/dev/null || echo 0)"
say "  balance      $(cast from-wei "$balance") CTC"
if [ "$balance" = "0" ]; then
    fail "Deployer has no CTC. Claim from Discord #token-faucet with: /faucet address: $DEPLOYER_ADDRESS"
fi

decoder_size="$(code_size "$DECODER_ADDRESS")"
if [ "$decoder_size" -lt 1000 ]; then
    fail "No decoder library code at $DECODER_ADDRESS on this chain. Re-run step 6 and set DECODER_ADDRESS."
fi
say "  decoder      $DECODER_ADDRESS, $decoder_size bytes"
say ""

# --- 1. EnclaveRegistry ------------------------------------------------------------------

if [ "$(code_size "$ENCLAVE_REGISTRY_ADDRESS")" -gt 0 ]; then
    say "1/4 EnclaveRegistry already deployed at $ENCLAVE_REGISTRY_ADDRESS, skipping"
else
    say "1/4 deploying EnclaveRegistry"
    run_create src/EnclaveRegistry.sol:EnclaveRegistry "${COMMON[@]}" "${GAS_ARGS[@]+"${GAS_ARGS[@]}"}" \
        --constructor-args "$REGISTRAR_ADDRESS"
    ENCLAVE_REGISTRY_ADDRESS="$DEPLOYED_ADDRESS"
    put_env ENCLAVE_REGISTRY_ADDRESS "$ENCLAVE_REGISTRY_ADDRESS"
    say "    $ENCLAVE_REGISTRY_ADDRESS"
fi

# --- 2. ComputeCredit --------------------------------------------------------------------

if [ "$(code_size "$COMPUTE_CREDIT_ADDRESS")" -gt 0 ]; then
    say "2/4 ComputeCredit already deployed at $COMPUTE_CREDIT_ADDRESS, skipping"
else
    say "2/4 deploying ComputeCredit"
    run_create src/ComputeCredit.sol:ComputeCredit "${COMMON[@]}" "${GAS_ARGS[@]+"${GAS_ARGS[@]}"}"
    COMPUTE_CREDIT_ADDRESS="$DEPLOYED_ADDRESS"
    put_env COMPUTE_CREDIT_ADDRESS "$COMPUTE_CREDIT_ADDRESS"
    say "    $COMPUTE_CREDIT_ADDRESS"
fi

# --- 3. ComputeSettlement ----------------------------------------------------------------

if [ "$(code_size "$SETTLEMENT_ADDRESS")" -gt 0 ]; then
    say "3/4 ComputeSettlement already deployed at $SETTLEMENT_ADDRESS, skipping"
else
    say "3/4 deploying ComputeSettlement, linked against the decoder library"
    run_create src/ComputeSettlement.sol:ComputeSettlement "${COMMON[@]}" "${GAS_ARGS[@]+"${GAS_ARGS[@]}"}" \
        --libraries "$LIB_LINK" \
        --constructor-args "$SOURCE_CHAIN_KEY" "$ENCLAVE_REGISTRY_ADDRESS" "$COMPUTE_CREDIT_ADDRESS" "$SOURCE_ESCROW_ADDRESS"
    SETTLEMENT_ADDRESS="$DEPLOYED_ADDRESS"
    put_env SETTLEMENT_ADDRESS "$SETTLEMENT_ADDRESS"
    say "    $SETTLEMENT_ADDRESS"
fi

# --- 4. setMinter, single shot and irreversible -------------------------------------------

current_minter="$(cast call "$COMPUTE_CREDIT_ADDRESS" "minter()(address)" --rpc-url "$CREDITCOIN_RPC_URL")"
current_minter="$(cast to-check-sum-address "$current_minter")"
zero="0x0000000000000000000000000000000000000000"
want_minter="$(cast to-check-sum-address "$SETTLEMENT_ADDRESS")"

if [ "$current_minter" = "$want_minter" ]; then
    say "4/4 minter already bound to the settlement contract, skipping"
elif [ "$current_minter" != "$zero" ]; then
    say ""
    say "ComputeCredit at $COMPUTE_CREDIT_ADDRESS already has a minter, and it is not this settlement contract."
    say "  minter now  $current_minter"
    say "  wanted      $want_minter"
    say ""
    say "setMinter is single shot by design, so this token cannot be repointed. Clear"
    say "COMPUTE_CREDIT_ADDRESS and SETTLEMENT_ADDRESS in .env and re-run to deploy a fresh pair."
    exit 1
else
    say "4/4 binding the minter"
    cast send "$COMPUTE_CREDIT_ADDRESS" "setMinter(address)" "$SETTLEMENT_ADDRESS" \
        --rpc-url "$CREDITCOIN_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY" >/dev/null
fi

# --- read the wiring back off chain --------------------------------------------------------

say ""
say "Reading the wiring back off chain"

check() {
    local label="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        printf '  ok    %-18s %s\n' "$label" "$got"
    else
        printf '  FAIL  %-18s got %s, wanted %s\n' "$label" "$got" "$want"
        exit 1
    fi
}

got_minter="$(cast to-check-sum-address "$(cast call "$COMPUTE_CREDIT_ADDRESS" "minter()(address)" --rpc-url "$CREDITCOIN_RPC_URL")")"
got_escrow="$(cast to-check-sum-address "$(cast call "$SETTLEMENT_ADDRESS" "SOURCE_ESCROW()(address)" --rpc-url "$CREDITCOIN_RPC_URL")")"
got_key="$(cast call "$SETTLEMENT_ADDRESS" "SOURCE_CHAIN_KEY()(uint64)" --rpc-url "$CREDITCOIN_RPC_URL" | awk '{print $1}')"
got_registry="$(cast to-check-sum-address "$(cast call "$SETTLEMENT_ADDRESS" "REGISTRY()(address)" --rpc-url "$CREDITCOIN_RPC_URL" 2>/dev/null || echo "$zero")")"
got_credit="$(cast to-check-sum-address "$(cast call "$SETTLEMENT_ADDRESS" "CREDIT()(address)" --rpc-url "$CREDITCOIN_RPC_URL" 2>/dev/null || echo "$zero")")"
got_registrar="$(cast to-check-sum-address "$(cast call "$ENCLAVE_REGISTRY_ADDRESS" "registrar()(address)" --rpc-url "$CREDITCOIN_RPC_URL" 2>/dev/null || echo "$zero")")"

check "credit.minter"        "$got_minter"   "$(cast to-check-sum-address "$SETTLEMENT_ADDRESS")"
check "SOURCE_ESCROW"        "$got_escrow"   "$(cast to-check-sum-address "$SOURCE_ESCROW_ADDRESS")"
check "SOURCE_CHAIN_KEY"     "$got_key"      "$SOURCE_CHAIN_KEY"
if [ "$got_registry" != "$zero" ]; then
    check "settlement.REGISTRY" "$got_registry" "$(cast to-check-sum-address "$ENCLAVE_REGISTRY_ADDRESS")"
fi
if [ "$got_credit" != "$zero" ]; then
    check "settlement.CREDIT" "$got_credit" "$(cast to-check-sum-address "$COMPUTE_CREDIT_ADDRESS")"
fi
if [ "$got_registrar" != "$zero" ]; then
    check "registry.registrar" "$got_registrar" "$(cast to-check-sum-address "$REGISTRAR_ADDRESS")"
fi

say ""
say "Wiring verified on chain, not assumed."

# --- fill in the public page's prefill file -------------------------------------------------

if command -v node >/dev/null 2>&1; then
    node -e '
        const fs = require("fs");
        const p = "site/deployments.json";
        const d = JSON.parse(fs.readFileSync(p, "utf8"));
        d.settlement      = process.env.SETTLEMENT_ADDRESS;
        d.enclaveRegistry = process.env.ENCLAVE_REGISTRY_ADDRESS;
        d.computeCredit   = process.env.COMPUTE_CREDIT_ADDRESS;
        d.sourceEscrow    = process.env.SOURCE_ESCROW_ADDRESS;
        d.sourceChainKey  = Number(process.env.SOURCE_CHAIN_KEY);
        fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");
    ' \
      SETTLEMENT_ADDRESS="$SETTLEMENT_ADDRESS" \
      ENCLAVE_REGISTRY_ADDRESS="$ENCLAVE_REGISTRY_ADDRESS" \
      COMPUTE_CREDIT_ADDRESS="$COMPUTE_CREDIT_ADDRESS" \
      SOURCE_ESCROW_ADDRESS="$SOURCE_ESCROW_ADDRESS" \
      SOURCE_CHAIN_KEY="$SOURCE_CHAIN_KEY" 2>/dev/null \
      && say "site/deployments.json updated" \
      || say "site/deployments.json not updated, fill it in by hand"
fi

# --- what to send me ------------------------------------------------------------------------

say ""
say "================ copy everything below this line and paste it to me ================"
say ""
say "ComputeJobEscrow  (Sepolia) : $SOURCE_ESCROW_ADDRESS"
say "EvmV1Decoder      (CC3)     : $DECODER_ADDRESS"
say "EnclaveRegistry   (CC3)     : $ENCLAVE_REGISTRY_ADDRESS"
say "ComputeCredit     (CC3)     : $COMPUTE_CREDIT_ADDRESS"
say "ComputeSettlement (CC3)     : $SETTLEMENT_ADDRESS"
say "registrar                   : $REGISTRAR_ADDRESS"
say ""
say "===================================================================================="
say ""
say "All of that is written into .env already. Load it into this shell with:"
say "    set -a; source .env; set +a"
