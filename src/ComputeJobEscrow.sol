// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {CalldataEnvelope} from "./CalldataEnvelope.sol";

/// @title ComputeJobEscrow
/// @notice Source-chain half of the settlement rail. Deployed on Ethereum Sepolia.
/// @dev A buyer locks payment for an off-chain inference and states, in the payment itself, which
/// enclave build they are willing to accept. The `JobCreated` event this emits is the cross-chain
/// fact that the Creditcoin settlement contract later proves through the Attestcoin oracle.
///
/// The buyer's policy travels with the payment. That is the point of the design: the settlement
/// contract on Creditcoin does not hold an allowlist of acceptable enclaves, it enforces whatever
/// the buyer demanded at the moment they paid.
contract ComputeJobEscrow {
    /// @param jobId Unique job identifier, derived from the buyer, their nonce and this contract
    /// @param payer Who paid
    /// @param provider Who is entitled to settlement once both proofs check out
    /// @param amount Wei locked for this job
    /// @param requiredMeasurement The enclave measurement the buyer will accept, and no other
    /// @param modelHash Identifier of the model the buyer is paying to run
    /// @param inputHash Commitment to the input, so the buyer's request is pinned without
    /// revealing it on a public chain
    event JobCreated(
        bytes32 indexed jobId,
        address indexed payer,
        address indexed provider,
        uint256 amount,
        bytes32 requiredMeasurement,
        bytes32 modelHash,
        bytes32 inputHash,
        bytes32 envelopeHash,
        uint64 settleBy
    );

    event JobRefunded(bytes32 indexed jobId, address indexed payer, uint256 amount);

    struct Job {
        address payer;
        address provider;
        uint256 amount;
        uint64 createdAt;
        bool refunded;
    }

    /// @notice How long a buyer must wait before reclaiming an unsettled job.
    /// @dev Deliberately long. See the honest limitation in the contract-level notes below.
    uint64 public constant REFUND_DELAY = 30 days;

    address public immutable settlementRelayer;
    uint64 public constant SETTLEMENT_WINDOW = 1 days;
    mapping(bytes32 => bool) public finalized;
    mapping(address => uint256) public withdrawable;
    event JobFinalized(bytes32 indexed jobId, uint256 paidToProvider, uint256 returnedToPayer);
    event PaymentWithdrawn(address indexed recipient, uint256 amount);
    error NotSettlementRelayer();
    error AlreadyFinalized();
    error InvalidSplit();
    error NothingToWithdraw();
    constructor() { settlementRelayer = msg.sender; }

    mapping(bytes32 => Job) public jobs;
    mapping(address => uint256) public nonces;

    error ZeroProvider();
    error ZeroPayment();
    error ZeroMeasurement();
    error JobUnknown(bytes32 jobId);
    error NotPayer();
    error AlreadyRefunded();
    error RefundTooEarly(uint64 availableAt);
    error RefundFailed();

    /// @notice Lock payment for one inference and publish the buyer's enclave policy.
    /// @param provider The compute provider entitled to settle this job
    /// @param requiredMeasurement Enclave measurement the buyer requires. Zero is rejected,
    /// because a job that accepts any enclave defeats the purpose of the rail
    /// @param modelHash Identifier of the model to run
    /// @param inputHash Commitment to the input
    /// @return jobId The identifier to quote when settling
    function createJob(address provider, bytes32 requiredMeasurement, bytes32 modelHash, bytes32 inputHash)
        external
        payable
        returns (bytes32 jobId)
    {
        if (provider == address(0)) revert ZeroProvider();
        if (msg.value == 0) revert ZeroPayment();
        if (requiredMeasurement == bytes32(0)) revert ZeroMeasurement();

        uint256 nonce = nonces[msg.sender]++;
        jobId = keccak256(abi.encode(block.chainid, address(this), msg.sender, nonce));

        jobs[jobId] =
            Job({payer: msg.sender, provider: provider, amount: msg.value, createdAt: uint64(block.timestamp), refunded: false});

        emit JobCreated(jobId, msg.sender, provider, msg.value, requiredMeasurement, modelHash, inputHash,
            keccak256(CalldataEnvelope.read(msg.data, 132)), uint64(block.timestamp) + SETTLEMENT_WINDOW);
    }

    /// @notice Reclaim a job's payment once the refund delay has passed.
    /// @dev Settlement must be recorded on Creditcoin within one day. The trusted return relayer
    /// has the remainder of the 30-day window to finalize on Sepolia. Finalized and refunded
    /// states are mutually exclusive. Source-chain safety still depends on that fixed relayer.
    function refund(bytes32 jobId) external {
        Job storage job = jobs[jobId];
        if (job.payer == address(0)) revert JobUnknown(jobId);
        if (job.payer != msg.sender) revert NotPayer();
        if (job.refunded) revert AlreadyRefunded();
        if (finalized[jobId]) revert AlreadyFinalized();

        uint64 availableAt = job.createdAt + REFUND_DELAY;
        if (block.timestamp < availableAt) revert RefundTooEarly(availableAt);

        job.refunded = true;
        uint256 amount = job.amount;

        emit JobRefunded(jobId, msg.sender, amount);

        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert RefundFailed();
    }
    /// @notice Trusted return leg: the relayer reads finalized Creditcoin state before calling.
    /// @dev This is NOT Attestcoin writability. The source chain trusts this fixed relayer.
    /// The relayer cannot redirect payment: both recipients were fixed by the buyer.
    function finalize(bytes32 jobId, uint256 paidToProvider, uint256 returnedToPayer) external {
        if (msg.sender != settlementRelayer) revert NotSettlementRelayer();
        Job storage job = jobs[jobId];
        if (job.payer == address(0)) revert JobUnknown(jobId);
        if (job.refunded) revert AlreadyRefunded();
        if (finalized[jobId]) revert AlreadyFinalized();
        if (paidToProvider > job.amount || returnedToPayer != job.amount - paidToProvider) revert InvalidSplit();
        finalized[jobId] = true;
        withdrawable[job.provider] += paidToProvider;
        withdrawable[job.payer] += returnedToPayer;
        emit JobFinalized(jobId, paidToProvider, returnedToPayer);
    }

    /// @notice Anyone can deliver a credit, but only to its recorded recipient.
    function withdrawFor(address recipient) external {
        uint256 amount = withdrawable[recipient];
        if (amount == 0) revert NothingToWithdraw();
        withdrawable[recipient] = 0;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert RefundFailed();
        emit PaymentWithdrawn(recipient, amount);
    }

}
