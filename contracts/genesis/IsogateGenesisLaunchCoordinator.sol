// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IsogateGenesisPositionLock} from "./IsogateGenesisPositionLock.sol";
import {IsogateGenesisFeeVault} from "./IsogateGenesisFeeVault.sol";
import {IsogateGenesisBeforeInitializeHook} from "./IsogateGenesisBeforeInitializeHook.sol";

interface IIsogateGenesisAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IIsogateGenesisPositionManager {
    function poolManager() external view returns (IPoolManager);
    function WETH9() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
}

interface IIsogateGenesisWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice The factory calls this narrow interface after an identity has been
/// approved.  Keeping the factory boundary explicit prevents a caller from
/// launching a token that was not held by the factory.
interface IIsogateGenesisLaunchCoordinator {
    function launch(address token, address creator, address feeVault, uint256 hookSalt) external payable;
    function predictHookAddress(address token, uint256 hookSalt) external view returns (address);
    function factory() external view returns (address);
    function poolManager() external view returns (IPoolManager);
    function positionManager() external view returns (IIsogateGenesisPositionManager);
    function permit2() external view returns (IIsogateGenesisAllowanceTransfer);
    function weth9() external view returns (IIsogateGenesisWETH);
    function HOOK_PERMISSION_MASK() external view returns (uint160);
    function LP_FEE() external view returns (uint24);
    function TICK_SPACING() external view returns (int24);
    function INITIAL_SQRT_PRICE_X96() external view returns (uint160);
}

/// @title Isogate Genesis Launch Coordinator
/// @notice Atomically creates the single, permanently locked Genesis v4 range.
///
/// This adapts the verified reference mechanics (one native/token position and
/// a fixed initial price), but intentionally does not reuse its dynamic-fee
/// hook or developer buy.  The pool uses a dedicated immutable
/// BEFORE_INITIALIZE-only hook, has a static 1% LP fee, and no launch tax.
contract IsogateGenesisLaunchCoordinator is IIsogateGenesisLaunchCoordinator {
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;
    // Uniswap's canonical v4 PoolManager and Permit2 deployments.  They are
    // checked on Robinhood; all other networks use constructor-injected mocks.
    address public constant OFFICIAL_POOL_MANAGER =
        0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public constant OFFICIAL_POSITION_MANAGER =
        0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address public constant OFFICIAL_WETH =
        0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address public constant OFFICIAL_PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Genesis v2 fixes the pool ratio at 34,500^2 = 1,190,250,000 token
    // units per native unit. This is a fixed protocol parameter, not a
    // statement about market value or future returns.
    uint160 public constant INITIAL_SQRT_PRICE_X96 =
        uint160(34_500 * FixedPoint96.Q96);
    uint256 public constant FINAL_TOKEN_SUPPLY = 999_000_000e18;
    uint24 public constant LP_FEE = 10_000; // 1%, static (not dynamic)
    int24 public constant TICK_SPACING = 200;
    uint160 public constant HOOK_PERMISSION_MASK = 1 << 13;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    IIsogateGenesisPositionManager public immutable positionManager;
    IIsogateGenesisAllowanceTransfer public immutable permit2;
    IIsogateGenesisWETH public immutable weth9;
    address public immutable factory;

    mapping(address token => bool launched) public launched;
    mapping(address token => address positionLock) public positionLockOf;
    mapping(address token => bytes32 poolId) public poolIdOf;
    mapping(address token => address hookOf) public hookOf;
    mapping(address token => uint256 tokenDust) public tokenDustOf;

    struct LaunchResult {
        address lockAddress;
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        uint256 nativeAmount;
        uint128 liquidity;
        bytes32 poolId;
    }

    error ZeroAddress();
    error InvalidDependencyConfiguration();
    error RobinhoodDeploymentMismatch();
    error OnlyFactory(address caller);
    error AlreadyLaunched(address token);
    error InvalidToken(address token);
    error InvalidVault(address vault);
    error EmptyFactoryBalance();
    error InsufficientNative(uint256 supplied, uint256 required);
    error InvalidTickRange();
    error InvalidPositionManagerTokenId(uint256 expected, uint256 actual);
    error TokenTransferFailed();
    error NativeTransferFailed();
    error PoolInitializationFailed();
    error InvalidHookSalt(address predicted, uint256 salt);
    error HookSaltNotFound(uint256 start, uint256 attempts);
    error HookDeploymentFailed();

    event GenesisPoolLaunched(
        address indexed token,
        address indexed creator,
        address indexed feeVault,
        address positionLock,
        uint256 positionTokenId,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenAmount,
        uint256 nativeAmount,
        uint256 tokenDust
    );

    constructor(
        IPoolManager poolManager_,
        IIsogateGenesisPositionManager positionManager_,
        IIsogateGenesisAllowanceTransfer permit2_,
        IIsogateGenesisWETH weth9_,
        address factory_
    ) {
        if (
            address(poolManager_) == address(0) ||
            address(positionManager_) == address(0) ||
            address(permit2_) == address(0) ||
            address(weth9_) == address(0) ||
            factory_ == address(0)
        ) revert ZeroAddress();
        if (
            address(poolManager_).code.length == 0 ||
            address(positionManager_).code.length == 0 ||
            address(permit2_).code.length == 0 ||
            address(weth9_).code.length == 0
        ) revert InvalidDependencyConfiguration();

        // PositionManager must be wired to exactly the same PoolManager and
        // WETH instance.  A bad deployment must never silently mis-account.
        IPoolManager configuredPoolManager;
        address configuredWeth;
        try positionManager_.poolManager() returns (IPoolManager value) {
            configuredPoolManager = value;
        } catch {
            revert InvalidDependencyConfiguration();
        }
        try positionManager_.WETH9() returns (address value) {
            configuredWeth = value;
        } catch {
            revert InvalidDependencyConfiguration();
        }
        if (
            address(configuredPoolManager) != address(poolManager_) ||
            address(configuredWeth) != address(weth9_)
        ) revert InvalidDependencyConfiguration();

        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            if (
                address(poolManager_) != OFFICIAL_POOL_MANAGER ||
                address(positionManager_) != OFFICIAL_POSITION_MANAGER ||
                address(permit2_) != OFFICIAL_PERMIT2 ||
                address(weth9_) != OFFICIAL_WETH
            ) revert RobinhoodDeploymentMismatch();
        }
        poolManager = poolManager_;
        positionManager = positionManager_;
        permit2 = permit2_;
        weth9 = weth9_;
        factory = factory_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory(msg.sender);
        _;
    }

    /// @inheritdoc IIsogateGenesisLaunchCoordinator
    function launch(address token, address creator, address feeVault, uint256 hookSalt)
        external
        payable
        override
        onlyFactory
    {
        if (launched[token]) revert AlreadyLaunched(token);
        if (token == address(0) || token.code.length == 0) revert InvalidToken(token);
        if (creator == address(0) || feeVault == address(0)) revert InvalidVault(feeVault);
        if (feeVault.code.length == 0) revert InvalidVault(feeVault);
        // This coordinator is the Genesis v2 launch boundary. A v1 token can
        // remain readable in the index, but can never enter a future v2 pool.
        if (
            IERC20(token).totalSupply() != FINAL_TOKEN_SUPPLY ||
            IERC20(token).balanceOf(creator) != 0 ||
            IERC20(token).balanceOf(address(0)) != 0
        ) revert InvalidToken(token);

        uint256 tokenAmount = IERC20(token).balanceOf(factory);
        if (tokenAmount == 0) revert EmptyFactoryBalance();
        if (!IERC20(token).transferFrom(factory, address(this), tokenAmount)) {
            revert TokenTransferFailed();
        }

        LaunchResult memory result = _initializeAndMint(
            token,
            feeVault,
            tokenAmount,
            msg.value,
            hookSalt
        );

        launched[token] = true;
        positionLockOf[token] = result.lockAddress;
        poolIdOf[token] = result.poolId;

        uint256 dust = IERC20(token).balanceOf(address(this));
        tokenDustOf[token] = dust;
        if (dust != 0) {
            if (!IERC20(token).transfer(DEAD_ADDRESS, dust)) revert TokenTransferFailed();
        }
        uint256 refund = address(this).balance;
        if (refund != 0) {
            (bool sent, ) = creator.call{value: refund}("");
            if (!sent) revert NativeTransferFailed();
        }
        _emitLaunch(
            token,
            creator,
            feeVault,
            result.lockAddress,
            result.tokenId,
            result.tickLower,
            result.tickUpper,
            tokenAmount,
            result.nativeAmount,
            dust
        );
    }

    function _emitLaunch(
        address token,
        address creator,
        address feeVault,
        address lockAddress,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenAmount,
        uint256 nativeAmount,
        uint256 dust
    ) internal {
        emit GenesisPoolLaunched(
            token,
            creator,
            feeVault,
            lockAddress,
            tokenId,
            tickLower,
            tickUpper,
            tokenAmount,
            nativeAmount,
            dust
        );
    }

    function _initializeAndMint(
        address token,
        address feeVault,
        uint256 tokenAmount,
        uint256 nativeSupplied,
        uint256 hookSalt
    ) internal returns (LaunchResult memory result) {
        Currency nativeCurrency = Currency.wrap(address(0));
        Currency tokenCurrency = Currency.wrap(token);
        address hook = _deployHook(token, hookSalt);
        hookOf[token] = hook;
        PoolKey memory key = PoolKey({
            currency0: nativeCurrency,
            currency1: tokenCurrency,
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
        });
        // The reference launch uses this fixed price. It is deliberately not
        // derived from a buy, which removes the developer-buy path.
        try poolManager.initialize(key, INITIAL_SQRT_PRICE_X96) returns (int24) {} catch {
            revert PoolInitializationFailed();
        }

        int24 initialTick = TickMath.getTickAtSqrtPrice(INITIAL_SQRT_PRICE_X96);
        result.tickLower = (TickMath.MIN_TICK / TICK_SPACING) * TICK_SPACING;
        result.tickUpper = ((initialTick / TICK_SPACING) + 1) * TICK_SPACING;
        if (
            result.tickLower < TickMath.MIN_TICK ||
            result.tickUpper > TickMath.MAX_TICK ||
            result.tickLower >= initialTick ||
            result.tickUpper <= initialTick
        ) revert InvalidTickRange();

        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(result.tickUpper);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(result.tickLower),
            INITIAL_SQRT_PRICE_X96,
            tokenAmount
        );
        if (liquidity == 0) revert EmptyFactoryBalance();
        result.nativeAmount = SqrtPriceMath.getAmount0Delta(
            INITIAL_SQRT_PRICE_X96,
            sqrtUpper,
            liquidity,
            true
        );
        if (nativeSupplied < result.nativeAmount) {
            revert InsufficientNative(nativeSupplied, result.nativeAmount);
        }

        uint256 expectedTokenId = positionManager.nextTokenId();
        result.lockAddress = _deployLock(token, feeVault, expectedTokenId);
        if (!IERC20(token).approve(address(permit2), tokenAmount)) {
            revert TokenTransferFailed();
        }
        permit2.approve(token, address(positionManager), type(uint160).max, type(uint48).max);

        result.liquidity = liquidity;
        _mintPosition(key, token, result, tokenAmount, nativeSupplied);
        // This coordinator is a one-shot payer.  Do not leave either layer of
        // Permit2 approval live after the atomic mint.
        if (!IERC20(token).approve(address(permit2), 0)) {
            revert TokenTransferFailed();
        }
        permit2.approve(token, address(positionManager), 0, 0);
        result.tokenId = expectedTokenId;
        if (positionManager.ownerOf(result.tokenId) != result.lockAddress) {
            revert InvalidPositionManagerTokenId(expectedTokenId, result.tokenId);
        }
        result.poolId = PoolId.unwrap(key.toId());
    }

    /// @notice Returns the hook address for a token and caller-selected CREATE2 salt.
    /// The creator mines a salt off-chain; launch rejects salts whose address
    /// does not encode exactly BEFORE_INITIALIZE.
    function predictHookAddress(address token, uint256 salt)
        public
        view
        override
        returns (address predicted)
    {
        predicted = _predictHookAddress(salt, _hookInitCodeHash(token));
    }

    /// @notice Mines a valid salt through a read-only eth_call.
    /// Launch itself never loops: it still validates one supplied salt and
    /// executes CREATE2 exactly once.
    function findHookSalt(address token, uint256 start, uint256 attempts)
        external
        view
        returns (uint256 salt, address predicted)
    {
        if (attempts == 0 || attempts > 65_536) {
            revert HookSaltNotFound(start, attempts);
        }
        bytes32 initCodeHash = _hookInitCodeHash(token);
        uint256 end = start + attempts;
        for (salt = start; salt < end; ++salt) {
            predicted = _predictHookAddress(salt, initCodeHash);
            if ((uint160(predicted) & ((1 << 14) - 1)) == HOOK_PERMISSION_MASK) {
                return (salt, predicted);
            }
        }
        revert HookSaltNotFound(start, attempts);
    }

    function _hookInitCodeHash(address token) private view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                type(IsogateGenesisBeforeInitializeHook).creationCode,
                abi.encode(poolManager, factory, address(this), token)
            )
        );
    }

    function _predictHookAddress(uint256 salt, bytes32 initCodeHash)
        private
        view
        returns (address)
    {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            bytes32(salt),
                            initCodeHash
                        )
                    )
                )
            )
        );
    }

    /// @dev The salt is explicit so launch gas is deterministic.  CREATE2 is
    /// executed exactly once after checking the predicted permission bits.
    function _deployHook(address token, uint256 salt) internal returns (address hook) {
        bytes memory initCode = abi.encodePacked(
            type(IsogateGenesisBeforeInitializeHook).creationCode,
            abi.encode(poolManager, factory, address(this), token)
        );
        address predicted = predictHookAddress(token, salt);
        if ((uint160(predicted) & ((1 << 14) - 1)) != HOOK_PERMISSION_MASK) {
            revert InvalidHookSalt(predicted, salt);
        }
        assembly ("memory-safe") {
            hook := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (hook == address(0) || hook != predicted) revert HookDeploymentFailed();
        if (!Hooks.isValidHookAddress(IHooks(hook), LP_FEE)) revert HookDeploymentFailed();
    }

    function _deployLock(address token, address feeVault, uint256 tokenId)
        internal
        returns (address lockAddress)
    {
        lockAddress = address(
            new IsogateGenesisPositionLock(
                address(positionManager),
                tokenId,
                token,
                feeVault,
                address(0),
                token
            )
        );
    }

    function _mintPosition(
        PoolKey memory key,
        address token,
        LaunchResult memory result,
        uint256 tokenAmount,
        uint256 nativeSupplied
    ) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR),
            uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            result.tickLower,
            result.tickUpper,
            uint256(result.liquidity),
            uint128(result.nativeAmount),
            uint128(tokenAmount),
            result.lockAddress,
            bytes("")
        );
        params[1] = abi.encode(Currency.wrap(address(0)), Currency.wrap(token));
        params[2] = abi.encode(Currency.wrap(address(0)), address(this));
        positionManager.modifyLiquidities{value: nativeSupplied}(
            abi.encode(actions, params),
            type(uint256).max
        );
    }

    receive() external payable {}
}