// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EvmV1Decoder} from "@gluwa/usc-contracts/contracts/decoding/EvmV1Decoder.sol";

import {EncodedTx} from "./EncodedTx.sol";

/// @notice Checks the project's understanding of the prover's wire format against bytes the live
/// Attestcoin prover actually produced, rather than against a reading of the documentation.
///
/// @dev The fixture is the `txBytes` field of a real proof for Sepolia transaction
/// `0x1187283d…dfcf` at block 11,535,171, fetched from
/// `prover.cc3-testnet.creditcoin.network` on 22 August 2026. It is a token burn made by an
/// unrelated third party against the tutorial's ERC20 on Sepolia.
///
/// Two things are being defended here.
///
/// The first is the synthetic transaction builder used by the settlement tests. If Gluwa change
/// the encoding, `EncodedTx` becomes a fiction and every settlement test would keep passing
/// against a format that no longer exists. This test decodes real bytes through the same decoder
/// the contract uses, so drift shows up as a failure rather than as silence.
///
/// The second is the decoding logic in `ComputeSettlement` itself: pulling a specific event out of
/// a receipt by signature, reading indexed values from topics and the rest from data. If that
/// works on somebody else's real transaction, it will work on ours.
contract RealOracleBytesTest is Test {
    /// @dev keccak256("TokensBurnedForBridging(address,uint256)"), the event in the fixture.
    bytes32 constant BURN_SIG = 0x17dc4d6f69d484e59be774c29b47d2fa4c14af2e01df42fc5643ac968f4d427e;

    /// @dev The tutorial's ERC20 on Sepolia, which emitted the event in the fixture.
    address constant SEPOLIA_BURNER = 0x0F24FD9e0524BA53d3f0A4A40350Adf5370b4A53;

    bytes internal realTxBytes;

    function setUp() public {
        string memory hexStr = vm.readFile("test/fixtures/sepolia-burn-txbytes.hex");
        realTxBytes = vm.parseBytes(hexStr);
    }

    function test_fixture_is_a_real_transaction_of_a_supported_type() public view {
        assertGt(realTxBytes.length, 1000, "fixture looks truncated");

        uint8 txType = EvmV1Decoder.getTransactionType(realTxBytes);
        assertTrue(EvmV1Decoder.isValidTransactionType(txType), "prover produced an unsupported tx type");
    }

    function test_decodes_the_receipt_from_real_prover_bytes() public view {
        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(realTxBytes);

        assertEq(receipt.receiptStatus, 1, "the fixture transaction should have succeeded");
        assertGt(receipt.receiptLogs.length, 0, "no logs decoded from a transaction that emitted one");
    }

    function test_finds_a_specific_event_by_signature_in_real_bytes() public view {
        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(realTxBytes);
        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(receipt, BURN_SIG);

        assertEq(logs.length, 1, "expected exactly one burn event in the fixture");
        assertEq(logs[0].address_, SEPOLIA_BURNER, "burn event came from an unexpected contract");
        assertEq(logs[0].topics.length, 2, "burn event should carry signature plus one indexed arg");
        assertEq(logs[0].data.length, 32, "burn event data should be a single uint256");

        uint256 amount = abi.decode(logs[0].data, (uint256));
        assertEq(amount, 50 ether, "the fixture burn was 50 tokens");
    }

    /// @notice The builder used by the settlement tests must round trip through the same decoder.
    /// @dev This is what keeps the synthetic tests honest. Both this and the real fixture above go
    /// through `EvmV1Decoder`, so the builder cannot drift away from the format without one of them
    /// noticing.
    function test_synthetic_builder_agrees_with_the_decoder() public pure {
        bytes32[] memory topics = new bytes32[](2);
        topics[0] = BURN_SIG;
        topics[1] = bytes32(uint256(uint160(address(0xABCD))));

        EncodedTx.Log memory log =
            EncodedTx.Log({emitter: SEPOLIA_BURNER, topics: topics, data: abi.encode(uint256(50 ether))});
        bytes memory built = EncodedTx.buildWithOneLog(1, log);

        assertEq(EvmV1Decoder.getTransactionType(built), 2, "builder should produce a type 2 transaction");

        EvmV1Decoder.ReceiptFields memory receipt = EvmV1Decoder.decodeReceiptFields(built);
        assertEq(receipt.receiptStatus, 1);

        EvmV1Decoder.LogEntry[] memory logs = EvmV1Decoder.getLogsByEventSignature(receipt, BURN_SIG);
        assertEq(logs.length, 1);
        assertEq(abi.decode(logs[0].data, (uint256)), 50 ether);
    }
}
