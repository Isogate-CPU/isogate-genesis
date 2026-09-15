// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Isogate Genesis Fee Vault
/// @notice Pull-payment accounting for native currency, WETH, and genesis token.
///
/// Each deposit is split independently, with the creator receiving 70% and
/// the protocol receiving the exact remainder.  Claims are pull payments:
/// deposits never call either recipient.
contract IsogateGenesisFeeVault is ReentrancyGuard {
    uint256 public constant CREATOR_BPS = 7_000;
    uint256 public constant PROTOCOL_BPS = 3_000;
    uint256 private constant BPS = 10_000;

    address public immutable creator;
    address public immutable protocol;
    address public immutable weth;
    address public immutable factory;
    address public genesisToken;

    uint256 public creatorNativeDue;
    uint256 public protocolNativeDue;
    uint256 public creatorWethDue;
    uint256 public protocolWethDue;
    uint256 public creatorGenesisTokenDue;
    uint256 public protocolGenesisTokenDue;

    error ZeroAddress();
    error OnlyFactory(address caller);
    error GenesisTokenAlreadyConfigured();
    error InvalidGenesisToken();
    error NotCreator(address caller);
    error NotProtocol(address caller);
    error TransferFailed();
    error IncorrectTokenAmount();

    event NativeFeesDeposited(
        address indexed payer,
        uint256 amount,
        uint256 creatorAmount,
        uint256 protocolAmount
    );
    event WETHFeesDeposited(
        address indexed payer,
        uint256 amount,
        uint256 creatorAmount,
        uint256 protocolAmount
    );
    event CreatorClaimed(address indexed recipient, uint256 nativeAmount, uint256 wethAmount);
    event ProtocolClaimed(address indexed recipient, uint256 nativeAmount, uint256 wethAmount);
    event GenesisTokenConfigured(address indexed token);
    event GenesisTokenFeesDeposited(
        address indexed payer,
        uint256 amount,
        uint256 creatorAmount,
        uint256 protocolAmount
    );
    event CreatorGenesisTokenClaimed(address indexed recipient, uint256 amount);
    event ProtocolGenesisTokenClaimed(address indexed recipient, uint256 amount);

    constructor(address creator_, address protocol_, address weth_) {
        if (
            creator_ == address(0) ||
            protocol_ == address(0) ||
            weth_ == address(0) ||
            weth_.code.length == 0
        ) {
            revert ZeroAddress();
        }
        creator = creator_;
        protocol = protocol_;
        weth = weth_;
        // Genesis factories configure the token immediately after deployment.
        // Capturing the deployer keeps the backwards-compatible three-argument
        // constructor while preventing an unrelated account from reconfiguring
        // a vault before its first collection.
        factory = msg.sender;
    }

    receive() external payable {
        _accountNative(msg.sender, msg.value);
    }

    function depositNative() external payable {
        _accountNative(msg.sender, msg.value);
    }

    function depositWETH(uint256 amount) external {
        uint256 beforeBalance = IERC20(weth).balanceOf(address(this));
        if (!IERC20(weth).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }
        uint256 afterBalance = IERC20(weth).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert IncorrectTokenAmount();
        }
        (uint256 creatorAmount, uint256 protocolAmount) = _split(amount);
        creatorWethDue += creatorAmount;
        protocolWethDue += protocolAmount;
        emit WETHFeesDeposited(msg.sender, amount, creatorAmount, protocolAmount);
    }

    /// @notice Binds this vault to its one genesis token.  The factory invokes
    /// this in the same transaction in which it deploys the vault.
    function initializeGenesisToken(address token) external {
        if (msg.sender != factory) revert OnlyFactory(msg.sender);
        if (genesisToken != address(0)) revert GenesisTokenAlreadyConfigured();
        if (token == address(0) || token == weth || token.code.length == 0) {
            revert InvalidGenesisToken();
        }
        genesisToken = token;
        emit GenesisTokenConfigured(token);
    }

    function depositGenesisToken(uint256 amount) external {
        address token = genesisToken;
        if (token == address(0)) revert InvalidGenesisToken();
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        if (!IERC20(token).transferFrom(msg.sender, address(this), amount)) {
            revert TransferFailed();
        }
        uint256 afterBalance = IERC20(token).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert IncorrectTokenAmount();
        }
        (uint256 creatorAmount, uint256 protocolAmount) = _split(amount);
        creatorGenesisTokenDue += creatorAmount;
        protocolGenesisTokenDue += protocolAmount;
        emit GenesisTokenFeesDeposited(msg.sender, amount, creatorAmount, protocolAmount);
    }

    /// @notice Claims both currencies owed to the creator.
    function claimCreator() external nonReentrant {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        _claimCreator();
    }

    /// @notice Claims both currencies owed to the protocol.
    function claimProtocol() external nonReentrant {
        if (msg.sender != protocol) revert NotProtocol(msg.sender);
        _claimProtocol();
    }

    function claimCreatorNative() external nonReentrant {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        uint256 amount = creatorNativeDue;
        creatorNativeDue = 0;
        _sendNative(msg.sender, amount);
        emit CreatorClaimed(msg.sender, amount, 0);
    }

    function claimCreatorWETH() external nonReentrant {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        uint256 amount = creatorWethDue;
        creatorWethDue = 0;
        _sendToken(msg.sender, amount);
        emit CreatorClaimed(msg.sender, 0, amount);
    }

    function claimCreatorGenesisToken() external nonReentrant {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        uint256 amount = creatorGenesisTokenDue;
        creatorGenesisTokenDue = 0;
        _sendGenesisToken(msg.sender, amount);
        emit CreatorGenesisTokenClaimed(msg.sender, amount);
    }

    function claimProtocolNative() external nonReentrant {
        if (msg.sender != protocol) revert NotProtocol(msg.sender);
        uint256 amount = protocolNativeDue;
        protocolNativeDue = 0;
        _sendNative(msg.sender, amount);
        emit ProtocolClaimed(msg.sender, amount, 0);
    }

    function claimProtocolWETH() external nonReentrant {
        if (msg.sender != protocol) revert NotProtocol(msg.sender);
        uint256 amount = protocolWethDue;
        protocolWethDue = 0;
        _sendToken(msg.sender, amount);
        emit ProtocolClaimed(msg.sender, 0, amount);
    }

    function claimProtocolGenesisToken() external nonReentrant {
        if (msg.sender != protocol) revert NotProtocol(msg.sender);
        uint256 amount = protocolGenesisTokenDue;
        protocolGenesisTokenDue = 0;
        _sendGenesisToken(msg.sender, amount);
        emit ProtocolGenesisTokenClaimed(msg.sender, amount);
    }

    function _accountNative(address payer, uint256 amount) internal {
        (uint256 creatorAmount, uint256 protocolAmount) = _split(amount);
        creatorNativeDue += creatorAmount;
        protocolNativeDue += protocolAmount;
        emit NativeFeesDeposited(payer, amount, creatorAmount, protocolAmount);
    }

    function _claimCreator() internal {
        uint256 nativeAmount = creatorNativeDue;
        uint256 wethAmount = creatorWethDue;
        uint256 tokenAmount = creatorGenesisTokenDue;
        creatorNativeDue = 0;
        creatorWethDue = 0;
        creatorGenesisTokenDue = 0;
        _sendNative(msg.sender, nativeAmount);
        _sendToken(msg.sender, wethAmount);
        _sendGenesisToken(msg.sender, tokenAmount);
        emit CreatorClaimed(msg.sender, nativeAmount, wethAmount);
    }

    function _claimProtocol() internal {
        uint256 nativeAmount = protocolNativeDue;
        uint256 wethAmount = protocolWethDue;
        uint256 tokenAmount = protocolGenesisTokenDue;
        protocolNativeDue = 0;
        protocolWethDue = 0;
        protocolGenesisTokenDue = 0;
        _sendNative(msg.sender, nativeAmount);
        _sendToken(msg.sender, wethAmount);
        _sendGenesisToken(msg.sender, tokenAmount);
        emit ProtocolClaimed(msg.sender, nativeAmount, wethAmount);
    }

    function _sendNative(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    function _sendToken(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (!IERC20(weth).transfer(recipient, amount)) revert TransferFailed();
    }

    function _sendGenesisToken(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        address token = genesisToken;
        if (token == address(0) || !IERC20(token).transfer(recipient, amount)) {
            revert TransferFailed();
        }
    }

    function _split(uint256 amount)
        private
        pure
        returns (uint256 creatorAmount, uint256 protocolAmount)
    {
        creatorAmount = (amount * CREATOR_BPS) / BPS;
        protocolAmount = amount - creatorAmount;
    }
}