// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Isogate Genesis Token
/// @notice A permanently fixed-supply token created for one genesis identity.
///
/// The genesis burn is performed with ERC20's canonical _burn path in the
/// constructor. The owner lifecycle is emitted for scanners, then ownership is
/// renounced before construction returns; no privileged token surface exists.
contract IsogateGenesisToken is ERC20, Ownable {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant GENESIS_BURN = 1_000_000e18;
    address public constant GENESIS_BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    address public immutable creator;
    bytes32 public immutable genesisDigest;

    // Solidity does not support dynamic immutable variables.  This value is
    // write-once constructor metadata: there is deliberately no setter or
    // privileged path that can change it.
    string private _logoUri;
    address public immutable launchRecipient;

    error ZeroAddress();
    error InvalidSupply();
    error EmptyGenesisDigest();
    error InvalidLogoUri();

    constructor(
        string memory name_,
        string memory symbol_,
        address creator_,
        bytes32 genesisDigest_,
        string memory logoUri_,
        address launchRecipient_
    ) ERC20(name_, symbol_) Ownable(creator_) {
        if (creator_ == address(0) || launchRecipient_ == address(0)) {
            revert ZeroAddress();
        }
        if (genesisDigest_ == bytes32(0)) revert EmptyGenesisDigest();
        if (GENESIS_BURN >= INITIAL_SUPPLY) revert InvalidSupply();
        if (!_isCanonicalLogoUri(bytes(logoUri_))) revert InvalidLogoUri();

        creator = creator_;
        genesisDigest = genesisDigest_;
        _logoUri = logoUri_;
        launchRecipient = launchRecipient_;

        // Mint the complete initial supply once, then use ERC20's canonical
        // _burn implementation. This emits Transfer(launchRecipient, 0, ...)
        // and leaves no genesis allocation at the dead address.
        _mint(launchRecipient_, INITIAL_SUPPLY);
        _burn(launchRecipient_, GENESIS_BURN);
        // Emit the standard ownership lifecycle while ensuring owner() is zero
        // before the constructor completes. Ownable has no usable post-deploy
        // capability because this contract exposes no onlyOwner functions.
        _transferOwnership(address(0));
    }

    /// @notice URI for the creator-supplied genesis logo.
    /// @dev The exact no-argument logo() signature is part of the identity API.
    function logo() external view returns (string memory) {
        return _logoUri;
    }

    /// @notice Returns true only for a direct ipfs:// CID URI.
    /// @dev Gateways, paths, query strings, fragments, and custom schemes are
    /// intentionally not accepted.  Both CIDv0 (Qm + base58btc) and CIDv1
    /// (lower-case base32, normally beginning with b) are supported.
    function isCanonicalLogoUri(string memory uri) public pure returns (bool) {
        return _isCanonicalLogoUri(bytes(uri));
    }

    function _isCanonicalLogoUri(bytes memory uri) private pure returns (bool) {
        bytes memory prefix = bytes("ipfs://");
        if (uri.length <= prefix.length) return false;
        for (uint256 i = 0; i < prefix.length; i++) {
            if (uri[i] != prefix[i]) return false;
        }

        uint256 cidLength = uri.length - prefix.length;
        // A direct URI is one CID, not a CID followed by a path or URL
        // component.  CIDv0 has a fixed 46-character representation.
        if (uri[prefix.length] == 0x51 && cidLength == 46) {
            if (uri[prefix.length + 1] != 0x6d) return false; // "Qm"
            for (uint256 i = prefix.length + 2; i < uri.length; i++) {
                if (!_isBase58(uri[i])) return false;
            }
            return true;
        }

        // CIDv1 base32 representations are lower-case and start with "b".
        // Keep a conservative length bound for the textual CID form.
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