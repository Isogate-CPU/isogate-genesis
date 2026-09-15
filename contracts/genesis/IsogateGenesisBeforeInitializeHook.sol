// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface IIsogateGenesisHookFactory {
    function launchCoordinator() external view returns (address);
}

/// @notice The only hook used by Genesis pools.
///
/// A hook is deployed for each token because the canonical pool key includes
/// that token.  Its address is mined by the coordinator so the v4 address
/// permission mask contains only BEFORE_INITIALIZE.  There is deliberately no
/// owner, callback, withdrawal, or arbitrary-call surface.
contract IsogateGenesisBeforeInitializeHook is IHooks {
    uint160 public constant BEFORE_INITIALIZE_FLAG = 1 << 13;
    uint24 public constant CANONICAL_FEE = 10_000;
    int24 public constant CANONICAL_TICK_SPACING = 200;
    uint160 public constant CANONICAL_SQRT_PRICE_X96 = uint160(34_500 * (2 ** 96));

    IPoolManager public immutable poolManager;
    address public immutable factory;
    address public immutable launchCoordinator;
    address public immutable token;

    error InvalidFactoryConfiguration();
    error UnauthorizedPoolManager(address caller);
    error UnauthorizedInitializer(address sender);
    error InvalidPoolKey();
    error InvalidSqrtPrice();
    error UnsupportedHookCall();

    constructor(IPoolManager poolManager_, address factory_, address launchCoordinator_, address token_) {
        if (
            address(poolManager_) == address(0) ||
            factory_ == address(0) ||
            launchCoordinator_ == address(0) ||
            token_ == address(0) ||
            address(poolManager_).code.length == 0
        ) revert InvalidFactoryConfiguration();
        if (IIsogateGenesisHookFactory(factory_).launchCoordinator() != launchCoordinator_) {
            revert InvalidFactoryConfiguration();
        }
        poolManager = poolManager_;
        factory = factory_;
        launchCoordinator = launchCoordinator_;
        token = token_;

        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        returns (bytes4)
    {
        if (msg.sender != address(poolManager)) revert UnauthorizedPoolManager(msg.sender);
        if (sender != launchCoordinator) revert UnauthorizedInitializer(sender);
        if (
            Currency.unwrap(key.currency0) != address(0) ||
            Currency.unwrap(key.currency1) != token ||
            key.fee != CANONICAL_FEE ||
            key.tickSpacing != CANONICAL_TICK_SPACING ||
            address(key.hooks) != address(this)
        ) revert InvalidPoolKey();
        if (sqrtPriceX96 != CANONICAL_SQRT_PRICE_X96) revert InvalidSqrtPrice();
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert UnsupportedHookCall();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert UnsupportedHookCall();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnsupportedHookCall();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        revert UnsupportedHookCall();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert UnsupportedHookCall();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert UnsupportedHookCall();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, int128)
    {
        revert UnsupportedHookCall();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnsupportedHookCall();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert UnsupportedHookCall();
    }
}