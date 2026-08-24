#!/usr/bin/env bash
#
# Launch the enclave on Google Confidential Space and read back its attested identity.
#
# Loops zones and machine types, because n2d capacity runs out and the error for that
# (ZONE_RESOURCE_POOL_EXHAUSTED) looks like a configuration problem when it is not.
#
# Reads the LAUNCHER log, not the instance serial log. The serial log tells you nothing useful.

set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${IMAGE_REF:?set IMAGE_REF to the value 20-build.sh printed}"
REGION="${REGION:-europe-west2}"
VM="${VM:-proofsettle-enclave}"
SA="${SA:-proofsettle-enclave@${PROJECT_ID}.iam.gserviceaccount.com}"

ZONES="${ZONES:-europe-west2-a europe-west2-b europe-west2-c europe-west4-a europe-west4-b us-central1-a us-central1-b}"
MACHINES="${MACHINES:-n2d-standard-2 n2d-standard-4}"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

say "0. Preflight"
command -v gcloud >/dev/null || die "gcloud not found"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null || die "cannot select project"

gcloud iam service-accounts describe "$SA" >/dev/null 2>&1 || {
  echo "  creating service account"
  gcloud iam service-accounts create "${SA%%@*}" --display-name "ProofSettle enclave" \
    || die "could not create service account"
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$SA" --role roles/confidentialcomputing.workloadUser --quiet >/dev/null
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member "serviceAccount:$SA" --role roles/logging.logWriter --quiet >/dev/null
}

say "1. Launch, looping zones and machine types"
launched=""
for zone in $ZONES; do
  for machine in $MACHINES; do
    echo "  trying $machine in $zone"
    if gcloud compute instances create "$VM" \
        --confidential-compute-type=SEV_SNP \
        --shielded-secure-boot \
        --maintenance-policy=TERMINATE \
        --machine-type="$machine" \
        --zone="$zone" \
        --image-project=confidential-space-images \
        --image-family=confidential-space-debug \
        --service-account="$SA" \
        --scopes=cloud-platform \
        --metadata="^~^tee-image-reference=${IMAGE_REF}~tee-container-log-redirect=true~tee-env-PORT=8080" \
        --quiet >/dev/null 2>&1; then
      launched="$zone"
      echo "  launched in $zone on $machine"
      break 2
    fi
  done
done
[ -n "$launched" ] || die "no capacity in any zone or machine type tried. Widen ZONES or MACHINES."

say "2. Wait for the workload, reading the LAUNCHER log"
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

cat <<EOF

  ENCLAVE SIGNER: $signer
  VM            : $VM in $launched

  Next:
    1. Fetch the attestation token from the running enclave's /identity endpoint.
    2. Verify it, then compute its keccak256 as ENCLAVE_EVIDENCE_HASH.
    3. Register the binding:
         ENCLAVE_SIGNING_KEY=$signer
         forge script script/Deploy.s.sol:RegisterEnclave --rpc-url \$CREDITCOIN_RPC_URL --broadcast

  Tear down when finished:
    gcloud compute instances delete $VM --zone $launched --quiet
EOF
