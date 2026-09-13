#!/usr/bin/env bash
#
# Assemble the public site into ./_site, ready to publish.
#
#   ./script/build-site.sh
#
# The page, the deck and the attestation token have to sit next to each other, because the page
# fetches the token and verifies it in the browser. Keeping that in one script means the published
# thing is never a hand-assembled folder that quietly went stale.
#
# Publishing is deliberately not done here. Two routes:
#
#   Cloudflare Pages, which works while the repository is still private:
#       npx wrangler pages deploy _site --project-name proofsettle
#
#   GitHub Pages, once the repository is public:
#       the workflow in .github/workflows/pages.yml does the same assembly and deploys it.

set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"

say()  { printf '%s\n' "$*"; }
fail() { printf '\n%s\n' "ERROR: $*" >&2; exit 1; }

out="_site"
rm -rf "$out"
mkdir -p "$out"

for f in site/index.html site/evidence.html site/purchase.js site/verify.html site/desk.html site/style.css site/experience.css site/experience.js site/fonts.css site/home.js site/demo.json site/abis.json site/deployments.json site/enclave.json deck/ProofSettle-deck.pdf enclave/attestation.jwt; do
    [ -f "$f" ] || fail "missing $f. The site is incomplete without it."
    cp "$f" "$out/"
done

cp -R site/vendor "$out/vendor"
[ ! -d site/releases ] || cp -R site/releases "$out/releases"
[ ! -d site/attestations ] || cp -R site/attestations "$out/attestations"

# The page reads deployments.json to prefill itself. A published site with empty addresses looks
# broken to the first person who opens it, so refuse to ship one.
for key in settlement enclaveRegistry sourceEscrow exampleJobId; do
    v="$(sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$out/deployments.json")"
    [ -n "$v" ] || fail "deployments.json has no $key, so the page would open with an empty form"
done

# The desk reads enclave.json before it seals anything. Ship it only if it names a build.
for key in build measurement signer; do
    v="$(sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p" "$out/enclave.json")"
    [ -n "$v" ] || fail "enclave.json has no $key. Run enclave/deploy/40-register.sh."
done

# Likewise a token the page cannot parse.
parts="$(tr -cd '.' < "$out/attestation.jwt" | wc -c | tr -d ' ')"
[ "$parts" = "2" ] || fail "attestation.jwt is not a three part JWT"

say "assembled $out"
ls -la "$out"
say ""
say "Publish with either of:"
say "  npx wrangler pages deploy $out --project-name proofsettle    (works while the repo is private)"
say "  the Pages workflow on GitHub                                  (once the repo is public)"
