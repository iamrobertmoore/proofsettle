// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IAttestcoinVerifier
/// @notice The Attestcoin Protocol's native query verifier, a precompile at
/// `0x0000000000000000000000000000000000000FD2` on Creditcoin.
/// @dev Written against the live precompile rather than copied. Both entry points below were
/// exercised against CC3 testnet on 22 August 2026 with a real proof, and with a corrupted proof
/// to confirm the failure path reverts with "Merkle proof validation failed".
///
/// The usc-contracts package from Gluwa vendors an interface exposing only the view `verify`. The non-view
/// `verifyAndEmit` is what the guided tutorials use, and it is what this project calls, because a
/// settlement that turns on a proof should leave the verifier's own record of that proof on chain
/// rather than only the caller's word for it.
interface IAttestcoinVerifier {
    struct MerkleProofEntry {
        bytes32 hash;
        bool isLeft;
    }

    struct MerkleProof {
        bytes32 root;
        MerkleProofEntry[] siblings;
    }

    struct ContinuityProof {
        bytes32 lowerEndpointDigest;
        bytes32[] roots;
    }

    /// @notice Verify a transaction's inclusion in an attested foreign block, and emit the
    /// verifier's own event recording it. Reverts if any part of the proof does not hold.
    function verifyAndEmit(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        MerkleProof calldata merkleProof,
        ContinuityProof calldata continuityProof
    ) external returns (bool);

    /// @notice Read-only variant of the same check.
    function verify(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        MerkleProof calldata merkleProof,
        ContinuityProof calldata continuityProof
    ) external view returns (bool);

    /// @notice Recover the transaction's index within its block from the shape of the merkle proof.
    /// @dev Used to build a replay key that is unique per proven transaction.
    function calculateTxIndex(MerkleProof calldata merkleProof) external view returns (uint64);
}
