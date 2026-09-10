# ProofSettle attested compute enclave.
#
# Two traps are handled here that cost days on previous Confidential Space builds:
#
#   1. NOT distroless:nonroot. uid 65532 cannot open the root-owned launcher socket, so the
#      workload cannot read its own attestation token and silently runs unattested.
#   2. Single platform. buildx provenance produces a multi-platform manifest index that the
#      Confidential Space launcher cannot resolve. Build with --provenance=false --sbom=false.
#
# The launch policy needs log_redirect always, or stdout is discarded on production images and you
# debug blind. See deploy/20-build.sh.

FROM node:22-bookworm-slim

WORKDIR /app

# No package.json and no install step. The enclave has zero runtime dependencies on purpose: a
# supply chain is a poor thing to put inside a trust boundary.
COPY crypto.mjs envelope.mjs model.mjs model.json server.mjs ./

ENV PORT=8080
EXPOSE 8080

# Root on purpose. See trap 1 above.
USER root

LABEL "tee.launch_policy.allow_env_override"="PORT"
LABEL "tee.launch_policy.log_redirect"="always"

CMD ["node", "server.mjs"]
