// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ComputeJobEscrow} from "../src/ComputeJobEscrow.sol";
import {ComputeSettlement} from "../src/ComputeSettlement.sol";
import {ComputeCredit} from "../src/ComputeCredit.sol";
import {EnclaveRegistry} from "../src/EnclaveRegistry.sol";
import {AttestcoinProven} from "../src/AttestcoinProven.sol";
import {IAttestcoinVerifier} from "../src/interfaces/IAttestcoinVerifier.sol";

import {EncodedTx} from "./EncodedTx.sol";
import {MockAttestcoinVerifier} from "./MockAttestcoinVerifier.sol";

/// @notice Settlement tests. Every test that asserts success has a paired test that removes one
/// ingredient and asserts failure, because a suite that only proves the happy path proves nothing
/// about the guarantee this contract is supposed to make.
contract ComputeSettlementTest is Test {
    address constant VERIFIER_PRECOMPILE = 0x0000000000000000000000000000000000000FD2;
    uint64 constant SEPOLIA_CHAIN_KEY = 1;

    ComputeSettlement settlement;
    EnclaveRegistry registry;
    ComputeCredit credit;
    MockAttestcoinVerifier verifier;

    address registrar = makeAddr("registrar");
    address provider = makeAddr("provider");
    address payer = makeAddr("payer");
    address sourceEscrow = makeAddr("sourceEscrow");

    bytes32 constant MEASUREMENT = keccak256("enclave-build-v1");
    bytes32 constant OTHER_MEASUREMENT = keccak256("enclave-build-v2");
    bytes32 constant JOB_ID = keccak256("job-1");
    bytes32 constant RESULT_HASH = keccak256("the-inference-output");
    uint256 constant AMOUNT = 1 ether;

    uint256 enclaveKey;
    address enclave;
    uint256 impostorKey;
    address impostor;

    function setUp() public {
        (enclave, enclaveKey) = makeAddrAndKey("enclave");
        (impostor, impostorKey) = makeAddrAndKey("impostor");

        // The precompile does not exist locally, so put the mock at its address.
        MockAttestcoinVerifier impl = new MockAttestcoinVerifier();
        vm.etch(VERIFIER_PRECOMPILE, address(impl).code);
        verifier = MockAttestcoinVerifier(VERIFIER_PRECOMPILE);
        verifier.setAccept(true);

        registry = new EnclaveRegistry(registrar);
        credit = new ComputeCredit();
        settlement = new ComputeSettlement(SEPOLIA_CHAIN_KEY, address(registry), address(credit), sourceEscrow);
        credit.setMinter(address(settlement));

        vm.prank(registrar);
        registry.register(MEASUREMENT, enclave, keccak256("attestation-doc"), "https://example.invalid/evidence.json");
    }

    // ------------------------------------------------------------------ helpers

    function _proofFor(bytes memory encodedTx)
        internal
        pure
        returns (IAttestcoinVerifier.MerkleProof memory mp, IAttestcoinVerifier.ContinuityProof memory cp)
    {
        encodedTx; // silence unused
        IAttestcoinVerifier.MerkleProofEntry[] memory sib = new IAttestcoinVerifier.MerkleProofEntry[](1);
        sib[0] = IAttestcoinVerifier.MerkleProofEntry({hash: keccak256("sibling"), isLeft: true});
        mp = IAttestcoinVerifier.MerkleProof({root: keccak256("merkle-root"), siblings: sib});

        bytes32[] memory roots = new bytes32[](1);
        roots[0] = keccak256("continuity-root");
        cp = IAttestcoinVerifier.ContinuityProof({lowerEndpointDigest: keccak256("lower"), roots: roots});
    }

    function _jobTx(address emitter, bytes32 measurement, uint8 receiptStatus) internal view returns (bytes memory) {
        EncodedTx.Log memory log = EncodedTx.jobCreatedLog(
            emitter,
            settlement.JOB_CREATED_SIG(),
            JOB_ID,
            payer,
            provider,
            AMOUNT,
            measurement,
            keccak256("model"),
            keccak256("input")
        );
        return EncodedTx.buildWithOneLog(receiptStatus, log);
    }

    function _sign(uint256 key, bytes32 jobId, bytes32 resultHash, ComputeSettlement.Outcome outcome, uint16 bps)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(key, settlement.resultDigest(jobId, resultHash, outcome, bps));
    }

    /// @dev Signature and proof are prepared as a separate step on purpose.
    ///
    /// `vm.expectRevert` arms the *next call*, and `resultDigest` is an external view call on the
    /// settlement contract. Building the signature inside the same helper that calls `settle` meant
    /// the expectation landed on `resultDigest` instead, and nine negative tests reported "next call
    /// did not revert as expected" while the contract was behaving correctly. Preparing first keeps
    /// `settle` as the very next call after the expectation is armed.
    struct Prepared {
        IAttestcoinVerifier.MerkleProof mp;
        IAttestcoinVerifier.ContinuityProof cp;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes encodedTx;
        ComputeSettlement.Outcome outcome;
        uint16 bps;
    }

    function _prepare(
        bytes memory encodedTx,
        uint256 signingKey,
        bytes32 resultHash,
        ComputeSettlement.Outcome outcome,
        uint16 bps
    ) internal view returns (Prepared memory p) {
        (p.mp, p.cp) = _proofFor(encodedTx);
        (p.v, p.r, p.s) = _sign(signingKey, JOB_ID, resultHash, outcome, bps);
        p.encodedTx = encodedTx;
        p.outcome = outcome;
        p.bps = bps;
    }

    function _prepare(bytes memory encodedTx, uint256 signingKey) internal view returns (Prepared memory) {
        return _prepare(encodedTx, signingKey, RESULT_HASH, ComputeSettlement.Outcome.Accepted, 0);
    }

    function _att(Prepared memory p) internal pure returns (ComputeSettlement.EnclaveAttestation memory) {
        return ComputeSettlement.EnclaveAttestation({
            resultHash: RESULT_HASH, outcome: p.outcome, scoreBps: p.bps, v: p.v, r: p.r, s: p.s
        });
    }

    function _call(Prepared memory p) internal returns (bytes32) {
        return settlement.settle(SEPOLIA_CHAIN_KEY, 11_535_171, p.encodedTx, p.mp, p.cp, _att(p));
    }

    function _settle(bytes memory encodedTx, uint256 signingKey) internal returns (bytes32) {
        return _call(_prepare(encodedTx, signingKey));
    }

    // ------------------------------------------------------------------ the happy path

    function test_settles_when_both_proofs_agree() public {
        bytes memory encodedTx = _jobTx(sourceEscrow, MEASUREMENT, 1);

        bytes32 jobId = _settle(encodedTx, enclaveKey);

        assertEq(jobId, JOB_ID, "settled the wrong job");
        assertEq(credit.balanceOf(provider), AMOUNT, "provider was not paid");
        assertEq(verifier.verifyCalls(), 1, "the oracle was not actually consulted");

        (, address gotProvider,, uint256 gotAmount, uint256 paid,,, address gotEnclave,,, uint64 settledAt) =
            settlement.settlements(JOB_ID);
        assertEq(gotProvider, provider);
        assertEq(gotAmount, AMOUNT);
        assertEq(paid, AMOUNT);
        assertEq(gotEnclave, enclave);
        assertTrue(settledAt != 0);
    }

    // ------------------------------------------------------------------ proof one must be real

    function test_reverts_when_the_oracle_rejects_the_proof() public {
        verifier.setRevertOnVerify(true);
        Prepared memory p = _prepare(_jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey);

        vm.expectRevert(bytes("Merkle proof validation failed"));
        _call(p);

        assertEq(credit.balanceOf(provider), 0, "paid out on a rejected proof");
    }

    function test_reverts_when_the_oracle_returns_false_without_reverting() public {
        verifier.setAccept(false);
        Prepared memory p = _prepare(_jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey);

        vm.expectRevert(AttestcoinProven.ProofRejected.selector);
        _call(p);

        assertEq(credit.balanceOf(provider), 0, "paid out on a false return");
    }

    function test_reverts_on_a_proof_from_the_wrong_source_chain() public {
        Prepared memory p = _prepare(_jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey);

        vm.expectRevert(abi.encodeWithSelector(AttestcoinProven.WrongSourceChain.selector, SEPOLIA_CHAIN_KEY, uint64(3)));
        settlement.settle(3, 11_535_171, p.encodedTx, p.mp, p.cp, _att(p));
    }

    function test_reverts_when_the_source_transaction_reverted() public {
        Prepared memory p = _prepare(_jobTx(sourceEscrow, MEASUREMENT, 0), enclaveKey);

        vm.expectRevert(abi.encodeWithSelector(ComputeSettlement.TransactionFailedOnSource.selector, uint8(0)));
        _call(p);
    }

    /// @notice The attack the emitter check exists to stop.
    /// @dev Anyone can deploy their own escrow, emit a perfectly well formed `JobCreated` naming
    /// themselves as provider for any amount, and get a genuine proof of it. The proof is real. The
    /// settlement would be theft. This is the single most important negative test in the suite.
    function test_reverts_when_the_event_came_from_an_impostor_escrow() public {
        address fakeEscrow = makeAddr("fakeEscrow");
        Prepared memory p = _prepare(_jobTx(fakeEscrow, MEASUREMENT, 1), enclaveKey);

        vm.expectRevert(abi.encodeWithSelector(ComputeSettlement.WrongEmitter.selector, sourceEscrow, fakeEscrow));
        _call(p);

        assertEq(credit.balanceOf(provider), 0, "paid out on a forged escrow");
    }

    function test_reverts_when_there_is_no_job_created_event() public {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = keccak256("SomethingElse(uint256)");
        EncodedTx.Log memory log =
            EncodedTx.Log({emitter: sourceEscrow, topics: topics, data: abi.encode(uint256(1))});
        Prepared memory p = _prepare(EncodedTx.buildWithOneLog(1, log), enclaveKey);

        vm.expectRevert(ComputeSettlement.NoJobCreatedEvent.selector);
        _call(p);
    }

    // ------------------------------------------------------------------ proof two must be real

    function test_reverts_when_an_unregistered_key_signed_the_result() public {
        Prepared memory p = _prepare(_jobTx(sourceEscrow, MEASUREMENT, 1), impostorKey);

        vm.expectRevert(
            abi.encodeWithSelector(ComputeSettlement.EnclaveNotAccepted.selector, MEASUREMENT, impostor)
        );
        _call(p);

        assertEq(credit.balanceOf(provider), 0, "paid out on an unregistered signature");
    }

    /// @notice The buyer's policy is what binds, not the registry's contents.
    /// @dev The enclave here is genuinely registered and its signature is genuinely valid. It is
    /// simply not the build the buyer said they would accept. That must not settle.
    function test_reverts_when_a_valid_enclave_is_not_the_one_the_buyer_demanded() public {
        Prepared memory p = _prepare(_jobTx(sourceEscrow, OTHER_MEASUREMENT, 1), enclaveKey);

        vm.expectRevert(
            abi.encodeWithSelector(ComputeSettlement.EnclaveNotAccepted.selector, OTHER_MEASUREMENT, enclave)
        );
        _call(p);
    }

    function test_reverts_after_the_enclave_is_revoked() public {
        vm.prank(registrar);
        registry.revoke(MEASUREMENT, "key rotated out of the enclave");

        Prepared memory p = _prepare(_jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey);

        vm.expectRevert(abi.encodeWithSelector(ComputeSettlement.EnclaveNotAccepted.selector, MEASUREMENT, enclave));
        _call(p);
    }

    function test_reverts_on_a_malleable_signature() public {
        Prepared memory p = _prepare(_jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey);

        // Flip the signature into the upper half of the curve, the classic malleability trick.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 flippedS = bytes32(n - uint256(p.s));
        uint8 flippedV = p.v == 27 ? 28 : 27;

        vm.expectRevert(ComputeSettlement.BadSignatureS.selector);
        ComputeSettlement.EnclaveAttestation memory bad = _att(p);
        bad.v = flippedV;
        bad.s = flippedS;
        settlement.settle(SEPOLIA_CHAIN_KEY, 11_535_171, p.encodedTx, p.mp, p.cp, bad);
    }

    function test_reverts_on_a_signature_over_a_different_result() public {
        // The enclave signed a different output than the one being claimed, so recovery yields
        // some unrelated address rather than the enclave. Asserting only the selector, because the
        // recovered address is whatever the curve produces and pinning it would test nothing.
        Prepared memory p = _prepare(
            _jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey, keccak256("a-different-output"),
            ComputeSettlement.Outcome.Accepted, 0
        );

        vm.expectPartialRevert(ComputeSettlement.EnclaveNotAccepted.selector);
        _call(p);
    }

    // ------------------------------------------------------------------ the verdict decides

    /// @notice A rejected job must return the buyer's claim, not pay the provider.
    /// @dev This is the AI output executing an on-chain decision. If the enclave says the job
    /// failed, the money goes back, and nobody had to trust the provider's account of it.
    function test_rejected_job_returns_the_claim_to_the_payer() public {
        Prepared memory p = _prepare(
            _jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey, RESULT_HASH, ComputeSettlement.Outcome.Rejected, 0
        );
        _call(p);

        assertEq(credit.balanceOf(provider), 0, "provider was paid for a rejected job");
        assertEq(credit.balanceOf(payer), AMOUNT, "payer did not get their claim back");
    }

    function test_partial_outcome_splits_by_score() public {
        Prepared memory p = _prepare(
            _jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey, RESULT_HASH, ComputeSettlement.Outcome.Partial, 2500
        );
        _call(p);

        assertEq(credit.balanceOf(provider), (AMOUNT * 2500) / 10_000, "provider share wrong");
        assertEq(credit.balanceOf(payer), AMOUNT - (AMOUNT * 2500) / 10_000, "payer share wrong");
        assertEq(
            credit.balanceOf(provider) + credit.balanceOf(payer), AMOUNT, "split does not conserve the amount"
        );
    }

    /// @notice The whole point of putting the verdict inside the signature.
    /// @dev A provider who received a Rejected verdict must not be able to submit it as Accepted.
    /// The signature is over the verdict, so swapping it makes recovery yield a different address
    /// and the registry check fails.
    function test_provider_cannot_upgrade_the_enclave_verdict() public {
        // The enclave signed Rejected.
        Prepared memory p = _prepare(
            _jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey, RESULT_HASH, ComputeSettlement.Outcome.Rejected, 0
        );

        // The provider submits the same signature claiming Accepted.
        ComputeSettlement.EnclaveAttestation memory forged = _att(p);
        forged.outcome = ComputeSettlement.Outcome.Accepted;

        vm.expectPartialRevert(ComputeSettlement.EnclaveNotAccepted.selector);
        settlement.settle(SEPOLIA_CHAIN_KEY, 11_535_171, p.encodedTx, p.mp, p.cp, forged);

        assertEq(credit.balanceOf(provider), 0, "forged verdict paid out");
    }

    function test_provider_cannot_inflate_the_partial_score() public {
        Prepared memory p = _prepare(
            _jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey, RESULT_HASH, ComputeSettlement.Outcome.Partial, 1000
        );

        ComputeSettlement.EnclaveAttestation memory forged = _att(p);
        forged.scoreBps = 9500;

        vm.expectPartialRevert(ComputeSettlement.EnclaveNotAccepted.selector);
        settlement.settle(SEPOLIA_CHAIN_KEY, 11_535_171, p.encodedTx, p.mp, p.cp, forged);
    }

    function test_rejects_a_score_above_one_hundred_percent() public {
        Prepared memory p = _prepare(
            _jobTx(sourceEscrow, MEASUREMENT, 1), enclaveKey, RESULT_HASH, ComputeSettlement.Outcome.Partial, 10_001
        );

        vm.expectRevert(abi.encodeWithSelector(ComputeSettlement.ScoreOutOfRange.selector, uint16(10_001)));
        _call(p);
    }

    function test_split_is_publicly_checkable_and_conserves_value(uint256 amount, uint16 bps) public view {
        amount = bound(amount, 0, type(uint128).max);
        bps = uint16(bound(bps, 0, 10_000));

        (uint256 a, uint256 b) = settlement.splitFor(amount, ComputeSettlement.Outcome.Partial, bps);
        assertEq(a + b, amount, "partial split lost or created value");

        (a, b) = settlement.splitFor(amount, ComputeSettlement.Outcome.Accepted, bps);
        assertEq(a, amount);
        assertEq(b, 0);

        (a, b) = settlement.splitFor(amount, ComputeSettlement.Outcome.Rejected, bps);
        assertEq(a, 0);
        assertEq(b, amount);
    }

    // ------------------------------------------------------------------ replay

    function test_reverts_when_the_same_proof_is_replayed() public {
        bytes memory encodedTx = _jobTx(sourceEscrow, MEASUREMENT, 1);
        _settle(encodedTx, enclaveKey);

        Prepared memory p = _prepare(encodedTx, enclaveKey);
        vm.expectPartialRevert(AttestcoinProven.QueryAlreadyConsumed.selector);
        _call(p);

        assertEq(credit.balanceOf(provider), AMOUNT, "double paid on replay");
    }

    // ------------------------------------------------------------------ wiring

    /// @notice The hand-written event signature constant must match the real escrow's ABI.
    /// @dev A wrong constant would make every settlement revert with NoJobCreatedEvent, which is
    /// safe but useless, and it is exactly the kind of thing that gets noticed late.
    function test_event_signature_constant_matches_the_deployed_escrow() public view {
        assertEq(
            settlement.JOB_CREATED_SIG(),
            keccak256("JobCreated(bytes32,address,address,uint256,bytes32,bytes32,bytes32)"),
            "JOB_CREATED_SIG drifted from the escrow event"
        );
    }

    function test_credit_cannot_be_minted_by_anyone_else() public {
        vm.expectRevert(ComputeCredit.NotMinter.selector);
        vm.prank(provider);
        credit.mint(provider, 1 ether);
    }

    function test_minter_can_only_be_set_once() public {
        vm.expectRevert(ComputeCredit.MinterAlreadySet.selector);
        credit.setMinter(address(0xdead));
    }
}
