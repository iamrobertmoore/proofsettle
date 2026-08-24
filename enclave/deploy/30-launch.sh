#!/usr/bin/env bash
#
# Launch the enclave on Google Confidential Space, open a path to it, and read back its identity.
#
#   PROJECT_ID=your-project IMAGE_REF=the-ref-20-build-printed ./enclave/deploy/30-launch.sh
#
# Three things here exist because of failures that are expensive to diagnose:
#
#   1. It loops zones and machine types. n2d capacity runs out, and the error for that
#      (ZONE_RESOURCE_POOL_EXHAUSTED) reads like a configuration problem when it is not.
#   2. It reads the LAUNCHER log, not the instance serial log. The serial log tells you nothing.
#   3. It tries the production image family first and only then the debug one, and it says which
#      it got. A debug image attests to less, and a demo that quietly used one while claiming
#      hardware attestation would be exactly the overclaim this project exists to argue against.
#
# The VM costs roughly 0.08 USD an hour and is billed until deleted. The teardown command is
# printed at the end. Run it.

set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${IMAGE_REF:?set IMAGE_REF to the value 20-build.sh printed}"

here="$(cd "$(dirname "$0")/../.." && pwd)"

REGION="${REGION:-europe-west2}"
VM="${VM:-proofsettle-enclave}"
TAG="${TAG:-proofsettle-enclave}"
SA="${SA:-proofsettle-enclave@${PROJECT_ID}.iam.gserviceaccount.com}"
PORT="${PORT:-8080}"

ZONES="${ZONES:-europe-west2-a europe-west2-b europe-west2-c europe-west4-a europe-west4-b us-central1-a us-central1-b}"
MACHINES="${MACHINES:-n2d-standard-2 n2d-standard-4}"
FAMILIES="${FAMILIES:-confidential-space confidential-space-debug}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

say "0. Preflight"
command -v gcloud >/dev/null || die "gcloud not found. Run ./enclave/deploy/10-setup.sh first."
gcloud config set project "$PROJECT_ID" --quiet >/dev/null || die "cannot select project $PROJECT_ID"
gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 \
    || die "service account $SA does not exist. Run ./enclave/deploy/10-setup.sh first."
echo "  project $PROJECT_ID"
echo "  image   $IMAGE_REF"

say "1. Firewall, open only to this machine"
# The enclave's answer is signed, so the channel does not have to be trusted: a man in the middle
# can drop the response but cannot alter the verdict without invalidating the signature the chain
# checks. Even so, there is no reason to publish the port to the whole internet.
MY_IP="$(curl -sf https://api.ipify.org || true)"
[ -n "$MY_IP" ] || die "could not determine this machine's public IP. Set MY_IP yourself and re-run."
echo "  this machine looks like $MY_IP"

if gcloud compute firewall-rules describe "${TAG}-in" >/dev/null 2>&1; then
    gcloud compute firewall-rules update "${TAG}-in" \
        --source-ranges "${MY_IP}/32" --allow "tcp:${PORT}" --quiet >/dev/null \
        || die "could not update the firewall rule"
    echo "  updated ${TAG}-in to allow tcp:${PORT} from ${MY_IP}/32"
else
    gcloud compute firewall-rules create "${TAG}-in" \
        --direction INGRESS --action ALLOW --rules "tcp:${PORT}" \
        --source-ranges "${MY_IP}/32" --target-tags "$TAG" --quiet >/dev/null \
        || die "could not create the firewall rule"
    echo "  created ${TAG}-in allowing tcp:${PORT} from ${MY_IP}/32"
fi

say "2. Launch, looping image family, zone and machine type"
launched_zone=""
launched_family=""
for family in $FAMILIES; do
  for zone in $ZONES; do
    for machine in $MACHINES; do
      echo "  trying $family / $machine / $zone"
      if gcloud compute instances create "$VM" \
          --confidential-compute-type=SEV_SNP \
          --shielded-secure-boot \
          --maintenance-policy=TERMINATE \
          --machine-type="$machine" \
          --zone="$zone" \
          --image-project=confidential-space-images \
          --image-family="$family" \
          --service-account="$SA" \
          --scopes=cloud-platform \
          --tags="$TAG" \
          --metadata="^~^tee-image-reference=${IMAGE_REF}~tee-container-log-redirect=true~tee-env-PORT=${PORT}" \
          --quiet >/dev/null 2>&1; then
        launched_zone="$zone"; launched_family="$family"
        echo "  launched"
        break 3
      fi
    done
  done
done
[ -n "$launched_zone" ] || die "nothing launched in any family, zone or machine type tried. Widen ZONES or MACHINES, or check quota."

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
echo "  $VM in $launched_zone on $launched_family, at $EXTERNAL_IP"

say "3. Wait for the workload, reading the LAUNCHER log"
# The launcher kills a workload whose env vars are not in allow_env_override, then logs
# "Workload completed", which reads exactly like success. Look for the signer line instead.
signer=""
for i in $(seq 1 40); do
  sleep 15
  logs="$(gcloud logging read \
    "resource.type=gce_instance AND logName:confidential-space-launcher AND labels.instance_name=$VM" \
    --limit 200 --format='value(textPayload)' 2>/dev/null || true)"
  signer="$(printf '%s\n' "$logs" | sed -n 's/^signer \(0x[0-9a-fA-F]\{40\}\).*/\1/p' | head -1)"
  if [ -n "$signer" ]; then break; fi
  if printf '%s' "$logs" | grep -q "Workload completed"; then
    printf '%s\n' "$logs" | tail -40
    die "the launcher reports the workload completed but no signer was ever printed. That usually means an env var is missing from allow_env_override, or the image is multi-platform."
  fi
  echo "  waiting ($((i * 15))s)"
done
[ -n "$signer" ] || die "no signer after 10 minutes. Read the launcher log above."
echo "  launcher log reports signer $signer"

say "4. Reach it from here, and check it agrees with its own log"
reached=""
for i in $(seq 1 20); do
  if curl -sf --max-time 5 "${ENCLAVE_URL}/health" >/dev/null 2>&1; then reached=1; break; fi
  sleep 5
done
[ -n "$reached" ] || die "the workload is running but ${ENCLAVE_URL}/health is unreachable. Check the firewall rule, and that your public IP has not changed since step 1."

http_signer="$(curl -sf "${ENCLAVE_URL}/identity" | sed -n 's/.*"signer":"\([^"]*\)".*/\1/p' || true)"
[ -n "$http_signer" ] || die "/identity did not return a signer"
[ "$(printf '%s' "$http_signer" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$signer" | tr 'A-Z' 'a-z')" ] \
    || die "the signer over HTTP ($http_signer) is not the one in the launcher log ($signer). Something is answering that is not the workload."

attested="$(curl -sf "${ENCLAVE_URL}/identity" | sed -n 's/.*"attested":\([a-z]*\).*/\1/p' || true)"
echo "  /identity signer  $http_signer"
echo "  /identity attested $attested"
[ "$attested" = "true" ] || die "the workload is running but reports attested:false, so it cannot read its own attestation token. Confidential Computing API off, or the image is not running under the launcher."

say "5. Record it"
env_file="$here/.env"
if [ -f "$env_file" ]; then
    tmp="$(mktemp)"
    replaced=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "${line%%=*}" = "ENCLAVE_URL" ] && [ "${line#\#}" = "$line" ]; then
            printf 'ENCLAVE_URL=%s\n' "$ENCLAVE_URL" >> "$tmp"; replaced=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$env_file"
    if [ "$replaced" -eq 0 ]; then printf 'ENCLAVE_URL=%s\n' "$ENCLAVE_URL" >> "$tmp"; fi
    mv "$tmp" "$env_file"
    echo "  ENCLAVE_URL written to .env"
else
    echo "  no .env found at $env_file, so set this yourself: ENCLAVE_URL=$ENCLAVE_URL"
fi

cat <<EOF

  ENCLAVE SIGNER : $signer
  ENCLAVE URL    : $ENCLAVE_URL
  VM             : $VM in $launched_zone, image family $launched_family

  Next:
    ./enclave/deploy/40-register.sh

  It fetches the attestation token, verifies it against Google's published keys, derives the
  measurement from the image digest inside it, and registers the binding on Creditcoin.

  When you are finished, stop paying for this:
    gcloud compute instances delete $VM --zone $launched_zone --quiet

EOF
