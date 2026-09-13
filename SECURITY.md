# Security model and release scope

ProofSettle is an unaudited testnet prototype. The current live release uses the v2 request/delivery-binding signature domain. Current addresses are in `site/deployments.json`; earlier addresses are retained only as historical evidence.

## v2 hardening

The settlement now checks the signed model, input and encrypted-envelope commitments against the proven source event. It also checks that the exact signed delivery bytes are present in the destination transaction. Regression tests use valid signatures over substituted requests and enforce atomic rollback of proof consumption.

The source escrow has a fixed trusted return relayer, single finalization, accounting-conserving splits, pull withdrawals to fixed recipients, a one-day destination deadline and a 30-day source timeout. Finalization and refund cannot both release one job. Destination receipts are non-transferable accounting history.

## Remaining assumptions

- Creditcoin, Sepolia, Attestcoin and their finality assumptions.
- Google Cloud Attestation, confidential hardware and the measured software supply chain.
- The registrar's enrollment decision and revocation operations.
- The fixed source return-relayer key. It can falsely report a split if compromised; the source chain does not independently prove Creditcoin state.
- Browser origin integrity, the user's device, and protection of the browser-held answer key.
- Availability of the enclave, proof worker, RPCs and return relayer. A timeout refund protects the payer after 30 days; it does not guarantee the provider gets paid if the return leg stalls.

The token proves historical enrollment, not continuous liveness. The registry has no same-measurement key-rotation mechanism. Restarting the same measured image generates new ephemeral keys; recovery needs a deliberate new release or a future registry upgrade.

## Reporting

Use the repository's private vulnerability reporting feature if available. Do not publish secrets, exploit instructions for active third-party systems or real borrower data in an issue. Ordinary reproducible test failures can be reported in a GitHub issue using synthetic data.
