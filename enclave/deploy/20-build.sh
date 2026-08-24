#!/usr/bin/env bash
#
# Build and push the enclave image, then print the digest the launch policy must allowlist.
#
# Every step refuses to continue rather than failing quietly. The failure mode this guards against
# is the one that costs a day: something goes wrong, the thing reporting back says success or says
# nothing, and the workload runs unattested while looking healthy.
#
# Requires: gcloud authenticated, docker, and PROJECT_ID set.

set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
REGION="${REGION:-europe-west2}"
REPO="${REPO:-proofsettle}"
IMAGE="${IMAGE:-enclave}"
TAG="${TAG:-v1}"
REF="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO}/${IMAGE}:${TAG}"

here="$(cd "$(dirname "$0")/.." && pwd)"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mFAILED: %s\033[0m\n' "$*" >&2; exit 1; }

say "0. Preflight"
command -v docker >/dev/null || die "docker not found"
command -v gcloud >/dev/null || die "gcloud not found"
[ -f "$here/Dockerfile" ] || die "Dockerfile not found at $here"
[ -f "$here/server.mjs" ] || die "server.mjs not found"
[ -f "$here/crypto.mjs" ] || die "crypto.mjs not found"

say "1. Prove the crypto before shipping it"
# An enclave that signs with a broken keccak produces signatures the chain rejects, and the only
# symptom is a reverting settlement. Check it here, where it is cheap.
( cd "$here/.." && node enclave/verify-crypto.mjs ) || die "enclave crypto does not match the reference"

say "2. Boot the container locally and poll it"
# A missing dependency or a syntax error kills the workload during startup, after anything watching
# for a crash has already concluded it is running. Boot it here first.
docker build --provenance=false --sbom=false -t "proofsettle-enclave-local" "$here" \
  || die "local build failed"

cid="$(docker run -d -p 18080:8080 proofsettle-enclave-local)" || die "container did not start"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT

ok=0
for _ in $(seq 1 30); do
  if curl -sf http://127.0.0.1:18080/health >/dev/null 2>&1; then ok=1; break; fi
  sleep 1
done
[ "$ok" = 1 ] || die "container started but never answered /health. Check: docker logs $cid"

signer="$(curl -sf http://127.0.0.1:18080/identity | sed -n 's/.*"signer":"\([^"]*\)".*/\1/p')"
[ -n "$signer" ] || die "/identity did not return a signer"
echo "  local signer: $signer"
docker rm -f "$cid" >/dev/null
trap - EXIT

say "3. Build and push, single platform"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet \
  || die "could not configure docker auth"

gcloud artifacts repositories describe "$REPO" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1 || {
  echo "  creating repository $REPO"
  gcloud artifacts repositories create "$REPO" --repository-format=docker \
    --location "$REGION" --project "$PROJECT_ID" || die "could not create artifact repository"
}

# buildx, not plain docker build. On an Apple Silicon machine, plain `docker build --platform
# linux/amd64` can reuse the arm64 layers it built a moment ago and stamp them amd64, producing an
# image that claims to be amd64 and contains aarch64 binaries. Confidential Space then boots it,
# the entrypoint dies with an exec format error, the launcher stops, and the VM terminates with no
# log at all. That is exactly the failure this build now refuses to ship.
docker buildx build --provenance=false --sbom=false --platform linux/amd64 \
  --load -t "$REF" "$here" \
  || die "amd64 build failed. If buildx is unavailable, run: docker buildx create --use"

say "3b. Prove the image really is amd64, by running it"
# Checking the metadata is not enough, because the metadata is exactly what gets faked. Run the
# thing and ask it. Docker Desktop executes amd64 images on Apple Silicon through Rosetta, so a
# genuine amd64 image answers x64 here and a mislabelled one fails to exec at all.
arch_reported="$(docker run --rm --platform linux/amd64 "$REF" \
    node -e 'process.stdout.write(process.arch)' 2>/dev/null || true)"
if [ "$arch_reported" != "x64" ]; then
    die "the image answered process.arch='$arch_reported', not 'x64', so it is not a working amd64 image and Confidential Space runs amd64 only. Nothing has been pushed.

  If it answered 'arm64', the build reused this machine's own layers. Try:
      docker buildx create --use
      docker buildx build --platform linux/amd64 --load -t $REF $here

  If it answered nothing at all, this machine may not be able to execute amd64 images. Turn on
  Rosetta in Docker Desktop, Settings, General, 'Use Rosetta for x86_64/amd64 emulation', and
  run this again."
fi
echo "  runs as x64 under linux, so it will exec on the VM"

docker push "$REF" || die "push failed"

say "4. Confirm it is a single-platform manifest"
# A manifest index here means the launcher cannot resolve the image, and the error it gives is
# unhelpful. Catch it now.
mt="$(docker manifest inspect "$REF" | sed -n 's/.*"mediaType": "\([^"]*\)".*/\1/p' | head -1)"
echo "  mediaType: $mt"
case "$mt" in
  *manifest.list*|*image.index*) die "multi-platform manifest. Rebuild with --provenance=false --sbom=false" ;;
esac

say "5. The digest to allowlist"
# The launch policy matches the CONFIG digest, not the manifest digest. Both are sha256 and both
# look right, which is why this line exists.
config_digest="$(docker manifest inspect "$REF" | python3 -c 'import sys,json; print(json.load(sys.stdin)["config"]["digest"])')" \
  || die "could not read the config digest"

cat <<EOF

  image      : $REF
  image_id   : $config_digest

  That image_id is the Docker CONFIG digest. It is what the Confidential Space allowlist matches.
  It is NOT the output of 'docker inspect --format={{.Id}}' and it is NOT the manifest digest.
  Using the wrong one produces an allowlist that silently never matches.

  Next: enclave/deploy/30-launch.sh
EOF
