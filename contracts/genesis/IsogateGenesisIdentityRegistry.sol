// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Isogate Genesis Identity Registry
/// @notice Stores canonical token identities after off-chain Native Node
/// execution, exact server recomputation, and creator approval.
contract IsogateGenesisIdentityRegistry {
    string public constant PROTOCOL_NAME = "Isogate Genesis Identity";
    string public constant PROTOCOL_VERSION = "1";

    bytes32 public constant DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes32 public constant IDENTITY_PROOF_TYPEHASH =
        keccak256(
            "IdentityProof(bytes32 providerJobRef,bytes32 providerRef,address creator,address factory,address protocol,string name,string symbol,bytes32 descriptionHash,bytes32 engineHash,bytes32 seedHash,bytes32 cpuDigest,bytes32 imageDigest,string logoUri,uint256 expiry,uint256 nonce)"
        );

    struct IdentityProof {
        bytes32 providerJobRef;
        bytes32 providerRef;
        address creator;
        address factory;
        address protocol;
        string name;
        string symbol;
        bytes32 descriptionHash;
        bytes32 engineHash;
        bytes32 seedHash;
        bytes32 cpuDigest;
        bytes32 imageDigest;
        string logoUri;
        uint256 expiry;
        uint256 nonce;
    }

    struct Identity {
        address creator;
        address factory;
        address protocol;
        string name;
        string symbol;
        string logoUri;
        bytes32 providerJobRef;
        bytes32 providerRef;
        uint256 expiry;
        uint256 nonce;
        bool approved;
    }

    address public immutable verifier;
    mapping(bytes32 digest => Identity identity) private identities;
    mapping(bytes32 providerJobRef => bool consumed) public consumedProviderJobs;
    mapping(address creator => mapping(uint256 nonce => bool consumed))
        public consumedNonces;

    error ZeroAddress();
    error CreatorMismatch(address caller, address creator);
    error InvalidVerifierSignature(address recovered, address expected);
    error ProviderJobAlreadyConsumed(bytes32 providerJobRef);
    error NonceAlreadyConsumed(address creator, uint256 nonce);
    error IdentityAlreadyApproved(bytes32 genesisDigest);
    error AttestationExpired(uint256 expiry);
    error InvalidLogoUri();

    event IdentityApproved(
        bytes32 indexed genesisDigest,
        bytes32 indexed providerJobRef,
        address indexed creator,
        string name,
        string symbol,
        string logoUri
    );

    constructor(address verifier_) {
        if (verifier_ == address(0)) revert ZeroAddress();
        verifier = verifier_;
    }

    /// @notice Records one server-attested Native Node identity. The creator
    /// submits the transaction; the verifier signature commits to the exact
    /// EIP-712 domain, factory, protocol, job, metadata, seed, pixels, expiry,
    /// and nonce.
    function approveIdentity(
        IdentityProof calldata proof,
        bytes calldata verifierSignature
    ) external {
        if (
            proof.creator == address(0) ||
            proof.factory == address(0) ||
            proof.protocol == address(0)
        ) {
            revert ZeroAddress();
        }
        if (msg.sender != proof.creator) {
            revert CreatorMismatch(msg.sender, proof.creator);
        }
        if (proof.expiry < block.timestamp) {
            revert AttestationExpired(proof.expiry);
        }
        if (consumedProviderJobs[proof.providerJobRef]) {
            revert ProviderJobAlreadyConsumed(proof.providerJobRef);
        }
        if (consumedNonces[proof.creator][proof.nonce]) {
            revert NonceAlreadyConsumed(proof.creator, proof.nonce);
        }
        if (!_isCanonicalLogoUri(bytes(proof.logoUri))) {
            revert InvalidLogoUri();
        }

        bytes32 genesisDigest = identityDigest(proof);
        if (identities[genesisDigest].approved) {
            revert IdentityAlreadyApproved(genesisDigest);
        }
        address recovered = ECDSA.recover(
            MessageHashUtils.toTypedDataHash(_domainSeparatorV4(), _structHash(proof)),
            verifierSignature
        );
        if (recovered != verifier) {
            revert InvalidVerifierSignature(recovered, verifier);
        }

        identities[genesisDigest] = Identity({
            creator: proof.creator,
            factory: proof.factory,
            protocol: proof.protocol,
            name: proof.name,
            symbol: proof.symbol,
            logoUri: proof.logoUri,
            providerJobRef: proof.providerJobRef,
            providerRef: proof.providerRef,
            expiry: proof.expiry,
            nonce: proof.nonce,
            approved: true
        });
        consumedProviderJobs[proof.providerJobRef] = true;
        consumedNonces[proof.creator][proof.nonce] = true;
        emit IdentityApproved(
            genesisDigest,
            proof.providerJobRef,
            proof.creator,
            proof.name,
            proof.symbol,
            proof.logoUri
        );
    }

    /// @notice The exact EIP-712 digest signed by the verifier.
    function identityDigest(IdentityProof calldata proof)
        public
        view
        returns (bytes32)
    {
        return
            MessageHashUtils.toTypedDataHash(
                _domainSeparatorV4(),
                _structHash(proof)
            );
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function approvedIdentity(bytes32 genesisDigest)
        external
        view
        returns (Identity memory)
    {
        return identities[genesisDigest];
    }

    function _domainSeparatorV4() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    DOMAIN_TYPEHASH,
                    keccak256(bytes(PROTOCOL_NAME)),
                    keccak256(bytes(PROTOCOL_VERSION)),
                    block.chainid,
                    address(this)
                )
            );
    }

    function _structHash(IdentityProof calldata proof)
        internal
        pure
        returns (bytes32)
    {
        bytes32 nameHash = keccak256(bytes(proof.name));
        bytes32 symbolHash = keccak256(bytes(proof.symbol));
        bytes32 logoHash = keccak256(bytes(proof.logoUri));
        bytes memory encoded = abi.encode(proof);
        bytes32 typeHash = IDENTITY_PROOF_TYPEHASH;
        bytes32 result;
        assembly {
            let ptr := mload(0x40)
            // abi.encode receives one dynamic tuple, so its first word is
            // the offset to the tuple head.
            let base := add(encoded, 0x40)
            mstore(ptr, typeHash)
            mstore(add(ptr, 0x20), mload(base))
            mstore(add(ptr, 0x40), mload(add(base, 0x20)))
            mstore(add(ptr, 0x60), mload(add(base, 0x40)))
            mstore(add(ptr, 0x80), mload(add(base, 0x60)))
            mstore(add(ptr, 0xa0), mload(add(base, 0x80)))
            mstore(add(ptr, 0xc0), nameHash)
            mstore(add(ptr, 0xe0), symbolHash)
            mstore(add(ptr, 0x100), mload(add(base, 0xe0)))
            mstore(add(ptr, 0x120), mload(add(base, 0x100)))
            mstore(add(ptr, 0x140), mload(add(base, 0x120)))
            mstore(add(ptr, 0x160), mload(add(base, 0x140)))
            mstore(add(ptr, 0x180), mload(add(base, 0x160)))
            mstore(add(ptr, 0x1a0), logoHash)
            mstore(add(ptr, 0x1c0), mload(add(base, 0x1a0)))
            mstore(add(ptr, 0x1e0), mload(add(base, 0x1c0)))
            result := keccak256(ptr, 0x200)
        }
        return result;
    }

    function _isCanonicalLogoUri(bytes memory uri)
        internal
        pure
        returns (bool)
    {
        bytes memory prefix = bytes("ipfs://");
        if (uri.length <= prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            if (uri[i] != prefix[i]) return false;
        }

        uint256 cidLength = uri.length - prefix.length;
        if (uri[prefix.length] == 0x51 && cidLength == 46) {
            if (uri[prefix.length + 1] != 0x6d) return false;
            for (uint256 i = prefix.length + 2; i < uri.length; i++) {
                if (!_isBase58(uri[i])) return false;
            }
            return true;
        }
        if (uri[prefix.length] != 0x62 || cidLength < 50 || cidLength > 128) {
            return false;
        }
        for (uint256 i = prefix.length + 1; i < uri.length; i++) {
            if (!_isBase32Lower(uri[i])) return false;
        }
        return true;
    }

    function _isBase58(bytes1 character) private pure returns (bool) {
        return
            (character >= 0x31 && character <= 0x39) ||
            (character >= 0x41 && character <= 0x48) ||
            (character >= 0x4a && character <= 0x4e) ||
            (character >= 0x50 && character <= 0x5a) ||
            (character >= 0x61 && character <= 0x6b) ||
            (character >= 0x6d && character <= 0x7a);
    }

    function _isBase32Lower(bytes1 character) private pure returns (bool) {
        return
            (character >= 0x61 && character <= 0x68) ||
            (character >= 0x6a && character <= 0x6b) ||
            (character >= 0x6d && character <= 0x6e) ||
            (character >= 0x70 && character <= 0x74) ||
            (character >= 0x76 && character <= 0x7a) ||
            (character >= 0x32 && character <= 0x37);
    }
}