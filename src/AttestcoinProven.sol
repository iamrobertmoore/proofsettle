// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAttestcoinVerifier} from "./interfaces/IAttestcoinVerifier.sol";

/// @title AttestcoinProven
/// @notice Base for an Attestcoin smart contract that acts on a proven foreign-chain transaction.
/// @dev Handles the two things every Attestcoin smart contract needs and neither of which is
/// business logic: putting a proof to the Attestcoin verifier precompile, and refusing to act on
/// the same proven transaction twice.
///
/// A derived contract calls `_consumeProof` and gets back the raw foreign transaction bytes to
/// interpret, plus a query id that is unique to that transaction. Everything after that is the
/// application's own concern.
abstract contract AttestcoinProven {
    /// @notice The Attestcoin native query verifier precompile on Creditcoin.
    IAttestcoinVerifier public constant VERIFIER = IAttestcoinVerifier(0x0000000000000000000000000000000000000FD2);

    /// @notice Chain key of the source chain this contract accepts proofs from.
    /// @dev Fixed at construction. A contract that accepts a proof from any chain accepts a proof
    /// from the cheapest chain to attack, so the source is pinned rather than passed in per call.
    uint64 public immutable SOURCE_CHAIN_KEY;

    /// @notice Query ids already acted upon.
    mapping(bytes32 => bool) public consumedQueries;

    event ProofConsumed(bytes32 indexed queryId, uint64 indexed height, uint64 txIndex);

    error WrongSourceChain(uint64 expected, uint64 got);
    error ProofRejected();
    error QueryAlreadyConsumed(bytes32 queryId);
    error ZeroChainKey();

    constructor(uint64 sourceChainKey) {
        if (sourceChainKey == 0) revert ZeroChainKey();
        SOURCE_CHAIN_KEY = sourceChainKey;
    }

    /// @notice Verify a foreign transaction and mark it consumed, exactly once.
    /// @dev Order matters. The replay key is computed and checked before the verifier is called so
    /// a replayed proof costs the attacker the cheaper revert, and the query is marked consumed
    /// before any business logic runs so a reentrant call through the application layer cannot come
    /// back around to the same proof.
    /// @param chainKey Source chain key carried by the proof, checked against the pinned one
    /// @param height Foreign block height the transaction was included in
    /// @param encodedTransaction The foreign transaction and receipt, encoded by the prover
    /// @param merkleProof Inclusion proof of the transaction within its block
    /// @param continuityProof Proof linking that block to an attested checkpoint
    /// @return queryId Unique identifier for this proven transaction
    function _consumeProof(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        IAttestcoinVerifier.MerkleProof calldata merkleProof,
        IAttestcoinVerifier.ContinuityProof calldata continuityProof
    ) internal returns (bytes32 queryId) {
        if (chainKey != SOURCE_CHAIN_KEY) revert WrongSourceChain(SOURCE_CHAIN_KEY, chainKey);

        uint64 txIndex = VERIFIER.calculateTxIndex(merkleProof);
        queryId = keccak256(abi.encode(chainKey, height, txIndex, merkleProof.root));

        if (consumedQueries[queryId]) revert QueryAlreadyConsumed(queryId);
        consumedQueries[queryId] = true;

        if (!VERIFIER.verifyAndEmit(chainKey, height, encodedTransaction, merkleProof, continuityProof)) {
            revert ProofRejected();
        }

        emit ProofConsumed(queryId, height, txIndex);
    }
}
