// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title EncodedTx
/// @notice Builds transactions in the wire format the Attestcoin prover emits, so the settlement
/// contract can be tested against realistic input without spending an oracle query.
/// @dev The format, read off `EvmV1Decoder` rather than out of a document:
///
///   encodedTransaction = abi.encode(uint8 txType, bytes[] chunks)
///     chunks[0] = abi.encode(nonce, gasLimit, from, toIsNull, to, value, data)
///     chunks[1] = type specific fields
///     chunks[2] = abi.encode(receiptStatus, receiptGasUsed, LogEntry[], logsBloom)   for types 0 to 2
///     chunks[3] = the receipt instead, for types 3 and 4
///
/// `EncodedTxRealFixtureTest` checks this understanding against bytes taken from the live prover,
/// so if Gluwa change the encoding the suite says so rather than quietly testing a fiction.
library EncodedTx {
    struct Log {
        address emitter;
        bytes32[] topics;
        bytes data;
    }

    /// @notice Build a type 2 transaction carrying `logs` in its receipt.
    function build(uint8 receiptStatus, Log[] memory logs) internal pure returns (bytes memory) {
        bytes[] memory chunks = new bytes[](3);

        chunks[0] = abi.encode(
            uint64(7), // nonce
            uint64(300_000), // gasLimit
            address(0xBEEF), // from
            false, // toIsNull
            address(0xCAFE), // to
            uint256(0), // value
            hex"" // data
        );

        // Type 2 specific fields: chainId, maxPriorityFeePerGas, maxFeePerGas, accessList, yParity, r, s
        bytes[] memory emptyAccessList = new bytes[](0);
        chunks[1] = abi.encode(
            uint64(11155111), uint128(1 gwei), uint128(30 gwei), emptyAccessList, uint8(0), bytes32(0), bytes32(0)
        );

        chunks[2] = abi.encode(receiptStatus, uint64(120_000), logs, bytes(hex"00"));

        return abi.encode(uint8(2), chunks);
    }

    /// @notice A single-log transaction, the common case in these tests.
    function buildWithOneLog(uint8 receiptStatus, Log memory log) internal pure returns (bytes memory) {
        Log[] memory logs = new Log[](1);
        logs[0] = log;
        return build(receiptStatus, logs);
    }

    /// @notice A well formed `JobCreated` log as `ComputeJobEscrow` emits it.
    function jobCreatedLog(
        address emitter,
        bytes32 eventSig,
        bytes32 jobId,
        address payer,
        address provider,
        uint256 amount,
        bytes32 requiredMeasurement,
        bytes32 modelHash,
        bytes32 inputHash
    ) internal view returns (Log memory log) {
        bytes32[] memory topics = new bytes32[](4);
        topics[0] = eventSig;
        topics[1] = jobId;
        topics[2] = bytes32(uint256(uint160(payer)));
        topics[3] = bytes32(uint256(uint160(provider)));

        log.emitter = emitter;
        log.topics = topics;
        log.data = abi.encode(amount, requiredMeasurement, modelHash, inputHash, keccak256(""), uint64(block.timestamp + 1 days));
    }
}
