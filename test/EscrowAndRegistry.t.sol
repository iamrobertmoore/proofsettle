// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ComputeJobEscrow} from "../src/ComputeJobEscrow.sol";
import {EnclaveRegistry} from "../src/EnclaveRegistry.sol";

contract ComputeJobEscrowTest is Test {
    ComputeJobEscrow escrow;

    address payer = makeAddr("payer");
    address provider = makeAddr("provider");
    bytes32 constant MEASUREMENT = keccak256("enclave-build-v1");

    event JobCreated(
        bytes32 indexed jobId,
        address indexed payer,
        address indexed provider,
        uint256 amount,
        bytes32 requiredMeasurement,
        bytes32 modelHash,
        bytes32 inputHash, bytes32 envelopeHash, uint64 settleBy
    );

    function setUp() public {
        escrow = new ComputeJobEscrow();
        vm.deal(payer, 100 ether);
    }

    function _create(uint256 value) internal returns (bytes32) {
        vm.prank(payer);
        return escrow.createJob{value: value}(provider, MEASUREMENT, keccak256("model"), keccak256("input"));
    }

    function test_creates_a_job_and_locks_the_payment() public {
        bytes32 jobId = _create(1 ether);

        (address gotPayer, address gotProvider, uint256 amount,, bool refunded) = escrow.jobs(jobId);
        assertEq(gotPayer, payer);
        assertEq(gotProvider, provider);
        assertEq(amount, 1 ether);
        assertFalse(refunded);
        assertEq(address(escrow).balance, 1 ether, "payment was not held");
    }

    function test_emits_the_event_the_settlement_contract_reads() public {
        vm.expectEmit(false, true, true, true, address(escrow));
        emit JobCreated(bytes32(0), payer, provider, 1 ether, MEASUREMENT, keccak256("model"), keccak256("input"), keccak256(""), uint64(block.timestamp + 1 days));
        _create(1 ether);
    }

    /// @notice A job that accepts any enclave is not a job this rail can settle meaningfully.
    function test_rejects_a_job_with_no_enclave_requirement() public {
        vm.prank(payer);
        vm.expectRevert(ComputeJobEscrow.ZeroMeasurement.selector);
        escrow.createJob{value: 1 ether}(provider, bytes32(0), keccak256("model"), keccak256("input"));
    }

    function test_rejects_an_unpaid_job() public {
        vm.prank(payer);
        vm.expectRevert(ComputeJobEscrow.ZeroPayment.selector);
        escrow.createJob{value: 0}(provider, MEASUREMENT, keccak256("model"), keccak256("input"));
    }

    /// @notice The sealed applicant record rides behind the arguments, where the ABI decoder
    /// ignores it. This is the whole premise of carrying encrypted input inside the payment
    /// without changing the contract, so it is pinned here against the compiled decoder rather
    /// than assumed from the ABI specification.
    function test_accepts_a_sealed_record_appended_after_the_arguments() public {
        bytes memory envelope = hex"01"; // version byte, then whatever the buyer sealed
        for (uint256 i = 0; i < 90; i++) envelope = abi.encodePacked(envelope, bytes1(uint8(i)));
        bytes memory data = abi.encodePacked(
            abi.encodeCall(escrow.createJob, (provider, MEASUREMENT, keccak256("model"), keccak256("input"))),
            envelope,
            uint32(envelope.length),
            bytes4("PSE1")
        );
        vm.expectEmit(false, true, true, true, address(escrow));
        emit JobCreated(bytes32(0), payer, provider, 1 ether, MEASUREMENT, keccak256("model"), keccak256("input"), keccak256(envelope), uint64(block.timestamp + 1 days));
        vm.prank(payer);
        (bool ok, bytes memory ret) = address(escrow).call{value: 1 ether}(data);
        assertTrue(ok, "the decoder rejected trailing calldata");
        assertEq(ret.length, 32, "createJob should still return the job id");
        assertEq(address(escrow).balance, 1 ether, "payment was not held");
    }

    function test_job_ids_are_unique_across_repeat_calls() public {
        bytes32 a = _create(1 ether);
        bytes32 b = _create(1 ether);
        assertTrue(a != b, "nonce is not making job ids unique");
    }

    function test_refund_is_refused_before_the_delay() public {
        bytes32 jobId = _create(1 ether);

        // Read the delay before arming anything. `vm.prank` applies to the next call, and
        // `escrow.REFUND_DELAY()` is a call, so computing the expected value inline consumed the
        // prank and the refund arrived from the test contract instead of the payer. The test then
        // reverted with NotPayer and looked like a contract bug.
        uint64 availableAt = uint64(block.timestamp) + escrow.REFUND_DELAY();

        vm.expectRevert(abi.encodeWithSelector(ComputeJobEscrow.RefundTooEarly.selector, availableAt));
        vm.prank(payer);
        escrow.refund(jobId);
    }

    function test_refund_after_the_delay_returns_the_payment() public {
        bytes32 jobId = _create(1 ether);
        uint256 before = payer.balance;

        vm.warp(block.timestamp + escrow.REFUND_DELAY() + 1);
        vm.prank(payer);
        escrow.refund(jobId);

        assertEq(payer.balance, before + 1 ether, "refund did not arrive");
    }

    function test_refund_cannot_be_taken_twice() public {
        bytes32 jobId = _create(1 ether);
        vm.warp(block.timestamp + escrow.REFUND_DELAY() + 1);

        vm.prank(payer);
        escrow.refund(jobId);

        vm.prank(payer);
        vm.expectRevert(ComputeJobEscrow.AlreadyRefunded.selector);
        escrow.refund(jobId);
    }

    function test_only_the_payer_can_refund() public {
        bytes32 jobId = _create(1 ether);
        vm.warp(block.timestamp + escrow.REFUND_DELAY() + 1);

        vm.prank(provider);
        vm.expectRevert(ComputeJobEscrow.NotPayer.selector);
        escrow.refund(jobId);
    }

    function test_only_the_fixed_relayer_can_finalize() public {
        bytes32 id = _create(1 ether);
        vm.prank(provider);
        vm.expectRevert(ComputeJobEscrow.NotSettlementRelayer.selector);
        escrow.finalize(id, 1 ether, 0);
    }
    function test_return_split_must_equal_the_locked_payment() public {
        bytes32 id = _create(1 ether);
        vm.expectRevert(ComputeJobEscrow.InvalidSplit.selector);
        escrow.finalize(id, 1 ether, 1);
    }
    function test_accepted_payment_reaches_provider_exactly_once() public {
        bytes32 id = _create(1 ether);
        escrow.finalize(id, 1 ether, 0);
        uint256 before = provider.balance;
        vm.prank(makeAddr("anyone"));
        escrow.withdrawFor(provider);
        assertEq(provider.balance - before, 1 ether);
        vm.expectRevert(ComputeJobEscrow.AlreadyFinalized.selector);
        escrow.finalize(id, 1 ether, 0);
        vm.expectRevert(ComputeJobEscrow.NothingToWithdraw.selector);
        escrow.withdrawFor(provider);
    }
    function test_rejected_payment_reaches_buyer() public {
        bytes32 id = _create(1 ether);
        escrow.finalize(id, 0, 1 ether);
        uint256 before = payer.balance;
        escrow.withdrawFor(payer);
        assertEq(payer.balance - before, 1 ether);
    }
    function test_partial_payment_conserves_eth() public {
        bytes32 id = _create(1 ether);
        escrow.finalize(id, 0.7 ether, 0.3 ether);
        uint256 p = provider.balance; uint256 b = payer.balance;
        escrow.withdrawFor(provider); escrow.withdrawFor(payer);
        assertEq(provider.balance - p, 0.7 ether);
        assertEq(payer.balance - b, 0.3 ether);
        assertEq(address(escrow).balance, 0);
    }
    function test_finalized_job_cannot_take_timeout_refund() public {
        bytes32 id = _create(1 ether);
        escrow.finalize(id, 1 ether, 0);
        vm.warp(block.timestamp + 31 days);
        vm.prank(payer);
        vm.expectRevert(ComputeJobEscrow.AlreadyFinalized.selector);
        escrow.refund(id);
    }
    function test_timeout_refunded_job_cannot_be_released_again() public {
        bytes32 id = _create(1 ether);
        vm.warp(block.timestamp + 31 days);
        vm.prank(payer); escrow.refund(id);
        vm.expectRevert(ComputeJobEscrow.AlreadyRefunded.selector);
        escrow.finalize(id, 1 ether, 0);
    }
}

contract EnclaveRegistryTest is Test {
    EnclaveRegistry registry;

    address registrar = makeAddr("registrar");
    address outsider = makeAddr("outsider");
    address enclave = makeAddr("enclave");
    address otherEnclave = makeAddr("otherEnclave");

    bytes32 constant MEASUREMENT = keccak256("build-v1");
    bytes32 constant EVIDENCE = keccak256("attestation-doc");

    function setUp() public {
        registry = new EnclaveRegistry(registrar);
    }

    function _register() internal {
        vm.prank(registrar);
        registry.register(MEASUREMENT, enclave, EVIDENCE, "https://example.invalid/e.json");
    }

    function test_registers_and_answers_the_settlement_question() public {
        _register();
        assertTrue(registry.isActiveSigner(MEASUREMENT, enclave));
        assertEq(registry.measurementOf(enclave), MEASUREMENT);
    }

    function test_a_stranger_cannot_register() public {
        vm.prank(outsider);
        vm.expectRevert(EnclaveRegistry.NotRegistrar.selector);
        registry.register(MEASUREMENT, enclave, EVIDENCE, "x");
    }

    function test_evidence_is_mandatory() public {
        vm.prank(registrar);
        vm.expectRevert(EnclaveRegistry.ZeroEvidenceHash.selector);
        registry.register(MEASUREMENT, enclave, bytes32(0), "x");
    }

    /// @notice One key must not stand for two builds, or the measurement stops meaning anything.
    function test_a_key_cannot_be_bound_to_two_measurements() public {
        _register();
        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(EnclaveRegistry.SigningKeyAlreadyBound.selector, enclave, MEASUREMENT)
        );
        registry.register(keccak256("build-v2"), enclave, EVIDENCE, "x");
    }

    function test_a_measurement_cannot_be_rebound_to_a_new_key() public {
        _register();
        vm.prank(registrar);
        vm.expectRevert(
            abi.encodeWithSelector(EnclaveRegistry.MeasurementAlreadyRegistered.selector, MEASUREMENT)
        );
        registry.register(MEASUREMENT, otherEnclave, EVIDENCE, "x");
    }

    function test_revocation_takes_effect_immediately() public {
        _register();
        assertTrue(registry.isActiveSigner(MEASUREMENT, enclave));

        vm.prank(registrar);
        registry.revoke(MEASUREMENT, "key rotated");

        assertFalse(registry.isActiveSigner(MEASUREMENT, enclave), "revoked enclave still active");
    }

    /// @notice The record survives revocation so that what was once trusted stays auditable.
    function test_revoked_records_are_kept_not_deleted() public {
        _register();
        vm.prank(registrar);
        registry.revoke(MEASUREMENT, "key rotated");

        EnclaveRegistry.Enclave memory e = registry.enclaveOf(MEASUREMENT);
        assertEq(e.signingKey, enclave, "record was wiped");
        assertEq(e.evidenceHash, EVIDENCE, "evidence was wiped");
        assertTrue(e.revokedAt != 0);
    }

    function test_a_stranger_cannot_revoke() public {
        _register();
        vm.prank(outsider);
        vm.expectRevert(EnclaveRegistry.NotRegistrar.selector);
        registry.revoke(MEASUREMENT, "nice try");
    }

    function test_unknown_signer_is_never_active() public view {
        assertFalse(registry.isActiveSigner(MEASUREMENT, enclave));
        assertFalse(registry.isActiveSigner(bytes32(0), address(0)));
    }
}
