// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {CalldataEnvelope} from "./CalldataEnvelope.sol";

import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

import {IAttestcoinVerifier} from "./interfaces/IAttestcoinVerifier.sol";
import {AttestcoinProven} from "./AttestcoinProven.sol";
import {EnclaveRegistry} from "./EnclaveRegistry.sol";
import {ComputeCredit} from "./ComputeCredit.sol";

/// @title ComputeSettlement
/// @notice Settles payment for off-chain AI compute only when two independent proofs, of two
/// different kinds, agree inside a single transaction. Service completion decides the split.
///
/// @dev The two proofs:
///
///   1. **The payment happened.** A `JobCreated` event on Ethereum Sepolia, proven through the
///      Attestcoin Protocol's native verifier precompile. Nobody is asked to take a relayer's word
///      for it.
///
///   2. **The right enclave did the work.** A secp256k1 signature over the result, from a key the
///      registry binds to the exact enclave measurement the buyer demanded when they paid.
///
/// Neither proof settles anything alone, and they are checked in the same call. Splitting them
/// into two transactions would make "neither half settles without the other" a property of the
/// off-chain worker rather than of the contract, and a worker is not a guarantee.
///
/// **The buyer's policy travels with the payment.** This contract holds no allowlist of acceptable
/// enclaves. It reads the measurement out of the proven foreign event and enforces that, which is
/// what makes this cross-chain business logic rather than cross-chain data delivery.
///
/// The signed service outcome controls the accounting split. A successfully computed decline
/// still pays the provider: applicant approval is private model output, not service completion.
/// Source-chain ETH release is a separate, explicitly trusted return-relayer operation.
contract ComputeSettlement is AttestcoinProven {
    /// @notice What the enclave concluded about the job it was asked to run.
    enum Outcome {
        Rejected, // 0: could not be completed. The buyer's claim returns to the buyer.
        Accepted, // 1: completed to specification. The provider is paid in full.
        Partial // 2: completed in part. Split by scoreBps.

    }

    /// @notice Everything the enclave signed, travelling as one argument.
    /// @dev Bundled rather than passed as six loose parameters. It keeps `settle` off the stack
    /// limit, and it makes the ABI say plainly that these fields are one signed object: change any
    /// of them and the signature no longer recovers.
    struct EnclaveAttestation {
        bytes32 resultHash;
        bytes32 requestHash;
        bytes32 deliveryHash;
        Outcome outcome;
        uint16 scoreBps;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice keccak256("JobCreated(bytes32,address,address,uint256,bytes32,bytes32,bytes32,bytes32,uint64)")
    /// @dev Asserted against the escrow's own event in the test suite rather than trusted as a
    /// hand-copied constant.
    bytes32 public constant JOB_CREATED_SIG = keccak256("JobCreated(bytes32,address,address,uint256,bytes32,bytes32,bytes32,bytes32,uint64)");

    /// @notice Domain tag for the enclave's signature, so a signature cannot be lifted to another
    /// deployment, another chain or another protocol.
    string public constant SIGNING_DOMAIN = "proofsettle.result.v2";

    uint16 public constant BPS_DENOMINATOR = 10_000;

    EnclaveRegistry public immutable REGISTRY;
    ComputeCredit public immutable CREDIT;

    /// @notice The one source-chain escrow whose events this contract will act on.
    /// @dev Without this check anybody could deploy their own escrow, emit a `JobCreated` naming
    /// themselves as provider for any amount, and prove it perfectly validly. The proof would be
    /// genuine and the settlement would be theft. Pinning the emitter is what makes a true proof
    /// also a relevant one.
    address public immutable SOURCE_ESCROW;

    struct Settlement {
        bytes32 queryId;
        address provider;
        address payer;
        uint256 amount;
        uint256 paidToProvider;
        uint256 returnedToPayer;
        bytes32 resultHash;
        address enclave;
        Outcome outcome;
        uint16 scoreBps;
        uint64 settledAt;
    }

    mapping(bytes32 => Settlement) public settlements;

    event JobSettled(
        bytes32 indexed jobId,
        address indexed provider,
        address indexed enclave,
        Outcome outcome,
        uint16 scoreBps,
        uint256 paidToProvider,
        uint256 returnedToPayer,
        bytes32 resultHash,
        bytes32 requiredMeasurement,
        bytes32 queryId
    );

    error RequestMismatch(bytes32 expected, bytes32 signed);
    error DeliveryMismatch(bytes32 expected, bytes32 actual);
    error SettlementExpired(uint64 settleBy);
    event RequestBound(bytes32 indexed jobId, bytes32 requestHash, bytes32 deliveryHash);
    error ZeroAddress();
    error TransactionFailedOnSource(uint8 receiptStatus);
    error UnsupportedTransactionType(uint8 txType);
    error NoJobCreatedEvent();
    error WrongEmitter(address expected, address got);
    error MalformedEvent();
    error JobAlreadySettled(bytes32 jobId);
    error BadSignatureS();
    error BadSignatureV(uint8 v);
    error SignatureRecoveryFailed();
    error EnclaveNotAccepted(bytes32 requiredMeasurement, address recovered);
    error InvalidOutcome(uint8 outcome);
    error ScoreOutOfRange(uint16 scoreBps);

    constructor(uint64 sourceChainKey, address registry, address credit, address sourceEscrow)
        AttestcoinProven(sourceChainKey)
    {
        if (registry == address(0) || credit == address(0) || sourceEscrow == address(0)) revert ZeroAddress();
        REGISTRY = EnclaveRegistry(registry);
        CREDIT = ComputeCredit(credit);
        SOURCE_ESCROW = sourceEscrow;
    }

    /// @notice Settle one job. Both proofs are checked here, in this order, or nothing happens.
    /// @param chainKey Source chain key carried by the proof, checked against the pinned one
    /// @param height Sepolia block height containing the payment transaction
    /// @param encodedTransaction The Sepolia transaction and receipt, as produced by the prover
    /// @param merkleProof Inclusion proof for that transaction
    /// @param continuityProof Continuity proof back to an attested checkpoint
    /// @param att Everything the enclave signed: result commitment, verdict, score and signature
    /// @return jobId The job that settled
    function settle(
        uint64 chainKey,
        uint64 height,
        bytes calldata encodedTransaction,
        IAttestcoinVerifier.MerkleProof calldata merkleProof,
        IAttestcoinVerifier.ContinuityProof calldata continuityProof,
        EnclaveAttestation calldata att
    ) external returns (bytes32 jobId) {
        if (uint8(att.outcome) > uint8(Outcome.Partial)) revert InvalidOutcome(uint8(att.outcome));
        if (att.scoreBps > BPS_DENOMINATOR) revert ScoreOutOfRange(att.scoreBps);

        // Proof one. Reverts if the foreign transaction is not provably in an attested block, or
        // if this exact transaction has been settled through before.
        bytes32 queryId = _consumeProof(chainKey, height, encodedTransaction, merkleProof, continuityProof);

        Job memory job = _readJob(encodedTransaction);
        jobId = job.jobId;

        if (settlements[jobId].settledAt != 0) revert JobAlreadySettled(jobId);
        _checkRequest(job, att);

        // Proof two. Reverts unless the signature came from the live key bound to exactly the
        // measurement the buyer named on the source chain. The verdict sits inside the signed
        // payload, so a provider cannot claim a better outcome than the enclave reported.
        address enclave = _recoverEnclave(jobId, att);
        if (!REGISTRY.isActiveSigner(job.requiredMeasurement, enclave)) {
            revert EnclaveNotAccepted(job.requiredMeasurement, enclave);
        }

        (uint256 toProvider, uint256 toPayer) = _split(job.amount, att.outcome, att.scoreBps);

        settlements[jobId] = Settlement({
            queryId: queryId,
            provider: job.provider,
            payer: job.payer,
            amount: job.amount,
            paidToProvider: toProvider,
            returnedToPayer: toPayer,
            resultHash: att.resultHash,
            enclave: enclave,
            outcome: att.outcome,
            scoreBps: att.scoreBps,
            settledAt: uint64(block.timestamp)
        });

        emit JobSettled(
            jobId,
            job.provider,
            enclave,
            att.outcome,
            att.scoreBps,
            toProvider,
            toPayer,
            att.resultHash,
            job.requiredMeasurement,
            queryId
        );

        emit RequestBound(jobId, att.requestHash, att.deliveryHash);

        if (toProvider > 0) CREDIT.mint(job.provider, toProvider);
        if (toPayer > 0) CREDIT.mint(job.payer, toPayer);
    }

    function _checkRequest(Job memory job, EnclaveAttestation calldata att) private view {
        if (block.timestamp >= job.settleBy) revert SettlementExpired(job.settleBy);
        bytes32 expectedRequest = keccak256(abi.encode(job.modelHash, job.inputHash, job.envelopeHash));
        if (att.requestHash != expectedRequest) revert RequestMismatch(expectedRequest, att.requestHash);
        bytes32 delivered = keccak256(CalldataEnvelope.read(msg.data, 4));
        if (att.deliveryHash != delivered) revert DeliveryMismatch(att.deliveryHash, delivered);
    }

    /// @notice How a verdict divides the payment.
    /// @dev Public and pure so the split is checkable off chain without replaying a settlement.
    function splitFor(uint256 amount, Outcome outcome, uint16 scoreBps)
        public
        pure
        returns (uint256 toProvider, uint256 toPayer)
    {
        return _split(amount, outcome, scoreBps);
    }

    function _split(uint256 amount, Outcome outcome, uint16 scoreBps)
        internal
        pure
        returns (uint256 toProvider, uint256 toPayer)
    {
        if (outcome == Outcome.Accepted) return (amount, 0);
        if (outcome == Outcome.Rejected) return (0, amount);
        toProvider = (amount * scoreBps) / BPS_DENOMINATOR;
        toPayer = amount - toProvider;
    }

    /// @notice The digest an enclave must sign for a given job, result and verdict.
    /// @dev Exposed so the enclave and the off-chain worker can assert byte-for-byte parity against
    /// this contract rather than reimplementing the formula and drifting from it silently. The
    /// verdict is inside the digest, so altering it invalidates the signature.
    function resultDigest(bytes32 jobId, bytes32 resultHash_, Outcome outcome, uint16 scoreBps, bytes32 requestHash, bytes32 deliveryHash)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(SIGNING_DOMAIN, block.chainid, address(this), jobId, resultHash_, uint8(outcome), scoreBps, requestHash, deliveryHash)
        );
    }

    struct Job {
        bytes32 jobId;
        address payer;
        address provider;
        uint256 amount;
        bytes32 requiredMeasurement;
        bytes32 modelHash;
        bytes32 inputHash;
        bytes32 envelopeHash;
        uint64 settleBy;
    }

    /// @dev Pull the job out of the proven foreign transaction.
    function _readJob(bytes calldata encodedTransaction) private view returns (Job memory job) {
        uint8 txType = EvmV1Decoder.getTransactionType(encodedTransaction);
        if (!EvmV1Decoder.isValidTransactionType(txType)) revert UnsupportedTransactionType(txType);

        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(encodedTransaction);

        // A reverted payment proves nothing worth paying for. The oracle will happily prove that a
        // failed transaction is in a block, which is exactly why this has to be checked here.
        if (receipt.receiptStatus != 1) revert TransactionFailedOnSource(receipt.receiptStatus);

        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(receipt, JOB_CREATED_SIG);
        if (logs.length == 0) revert NoJobCreatedEvent();

        EvmV1Decoder.LogEntry memory log = logs[0];
        if (log.address_ != SOURCE_ESCROW) revert WrongEmitter(SOURCE_ESCROW, log.address_);

        // jobId, payer, provider are indexed, so topics is [signature, jobId, payer, provider].
        if (log.topics.length != 4) revert MalformedEvent();
        // amount, requiredMeasurement, modelHash, inputHash are not indexed: four 32 byte words.
        if (log.data.length != 192) revert MalformedEvent();

        job.jobId = log.topics[1];
        job.payer = address(uint160(uint256(log.topics[2])));
        job.provider = address(uint160(uint256(log.topics[3])));
        (job.amount, job.requiredMeasurement, job.modelHash, job.inputHash, job.envelopeHash, job.settleBy) = abi.decode(log.data, (uint256, bytes32, bytes32, bytes32, bytes32, uint64));
    }

    /// @dev Recover the signer, rejecting the malleable half of the curve and any recovery id
    /// outside {27, 28}. `ecrecover` returns the zero address on failure rather than reverting,
    /// which is a well known way for a naive implementation to accept a bad signature.
    function _recoverEnclave(bytes32 jobId, EnclaveAttestation calldata att) private view returns (address) {
        if (uint256(att.s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert BadSignatureS();
        }
        if (att.v != 27 && att.v != 28) revert BadSignatureV(att.v);

        address recovered =
            ecrecover(resultDigest(jobId, att.resultHash, att.outcome, att.scoreBps, att.requestHash, att.deliveryHash), att.v, att.r, att.s);
        if (recovered == address(0)) revert SignatureRecoveryFailed();
        return recovered;
    }
}
