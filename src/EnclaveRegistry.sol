// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title EnclaveRegistry
/// @notice Binds a TEE build measurement to the secp256k1 key that enclave signs results with.
/// Deployed on Creditcoin.
///
/// @dev THE TRUST BOUNDARY, STATED UP FRONT.
///
/// This contract does NOT verify a hardware attestation. Verifying an AMD SEV or Google
/// Confidential Space attestation means walking an X.509 chain and doing RSA against a vendor's
/// key distribution service. That is not feasible in the EVM at any sane gas price, and a
/// contract that claims to do it is worth reading very carefully.
///
/// What this contract does instead is narrower and honest:
///
///   1. It records the binding: measurement -> signing key.
///   2. It records a content hash of the attestation document that justifies the binding, plus a
///      pointer to where that document can be fetched in full.
///   3. It makes the binding, and the evidence for it, world-readable so that anybody can
///      recompute the verdict off-chain and disagree with the registrar in public.
///
/// So the settlement contract enforces the BINDING, not the attestation. The distinction matters:
/// it proves the key that signed a result is the key this registry says belongs to the build the
/// buyer demanded. Whether the registrar was right to make that binding is checkable by anyone
/// holding the evidence hash, and is not taken on trust from a README.
contract EnclaveRegistry {
    struct Enclave {
        bytes32 measurement;
        address signingKey;
        bytes32 evidenceHash;
        string evidenceUri;
        uint64 registeredAt;
        uint64 revokedAt;
    }

    event EnclaveRegistered(
        bytes32 indexed measurement, address indexed signingKey, bytes32 evidenceHash, string evidenceUri
    );
    event EnclaveRevoked(bytes32 indexed measurement, address indexed signingKey, string reason);
    event RegistrarTransferred(address indexed from, address indexed to);

    /// @notice measurement => enclave record
    mapping(bytes32 => Enclave) private _byMeasurement;
    /// @notice signing key => measurement it is bound to
    mapping(address => bytes32) private _measurementOf;

    address public registrar;

    error NotRegistrar();
    error ZeroMeasurement();
    error ZeroSigningKey();
    error ZeroEvidenceHash();
    error MeasurementAlreadyRegistered(bytes32 measurement);
    error SigningKeyAlreadyBound(address signingKey, bytes32 measurement);
    error UnknownMeasurement(bytes32 measurement);
    error AlreadyRevoked(bytes32 measurement);
    error ZeroAddress();

    modifier onlyRegistrar() {
        if (msg.sender != registrar) revert NotRegistrar();
        _;
    }

    constructor(address initialRegistrar) {
        if (initialRegistrar == address(0)) revert ZeroAddress();
        registrar = initialRegistrar;
        emit RegistrarTransferred(address(0), initialRegistrar);
    }

    /// @notice Bind a measurement to the key the enclave signs with, and publish the evidence.
    /// @param measurement The enclave build measurement, as reported by the attestation
    /// @param signingKey The address of the secp256k1 key the enclave holds
    /// @param evidenceHash keccak256 of the full attestation document
    /// @param evidenceUri Where that document can be fetched and checked independently
    function register(bytes32 measurement, address signingKey, bytes32 evidenceHash, string calldata evidenceUri)
        external
        onlyRegistrar
    {
        if (measurement == bytes32(0)) revert ZeroMeasurement();
        if (signingKey == address(0)) revert ZeroSigningKey();
        if (evidenceHash == bytes32(0)) revert ZeroEvidenceHash();
        if (_byMeasurement[measurement].signingKey != address(0)) revert MeasurementAlreadyRegistered(measurement);

        bytes32 existing = _measurementOf[signingKey];
        if (existing != bytes32(0)) revert SigningKeyAlreadyBound(signingKey, existing);

        _byMeasurement[measurement] = Enclave({
            measurement: measurement,
            signingKey: signingKey,
            evidenceHash: evidenceHash,
            evidenceUri: evidenceUri,
            registeredAt: uint64(block.timestamp),
            revokedAt: 0
        });
        _measurementOf[signingKey] = measurement;

        emit EnclaveRegistered(measurement, signingKey, evidenceHash, evidenceUri);
    }

    /// @notice Withdraw a binding. Revocation is permanent and the measurement cannot be re-registered.
    /// @dev A revoked enclave must fail settlement immediately, which is why `isActiveSigner` reads
    /// `revokedAt` rather than deleting the record. Keeping the record means the history of what was
    /// once trusted stays auditable.
    function revoke(bytes32 measurement, string calldata reason) external onlyRegistrar {
        Enclave storage e = _byMeasurement[measurement];
        if (e.signingKey == address(0)) revert UnknownMeasurement(measurement);
        if (e.revokedAt != 0) revert AlreadyRevoked(measurement);

        e.revokedAt = uint64(block.timestamp);
        emit EnclaveRevoked(measurement, e.signingKey, reason);
    }

    function transferRegistrar(address to) external onlyRegistrar {
        if (to == address(0)) revert ZeroAddress();
        emit RegistrarTransferred(registrar, to);
        registrar = to;
    }

    /// @notice The question the settlement contract actually asks.
    /// @return True only if `signer` is the live, unrevoked key bound to `measurement`.
    function isActiveSigner(bytes32 measurement, address signer) external view returns (bool) {
        Enclave storage e = _byMeasurement[measurement];
        return e.signingKey != address(0) && e.signingKey == signer && e.revokedAt == 0;
    }

    function enclaveOf(bytes32 measurement) external view returns (Enclave memory) {
        return _byMeasurement[measurement];
    }

    function measurementOf(address signingKey) external view returns (bytes32) {
        return _measurementOf[signingKey];
    }
}
