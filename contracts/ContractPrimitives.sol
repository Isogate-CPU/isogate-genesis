// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

/// @notice Minimal ERC-20 interface used by the infrastructure contracts.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice Small, self-contained role and two-step administrator implementation.
abstract contract RoleManaged {
    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    mapping(bytes32 role => mapping(address account => bool)) private _roles;

    address public admin;
    address public pendingAdmin;

    error AccountZero();
    error NotAdmin(address caller);
    error MissingRole(bytes32 role, address account);
    error NotPendingAdmin(address caller);

    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event AdminTransferStarted(address indexed currentAdmin, address indexed pendingAdmin);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert AccountZero();
        admin = initialAdmin;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) revert MissingRole(role, msg.sender);
        _;
    }

    /// @notice Returns whether an account has a role.
    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    /// @notice Starts a two-step administrator transfer.
    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert AccountZero();
        pendingAdmin = newAdmin;
        emit AdminTransferStarted(admin, newAdmin);
    }

    /// @notice Cancels an outstanding administrator transfer.
    function cancelAdminTransfer() external onlyAdmin {
        pendingAdmin = address(0);
    }

    /// @notice Completes a two-step administrator transfer.
    function acceptAdmin() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin(msg.sender);
        address previousAdmin = admin;
        admin = msg.sender;
        pendingAdmin = address(0);
        _roles[DEFAULT_ADMIN_ROLE][previousAdmin] = false;
        _roles[DEFAULT_ADMIN_ROLE][msg.sender] = true;
        emit RoleRevoked(DEFAULT_ADMIN_ROLE, previousAdmin, msg.sender);
        emit RoleGranted(DEFAULT_ADMIN_ROLE, msg.sender, msg.sender);
        emit AdminTransferred(previousAdmin, msg.sender);
    }

    /// @notice Grants an operational role.
    function grantRole(bytes32 role, address account) external onlyAdmin {
        if (account == address(0)) revert AccountZero();
        _grantRole(role, account);
    }

    /// @notice Revokes an operational role.
    function revokeRole(bytes32 role, address account) external onlyAdmin {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    /// @notice Allows an account to give up one of its own roles.
    function renounceRole(bytes32 role) external {
        if (_roles[role][msg.sender]) {
            _roles[role][msg.sender] = false;
            emit RoleRevoked(role, msg.sender, msg.sender);
        }
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }
}

/// @notice Reentrancy guard used around token-moving entry points.
abstract contract ReentrancyGuard {
    uint256 private _reentrancyState = 1;

    error Reentrancy();

    modifier nonReentrant() {
        if (_reentrancyState != 1) revert Reentrancy();
        _reentrancyState = 2;
        _;
        _reentrancyState = 1;
    }
}

/// @notice Emergency stop primitive. Withdrawals intentionally remain available
/// in the concrete contracts so users can pull already-accounted-for funds.
abstract contract Pausable {
    bool public paused;

    error ContractPaused();
    error ContractNotPaused();

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier whenPaused() {
        if (!paused) revert ContractNotPaused();
        _;
    }

    function _pause() internal {
        if (paused) revert ContractPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    function _unpause() internal {
        if (!paused) revert ContractNotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }
}

/// @notice ERC-20 binding and strict low-level transfer helpers.
abstract contract TokenBound {
    address public immutable token;

    error TokenAddressZero();
    error TokenNotContract();
    error TokenCallFailed();
    error IncorrectTokenAmount();

    constructor(address token_) {
        if (token_ == address(0)) revert TokenAddressZero();
        if (token_.code.length == 0) revert TokenNotContract();
        token = token_;
    }

    function _balanceOf(address account) internal view returns (uint256 balance) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, account)
        );
        if (!success || data.length < 32) revert TokenCallFailed();
        balance = abi.decode(data, (uint256));
    }

    function _safeTransfer(address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
        );
        if (
            !success ||
            (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))
        ) {
            revert TokenCallFailed();
        }
    }

    function _safeTransferFrom(address from, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, from, to, amount)
        );
        if (
            !success ||
            (data.length != 0 && (data.length < 32 || !abi.decode(data, (bool))))
        ) {
            revert TokenCallFailed();
        }
    }

    /// @dev Rejects fee-on-transfer behavior so internal accounting remains exact.
    function _pullExact(address from, uint256 amount) internal {
        uint256 beforeBalance = _balanceOf(address(this));
        _safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = _balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) {
            revert IncorrectTokenAmount();
        }
    }
}