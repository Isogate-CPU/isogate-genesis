// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "./ContractPrimitives.sol";

/// @title ProviderBond
/// @notice Custodies provider ERC-20 bonds and reserves them against disputes.
contract ProviderBond is RoleManaged, ReentrancyGuard, Pausable, TokenBound {
    bytes32 public constant BOND_OPERATOR_ROLE = keccak256("BOND_OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum LockStatus {
        None,
        Active,
        Released,
        Slashed
    }

    struct DisputeLock {
        address provider;
        uint256 amount;
        LockStatus status;
    }

    mapping(address provider => uint256) public totalBond;
    mapping(address provider => uint256) public lockedBond;
    mapping(bytes32 disputeId => DisputeLock) public disputeLocks;
    mapping(address account => uint256) public pendingWithdrawals;

    error DisputeIdZero();
    error DisputeAlreadyExists(bytes32 disputeId);
    error DisputeNotActive(bytes32 disputeId);
    error ProviderZero();
    error BeneficiaryZero();
    error InvalidAmount();
    error InsufficientAvailableBond(uint256 available, uint256 requested);
    error NoPayment();

    event BondDeposited(address indexed provider, uint256 amount);
    event BondWithdrawn(address indexed provider, uint256 amount);
    event BondLocked(
        bytes32 indexed disputeId,
        address indexed provider,
        uint256 amount
    );
    event BondReleased(
        bytes32 indexed disputeId,
        address indexed provider,
        uint256 amount
    );
    event BondSlashed(
        bytes32 indexed disputeId,
        address indexed provider,
        address indexed beneficiary,
        uint256 amount
    );
    event PaymentAccrued(address indexed account, uint256 amount);
    event PaymentWithdrawn(address indexed account, uint256 amount);

    constructor(address token_, address initialAdmin)
        RoleManaged(initialAdmin)
        TokenBound(token_)
    {
        _grantRole(BOND_OPERATOR_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    /// @notice Pauses deposits and dispute state transitions.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes deposits and dispute state transitions.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Deposits an exact amount of the configured ERC-20 bond token.
    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert InvalidAmount();
        totalBond[msg.sender] += amount;
        // State is accounted before the external token call; a failure rolls
        // back the accounting and the token transfer together.
        _pullExact(msg.sender, amount);
        emit BondDeposited(msg.sender, amount);
    }

    /// @notice Withdraws currently unlocked bond tokens.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 available = totalBond[msg.sender] - lockedBond[msg.sender];
        if (amount > available) revert InsufficientAvailableBond(available, amount);
        totalBond[msg.sender] -= amount;
        _safeTransfer(msg.sender, amount);
        emit BondWithdrawn(msg.sender, amount);
    }

    /// @notice Returns the provider's amount that is not reserved for disputes.
    function availableBond(address provider) external view returns (uint256) {
        return totalBond[provider] - lockedBond[provider];
    }

    /// @notice Reserves a provider's unlocked bond for one unique dispute ID.
    function lockBond(bytes32 disputeId, address provider, uint256 amount)
        external
        whenNotPaused
        onlyRole(BOND_OPERATOR_ROLE)
    {
        if (disputeId == bytes32(0)) revert DisputeIdZero();
        if (disputeLocks[disputeId].status != LockStatus.None) {
            revert DisputeAlreadyExists(disputeId);
        }
        if (provider == address(0)) revert ProviderZero();
        uint256 available = totalBond[provider] - lockedBond[provider];
        if (amount == 0 || amount > available) {
            revert InsufficientAvailableBond(available, amount);
        }

        disputeLocks[disputeId] = DisputeLock({
            provider: provider,
            amount: amount,
            status: LockStatus.Active
        });
        lockedBond[provider] += amount;
        emit BondLocked(disputeId, provider, amount);
    }

    /// @notice Releases an active dispute lock back to the provider's balance.
    function releaseBond(bytes32 disputeId)
        external
        whenNotPaused
        onlyRole(BOND_OPERATOR_ROLE)
    {
        DisputeLock storage dispute = disputeLocks[disputeId];
        if (dispute.status != LockStatus.Active) revert DisputeNotActive(disputeId);
        dispute.status = LockStatus.Released;
        lockedBond[dispute.provider] -= dispute.amount;
        emit BondReleased(disputeId, dispute.provider, dispute.amount);
    }

    /// @notice Slashes an active lock and credits its beneficiary for pull withdrawal.
    function slashBond(bytes32 disputeId, address beneficiary)
        external
        whenNotPaused
        onlyRole(BOND_OPERATOR_ROLE)
    {
        if (beneficiary == address(0)) revert BeneficiaryZero();
        DisputeLock storage dispute = disputeLocks[disputeId];
        if (dispute.status != LockStatus.Active) revert DisputeNotActive(disputeId);
        dispute.status = LockStatus.Slashed;
        lockedBond[dispute.provider] -= dispute.amount;
        totalBond[dispute.provider] -= dispute.amount;
        pendingWithdrawals[beneficiary] += dispute.amount;
        emit PaymentAccrued(beneficiary, dispute.amount);
        emit BondSlashed(
            disputeId,
            dispute.provider,
            beneficiary,
            dispute.amount
        );
    }

    /// @notice Withdraws a slash payout credited to the caller.
    function withdrawSlashedFunds() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NoPayment();
        pendingWithdrawals[msg.sender] = 0;
        _safeTransfer(msg.sender, amount);
        emit PaymentWithdrawn(msg.sender, amount);
    }
}