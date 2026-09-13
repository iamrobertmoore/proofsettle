# Thin-file scoring demonstrator

This model exists to make a private-compute settlement observable. It is **not suitable for real lending decisions**.

- **Form:** deterministic logistic regression, eight normalized features, published coefficients and thresholds.
- **Inputs:** synthetic transaction-history, inflow, supplier-payment and prior-loan features. The random `_nonce` is included in the input commitment but is not a model feature.
- **Outputs:** probability, approve/refer/decline label, feature contributions and commitments to the model and input. Accepted output is encrypted to the buyer.
- **Purpose:** show that the model the buyer names is the model served by the measured workload, that the exact committed input is used, and that delivery is bound to payment.
- **Provenance limit:** the original model metadata describes synthetic fitting. This repository does not contain the training data or fitting pipeline, so that history is not independently reproduced here. Treat the coefficients as a published illustrative demonstrator, not a trained model with established predictive quality.
- **Evaluation:** deterministic inference and protocol integration are tested. Accuracy, calibration, representativeness, fairness and performance on real applicants have not been evaluated.
- **Hardware:** this small model runs on a CPU. GPU workloads are a possible future application, not part of the demonstrated deployment.

A provider earns payment for a correctly completed computation, including a `decline` decision. The protocol's service outcome is separate from the applicant decision.
