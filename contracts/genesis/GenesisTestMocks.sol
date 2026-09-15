// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IsogateGenesisFeeVault} from "./IsogateGenesisFeeVault.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

using Hooks for IHooks;

interface GenesisMockPermit2Like {
    function transferFrom(address from, address to, uint160 amount, address token) external;
}

/// @dev Test-only WETH-shaped token.  It is kept under the genesis source
/// tree so Hardhat can compile it without introducing a second source root.
contract GenesisTestWETH is IERC20 {
    string public name = "Test WETH";
    string public symbol = "WETH";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
        totalSupply += amount;
        emit Transfer(address(0), account, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            require(currentAllowance >= amount, "allowance");
            allowance[from][msg.sender] = currentAllowance - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract GenesisRevertingRecipient {
    function claimCreator(address vault) external {
        IsogateGenesisFeeVault(payable(vault)).claimCreator();
    }

    receive() external payable {
        revert("native transfer rejected");
    }
}

contract GenesisReentrantRecipient {
    address public vault;
    bool private entered;

    function claimCreator(address vault_) external {
        vault = vault_;
        IsogateGenesisFeeVault(payable(vault_)).claimCreator();
    }

    receive() external payable {
        if (!entered) {
            entered = true;
            IsogateGenesisFeeVault(payable(vault)).claimCreator();
        }
    }
}

/// @dev Small local stand-ins for the official v4 dependencies.  These are
/// intentionally test-only: they exercise the coordinator's exact action
/// payload and dependency/configuration checks without pretending to be the
/// production PoolManager or PositionManager.
contract GenesisMockWETH {
    receive() external payable {}
}

contract GenesisMockPermit2 {
    mapping(address token => mapping(address owner => mapping(address spender => uint160 amount)))
        public allowance;

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowance[token][msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 allowed = allowance[token][from][msg.sender];
        require(allowed >= amount, "permit2 allowance");
        if (allowed != type(uint160).max) allowance[token][from][msg.sender] = allowed - amount;
        require(IERC20(token).transferFrom(from, to, amount), "token transfer");
    }
}

contract GenesisMockPoolManager {
    bool public initialized;
    uint160 public sqrtPriceX96;
    uint24 public fee;
    int24 public tickSpacing;
    address public currency0;
    address public currency1;
    address public hooks;

    function initialize(PoolKey memory key, uint160 sqrtPrice) external returns (int24) {
        require(!initialized, "initialized");
        require(key.hooks.isValidHookAddress(key.fee), "invalid hook");
        if (address(key.hooks) != address(0)) {
            key.hooks.beforeInitialize(key, sqrtPrice);
        }
        initialized = true;
        sqrtPriceX96 = sqrtPrice;
        fee = key.fee;
        tickSpacing = key.tickSpacing;
        currency0 = Currency.unwrap(key.currency0);
        currency1 = Currency.unwrap(key.currency1);
        hooks = address(key.hooks);
        return 202_400;
    }
}

contract GenesisMockPositionManager {
    struct MintParams {
        PoolKey key;
        int24 lower;
        int24 upper;
        uint256 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        address owner;
        bytes hookData;
    }

    address public immutable poolManager;
    address public immutable permit2;
    address public immutable WETH9;
    uint256 public nextTokenId = 1;
    mapping(uint256 tokenId => address owner) public ownerOf;
    mapping(uint256 tokenId => uint128 liquidity) public liquidityOf;
    int24 public positionTickLower;
    int24 public positionTickUpper;
    uint256 public mintedAmount0;
    uint256 public mintedAmount1;
    uint256 public pendingNative;
    mapping(address token => uint256 amount) public pendingToken;

    error NonzeroDecrease();
    error UnsupportedAction();
    error UnsweptNative();

    constructor(address poolManager_, address permit2_, address weth_) {
        poolManager = poolManager_;
        permit2 = permit2_;
        WETH9 = weth_;
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external payable {
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        if (
            actions.length >= 2 &&
            uint8(actions[0]) == 2 &&
            uint8(actions[1]) == 0x0d
        ) {
            _mintPosition(actions, params);
            return;
        }
        if (actions.length == 2 && uint8(actions[0]) == 1) {
            (
                uint256 tokenId,
                uint256 decrease,
                uint128 amount0Min,
                uint128 amount1Min,
                bytes memory hookData
            ) = abi.decode(
                params[0],
                (uint256, uint256, uint128, uint128, bytes)
            );
            if (decrease != 0 || ownerOf[tokenId] != msg.sender) revert NonzeroDecrease();
            (Currency currency0, Currency currency1, address recipient) = abi.decode(
                params[1],
                (Currency, Currency, address)
            );
            uint256 nativeAmount = pendingNative;
            pendingNative = 0;
            if (nativeAmount != 0) {
                (bool sent, ) = recipient.call{value: nativeAmount}("");
                require(sent, "native");
            }
            uint256 tokenAmount = pendingToken[Currency.unwrap(currency1)];
            pendingToken[Currency.unwrap(currency1)] = 0;
            if (tokenAmount != 0) require(IERC20(Currency.unwrap(currency1)).transfer(recipient, tokenAmount));
            return;
        }
        revert UnsupportedAction();
    }

    function _mintPosition(bytes memory actions, bytes[] memory params) private {
            MintParams memory mint = abi.decode(params[0], (MintParams));
            address token = Currency.unwrap(mint.key.currency1);
            positionTickLower = mint.lower;
            positionTickUpper = mint.upper;
            uint160 sqrtCurrent = uint160(34_500 * FixedPoint96.Q96);
            uint256 requiredAmount0 = SqrtPriceMath.getAmount0Delta(
                sqrtCurrent,
                TickMath.getSqrtPriceAtTick(mint.upper),
                uint128(mint.liquidity),
                true
            );
            uint256 requiredAmount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtPriceAtTick(mint.lower),
                sqrtCurrent,
                uint128(mint.liquidity),
                true
            );
            require(mint.amount0Max >= requiredAmount0, "amount0 max");
            require(mint.amount1Max >= requiredAmount1, "amount1 max");
            require(msg.value >= requiredAmount0, "native amount");
            mintedAmount0 = requiredAmount0;
            mintedAmount1 = requiredAmount1;
            GenesisMockPermit2Like(permit2).transferFrom(
                msg.sender,
                address(this),
                uint160(mint.amount1Max),
                token
            );
            // Model v4's principal settlement: max amounts are supplied by
            // Permit2, while rounding excess is returned to the payer.  The
            // coordinator burns that excess rather than depositing principal
            // in the fee vault.
            uint256 tokenExcess = mint.amount1Max - requiredAmount1;
            if (tokenExcess != 0) {
                require(IERC20(token).transfer(msg.sender, tokenExcess), "token excess");
            }
            uint256 tokenId = nextTokenId++;
            ownerOf[tokenId] = mint.owner;
            liquidityOf[tokenId] = uint128(mint.liquidity);
            _sweepNativeExcess(actions, params, requiredAmount0);
    }

    function _sweepNativeExcess(bytes memory actions, bytes[] memory params, uint256 requiredAmount0) private {
        bool sweptNative;
        for (uint256 i = 2; i < actions.length; ++i) {
            if (uint8(actions[i]) != 0x14) revert UnsupportedAction();
            (Currency currency, address recipient) = abi.decode(params[i], (Currency, address));
            if (Currency.unwrap(currency) != address(0)) revert UnsupportedAction();
            uint256 excessNative = msg.value - requiredAmount0;
            if (excessNative != 0) {
                (bool sent, ) = recipient.call{value: excessNative}("");
                require(sent, "native excess");
            }
            sweptNative = true;
        }
        if (msg.value > requiredAmount0 && !sweptNative) revert UnsweptNative();
    }

    function seedTokenFees(address token, uint256 amount) external {
        pendingToken[token] += amount;
    }

    function seedNativeFees() external payable {
        pendingNative += msg.value;
    }

    receive() external payable {}
}