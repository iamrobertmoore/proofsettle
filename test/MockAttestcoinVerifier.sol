// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IAttestcoinVerifier} from "../src/interfaces/IAttestcoinVerifier.sol";

/// @notice Stand-in for the Attestcoin verifier precompile, etched to `0x…0FD2` in tests.
/// @dev The precompile does not exist in a local EVM. This mock exists so the settlement logic can
/// be tested against both outcomes of the real verifier, including the one that matters most:
/// what happens when a proof is rejected.
///
/// The real precompile reverts with "Merkle proof validation failed" on a corrupted proof, which
/// was confirmed against CC3 testnet on 22 August 2026. `setRevertOnVerify` reproduces that, and
/// `setAccept(false)` reproduces the other failure shape, a plain false return. Both are covered
/// because a contract that only handles the revert would silently accept a `false`.
contract MockAttestcoinVerifier is IAttestcoinVerifier {
    bool public accept = true;
    bool public revertOnVerify;
    uint64 public txIndexToReturn = 42;

    uint256 public verifyCalls;

    event Verified(uint64 chainKey, uint64 height, bytes32 merkleRoot);

    function setAccept(bool v) external {
        accept = v;
    }

    function setRevertOnVerify(bool v) external {
        revertOnVerify = v;
    }

    function setTxIndex(uint64 v) external {
        txIndexToReturn = v;
    }

    function verifyAndEmit(
        uint64 chainKey,
        uint64 height,
        bytes calldata,
        MerkleProof calldata merkleProof,
        ContinuityProof calldata
    ) external returns (bool) {
        verifyCalls++;
        if (revertOnVerify) revert("Merkle proof validation failed");
        emit Verified(chainKey, height, merkleProof.root);
        return accept;
    }

    function verify(uint64, uint64, bytes calldata, MerkleProof calldata, ContinuityProof calldata)
        external
        view
        returns (bool)
    {
        if (revertOnVerify) revert("Merkle proof validation failed");
        return accept;
    }

    function calculateTxIndex(MerkleProof calldata) external view returns (uint64) {
        return txIndexToReturn;
    }
}
