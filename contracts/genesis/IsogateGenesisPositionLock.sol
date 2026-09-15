// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IsogateGenesisFeeVault} from "./IsogateGenesisFeeVault.sol";

interface IIsogateGenesisPositionManagerLock {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

/// @title Isogate Genesis Immutable Position Lock
/// @notice Owns one v4 PositionManager NFT forever.
///
/// There is intentionally no transfer, approval, liquidity-decrease, or
/// arbitrary-call entrypoint.  The sole operation is a permissionless poke
/// with zero liquidity change, followed by forwarding the accrued native and
/// genesis-token fees to the vault.
contract IsogateGenesisPositionLock {
    IIsogateGenesisPositionManagerLock public immutable positionManager;
    uint256 public immutable tokenId;
    address public immutable genesisToken;
    address public immutable feeVault;
    address public immutable currency0;
    address public immutable currency1;

    error ZeroAddress();
    error TokenTransferFailed();

    constructor(
        address positionManager_,
        uint256 tokenId_,
        address genesisToken_,
        address feeVault_,
        address currency0_,
        address currency1_
    ) {
        if (
            positionManager_ == address(0) ||
            genesisToken_ == address(0) ||
            feeVault_ == address(0) ||
            currency1_ == address(0)
        ) revert ZeroAddress();
        positionManager = IIsogateGenesisPositionManagerLock(positionManager_);
        tokenId = tokenId_;
        genesisToken = genesisToken_;
        feeVault = feeVault_;
        currency0 = currency0_;
        currency1 = currency1_;
    }

    /// @notice Anyone may collect only accrued fees; principal can never move.
    function collectFees() external {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        // A zero decrease is a v4 fee poke.  Nonzero liquidity decreases are
        // not reachable from this contract and therefore remain locked forever.
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(
            Currency.wrap(currency0),
            Currency.wrap(currency1),
            address(this)
        );
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            type(uint256).max
        );

        uint256 nativeAmount = address(this).balance;
        if (nativeAmount != 0) {
            IsogateGenesisFeeVault(payable(feeVault)).depositNative{value: nativeAmount}();
        }
        uint256 tokenAmount = IERC20(genesisToken).balanceOf(address(this));
        if (tokenAmount != 0) {
            if (!IERC20(genesisToken).approve(feeVault, tokenAmount)) {
                revert TokenTransferFailed();
            }
            IsogateGenesisFeeVault(payable(feeVault)).depositGenesisToken(tokenAmount);
        }
    }

    receive() external payable {}
}