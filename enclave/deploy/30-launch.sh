#!/usr/bin/env bash
#
# Launch the enclave on Google Confidential Space, open a path to it, and read back its identity.
#
#   PROJECT_ID=your-project ./enclave/deploy/30-launch.sh
#
# You do not have to pass IMAGE_REF. It is derived from the same REGION, REPO, IMAGE and TAG that
# 20-build.sh used, then resolved to an immutable digest by asking Artifact Registry. An earlier
# version of this script asked you to paste the reference and would launch a VM against whatever
# string it was given, including a placeholder, and then wait ten minutes for a workload that could
# never start. That is fixed here: the image is checked to exist before anything is created.
#
# Other things here that exist because of failures that are expensive to diagnose:
#
#   1. It loops zones and machine types. n2d capacity runs out, and the error for that
#      (ZONE_RESOURCE_POOL_EXHAUSTED) reads like a configuration problem when it is not.
#   2. It waits on the enclave answering, not on a log line. An earlier version polled Cloud
#      Logging with a filter on an instance NAME label, which does not exist: Cloud Logging
#      identifies the instance by numeric id. The query returned nothing forever, which is
#      indistinguishable from a workload that never started. The log is now only ever used to
#      explain a failure, and it dumps the serial console too.
#   3. It proves the thing answering is the image it launched, by verifying the attestation token
#      and checking the image digest inside it. An IP address answering on port 8080 is not
#      evidence of anything; a Google-signed token naming our digest is.
#   4. It tries the production image family first and only then the debug one, and it says which
#      it got. A debug image attests to less, and a demo that quietly used one while claiming
#      hardware attestation would be exactly the overclaim this project argues against.
#
# Safe to re-run. If a working enclave is already there it says so and changes nothing. If a dead
# one is there it replaces it.
#
# The VM costs roughly 0.08 USD an hour and is billed until deleted. The teardown command is
# printed at the end. Run it.

set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"

here="$(cd "$(dirname "$0")/../.." && pwd)"

REGION="${REGION:-europe-west2}"
REPO="${REPO:-proofsettle}"
IMAGE="${IMAGE:-enclave}"
TAG_NAME="${TAG:-v1}"
VM="${VM:-proofsettle-enclave}"
NETTAG="${NETTAG:-proofsettle-enclave}"
SA="${SA:-proofsettle-enclave@${PROJECT_ID}.iam.gserviceaccount.com}"
PORT="${PORT:-8080}"

ZONES="${ZONES:-europe-west2-a europe-west2-b europe-west2-c europe-west4-a europe-west4-b us-central1-a us-central1-b}"

# Confidential compute type paired with a machine type that supports it.
#
# SEV, not SEV_SNP. Google Cloud Attestation, the service that issues the Confidential Space
# token, refuses SEV-SNP outright:
#
#   Error 400: attestation failed: AMD SEV-SNP is not currently supported by Google Cloud
#   Attestation, reason = UNSUPPORTED_CC_TECHNOLOGY
#
# The VM boots fine, the image pulls fine, the container is prepared fine, and then the launcher
# cannot get a token and shuts the whole thing down. The hardware model values the token
# documentation lists are GCP_AMD_SEV, GCP_AMD_SEV_ES, GCP_SHIELDED_VM and GCP_INTEL_TDX. There
# is no SNP in that list, and that list is not stale.
COMBOS="${COMBOS:-SEV:n2d-standard-2 SEV:n2d-standard-4 TDX:c3-standard-4}"
FAMILIES="${FAMILIES:-confidential-space confidential-space-debug}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

# ENV_FILE lets the launch-decision test point this at a scratch file. Without it the test wrote
# the fake enclave's 127.0.0.1 address into the real .env, and the next worker run on the
# developer's machine quietly targeted an enclave that was not there.
write_env() {
    local url="$1" env_file="${ENV_FILE:-$here/.env}" tmp replaced=0 line
    if [ ! -f "$env_file" ]; then
        echo "  no .env at $env_file, so set this yourself: ENCLAVE_URL=$url"
        return 0
    fi
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%=*}" = "ENCLAVE_URL" ] && [ "${line#\#}" = "$line" ]; then
            printf 'ENCLAVE_URL=%s\n' "$url" >> "$tmp"; replaced=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$env_file"
    if [ "$replaced" -eq 0 ]; then printf 'ENCLAVE_URL=%s\n' "$url" >> "$tmp"; fi
    mv "$tmp" "$env_file"
    echo "  ENCLAVE_URL written to .env"
}

# Cloud Logging identifies the instance by numeric id, not by name. Filtering on a name label
# silently returns nothing, which is indistinguishable from "the workload never started". That
# cost an afternoon, so the id is looked up rather than assumed, and the log is only ever used to
# explain a failure. The signal that the enclave is up is the enclave answering.
INSTANCE_ID=""

# Everything this VM says, from both places it can say it.
#
#   confidential-space-launcher  the container's own stdout, when tee-container-log-redirect is on
#   serialconsole                the launcher's own messages, which is where the useful errors are
#
# The instance is launched with serial-port-logging-enable=true so the serial console is streamed
# into Cloud Logging as it happens. That matters more than it sounds: the launcher shuts the VM
# down when the workload fails, a terminated instance serves no serial output at all, and the only
# copy of the reason it died goes with it. Streaming it means the evidence survives the machine.
instance_logs() {
    # Newest first. `--order=asc` with a limit returns the OLDEST N entries, which on a Confidential
    # Space boot is several hundred lines of UEFI firmware chatter and none of the launcher output
    # that matters. Read newest-first, then put it back in order for display.
    [ -n "$INSTANCE_ID" ] || return 0
    gcloud logging read \
        "resource.type=gce_instance AND resource.labels.instance_id=\"$INSTANCE_ID\"" \
        --limit 400 --freshness=2h --order=desc \
        --format='value(textPayload)' 2>&1 || true
}

# Oldest last, so a terminal shows the end of the story at the bottom.
chronological() { awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) print a[i] }'; }

say "0. Preflight"
command -v gcloud >/dev/null || die "gcloud not found. Run ./enclave/deploy/10-setup.sh first."
command -v curl   >/dev/null || die "curl not found"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null 2>&1 || die "cannot select project $PROJECT_ID"
gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 \
    || die "service account $SA does not exist. Run ./enclave/deploy/10-setup.sh first."
echo "  project $PROJECT_ID"

say "1. Find the image, and pin it by digest"
TAGGED="${IMAGE_REF:-${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG_NAME}}"

case "$TAGGED" in
    *-docker.pkg.dev/*/*/*|gcr.io/*/*) ;;
    *) die "IMAGE_REF does not look like an Artifact Registry reference: '$TAGGED'. Leave IMAGE_REF unset and let this script work it out, or paste the full 'image :' line that 20-build.sh printed." ;;
esac

DIGEST="$(gcloud artifacts docker images describe "$TAGGED" \
    --format='value(image_summary.digest)' 2>/dev/null || true)"
[ -n "$DIGEST" ] \
    || die "no image at $TAGGED. Run ./enclave/deploy/20-build.sh first, or set REGION, REPO, IMAGE and TAG to match what it pushed."

case "$TAGGED" in
    *@sha256:*) PINNED="$TAGGED" ;;   # already pinned, leave it alone
    *)          PINNED="${TAGGED%:*}@${DIGEST}" ;;
esac
echo "  tagged  $TAGGED"
echo "  digest  $DIGEST"
echo "  pinned  $PINNED"

# You can push the image, so the repository looks fine from here. The workload runs as the service
# account, which is a different principal, and if it cannot read the repository the launcher gets
# 403 Forbidden fetching a pull token and shuts the VM down. Check before creating anything.
repo_policy="$(gcloud artifacts repositories get-iam-policy "$REPO" --location "$REGION" --format=json 2>/dev/null || echo '{}')"
proj_roles="$(gcloud projects get-iam-policy "$PROJECT_ID" --flatten='bindings[].members' \
    --filter="bindings.members:serviceAccount:$SA" --format='value(bindings.role)' 2>/dev/null || true)"
# Written as `if` blocks rather than `cmd && flag=1`, because under `set -e` a failing grep in a
# bare && chain exits the script instead of setting the flag.
can_read=""
if printf '%s' "$repo_policy" | grep -q "artifactregistry.reader" \
   && printf '%s' "$repo_policy" | grep -q "$SA"; then
    can_read=1
fi
if printf '%s\n' "$proj_roles" | grep -qE "artifactregistry|roles/owner|roles/editor"; then
    can_read=1
fi

# Better than reading the policy: become the service account and try. This is the exact operation
# the launcher performs, so it either works or fails for the same reason, in two seconds rather
# than after a VM launch and a ten minute wait. Needs permission to impersonate; if that is not
# granted, fall back to the policy read above rather than blocking on it.
imp_out="$(gcloud artifacts docker images describe "$TAGGED" \
    --impersonate-service-account="$SA" --format='value(image_summary.digest)' 2>&1 || true)"
case "$imp_out" in
    sha256:*)
        # Authoritative pass.
        can_read=1
        echo "  verified by impersonation: $SA can pull this image" ;;
    *impersonat*|*serviceAccounts*|*getAccessToken*)
        # We are not allowed to become it, so this test could not run. Not a finding either way.
        echo "  (cannot impersonate the service account, so going on the IAM policy alone)" ;;
    *PERMISSION_DENIED*|*Permission*denied*|*403*|*denied*)
        # Authoritative fail, and it outranks the policy read: this is the operation that matters.
        can_read=""
        printf '  impersonated read was refused: %s\n' "$(printf '%s' "$imp_out" | tr '\n' ' ' | cut -c1-200)" ;;
    *)
        : ;;   # some other error, or empty. Do not block on what we cannot interpret.
esac

if [ -z "$can_read" ]; then
    die "the workload service account cannot read the image repository, so the launcher would get 403 Forbidden and shut the VM down. Fix it with either of these, then re-run:

      ./enclave/deploy/10-setup.sh

    or just the one grant:

      gcloud artifacts repositories add-iam-policy-binding $REPO \\
          --location $REGION \\
          --member serviceAccount:$SA \\
          --role roles/artifactregistry.reader

    Artifact Registry IAM can take several minutes to take effect, not the one minute I said
    earlier. If you granted it moments ago, wait five and run this again."
fi
echo "  $SA can read $REPO"
echo ""
echo "  Launching by digest rather than by tag, so the workload cannot be swapped underneath the"
echo "  attestation by repointing the tag."

say "2. Is one already running?"

# Three outcomes: nothing there, something there running this exact image, or something there
# running a different one. The third case is the one that matters. Answering on port 8080 is not
# the same as answering with the build we are about to attest, and without this check a corrected
# image can be rebuilt, pushed, and then never actually launched, while every script reports
# success. Ask the running workload's own attestation token which image it is.
EXISTING_ZONE="$(gcloud compute instances list --filter="name=$VM" --format='value(zone)' 2>/dev/null | head -1 || true)"
reuse=""
if [ -n "$EXISTING_ZONE" ]; then
    EXISTING_IP="$(gcloud compute instances describe "$VM" --zone "$EXISTING_ZONE" \
        --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"
    echo "  $VM already exists in $EXISTING_ZONE at ${EXISTING_IP:-no external IP}"

    existing_identity=""
    if [ -n "$EXISTING_IP" ] && curl -sf --max-time 5 "http://${EXISTING_IP}:${PORT}/health" >/dev/null 2>&1; then
        existing_identity="$(curl -sf --max-time 5 "http://${EXISTING_IP}:${PORT}/identity" || true)"
    fi

    if [ -z "$existing_identity" ]; then
        echo "  it is not answering, so it is no use to anyone. Replacing it."
    else
        existing_digest=""
        if command -v node >/dev/null 2>&1; then
            etok="$(mktemp)"
            printf '%s' "$existing_identity" \
                | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{try{process.stdout.write(JSON.parse(b).attestationToken??"")}catch{}})' > "$etok"
            if [ -s "$etok" ]; then
                existing_digest="$(node "$here/enclave/verify-token.mjs" "$etok" 2>/dev/null \
                    | sed -n 's/^  ENCLAVE_MEASUREMENT=0x/sha256:/p' | head -1 || true)"
            fi
            rm -f "$etok"
        fi

        if [ -z "$existing_digest" ]; then
            # Could not read a verified image digest out of what is answering. Reusing an enclave
            # whose identity cannot be established is the exact failure this project exists to
            # argue against, so the benefit of the doubt goes the other way: replace it.
            echo "  cannot establish which image it is running, so it is being replaced rather"
            echo "  than trusted. That is deliberate."
        elif [ "$existing_digest" != "$DIGEST" ]; then
            echo "  it is running a different image:"
            echo "    running  $existing_digest"
            echo "    wanted   $DIGEST"
            echo "  replacing it, so the build that gets attested is the one you just pushed."
        else
            echo "  its attestation token names the image we were about to launch"
            reuse=1
        fi
    fi

    if [ -n "$reuse" ]; then
        existing_signer="$(printf '%s' "$existing_identity" | sed -n 's/.*"signer":"\([^"]*\)".*/\1/p')"
        say "Already running this exact image, nothing to do"
        echo "  ENCLAVE SIGNER : $existing_signer"
        echo "  ENCLAVE URL    : http://${EXISTING_IP}:${PORT}"
        write_env "http://${EXISTING_IP}:${PORT}"
        echo ""
        echo "  If you meant to replace it anyway, delete it first:"
        echo "    gcloud compute instances delete $VM --zone $EXISTING_ZONE --quiet"
        exit 0
    fi

    gcloud compute instances delete "$VM" --zone "$EXISTING_ZONE" --quiet >/dev/null 2>&1 \
        || die "could not delete the old instance. Delete it by hand and re-run: gcloud compute instances delete $VM --zone $EXISTING_ZONE --quiet"
    echo "  deleted"
else
    echo "  no existing instance"
fi

say "3. Firewall, open only to this machine"
# The enclave's answer is signed, so the channel does not have to be trusted: a man in the middle
# can drop the response but cannot alter the verdict without invalidating the signature the chain
# checks. Even so, there is no reason to publish the port to the whole internet.
MY_IP="${MY_IP:-$(curl -sf https://api.ipify.org || true)}"
[ -n "$MY_IP" ] || die "could not determine this machine's public IP. Set MY_IP yourself and re-run."
echo "  this machine looks like $MY_IP"

if gcloud compute firewall-rules describe "${NETTAG}-in" >/dev/null 2>&1; then
    gcloud compute firewall-rules update "${NETTAG}-in" \
        --source-ranges "${MY_IP}/32" --allow "tcp:${PORT}" --quiet >/dev/null \
        || die "could not update the firewall rule"
    echo "  updated ${NETTAG}-in to allow tcp:${PORT} from ${MY_IP}/32"
else
    gcloud compute firewall-rules create "${NETTAG}-in" \
        --direction INGRESS --action ALLOW --rules "tcp:${PORT}" \
        --source-ranges "${MY_IP}/32" --target-tags "$NETTAG" --quiet >/dev/null \
        || die "could not create the firewall rule"
    echo "  created ${NETTAG}-in allowing tcp:${PORT} from ${MY_IP}/32"
fi

# tee-restart-policy defaults to Never. With Never, a workload that dies on startup takes the whole
# VM down with it: status goes TERMINATED, the serial console is gone, and Cloud Logging never
# received anything, so there is nothing at all left to read. Always keeps the instance up and
# crash-looping, which costs pence and leaves the evidence in place.
say "4. Launch, looping image family, zone and machine type"
launched_zone=""
launched_family=""
launched_cc=""
launched_machine=""
for family in $FAMILIES; do
  for combo in $COMBOS; do
    cc_type="${combo%%:*}"; machine="${combo#*:}"
    for zone in $ZONES; do
      echo "  trying $family / $cc_type / $machine / $zone"
      if gcloud compute instances create "$VM" \
          --confidential-compute-type="$cc_type" \
          --shielded-secure-boot \
          --maintenance-policy=TERMINATE \
          --machine-type="$machine" \
          --zone="$zone" \
          --image-project=confidential-space-images \
          --image-family="$family" \
          --service-account="$SA" \
          --scopes=cloud-platform \
          --tags="$NETTAG" \
          --metadata="^~^tee-image-reference=${PINNED}~tee-container-log-redirect=true~tee-env-PORT=${PORT}~tee-restart-policy=Always~serial-port-logging-enable=true" \
          --quiet >/dev/null 2>&1; then
        launched_zone="$zone"; launched_family="$family"; launched_cc="$cc_type"; launched_machine="$machine"
        echo "  launched"
        break 3
      fi
    done
  done
done
[ -n "$launched_zone" ] || die "nothing launched in any family, confidential compute type, machine type or zone tried. Widen ZONES or COMBOS, or check quota."

if [ "$launched_family" != "confidential-space" ]; then
    echo ""
    echo "  NOTE: this is the DEBUG image family. It attests to less than the production one, and"
    echo "  40-register.sh will say so from the token's own dbgstat claim. Do not describe this as"
    echo "  a production attestation."
fi

EXTERNAL_IP="$(gcloud compute instances describe "$VM" --zone "$launched_zone" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"
[ -n "$EXTERNAL_IP" ] || die "the instance has no external IP, so nothing can reach it"
ENCLAVE_URL="http://${EXTERNAL_IP}:${PORT}"
echo "  $VM in $launched_zone on $launched_family, $launched_cc on $launched_machine, at $EXTERNAL_IP"

INSTANCE_ID="$(gcloud compute instances describe "$VM" --zone "$launched_zone" \
    --format='value(id)' 2>/dev/null || true)"
echo "  instance id $INSTANCE_ID"

say "5. Wait for the enclave to answer"
# Poll the enclave itself. A log line is a convenience that depends on redirection, a role binding
# and the right query; the endpoint answering is the thing that actually has to be true.
#
# Also watch the instance status. When the workload or the launcher fails, the launcher shuts the
# VM down, so a dead deployment shows up as TERMINATED within about a minute. Noticing that turns
# a ten minute wait into a forty second one, and the streamed serial console explains why.
dump_evidence() {
    local lg
    lg="$(instance_logs)"
    if [ -z "$lg" ]; then
        echo ""
        echo "  Nothing in Cloud Logging yet. Serial streaming lags a few seconds, so try:"
        echo "    gcloud logging read 'resource.type=gce_instance AND resource.labels.instance_id=\"$INSTANCE_ID\"' --freshness=2h --order=desc --limit 60 --format='value(textPayload)'"
        return 0
    fi

    echo ""
    echo "  --- the launcher's own messages, oldest first ---"
    if printf '%s\n' "$lg" | grep -qE 'level=(INFO|WARN|ERROR)'; then
        printf '%s\n' "$lg" | grep -E 'level=(INFO|WARN|ERROR)' | chronological | tail -25
    else
        echo "  (none yet: the launcher had not started, or its output has not reached Logging)"
    fi

    echo ""
    echo "  --- last 30 lines of everything the instance said ---"
    printf '%s\n' "$lg" | chronological | tail -30
    echo "  --- end ---"
}

reached=""
for i in $(seq 1 60); do
  if curl -sf --max-time 5 "${ENCLAVE_URL}/health" >/dev/null 2>&1; then reached=1; break; fi

  if [ $((i % 4)) -eq 0 ]; then
    status="$(gcloud compute instances describe "$VM" --zone "$launched_zone" --format='value(status)' 2>/dev/null || echo UNKNOWN)"
    if [ "$status" != "RUNNING" ]; then
        echo "  instance status is $status"
        dump_evidence
        die "the launcher shut the VM down, which is what it does when the workload or the launcher fails. The reason is in the output above. Nothing is left running, so nothing is still being billed."
    fi

    logs="$(instance_logs)"
    if printf '%s' "$logs" | grep -qiE "failed to pull|error pulling|manifest unknown|unauthorized|denied: |403 Forbidden"; then
      printf '%s\n' "$logs" | chronological | tail -30
      die "the launcher could not pull $PINNED. If the message above says 403 Forbidden, the workload service account still cannot read the repository. Artifact Registry IAM can take several minutes to take effect, so if you granted it just now, wait five minutes and run this again."
    fi
    if printf '%s' "$logs" | grep -qiE "exec format error|cannot execute binary"; then
      printf '%s\n' "$logs" | chronological | tail -30
      die "the workload cannot execute, which is an architecture mismatch. Re-run ./enclave/deploy/20-build.sh."
    fi
    if printf '%s' "$logs" | grep -q "UNSUPPORTED_CC_TECHNOLOGY"; then
      printf '%s\n' "$logs" | chronological | tail -20
      die "Google Cloud Attestation refused this confidential compute type, so the launcher could never get a token. Change COMBOS at the top of this script: SEV works, SEV_SNP does not."
    fi
    if printf '%s' "$logs" | grep -q "Workload completed"; then
      printf '%s\n' "$logs" | chronological | tail -40
      die "the launcher reports the workload completed but nothing is listening. The reason is above."
    fi

    echo "  waiting ($((i * 10))s, instance $status)"
  fi
  sleep 10
done

if [ -z "$reached" ]; then
    dump_evidence
    die "${ENCLAVE_URL}/health never answered, and the instance stayed RUNNING throughout, so the workload is up but unreachable. Check that the Dockerfile still carries EXPOSE ${PORT}: Confidential Space blocks every inbound port that the image does not name. The instance is still up; delete it with 'gcloud compute instances delete $VM --zone $launched_zone --quiet'."
fi
echo "  answering at $ENCLAVE_URL"

say "6. Check it is the image we launched, not something else on that address"
identity="$(curl -sf --max-time 10 "${ENCLAVE_URL}/identity" || true)"
[ -n "$identity" ] || die "/identity returned nothing"

signer="$(printf '%s' "$identity" | sed -n 's/.*"signer":"\([^"]*\)".*/\1/p')"
attested="$(printf '%s' "$identity" | sed -n 's/.*"attested":\([a-z]*\).*/\1/p')"
[ -n "$signer" ] || die "/identity returned no signer"
echo "  signer   $signer"
echo "  attested $attested"

[ "$attested" = "true" ] \
    || die "it reports attested:false, so it cannot read its own attestation token. Confidential Computing API off, or it is not running under the launcher."

# The strong check. Anything can claim to be an enclave on an IP address; only the real one can
# produce a Google-signed token naming the image digest we just launched.
if command -v node >/dev/null 2>&1; then
    tok="$(mktemp)"
    printf '%s' "$identity" | node -e 'let b="";process.stdin.on("data",c=>b+=c).on("end",()=>{try{process.stdout.write(JSON.parse(b).attestationToken??"")}catch{}})' > "$tok"
    if [ -s "$tok" ]; then
        token_measurement="$(node "$here/enclave/verify-token.mjs" "$tok" | sed -n 's/^  ENCLAVE_MEASUREMENT=//p' || true)"
        rm -f "$tok"
        [ -n "$token_measurement" ] || die "the attestation token did not verify. Run 'node enclave/verify-token.mjs' against it to see which check failed."
        expected="0x${DIGEST#sha256:}"
        if [ "$token_measurement" = "$expected" ]; then
            echo "  token names the image we launched: $token_measurement"
        else
            die "the attestation token names image $token_measurement but we launched $expected. Something other than our workload is answering on that address."
        fi
    else
        rm -f "$tok"
        echo "  no token in /identity despite attested:true, which should not happen"
    fi
else
    echo "  node not found, so the token was not checked here. 40-register.sh will check it."
fi

say "7. Record it"
write_env "$ENCLAVE_URL"

cat <<EOF

  ENCLAVE SIGNER : $signer
  ENCLAVE URL    : $ENCLAVE_URL
  IMAGE          : $PINNED
  VM             : $VM in $launched_zone, $launched_family, $launched_cc on $launched_machine, id $INSTANCE_ID

  Next:
    ./enclave/deploy/40-register.sh

  It fetches the attestation token, verifies it against Google's published keys, derives the
  measurement from the image digest inside it, and registers the binding on Creditcoin.

  When you are finished, stop paying for this:
    gcloud compute instances delete $VM --zone $launched_zone --quiet

EOF
