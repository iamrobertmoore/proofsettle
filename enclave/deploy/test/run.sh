#!/usr/bin/env bash
#
# Tests the decision 30-launch.sh makes about an instance that already exists.
#
#   ./enclave/deploy/test/run.sh
#
# Deployment scripts usually go untested because testing them appears to mean creating real
# infrastructure. It does not. What matters here is a decision, and a decision can be exercised
# against a scripted stand-in for gcloud and a fake enclave that serves a real, verifiable
# attestation token signed by a local key.
#
# This exists because the untested version of that decision shipped twice with the wrong answer:
# once treating any answering instance as current, which silently kept a stale build alive through
# a rebuild, and once with an unbound variable that killed the script before the check ran.

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$here/../../.."
cd "$repo"

state=/tmp/proofsettle-launch-test
A="sha256:$(printf 'a%.0s' $(seq 64))"
B="sha256:$(printf 'b%.0s' $(seq 64))"
pass=0; fail=0

check() {
    local what="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then printf '  ok    %s\n' "$what"; pass=$((pass + 1))
    else printf '  FAIL  %s: got %s, wanted %s\n' "$what" "$got" "$want"; fail=$((fail + 1)); fi
}

scenario() {
    local name="$1" zone="$2" ip="$3" attests="$4" wants="$5" want_deletes="$6" want_creates="$7"
    rm -rf "$state"; mkdir -p "$state/bin"
    cp "$here/fake-gcloud" "$state/bin/gcloud"; chmod +x "$state/bin/gcloud"
    printf '%s' "$wants" > "$state/digest"
    printf '%s' "$zone"  > "$state/existing_zone"
    printf '%s' "$ip"    > "$state/existing_ip"
    : > "$state/deletes"; : > "$state/creates"

    local hpid=""
    if [ -n "$attests" ]; then
        node "$here/fake-enclave.mjs" "$attests" >/dev/null 2>&1 &
        hpid=$!
        sleep 1.2
    fi

    printf '\n%s\n' "$name"
    PATH="$stub:$PATH" PROJECT_ID=p MY_IP=203.0.113.7 \
        CS_DISCOVERY_URL=http://127.0.0.1:8791/.well-known/openid-configuration \
        CS_EXPECTED_ISS=http://127.0.0.1:8791 \
        ZONES=z1 COMBOS=SEV:m1 FAMILIES=confidential-space \
        ./enclave/deploy/30-launch.sh >/dev/null 2>&1 || true

    check "instances deleted" "$(wc -l < "$state/deletes" | tr -d ' ')" "$want_deletes"
    check "launch attempted"  "$(wc -l < "$state/creates" | tr -d ' ')" "$want_creates"
    if [ -n "$hpid" ]; then kill "$hpid" 2>/dev/null || true; fi
    sleep 0.4
}

stub="$state/bin"
mkdir -p "$stub"
cp "$here/fake-gcloud" "$stub/gcloud"
chmod +x "$stub/gcloud"
trap 'rm -rf "$state"' EXIT

#         name                                zone  ip             attests  wants  del  create
scenario "nothing is running"                 ""    ""             ""       "$A"   0    1
scenario "running this exact image"           "z1"  "127.0.0.1"    "$A"     "$A"   0    0
scenario "running a different image"          "z1"  "127.0.0.1"    "$B"     "$A"   1    1
scenario "exists but does not answer"         "z1"  "10.255.255.1" ""       "$A"   1    1

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
