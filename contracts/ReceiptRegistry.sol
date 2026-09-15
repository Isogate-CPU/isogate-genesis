// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "./ContractPrimitives.sol";

/// @title ReceiptRegistry
/// @notice Records compact, content-addressed result receipts for completed jobs.
/// @dev Deliberately stores no trace, log, or other large payload.
contract ReceiptRegistry is RoleManaged, Pausable {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant RECEIPT_HASH_DOMAIN =
        keccak256("IsogateReceiptRegistry:Receipt:v1");

    struct Receipt {
        bytes32 resultDigest;
        bytes32 receiptHash;
        address provider;
        uint64 acceptedAt;
        uint32 version;
    }

    mapping(bytes32 jobId => Receipt) public receipts;

    error JobIdZero();
    error ReceiptAlreadyExists(bytes32 jobId);
    error ReceiptNotFound(bytes32 jobId);
    error DigestZero();
    error ReceiptHashMismatch(bytes32 expected, bytes32 provided);
    error ProviderZero();
    error VersionZero();

    event ReceiptIssued(
        bytes32 indexed jobId,
        bytes32 indexed resultDigest,
        bytes32 indexed receiptHash,
        address provider,
        uint64 acceptedAt,
        uint32 version
    );

    constructor(address initialAdmin) RoleManaged(initialAdmin) {
        _grantRole(ISSUER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    /// @notice Pauses receipt issuance.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes receipt issuance.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Issues one compact receipt for a job ID.
    function issueReceipt(
        bytes32 jobId,
        bytes32 resultDigest,
        bytes32 receiptHash,
        address provider,
        uint32 version
    ) external whenNotPaused onlyRole(ISSUER_ROLE) {
        if (jobId == bytes32(0)) revert JobIdZero();
        if (receipts[jobId].acceptedAt != 0) {
            revert ReceiptAlreadyExists(jobId);
        }
        if (resultDigest == bytes32(0)) revert DigestZero();
        if (provider == address(0)) revert ProviderZero();
        if (version == 0) revert VersionZero();

        uint64 acceptedAt = uint64(block.timestamp);
        bytes32 expectedReceiptHash = computeReceiptHash(
            jobId,
            resultDigest,
            provider,
            acceptedAt,
            version
        );
        if (receiptHash != expectedReceiptHash) {
            revert ReceiptHashMismatch(expectedReceiptHash, receiptHash);
        }
        receipts[jobId] = Receipt({
            resultDigest: resultDigest,
            receiptHash: expectedReceiptHash,
            provider: provider,
            acceptedAt: acceptedAt,
            version: version
        });
        emit ReceiptIssued(
            jobId,
            resultDigest,
            expectedReceiptHash,
            provider,
            acceptedAt,
            version
        );
    }

    /// @notice Derives the canonical content-addressed hash for a receipt.
    /// @dev The registry address and chain ID bind a receipt to this deployment
    ///      and prevent the same payload from being replayed across registries.
    function computeReceiptHash(
        bytes32 jobId,
        bytes32 resultDigest,
        address provider,
        uint64 acceptedAt,
        uint32 version
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                RECEIPT_HASH_DOMAIN,
                block.chainid,
                address(this),
                jobId,
                resultDigest,
                provider,
                acceptedAt,
                version
            )
        );
    }

    /// @notice Reads a compact receipt; no trace payload is returned or stored.
    function getReceipt(bytes32 jobId) external view returns (Receipt memory) {
        Receipt memory receipt = receipts[jobId];
        if (receipt.acceptedAt == 0) revert ReceiptNotFound(jobId);
        return receipt;
    }

    /// @notice Returns whether a job has an issued receipt.
    function hasReceipt(bytes32 jobId) external view returns (bool) {
        return receipts[jobId].acceptedAt != 0;
    }
}