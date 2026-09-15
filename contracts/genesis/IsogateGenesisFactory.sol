// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IsogateGenesisToken} from "./IsogateGenesisToken.sol";
import {IsogateGenesisIdentityRegistry} from "./IsogateGenesisIdentityRegistry.sol";
import {IsogateGenesisFeeVault} from "./IsogateGenesisFeeVault.sol";
import {
    IIsogateGenesisLaunchCoordinator,
    IIsogateGenesisPositionManager,
    IIsogateGenesisAllowanceTransfer,
    IIsogateGenesisWETH
} from "./IsogateGenesisLaunchCoordinator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title Isogate Genesis Factory
/// @notice Deploys only identities recorded after verified Native Node
/// execution and creator approval.
contract IsogateGenesisFactory {
    IsogateGenesisIdentityRegistry public immutable identityRegistry;
    address public immutable protocol;
    address public immutable weth;
    IIsogateGenesisLaunchCoordinator public launchCoordinator;
    mapping(bytes32 digest => address token) public tokenByGenesisDigest;
    mapping(address token => address creator) public creatorOf;
    mapping(address token => address feeVault) public feeVaultOf;

    error EmptyGenesisDigest();
    error IdentityNotApproved(bytes32 genesisDigest);
    error IdentityCreatorMismatch(address caller, address approvedCreator);
    error IdentityFactoryMismatch(address expectedFactory, address approvedFactory);
    error IdentityProtocolMismatch(address expectedProtocol, address approvedProtocol);
    error GenesisAlreadyExists(bytes32 genesisDigest, address token);
    error UnknownToken(address token);
    error NotCreator(address caller);
    error ZeroAddress();
    error AmountExceedsFactoryBalance(uint256 requested, uint256 available);
    error TokenTransferFailed();
    error OnlyProtocol(address caller);
    error LaunchCoordinatorNotConfigured();
    error LaunchAlreadyStarted(address token);
    error LaunchCoordinatorFactoryMismatch(address expected, address actual);
    error LaunchCoordinatorConfigurationMismatch();

    event GenesisDeployed(
        bytes32 indexed genesisDigest,
        address indexed token,
        address indexed creator,
        string name,
        string symbol_,
        string logoUri
    );
    event GenesisLaunched(
        address indexed token,
        address indexed creator,
        address indexed recipient,
        uint256 amount
    );
    event GenesisFeeVaultCreated(
        address indexed token,
        address indexed vault,
        address indexed creator,
        address protocol,
        address weth
    );
    event LaunchCoordinatorConfigured(address indexed coordinator);

    constructor(
        IsogateGenesisIdentityRegistry identityRegistry_,
        address protocol_,
        address weth_
    ) {
        if (
            address(identityRegistry_) == address(0) ||
            protocol_ == address(0) ||
            weth_ == address(0) ||
            weth_.code.length == 0
        ) revert ZeroAddress();
        identityRegistry = identityRegistry_;
        protocol = protocol_;
        weth = weth_;
    }

    /// @notice Deploys the canonical registry identity for msg.sender and
    /// holds its launch allocation until launchGenesis is called.
    function deployGenesis(bytes32 genesisDigest_) external returns (address token) {
        if (genesisDigest_ == bytes32(0)) revert EmptyGenesisDigest();
        address prior = tokenByGenesisDigest[genesisDigest_];
        if (prior != address(0)) {
            revert GenesisAlreadyExists(genesisDigest_, prior);
        }
        IsogateGenesisIdentityRegistry.Identity memory identity =
            identityRegistry.approvedIdentity(genesisDigest_);
        if (!identity.approved) {
            revert IdentityNotApproved(genesisDigest_);
        }
        if (identity.creator != msg.sender) {
            revert IdentityCreatorMismatch(msg.sender, identity.creator);
        }
        if (identity.factory != address(this)) {
            revert IdentityFactoryMismatch(address(this), identity.factory);
        }
        if (identity.protocol != protocol) {
            revert IdentityProtocolMismatch(protocol, identity.protocol);
        }

        token = address(
            new IsogateGenesisToken(
                identity.name,
                identity.symbol,
                msg.sender,
                genesisDigest_,
                identity.logoUri,
                address(this)
            )
        );
        tokenByGenesisDigest[genesisDigest_] = token;
        creatorOf[token] = msg.sender;
        address feeVault = address(
            new IsogateGenesisFeeVault(msg.sender, protocol, weth)
        );
        feeVaultOf[token] = feeVault;
        IsogateGenesisFeeVault(payable(feeVault)).initializeGenesisToken(token);

        emit GenesisDeployed(
            genesisDigest_,
            token,
            msg.sender,
            identity.name,
            identity.symbol,
            identity.logoUri
        );
        emit GenesisFeeVaultCreated(
            token,
            feeVault,
            msg.sender,
            protocol,
            weth
        );
    }

    /// @notice Sets the reviewed coordinator.  This is the one-time protocol
    /// bootstrap trust boundary: the protocol account must verify the official
    /// dependency deployments and the coordinator's immutable hook parameters.
    /// It is not a launch control and cannot be changed after configuration.
    function configureLaunchCoordinator(
        IIsogateGenesisLaunchCoordinator coordinator_
    ) external {
        if (msg.sender != protocol) revert OnlyProtocol(msg.sender);
        if (address(launchCoordinator) != address(0)) {
            revert LaunchAlreadyStarted(address(launchCoordinator));
        }
        if (address(coordinator_) == address(0) || address(coordinator_).code.length == 0) {
            revert ZeroAddress();
        }
        address configuredFactory;
        try coordinator_.factory() returns (address value) {
            configuredFactory = value;
        } catch {
            revert LaunchCoordinatorFactoryMismatch(address(this), address(0));
        }
        if (configuredFactory != address(this)) {
            revert LaunchCoordinatorFactoryMismatch(address(this), configuredFactory);
        }
        IPoolManager configuredPoolManager;
        IIsogateGenesisPositionManager configuredPositionManager;
        IIsogateGenesisAllowanceTransfer configuredPermit2;
        IIsogateGenesisWETH configuredWeth;
        uint160 permissionMask;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPrice;
        IPoolManager positionConfiguredPoolManager;
        address positionConfiguredWeth;
        try coordinator_.poolManager() returns (IPoolManager value) {
            configuredPoolManager = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try coordinator_.positionManager() returns (IIsogateGenesisPositionManager value) {
            configuredPositionManager = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try coordinator_.permit2() returns (IIsogateGenesisAllowanceTransfer value) {
            configuredPermit2 = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try coordinator_.weth9() returns (IIsogateGenesisWETH value) {
            configuredWeth = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try coordinator_.HOOK_PERMISSION_MASK() returns (uint160 value) {
            permissionMask = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try coordinator_.LP_FEE() returns (uint24 value) {
            fee = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try coordinator_.TICK_SPACING() returns (int24 value) {
            tickSpacing = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try coordinator_.INITIAL_SQRT_PRICE_X96() returns (uint160 value) {
            sqrtPrice = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try configuredPositionManager.poolManager() returns (IPoolManager value) {
            positionConfiguredPoolManager = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        try configuredPositionManager.WETH9() returns (address value) {
            positionConfiguredWeth = value;
        } catch {
            revert LaunchCoordinatorConfigurationMismatch();
        }
        if (
            address(configuredPoolManager).code.length == 0 ||
            address(configuredPositionManager).code.length == 0 ||
            address(configuredPermit2).code.length == 0 ||
            address(configuredWeth) != weth ||
            address(configuredWeth).code.length == 0 ||
            address(positionConfiguredPoolManager) != address(configuredPoolManager) ||
            positionConfiguredWeth != weth ||
            permissionMask != (uint160(1) << 13) ||
            fee != 10_000 ||
            tickSpacing != 200 ||
            sqrtPrice != uint160(34_500 * (2 ** 96))
        ) revert LaunchCoordinatorConfigurationMismatch();
        launchCoordinator = coordinator_;
        emit LaunchCoordinatorConfigured(address(coordinator_));
    }

    /// @notice Atomically hands the entire factory-held balance to the
    /// coordinator.  The creator supplies a salt mined off-chain for the
    /// coordinator's CREATE2 hook address. There is no arbitrary release
    /// recipient or partial release path.
    function launchGenesis(address token, uint256 hookSalt) external payable {
        address creator = creatorOf[token];
        if (creator == address(0)) revert UnknownToken(token);
        if (msg.sender != creator) revert NotCreator(msg.sender);
        IIsogateGenesisLaunchCoordinator coordinator = launchCoordinator;
        if (address(coordinator) == address(0)) revert LaunchCoordinatorNotConfigured();

        uint256 available = IsogateGenesisToken(token).balanceOf(address(this));
        if (available == 0) revert AmountExceedsFactoryBalance(1, available);
        if (!IERC20(token).approve(address(coordinator), available)) {
            revert TokenTransferFailed();
        }
        coordinator.launch{value: msg.value}(token, msg.sender, feeVaultOf[token], hookSalt);
        emit GenesisLaunched(token, msg.sender, address(coordinator), available);
    }

    function tokenForDigest(bytes32 genesisDigest_) external view returns (address) {
        return tokenByGenesisDigest[genesisDigest_];
    }
}