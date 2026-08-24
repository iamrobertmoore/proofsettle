#!/usr/bin/env bash
#
# Get a Google Cloud project into a state where Confidential Space can actually run.
#
#   PROJECT_ID=your-project ./enclave/deploy/10-setup.sh
#
# This is the step that eats an afternoon if you do it by hand, because every missing piece fails
# later, in a different script, with an error that does not name the missing piece. So it checks
# each one here and says exactly what to click if it cannot fix it itself.
#
# Nothing here costs money on its own. The VM in 30-launch.sh does, at roughly 0.08 USD an hour
# for n2d-standard-2, and it is billed until you delete it.

set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID, for example: export PROJECT_ID=proofsettle-demo}"
REGION="${REGION:-europe-west2}"
REPO="${REPO:-proofsettle}"
SA_NAME="${SA_NAME:-proofsettle-enclave}"
SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

say "0. Tools"
command -v gcloud >/dev/null || die "gcloud not found. Install the Google Cloud CLI: https://cloud.google.com/sdk/docs/install-sdk"
command -v docker >/dev/null || die "docker not found. Install Docker Desktop and start it: https://docs.docker.com/desktop/setup/install/mac-install/"
docker info >/dev/null 2>&1 || die "docker is installed but the daemon is not running. Start Docker Desktop and wait for the whale icon to settle."
echo "  $(gcloud version 2>/dev/null | head -1)"
echo "  docker $(docker version --format '{{.Client.Version}}' 2>/dev/null)"

say "1. Logged in"
account="$(gcloud config get-value account 2>/dev/null || true)"
if [ -z "$account" ] || [ "$account" = "(unset)" ]; then
    die "not logged in. Run: gcloud auth login"
fi
echo "  $account"

say "2. Project"
gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1 \
    || die "project $PROJECT_ID does not exist, or this account cannot see it. Create it at https://console.cloud.google.com/projectcreate"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null
echo "  $PROJECT_ID"

say "3. Billing"
# Without billing, enabling the compute API appears to work and then every instance create fails.
billing="$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo unknown)"
case "$billing" in
    True|true) echo "  billing is enabled" ;;
    unknown)   echo "  could not read billing status, which usually means the Cloud Billing API is off."
               echo "  Check by eye: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID" ;;
    *)         die "billing is not enabled on $PROJECT_ID. Link a billing account at https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID and run this again." ;;
esac

say "4. APIs"
# confidentialcomputing is the one people miss. Without it the VM boots and the workload runs, but
# it can never fetch an attestation token, so it signs unattested and looks fine doing it.
for api in compute.googleapis.com artifactregistry.googleapis.com confidentialcomputing.googleapis.com logging.googleapis.com iam.googleapis.com; do
    if gcloud services list --enabled --filter="config.name=$api" --format='value(config.name)' 2>/dev/null | grep -q .; then
        echo "  already on   $api"
    else
        echo "  enabling     $api"
        gcloud services enable "$api" --quiet || die "could not enable $api. Usually billing, occasionally an org policy."
    fi
done

say "5. Artifact Registry repository"
if gcloud artifacts repositories describe "$REPO" --location "$REGION" >/dev/null 2>&1; then
    echo "  already there  $REGION/$REPO"
else
    gcloud artifacts repositories create "$REPO" --repository-format=docker --location "$REGION" --quiet \
        || die "could not create the artifact repository"
    echo "  created        $REGION/$REPO"
fi

say "6. Service account for the workload"
if gcloud iam service-accounts describe "$SA" >/dev/null 2>&1; then
    echo "  already there  $SA"
else
    gcloud iam service-accounts create "$SA_NAME" --display-name "ProofSettle enclave" --quiet \
        || die "could not create the service account"
    echo "  created        $SA"
fi

for role in roles/confidentialcomputing.workloadUser roles/logging.logWriter; do
    echo "  granting       $role"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
        --member "serviceAccount:$SA" --role "$role" --quiet >/dev/null \
        || die "could not grant $role"
done

# The one that is easy to miss, and whose absence is invisible until a VM has already been
# created. Your own account can push the image, so the repository looks fine, but the workload
# runs as this service account and it is a different principal entirely. Without this the
# launcher gets 403 Forbidden fetching a pull token, gives up, and shuts the VM down.
# Granted on the repository rather than the project, because that is all it needs.
echo "  granting       roles/artifactregistry.reader on $REPO"
gcloud artifacts repositories add-iam-policy-binding "$REPO" \
    --location "$REGION" \
    --member "serviceAccount:$SA" --role roles/artifactregistry.reader --quiet >/dev/null \
    || die "could not grant artifactregistry.reader on $REPO"

say "7. Docker can push to Artifact Registry"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet >/dev/null \
    || die "could not configure docker auth"
echo "  configured for ${REGION}-docker.pkg.dev"

cat <<EOF

Ready.

  project        $PROJECT_ID
  region         $REGION
  repository     $REPO
  service acct   $SA

Next, in the same terminal:

    export PROJECT_ID=$PROJECT_ID
    ./enclave/deploy/20-build.sh

EOF
