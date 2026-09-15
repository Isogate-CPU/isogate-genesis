// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import "./ContractPrimitives.sol";

/// @title JobEscrowSettlement
/// @notice Holds quoted ERC-20 job amounts and accounts for pull-based payouts.
/// @dev The token is fixed at deployment and is never inferred from an address
///      or a symbol. This contract does not deploy or issue a token.
contract JobEscrowSettlement is RoleManaged, ReentrancyGuard, Pausable, TokenBound {
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct Job {
        address requester;
        uint256 quotedAmount;
        uint64 refundAfter;
        bool settled;
        bool refunded;
    }

    mapping(bytes32 jobId => Job) public jobs;
    mapping(address account => uint256) public pendingWithdrawals;

    error JobIdZero();
    error JobAlreadyExists(bytes32 jobId);
    error JobNotFound(bytes32 jobId);
    error InvalidAmount();
    error InvalidRecipient();
    error JobAlreadyFinalized(bytes32 jobId);
    error SplitMismatch();
    error NotRequesterOrSettlementRole();
    error RefundDeadlineNotFuture(uint256 refundAfter);
    error RefundNotAvailable(bytes32 jobId, uint64 refundAfter);
    error NoPayment();

    event JobCreated(
        bytes32 indexed jobId,
        address indexed requester,
        uint256 quotedAmount,
        uint64 refundAfter
    );
    event JobSettled(
        bytes32 indexed jobId,
        address indexed provider,
        address indexed verifier,
        address treasury,
        uint256 providerAmount,
        uint256 verifierAmount,
        uint256 treasuryAmount
    );
    event JobRefunded(
        bytes32 indexed jobId,
        address indexed requester,
        uint256 amount,
        bool settlementInitiated
    );
    event PaymentAccrued(address indexed account, uint256 amount);
    event PaymentWithdrawn(address indexed account, uint256 amount);

    constructor(address token_, address initialAdmin)
        RoleManaged(initialAdmin)
        TokenBound(token_)
    {
        _grantRole(SETTLEMENT_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    /// @notice Pauses new deposits and finalization operations.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resumes normal escrow operations.
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @notice Deposits the exact quoted amount for a new, globally unique job ID.
    /// @param refundAfter The timestamp at which the requester becomes eligible
    ///        for a refund. The settlement role may cancel earlier.
    function createJob(bytes32 jobId, uint256 quotedAmount, uint64 refundAfter)
        external
        nonReentrant
        whenNotPaused
    {
        if (jobId == bytes32(0)) revert JobIdZero();
        if (quotedAmount == 0) revert InvalidAmount();
        if (jobs[jobId].requester != address(0)) revert JobAlreadyExists(jobId);
        if (refundAfter <= block.timestamp) {
            revert RefundDeadlineNotFuture(refundAfter);
        }

        // Set state before the external token call; a revert rolls this back.
        jobs[jobId] = Job({
            requester: msg.sender,
            quotedAmount: quotedAmount,
            refundAfter: refundAfter,
            settled: false,
            refunded: false
        });
        _pullExact(msg.sender, quotedAmount);
        emit JobCreated(jobId, msg.sender, quotedAmount, refundAfter);
    }

    /// @notice Finalizes a funded job exactly once and credits all recipients.
    /// @dev Recipients pull their credits with withdraw(). Zero-valued splits may
    ///      use the zero address; non-zero splits always require a recipient.
    function settleJob(
        bytes32 jobId,
        address provider,
        address verifier,
        address treasury,
        uint256 providerAmount,
        uint256 verifierAmount,
        uint256 treasuryAmount
    ) external nonReentrant whenNotPaused onlyRole(SETTLEMENT_ROLE) {
        Job storage job = jobs[jobId];
        if (job.requester == address(0)) revert JobNotFound(jobId);
        if (job.settled || job.refunded) revert JobAlreadyFinalized(jobId);
        if (
            (providerAmount != 0 && provider == address(0)) ||
            (verifierAmount != 0 && verifier == address(0)) ||
            (treasuryAmount != 0 && treasury == address(0))
        ) {
            revert InvalidRecipient();
        }
        if (
            providerAmount + verifierAmount + treasuryAmount != job.quotedAmount
        ) {
            revert SplitMismatch();
        }

        job.settled = true;
        _credit(provider, providerAmount);
        _credit(verifier, verifierAmount);
        _credit(treasury, treasuryAmount);
        emit JobSettled(
            jobId,
            provider,
            verifier,
            treasury,
            providerAmount,
            verifierAmount,
            treasuryAmount
        );
    }

    /// @notice Refunds an unfinalized job to its requester as a pull payment.
    /// @dev The requester or the settlement role may initiate the refund.
    function refundJob(bytes32 jobId) external nonReentrant whenNotPaused {
        Job storage job = jobs[jobId];
        if (job.requester == address(0)) revert JobNotFound(jobId);
        if (job.settled || job.refunded) revert JobAlreadyFinalized(jobId);
        bool settlementInitiated = hasRole(SETTLEMENT_ROLE, msg.sender);
        if (msg.sender != job.requester && !settlementInitiated) {
            revert NotRequesterOrSettlementRole();
        }
        if (!settlementInitiated && block.timestamp < job.refundAfter) {
            revert RefundNotAvailable(jobId, job.refundAfter);
        }

        job.refunded = true;
        _credit(job.requester, job.quotedAmount);
        emit JobRefunded(
            jobId,
            job.requester,
            job.quotedAmount,
            settlementInitiated
        );
    }

    /// @notice Withdraws an accrued settlement or refund.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NoPayment();
        pendingWithdrawals[msg.sender] = 0;
        _safeTransfer(msg.sender, amount);
        emit PaymentWithdrawn(msg.sender, amount);
    }

    function _credit(address account, uint256 amount) internal {
        if (amount == 0) return;
        pendingWithdrawals[account] += amount;
        emit PaymentAccrued(account, amount);
    }
}