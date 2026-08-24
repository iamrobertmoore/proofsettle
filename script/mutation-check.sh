#!/usr/bin/env bash
#
# Prove the test suite can fail.
#
# A green suite is not evidence on its own. This script breaks one guarantee at a time, runs the
# tests, and checks that the test written to defend that guarantee is the one that goes red. If a
# mutation is applied and everything still passes, the test defending it was decorative.
#
# Run from the repo root:  ./script/mutation-check.sh
#
# Exits non-zero if any mutation survives.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FORGE="${FORGE:-forge}"
BACKUP="$(mktemp -d)"
cp -r src "$BACKUP/src"

restore() { rm -rf src && cp -r "$BACKUP/src" src; }
trap 'restore; rm -rf "$BACKUP"' EXIT

pass=0
fail=0

# mutate <name> <file> <search> <replace> <test that must go red>
mutate() {
    local name="$1" file="$2" search="$3" replace="$4" expected="$5"

    restore
    if ! python3 - "$file" "$search" "$replace" <<'PY'
import sys
path, search, replace = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding='utf-8').read()
if search not in s:
    sys.exit(2)
open(path, 'w', encoding='utf-8').write(s.replace(search, replace, 1))
PY
    then
        echo "  SKIP  $name  (mutation target not found, the code moved)"
        fail=$((fail + 1))
        return
    fi

    local out
    out="$($FORGE test --match-test "$expected" 2>&1)"

    if echo "$out" | grep -q "\[FAIL"; then
        echo "  ok    $name"
        echo "          broke: $expected"
        pass=$((pass + 1))
    else
        echo "  SURVIVED  $name"
        echo "          $expected still passed with the guarantee removed."
        echo "          That test is not defending anything."
        fail=$((fail + 1))
    fi
}

echo "Mutation check: breaking one guarantee at a time."
echo

mutate "drop the source escrow emitter check" \
    "src/ComputeSettlement.sol" \
    'if (log.address_ != SOURCE_ESCROW) revert WrongEmitter(SOURCE_ESCROW, log.address_);' \
    '// mutated: emitter check removed' \
    "test_reverts_when_the_event_came_from_an_impostor_escrow"

mutate "drop the enclave registry check" \
    "src/ComputeSettlement.sol" \
    'if (!REGISTRY.isActiveSigner(job.requiredMeasurement, enclave)) {
            revert EnclaveNotAccepted(job.requiredMeasurement, enclave);
        }' \
    '// mutated: registry check removed' \
    "test_reverts_when_an_unregistered_key_signed_the_result"

mutate "accept a revoked enclave" \
    "src/EnclaveRegistry.sol" \
    'return e.signingKey != address(0) && e.signingKey == signer && e.revokedAt == 0;' \
    'return e.signingKey != address(0) && e.signingKey == signer;' \
    "test_reverts_after_the_enclave_is_revoked"

mutate "drop the replay guard" \
    "src/AttestcoinProven.sol" \
    'if (consumedQueries[queryId]) revert QueryAlreadyConsumed(queryId);' \
    '// mutated: replay guard removed' \
    "test_reverts_when_the_same_proof_is_replayed"

mutate "ignore the oracle returning false" \
    "src/AttestcoinProven.sol" \
    'if (!VERIFIER.verifyAndEmit(chainKey, height, encodedTransaction, merkleProof, continuityProof)) {
            revert ProofRejected();
        }' \
    'VERIFIER.verifyAndEmit(chainKey, height, encodedTransaction, merkleProof, continuityProof);' \
    "test_reverts_when_the_oracle_returns_false_without_reverting"

mutate "settle on a reverted source transaction" \
    "src/ComputeSettlement.sol" \
    'if (receipt.receiptStatus != 1) revert TransactionFailedOnSource(receipt.receiptStatus);' \
    '// mutated: receipt status check removed' \
    "test_reverts_when_the_source_transaction_reverted"

mutate "accept malleable signatures" \
    "src/ComputeSettlement.sol" \
    'if (uint256(att.s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert BadSignatureS();
        }' \
    '// mutated: malleability check removed' \
    "test_reverts_on_a_malleable_signature"

mutate "accept a proof from any source chain" \
    "src/AttestcoinProven.sol" \
    'if (chainKey != SOURCE_CHAIN_KEY) revert WrongSourceChain(SOURCE_CHAIN_KEY, chainKey);' \
    '// mutated: source chain pin removed' \
    "test_reverts_on_a_proof_from_the_wrong_source_chain"

mutate "let a rejected job pay the provider anyway" \
    "src/ComputeSettlement.sol" \
    'if (outcome == Outcome.Rejected) return (0, amount);' \
    'if (outcome == Outcome.Rejected) return (amount, 0);' \
    "test_rejected_job_returns_the_claim_to_the_payer"

mutate "drop the verdict from the signed digest" \
    "src/ComputeSettlement.sol" \
    'SIGNING_DOMAIN, block.chainid, address(this), jobId, resultHash_, uint8(outcome), scoreBps' \
    'SIGNING_DOMAIN, block.chainid, address(this), jobId, resultHash_' \
    "test_provider_cannot_upgrade_the_enclave_verdict"

mutate "let the partial split create value" \
    "src/ComputeSettlement.sol" \
    'toPayer = amount - toProvider;' \
    'toPayer = amount;' \
    "test_split_is_publicly_checkable_and_conserves_value"

restore

echo
echo "killed $pass, survived or skipped $fail"
if [ "$fail" -ne 0 ]; then
    echo "FAIL: at least one guarantee is not defended by a test."
    exit 1
fi

echo "Every mutation was caught. Re-running the full suite on the restored source."
$FORGE test
