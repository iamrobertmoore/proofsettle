// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {ComputeJobEscrow} from "../src/ComputeJobEscrow.sol";
import {EnclaveRegistry} from "../src/EnclaveRegistry.sol";
import {ComputeCredit} from "../src/ComputeCredit.sol";
import {ComputeSettlement} from "../src/ComputeSettlement.sol";

/// @notice Deploys the Sepolia half. Run this first: the Creditcoin half needs its address.
/// @dev forge script script/Deploy.s.sol:DeploySepolia --rpc-url $SOURCE_CHAIN_RPC_URL --broadcast
contract DeploySepolia is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        ComputeJobEscrow escrow = new ComputeJobEscrow();

        vm.stopBroadcast();

        console.log("");
        console.log("=== SEPOLIA ===");
        console.log("ComputeJobEscrow:", address(escrow));
        console.log("");
        console.log("Put this in .env as SOURCE_ESCROW_ADDRESS, then deploy the Creditcoin half.");
    }
}

/// @notice Deploys the Creditcoin half and wires it up.
/// @dev The EvmV1Decoder library must be deployed first and linked, because it exposes public
/// functions. DEPLOY.md carries the exact two-step invocation including the library link flag.
contract DeployCreditcoin is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address sourceEscrow = vm.envAddress("SOURCE_ESCROW_ADDRESS");
        uint64 chainKey = uint64(vm.envOr("SOURCE_CHAIN_KEY", uint256(1)));
        address registrar = vm.envOr("REGISTRAR_ADDRESS", vm.addr(pk));

        require(sourceEscrow != address(0), "SOURCE_ESCROW_ADDRESS not set");

        vm.startBroadcast(pk);

        EnclaveRegistry registry = new EnclaveRegistry(registrar);
        ComputeCredit credit = new ComputeCredit();
        ComputeSettlement settlement =
            new ComputeSettlement(chainKey, address(registry), address(credit), sourceEscrow);

        // Single shot and irreversible. After this nothing but the settlement contract can mint.
        credit.setMinter(address(settlement));

        vm.stopBroadcast();

        require(credit.minter() == address(settlement), "minter wiring failed");
        require(settlement.SOURCE_ESCROW() == sourceEscrow, "escrow wiring failed");
        require(settlement.SOURCE_CHAIN_KEY() == chainKey, "chain key wiring failed");

        console.log("");
        console.log("=== CREDITCOIN CC3 TESTNET ===");
        console.log("EnclaveRegistry  :", address(registry));
        console.log("ComputeCredit    :", address(credit));
        console.log("ComputeSettlement:", address(settlement));
        console.log("registrar        :", registrar);
        console.log("source escrow    :", sourceEscrow);
        console.log("source chain key :", chainKey);
        console.log("");
        console.log("Wiring verified on chain, not assumed.");
    }
}

/// @notice Registers an attested enclave build against its signing key.
/// @dev forge script script/Deploy.s.sol:RegisterEnclave --rpc-url $CREDITCOIN_RPC_URL --broadcast
contract RegisterEnclave is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        EnclaveRegistry registry = EnclaveRegistry(vm.envAddress("ENCLAVE_REGISTRY_ADDRESS"));
        bytes32 measurement = vm.envBytes32("ENCLAVE_MEASUREMENT");
        address signingKey = vm.envAddress("ENCLAVE_SIGNING_KEY");
        bytes32 evidenceHash = vm.envBytes32("ENCLAVE_EVIDENCE_HASH");
        string memory evidenceUri = vm.envString("ENCLAVE_EVIDENCE_URI");

        vm.startBroadcast(pk);
        registry.register(measurement, signingKey, evidenceHash, evidenceUri);
        vm.stopBroadcast();

        require(registry.isActiveSigner(measurement, signingKey), "registration did not take effect");

        console.log("");
        console.log("=== ENCLAVE REGISTERED ===");
        console.log("measurement :", vm.toString(measurement));
        console.log("signing key :", signingKey);
        console.log("evidence    :", evidenceUri);
        console.log("");
        console.log("isActiveSigner confirmed true by reading the registry back.");
    }
}
