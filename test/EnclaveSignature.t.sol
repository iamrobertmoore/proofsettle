// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {ComputeSettlement} from "../src/ComputeSettlement.sol";
import {ComputeCredit} from "../src/ComputeCredit.sol";
import {EnclaveRegistry} from "../src/EnclaveRegistry.sol";

/// @notice The cross-language check between the enclave and the chain.
///
/// @dev The enclave signs in JavaScript, with a hand-rolled keccak256 and a hand-rolled ABI
/// encoder, because it carries no runtime dependencies. The contract recomputes the same digest in
/// Solidity. Two independent implementations of one formula is exactly the situation where a
/// mismatch hides until it costs a live transaction.
///
/// The fixture is produced by `node enclave/make-fixture.mjs`, which boots the real enclave server
/// and records what it actually signed, including one job of each outcome so the verdict byte
/// inside the digest is exercised rather than assumed.
///
/// If this test fails, the enclave and the settlement contract disagree, and no amount of green
/// unit tests on either side would have told you.
contract EnclaveSignatureTest is Test {
    using stdJson for string;

    ComputeSettlement settlement;
    EnclaveRegistry registry;
    ComputeCredit credit;

    string fixture;
    address enclaveSigner;
    uint256 fixtureChainId;

    function setUp() public {
        fixture = vm.readFile("test/fixtures/enclave-signatures.json");
        enclaveSigner = fixture.readAddress(".signer");
        fixtureChainId = fixture.readUint(".chainId");

        // The digest binds chainid and the contract address, so both must match the fixture for
        // the signature to recover. Deploying to a deterministic address under the fixture's chain
        // id is what makes this test meaningful rather than tautological.
        vm.chainId(fixtureChainId);

        address target = fixture.readAddress(".settlement");
        registry = new EnclaveRegistry(address(this));
        credit = new ComputeCredit();

        ComputeSettlement impl = new ComputeSettlement(1, address(registry), address(credit), address(0xE5C0));
        vm.etch(target, address(impl).code);
        settlement = ComputeSettlement(target);

        registry.register(MEASUREMENT, enclaveSigner, keccak256("evidence"), "https://example.invalid/e.json");
    }

    bytes32 constant MEASUREMENT = keccak256("proofsettle-enclave-v1");

    function _job(uint256 i)
        internal
        view
        returns (bytes32 jobId, bytes32 resultHash, uint8 outcome, uint16 bps, uint8 v, bytes32 r, bytes32 s)
    {
        string memory base = string.concat(".jobs[", vm.toString(i), "]");
        jobId = fixture.readBytes32(string.concat(base, ".jobId"));
        resultHash = fixture.readBytes32(string.concat(base, ".resultHash"));
        outcome = uint8(fixture.readUint(string.concat(base, ".outcome")));
        bps = uint16(fixture.readUint(string.concat(base, ".scoreBps")));
        v = uint8(fixture.readUint(string.concat(base, ".v")));
        r = fixture.readBytes32(string.concat(base, ".r"));
        s = fixture.readBytes32(string.concat(base, ".s"));
    }

    /// @notice Every signature the real enclave produced must recover to the enclave's own address.
    function test_enclave_signatures_recover_to_the_enclave() public view {
        for (uint256 i = 0; i < 3; i++) {
            (bytes32 jobId, bytes32 resultHash, uint8 outcome, uint16 bps, uint8 v, bytes32 r, bytes32 s) = _job(i);

            bytes32 digest = settlement.resultDigest(jobId, resultHash, ComputeSettlement.Outcome(outcome), bps);
            address recovered = ecrecover(digest, v, r, s);

            assertEq(recovered, enclaveSigner, "enclave digest disagrees with the contract digest");
        }
    }

    /// @notice The registry accepts those signatures for the measurement they are bound to.
    function test_registry_accepts_the_enclave_for_its_measurement() public view {
        for (uint256 i = 0; i < 3; i++) {
            (bytes32 jobId, bytes32 resultHash, uint8 outcome, uint16 bps, uint8 v, bytes32 r, bytes32 s) = _job(i);
            address recovered =
                ecrecover(settlement.resultDigest(jobId, resultHash, ComputeSettlement.Outcome(outcome), bps), v, r, s);
            assertTrue(registry.isActiveSigner(MEASUREMENT, recovered), "registry rejected a real enclave signature");
        }
    }

    /// @notice Signatures are canonical, matching what the settlement contract enforces.
    /// @dev The enclave normalises s into the lower half of the curve itself. If it stopped doing
    /// that, every settlement would revert with BadSignatureS on chain and nowhere else.
    function test_enclave_signatures_are_canonical() public view {
        uint256 half = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint8 v, , bytes32 s) = _job(i);
            assertLe(uint256(s), half, "enclave produced a malleable signature the contract will reject");
            assertTrue(v == 27 || v == 28, "enclave produced an out of range recovery id");
        }
    }

    /// @notice Changing the verdict must break the signature.
    /// @dev This is the property the whole design rests on: a provider holding a Rejected
    /// signature must not be able to present it as Accepted.
    function test_altering_the_verdict_breaks_the_signature() public view {
        (bytes32 jobId, bytes32 resultHash, uint8 outcome, uint16 bps, uint8 v, bytes32 r, bytes32 s) = _job(0);

        address honest =
            ecrecover(settlement.resultDigest(jobId, resultHash, ComputeSettlement.Outcome(outcome), bps), v, r, s);
        assertEq(honest, enclaveSigner);

        uint8 tampered = outcome == 1 ? 0 : 1;
        address forged =
            ecrecover(settlement.resultDigest(jobId, resultHash, ComputeSettlement.Outcome(tampered), bps), v, r, s);

        assertTrue(forged != enclaveSigner, "the verdict is not actually bound into the signature");
        assertFalse(registry.isActiveSigner(MEASUREMENT, forged), "a tampered verdict still passed the registry");
    }

    /// @notice The fixture records whether it came from real hardware, and says so.
    /// @dev Not an assertion that it was attested, because during development it is not. The point
    /// is that the fixture cannot quietly imply hardware it never ran on.
    function test_fixture_states_its_attestation_status_honestly() public {
        bool attested = fixture.readBool(".attested");
        if (!attested) {
            emit log_string(
                "NOTE: this fixture was signed by a development enclave with no attestation token. "
                "It proves the crypto agrees, not that hardware was involved."
            );
        }
    }
}
