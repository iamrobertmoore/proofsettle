#!/usr/bin/env bash
#
# Everything a judge can check, in one command, with no key and no account.
#
#   npm run judge:verify
#
# It runs the contract tests and the mutation check that proves they can fail, the launch-decision
# test for the deployment scripts, the enclave and worker node tests, the three browser suites
# (verifier, attestation, desk), verifies the committed attestation token against Google's live
# keys, and then reads the live state back off Creditcoin CC3 testnet: the registry binding for
# the build the site names, the example settlement, and the Attestcoin oracle's attested height.
#
# Nothing here is mocked that can be real. The browser suites stand in for MetaMask and for the
# two chains because a test that needs a funded wallet and a nine-minute attestation wait is not a
# test anyone re-runs, but the enclave code, the envelope crypto on both sides and the calldata
# they exchange are the real thing.
#
# Skips, not failures: a stage whose tool is missing is reported as SKIP and named at the end, so
# a judge without Foundry still sees every other stage run. The exit code is non-zero only when a
# stage that ran has failed.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

RPC="${CREDITCOIN_RPC_URL:-https://rpc.cc3-testnet.creditcoin.network}"
PW="${PW_CHROMIUM:-}"
passed=(); failed=(); skipped=()

say()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
stage() {
    local name="$1"; shift
    say "$name"
    if "$@"; then passed+=("$name"); printf '\033[32m   PASS  %s\033[0m\n' "$name"
    else failed+=("$name"); printf '\033[31m   FAIL  %s\033[0m\n' "$name"; fi
}
skip()  { skipped+=("$1: $2"); printf '\n\033[33m   SKIP  %s (%s)\033[0m\n' "$1" "$2"; }

# ---------------------------------------------------------------- contracts
if command -v forge >/dev/null 2>&1; then
    stage "contract tests (forge test)" forge test
    stage "mutation check: the tests can fail" ./script/mutation-check.sh
else
    skip "contract tests" "forge not on PATH; install Foundry v1.2.3"
    skip "mutation check" "forge not on PATH"
fi

# ---------------------------------------------------------------- enclave and worker, node
stage "enclave: refusals, sealed round trip, determinism" node --test enclave/test/enclave.test.mjs
stage "worker: calldata riders still decode" node --test worker/test/calldata.test.mjs
stage "deploy scripts: the launch decision" ./enclave/deploy/test/run.sh

# ---------------------------------------------------------------- the browser suites
browser_ok=0
if [ -n "$PW" ] && [ -x "$PW" ]; then browser_ok=1
elif [ -x /opt/pw-browsers/chromium-1194/chrome-linux/chrome ]; then browser_ok=1
elif node -e "require('playwright')" >/dev/null 2>&1 && npx --no-install playwright --version >/dev/null 2>&1; then
    # Playwright is installed locally; let it find its own browser.
    export PW_CHROMIUM="$(node -e "console.log(require('playwright').chromium.executablePath())" 2>/dev/null || true)"
    [ -n "$PW_CHROMIUM" ] && [ -x "$PW_CHROMIUM" ] && browser_ok=1
fi
if [ "$browser_ok" = 1 ]; then
    stage "verifier page in a real browser" node site/test-page.mjs
    stage "attestation checks across four token scenarios" node site/test-attestation.mjs
    stage "desk: seal, pay, settle, open, refuse, in a real browser against the real enclave" node site/test-desk.mjs
else
    skip "browser suites" "no Chromium for Playwright; npx playwright install chromium, or set PW_CHROMIUM"
fi

# ---------------------------------------------------------------- the committed attestation
stage "attestation token verifies against Google's live keys" node enclave/verify-token.mjs enclave/attestation.jwt

# ---------------------------------------------------------------- live state on Creditcoin
readback() {
    RPC="$RPC" node --input-type=module -e '
      import { readFileSync } from "node:fs";
      import { ethers } from "ethers";
      const d = JSON.parse(readFileSync("site/deployments.json", "utf8"));
      const en = JSON.parse(readFileSync("site/enclave.json", "utf8"));
      const p = new ethers.JsonRpcProvider(process.env.RPC, undefined, { staticNetwork: true });
      const reg = new ethers.Contract(d.enclaveRegistry, ["function isActiveSigner(bytes32,address) view returns (bool)", "function measurementOf(address) view returns (bytes32)"], p);
      const set = new ethers.Contract(d.settlement, ["function settlements(bytes32) view returns (bytes32 queryId,address provider,address payer,uint256 amount,uint256 paidToProvider,uint256 returnedToPayer,bytes32 resultHash,address enclave,uint8 outcome,uint16 scoreBps,uint256 settledAt)"], p);
      const info = new ethers.Contract("0x0000000000000000000000000000000000000fd3", ["function get_latest_attestation_height_and_hash(uint64) view returns (uint64,bytes32,bool,bool)"], p);
      let ok = true; const row = (good, label, detail) => { ok = ok && good; console.log(`   ${good ? "ok  " : "FAIL"}  ${label}${detail ? "  " + detail : ""}`); };
      const chainId = Number((await p.getNetwork()).chainId);
      row(chainId === d.chainId, `connected to Creditcoin chain ${chainId}`, process.env.RPC);
      const active = await reg.isActiveSigner(en.measurement, en.signer);
      row(active, `registry binds ${en.build} (${en.measurement.slice(0, 12)}…) to signer ${en.signer.slice(0, 10)}…, and the binding is live`);
      const mo = await reg.measurementOf(en.signer);
      row(mo.toLowerCase() === en.measurement.toLowerCase(), "measurementOf(signer) reads back the same build");
      const s = await set.settlements(d.exampleJobId);
      row(s.settledAt > 0n, `example job ${d.exampleJobId.slice(0, 12)}… settled at ${new Date(Number(s.settledAt) * 1000).toISOString()}`, `outcome ${["Rejected", "Accepted", "Partial"][Number(s.outcome)]}, enclave ${s.enclave.slice(0, 10)}…`);
      const [h] = await info.get_latest_attestation_height_and_hash(d.sourceChainKey);
      row(h > 0n, `Attestcoin oracle: chain key ${d.sourceChainKey} attested to height ${h.toLocaleString("en-GB")}`, "read from the ChainInfo precompile at 0x…0fd3");
      if (en.previousMeasurement) {
        const prevActive = await reg.isActiveSigner(en.previousMeasurement, en.signer);
        row(!prevActive, `the previous build ${en.previousBuild ?? ""} is not what this signer is bound to`, "so a payment demanding it is refused by name");
      }
      process.exit(ok ? 0 : 1);
    '
}
stage "live readbacks from Creditcoin CC3 testnet" readback

stage "live v2 request, sealed delivery, original payout and refusal" node script/verify-live.mjs

# ---------------------------------------------------------------- summary
printf '\n\033[1m== summary\033[0m\n'
for s in "${passed[@]:-}";  do [ -n "$s" ] && printf '\033[32m   PASS  %s\033[0m\n' "$s"; done
for s in "${skipped[@]:-}"; do [ -n "$s" ] && printf '\033[33m   SKIP  %s\033[0m\n' "$s"; done
for s in "${failed[@]:-}";  do [ -n "$s" ] && printf '\033[31m   FAIL  %s\033[0m\n' "$s"; done
printf '\n'
if [ "${#failed[@]}" -gt 0 ]; then printf '\033[31m%s stage(s) failed\033[0m\n' "${#failed[@]}"; exit 1; fi
printf '\033[32mevery stage that ran passed'; [ "${#skipped[@]}" -gt 0 ] && printf ', %s skipped' "${#skipped[@]}"; printf '\033[0m\n'
