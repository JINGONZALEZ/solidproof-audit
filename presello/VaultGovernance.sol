// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    Proposal, TimelockOp,
    PROPOSAL_EXPIRY, EMERGENCY_TIMELOCK, LARGE_WITHDRAWAL_TIMELOCK,
    SIGNER_ROTATION_TIMELOCK, CHANGE_BACKEND_TIMELOCK, PAUSE_COOLDOWN,
    RESCUE_TIMELOCK, LARGE_RELEASE_REQUEUE_COOLDOWN,
    SECONDS_PER_DAY, MAX_BATCH_SIZE,
    PROPOSAL_UNPAUSE, PROPOSAL_CHANGE_BACKEND, PROPOSAL_EMERGENCY_WITHDRAW,
    PROPOSAL_ROTATE_SIGNER, PROPOSAL_RESCUE_TOKEN
} from "./VaultTypes.sol";

/**
 * @title VaultGovernance
 * @notice Governance layer for the PreselloVault: multisig proposals, signer
 *         rotation, emergency withdrawal, rescue, pause/unpause, and timelock
 *         management. Inherited by the main PreselloVault contract.
 *
 * @dev Architecture: Pooled custody model.
 *      The `totalDeposited` mapping records lifetime deposit amounts per user per token.
 *      It is NOT decremented on release — individual seller entitlements are tracked
 *      off-chain in the backend database. The vault is a dumb custodian; the backend
 *      is the sole source of truth for who is owed what.
 *
 * @dev Security features:
 *      - 2-of-3 multisig for all sensitive operations
 *      - Emergency timelocks require 2-of-3 to cancel (single signer cannot veto)
 *      - Signer rotation with 7-day timelock
 *      - Token rescue function for blacklisted or stuck tokens
 *      - Pause cooldown prevents rapid pause/unpause cycling
 *      - One active proposal per type prevents proposal spam
 *      - Proposal cancellation with 2-of-3 approval
 */
abstract contract VaultGovernance is ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =========================================================================
    //                               STATE
    // =========================================================================

    address public backendAddress;
    address public immutable safeAddress;
    address[3] public signers;

    uint256 public defaultDailyCap;
    uint256 public defaultLargeThreshold;
    uint256 public immutable minDailyCap;
    uint256 public immutable minLargeThreshold;
    uint256 public immutable maxDailyCap;
    uint256 public immutable maxLargeThreshold;
    uint256 public lastUnpauseTime;

    // Proposals
    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public proposalApprovals;
    mapping(uint256 => mapping(address => bool)) public cancelApprovals;
    mapping(uint8 => uint256) internal _activeProposalId;
    mapping(uint8 => bool) internal _hasActiveProposal;

    // Timelocks
    uint256 public timelockCount;
    mapping(uint256 => TimelockOp) public timelocks;
    mapping(uint256 => mapping(address => bool)) public timelockCancelApprovals;

    // Large release re-queue cooldown (per token)
    mapping(address => uint256) public lastLargeReleaseQueued;

    // Token allowlist — only approved tokens can be deposited
    mapping(address => bool) public allowedTokens;

    // =========================================================================
    //                               EVENTS
    // =========================================================================

    event EmergencyWithdrawRequested(uint256 indexed proposalId, address indexed token, address indexed proposer);
    event EmergencyWithdrawExecuted(uint256 indexed proposalId, address indexed token, uint256 amount);
    event BackendAddressChangeRequested(uint256 indexed proposalId, address indexed newBackend, address indexed proposer);
    event BackendAddressChanged(address indexed oldBackend, address indexed newBackend);
    event ProposalCreated(uint256 indexed proposalId, uint8 proposalType, address indexed proposer);
    event ProposalApproved(uint256 indexed proposalId, address indexed signer);
    event ProposalCancelled(uint256 indexed proposalId);
    event ProposalCancelVote(uint256 indexed proposalId, address indexed signer);
    event LargeWithdrawalQueued(uint256 indexed timelockId, address indexed token, address indexed to, uint256 amount, uint256 executeAfter);
    event LargeWithdrawalExecuted(uint256 indexed timelockId);
    event LargeWithdrawalCancelled(uint256 indexed timelockId);
    event DailyCapUpdated(address indexed token, uint256 newCap);
    event LargeThresholdUpdated(address indexed token, uint256 newThreshold);
    event SignerRotationProposed(uint256 indexed proposalId, address indexed oldSigner, address indexed newSigner);
    event SignerRotated(address indexed oldSigner, address indexed newSigner);
    event RescueTokenProposed(uint256 indexed proposalId, address indexed token);
    event TokenRescued(address indexed token, uint256 amount);
    event EmergencyTimelockCancelVote(uint256 indexed timelockId, address indexed signer);
    event TokenAllowed(address indexed token, address indexed signer);
    event TokenDisallowed(address indexed token, address indexed signer);

    // =========================================================================
    //                              MODIFIERS
    // =========================================================================

    modifier onlyBackend() {
        require(msg.sender == backendAddress, "Vault: caller is not backend");
        _;
    }

    modifier onlySigner() {
        require(_isSigner(msg.sender), "Vault: caller is not a signer");
        _;
    }

    // =========================================================================
    //                            CONSTRUCTOR
    // =========================================================================

    constructor(
        address[3] memory _signers,
        address _backendAddress,
        address _safeAddress,
        uint256 _defaultDailyCap,
        uint256 _defaultLargeThreshold,
        uint256 _minDailyCap,
        uint256 _minLargeThreshold,
        uint256 _maxDailyCap,
        uint256 _maxLargeThreshold
    ) {
        require(_backendAddress != address(0), "Vault: zero backend address");
        require(_safeAddress != address(0), "Vault: zero safe address");
        require(_defaultDailyCap > 0, "Vault: zero daily cap");
        require(_defaultLargeThreshold > 0, "Vault: zero large threshold");
        require(_minDailyCap > 0, "Vault: zero min daily cap");
        require(_minLargeThreshold > 0, "Vault: zero min large threshold");
        require(_maxDailyCap > 0, "Vault: zero max daily cap");
        require(_maxLargeThreshold > 0, "Vault: zero max large threshold");
        require(_defaultDailyCap >= _defaultLargeThreshold, "Vault: daily cap must be >= threshold");
        require(_minDailyCap >= _minLargeThreshold, "Vault: min cap must be >= min threshold");
        require(_defaultDailyCap >= _minDailyCap, "Vault: default cap below minimum");
        require(_defaultLargeThreshold >= _minLargeThreshold, "Vault: default threshold below minimum");
        require(_maxDailyCap >= _defaultDailyCap, "Vault: max cap below default");
        require(_maxLargeThreshold >= _defaultLargeThreshold, "Vault: max threshold below default");

        for (uint256 i = 0; i < 3; i++) {
            require(_signers[i] != address(0), "Vault: zero signer address");
            for (uint256 j = 0; j < i; j++) {
                require(_signers[i] != _signers[j], "Vault: duplicate signer");
            }
        }
        require(_backendAddress != _safeAddress, "Vault: backend == safe");
        for (uint256 i = 0; i < 3; i++) {
            require(_signers[i] != _backendAddress, "Vault: signer == backend");
            require(_signers[i] != _safeAddress, "Vault: signer == safe");
        }

        signers = _signers;
        backendAddress = _backendAddress;
        safeAddress = _safeAddress;
        defaultDailyCap = _defaultDailyCap;
        defaultLargeThreshold = _defaultLargeThreshold;
        minDailyCap = _minDailyCap;
        minLargeThreshold = _minLargeThreshold;
        maxDailyCap = _maxDailyCap;
        maxLargeThreshold = _maxLargeThreshold;
    }

    // =========================================================================
    //                      PAUSE / UNPAUSE
    // =========================================================================

    function pause() external onlySigner {
        require(block.timestamp >= lastUnpauseTime + PAUSE_COOLDOWN, "Vault: pause cooldown active");
        _pause();
    }

    function proposeUnpause() external onlySigner returns (uint256 proposalId) {
        require(paused(), "Vault: not paused");
        proposalId = _createProposal(PROPOSAL_UNPAUSE, address(0), address(0), address(0));
        _approveProposal(proposalId);
    }

    function approveUnpause(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(p.proposalType == PROPOSAL_UNPAUSE, "Vault: wrong proposal type");
        _requireProposalActive(p);
        _approveProposal(proposalId);
        if (_approvalCount(proposalId) >= 2) {
            p.executed = true;
            p.approved = true;
            _clearActiveProposal(PROPOSAL_UNPAUSE);
            lastUnpauseTime = block.timestamp;
            _unpause();
        }
    }

    // =========================================================================
    //                 CHANGE BACKEND ADDRESS
    // =========================================================================

    function proposeChangeBackend(address newBackend) external onlySigner returns (uint256 proposalId) {
        require(newBackend != address(0), "Vault: zero address");
        require(newBackend != backendAddress, "Vault: same address");
        proposalId = _createProposal(PROPOSAL_CHANGE_BACKEND, address(0), newBackend, address(0));
        _approveProposal(proposalId);
        emit BackendAddressChangeRequested(proposalId, newBackend, msg.sender);
    }

    function approveChangeBackend(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(p.proposalType == PROPOSAL_CHANGE_BACKEND, "Vault: wrong proposal type");
        _requireProposalActive(p);
        _approveProposal(proposalId);
        if (_approvalCount(proposalId) >= 2) {
            p.approved = true;
            p.executeAfter = block.timestamp + CHANGE_BACKEND_TIMELOCK;
        }
    }

    /// @notice Execute a backend address change after the 24-hour timelock.
    function executeChangeBackend(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(p.proposalType == PROPOSAL_CHANGE_BACKEND, "Vault: wrong proposal type");
        require(p.approved, "Vault: not yet approved");
        require(!p.executed, "Vault: already executed");
        require(!p.cancelled, "Vault: cancelled");
        require(block.timestamp >= p.executeAfter, "Vault: backend change delay not elapsed");
        require(
            block.timestamp <= p.createdAt + PROPOSAL_EXPIRY + CHANGE_BACKEND_TIMELOCK,
            "Vault: backend change expired"
        );
        p.executed = true;
        _clearActiveProposal(PROPOSAL_CHANGE_BACKEND);
        address oldBackend = backendAddress;
        backendAddress = p.newAddress;
        emit BackendAddressChanged(oldBackend, p.newAddress);
    }

    // =========================================================================
    //                     EMERGENCY WITHDRAW
    // =========================================================================

    function proposeEmergencyWithdraw(address token) external onlySigner returns (uint256 proposalId) {
        require(token != address(0), "Vault: zero token address");
        proposalId = _createProposal(PROPOSAL_EMERGENCY_WITHDRAW, token, address(0), address(0));
        _approveProposal(proposalId);
        emit EmergencyWithdrawRequested(proposalId, token, msg.sender);
    }

    function approveEmergencyWithdraw(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(p.proposalType == PROPOSAL_EMERGENCY_WITHDRAW, "Vault: wrong proposal type");
        _requireProposalActive(p);
        _approveProposal(proposalId);
        if (_approvalCount(proposalId) >= 2) {
            p.executed = true;
            p.approved = true;
            _clearActiveProposal(PROPOSAL_EMERGENCY_WITHDRAW);
            uint256 balance = IERC20(p.token).balanceOf(address(this));
            require(balance > 0, "Vault: no balance to withdraw");
            uint256 timelockId = timelockCount++;
            timelocks[timelockId] = TimelockOp({
                token: p.token,
                to: safeAddress,
                amount: balance,
                executeAfter: block.timestamp + EMERGENCY_TIMELOCK,
                executed: false,
                cancelled: false,
                isEmergency: true
            });
            emit LargeWithdrawalQueued(timelockId, p.token, safeAddress, balance, block.timestamp + EMERGENCY_TIMELOCK);
        }
    }

    function executeEmergencyWithdraw(uint256 timelockId) external nonReentrant onlySigner {
        TimelockOp storage op = timelocks[timelockId];
        require(!op.executed, "Vault: already executed");
        require(!op.cancelled, "Vault: cancelled");
        require(op.isEmergency, "Vault: not an emergency timelock");
        require(block.timestamp >= op.executeAfter, "Vault: timelock not expired");
        require(op.to == safeAddress, "Vault: invalid destination");
        op.executed = true;
        uint256 currentBalance = IERC20(op.token).balanceOf(address(this));
        uint256 transferAmount = currentBalance < op.amount ? currentBalance : op.amount;
        require(transferAmount > 0, "Vault: nothing to withdraw");
        IERC20(op.token).safeTransfer(safeAddress, transferAmount);
        emit EmergencyWithdrawExecuted(timelockId, op.token, transferAmount);
    }

    // =========================================================================
    //                    SIGNER ROTATION (7-day delay)
    // =========================================================================

    function proposeRotateSigner(address oldSigner, address newSigner) external onlySigner returns (uint256 proposalId) {
        require(_isSigner(oldSigner), "Vault: not a current signer");
        require(newSigner != address(0), "Vault: zero new signer");
        require(!_isSigner(newSigner), "Vault: already a signer");
        require(newSigner != backendAddress, "Vault: new signer == backend");
        require(newSigner != safeAddress, "Vault: new signer == safe");
        proposalId = _createProposal(PROPOSAL_ROTATE_SIGNER, address(0), newSigner, oldSigner);
        _approveProposal(proposalId);
        emit SignerRotationProposed(proposalId, oldSigner, newSigner);
    }

    function approveRotateSigner(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(p.proposalType == PROPOSAL_ROTATE_SIGNER, "Vault: wrong proposal type");
        _requireProposalActive(p);
        _approveProposal(proposalId);
        if (_approvalCount(proposalId) >= 2) {
            p.approved = true;
            p.executeAfter = block.timestamp + SIGNER_ROTATION_TIMELOCK;
        }
    }

    function executeRotateSigner(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(p.proposalType == PROPOSAL_ROTATE_SIGNER, "Vault: wrong proposal type");
        require(p.approved, "Vault: not yet approved");
        require(!p.executed, "Vault: already executed");
        require(!p.cancelled, "Vault: cancelled");
        require(block.timestamp >= p.executeAfter, "Vault: rotation delay not elapsed");
        require(
            block.timestamp <= p.createdAt + PROPOSAL_EXPIRY + SIGNER_ROTATION_TIMELOCK,
            "Vault: rotation expired"
        );
        require(!_isSigner(p.newAddress), "Vault: already a signer");
        require(p.newAddress != backendAddress, "Vault: new signer == backend");
        p.executed = true;
        _clearActiveProposal(PROPOSAL_ROTATE_SIGNER);
        for (uint256 i = 0; i < 3; i++) {
            if (signers[i] == p.oldAddress) {
                signers[i] = p.newAddress;
                break;
            }
        }
        emit SignerRotated(p.oldAddress, p.newAddress);
    }

    // =========================================================================
    //              RESCUE TOKEN (for blacklisted/stuck tokens)
    // =========================================================================

    function proposeRescueToken(address token) external onlySigner returns (uint256 proposalId) {
        require(token != address(0), "Vault: zero token address");
        proposalId = _createProposal(PROPOSAL_RESCUE_TOKEN, token, address(0), address(0));
        _approveProposal(proposalId);
        emit RescueTokenProposed(proposalId, token);
    }

    function approveRescueToken(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(p.proposalType == PROPOSAL_RESCUE_TOKEN, "Vault: wrong proposal type");
        _requireProposalActive(p);
        _approveProposal(proposalId);
        if (_approvalCount(proposalId) >= 2) {
            p.executed = true;
            p.approved = true;
            _clearActiveProposal(PROPOSAL_RESCUE_TOKEN);
            uint256 balance = IERC20(p.token).balanceOf(address(this));
            require(balance > 0, "Vault: no balance to rescue");
            // Create a 24-hour timelock (shorter than 72h emergency, faster for urgent rescue)
            // Execute via executeEmergencyWithdraw() after the delay
            uint256 timelockId = timelockCount++;
            timelocks[timelockId] = TimelockOp({
                token: p.token,
                to: safeAddress,
                amount: balance,
                executeAfter: block.timestamp + RESCUE_TIMELOCK,
                executed: false,
                cancelled: false,
                isEmergency: true
            });
            emit TokenRescued(p.token, balance);
            emit LargeWithdrawalQueued(timelockId, p.token, safeAddress, balance, block.timestamp + RESCUE_TIMELOCK);
        }
    }

    // =========================================================================
    //                  CANCEL PROPOSAL (2-of-3)
    // =========================================================================

    function cancelProposal(uint256 proposalId) external onlySigner {
        Proposal storage p = proposals[proposalId];
        require(!p.executed, "Vault: already executed");
        require(!p.cancelled, "Vault: already cancelled");
        require(block.timestamp <= p.createdAt + PROPOSAL_EXPIRY, "Vault: proposal expired");
        require(!cancelApprovals[proposalId][msg.sender], "Vault: already voted to cancel");
        // Signers can cancel even after approving (allows reversal if new info emerges)
        cancelApprovals[proposalId][msg.sender] = true;
        emit ProposalCancelVote(proposalId, msg.sender);
        uint256 cancelCount = 0;
        for (uint256 i = 0; i < 3; i++) {
            if (cancelApprovals[proposalId][signers[i]]) cancelCount++;
        }
        if (cancelCount >= 2) {
            p.cancelled = true;
            _clearActiveProposal(p.proposalType);
            emit ProposalCancelled(proposalId);
        }
    }

    // =========================================================================
    //                  CANCEL TIMELOCK (split: regular vs emergency)
    // =========================================================================

    function cancelTimelock(uint256 timelockId) external onlySigner {
        TimelockOp storage op = timelocks[timelockId];
        require(!op.executed, "Vault: already executed");
        require(!op.cancelled, "Vault: already cancelled");
        if (op.isEmergency) {
            require(!timelockCancelApprovals[timelockId][msg.sender], "Vault: already voted to cancel");
            timelockCancelApprovals[timelockId][msg.sender] = true;
            emit EmergencyTimelockCancelVote(timelockId, msg.sender);
            uint256 cancelCount = 0;
            for (uint256 i = 0; i < 3; i++) {
                if (timelockCancelApprovals[timelockId][signers[i]]) cancelCount++;
            }
            if (cancelCount < 2) return;
        }
        op.cancelled = true;
        emit LargeWithdrawalCancelled(timelockId);
    }

    // =========================================================================
    //                        CONFIGURATION
    // =========================================================================

    function setDailyCap(address token, uint256 cap) external onlySigner {
        require(cap >= minDailyCap, "Vault: below minimum cap");
        require(cap <= maxDailyCap, "Vault: above maximum cap");
        // Cross-validate: cap must be >= the effective threshold for this scope
        if (token == address(0)) {
            require(cap >= defaultLargeThreshold, "Vault: cap below default threshold");
            defaultDailyCap = cap;
        } else {
            require(cap >= _getLargeThreshold(token), "Vault: cap below token threshold");
            tokenDailyCap[token] = cap;
        }
        emit DailyCapUpdated(token, cap);
    }

    function setLargeThreshold(address token, uint256 threshold) external onlySigner {
        require(threshold >= minLargeThreshold, "Vault: below minimum threshold");
        require(threshold <= maxLargeThreshold, "Vault: above maximum threshold");
        // Cross-validate: threshold must be <= the effective cap for this scope
        if (token == address(0)) {
            require(defaultDailyCap >= threshold, "Vault: threshold above default cap");
            defaultLargeThreshold = threshold;
        } else {
            require(_getDailyCap(token) >= threshold, "Vault: threshold above token cap");
            tokenLargeThreshold[token] = threshold;
        }
        emit LargeThresholdUpdated(token, threshold);
    }

    /// @notice Add a token to the allowlist. Only allowed tokens can be deposited.
    function allowToken(address token) external onlySigner {
        require(token != address(0), "Vault: zero token address");
        require(!allowedTokens[token], "Vault: token already allowed");
        allowedTokens[token] = true;
        emit TokenAllowed(token, msg.sender);
    }

    /// @notice Remove a token from the allowlist. Existing deposits are unaffected.
    function disallowToken(address token) external onlySigner {
        require(allowedTokens[token], "Vault: token not allowed");
        allowedTokens[token] = false;
        emit TokenDisallowed(token, msg.sender);
    }

    /// @notice Check if a token is on the allowlist.
    function isTokenAllowed(address token) external view returns (bool) {
        return allowedTokens[token];
    }

    // ---- Storage for config (must be here for inheritance) ----
    mapping(address => uint256) public tokenDailyCap;
    mapping(address => uint256) public tokenLargeThreshold;

    // =========================================================================
    //                         VIEW FUNCTIONS
    // =========================================================================

    function getApprovalCount(uint256 proposalId) external view returns (uint256) {
        return _approvalCount(proposalId);
    }

    function hasApproved(uint256 proposalId, address signer) external view returns (bool) {
        return proposalApprovals[proposalId][signer];
    }

    function hasActiveProposalOfType(uint8 proposalType) external view returns (bool active, uint256 pid) {
        if (!_hasActiveProposal[proposalType]) return (false, 0);
        pid = _activeProposalId[proposalType];
        Proposal storage p = proposals[pid];
        if (p.executed || p.cancelled || block.timestamp > p.createdAt + PROPOSAL_EXPIRY) {
            return (false, pid);
        }
        return (true, pid);
    }

    // =========================================================================
    //                         INTERNAL FUNCTIONS
    // =========================================================================

    function _isSigner(address addr) internal view returns (bool) {
        return addr == signers[0] || addr == signers[1] || addr == signers[2];
    }

    function _requireProposalActive(Proposal storage p) internal view {
        require(!p.executed, "Vault: already executed");
        require(!p.cancelled, "Vault: cancelled");
        require(block.timestamp <= p.createdAt + PROPOSAL_EXPIRY, "Vault: proposal expired");
    }

    function _createProposal(
        uint8 proposalType,
        address token,
        address newAddress,
        address oldAddress
    ) internal returns (uint256 proposalId) {
        if (_hasActiveProposal[proposalType]) {
            Proposal storage existing = proposals[_activeProposalId[proposalType]];
            // For proposals with timelocks (rotation, backend change), use extended expiry
            // to avoid governance freeze when approved but not yet executed
            uint256 effectiveExpiry = existing.createdAt + PROPOSAL_EXPIRY;
            if (proposalType == PROPOSAL_ROTATE_SIGNER) {
                effectiveExpiry += SIGNER_ROTATION_TIMELOCK;
            } else if (proposalType == PROPOSAL_CHANGE_BACKEND) {
                effectiveExpiry += CHANGE_BACKEND_TIMELOCK;
            }
            require(
                existing.executed || existing.cancelled ||
                block.timestamp > effectiveExpiry,
                "Vault: active proposal exists for this type"
            );
        }
        proposalId = proposalCount++;
        proposals[proposalId] = Proposal({
            proposalType: proposalType,
            proposer: msg.sender,
            token: token,
            newAddress: newAddress,
            oldAddress: oldAddress,
            createdAt: block.timestamp,
            executeAfter: 0,
            approved: false,
            executed: false,
            cancelled: false
        });
        _hasActiveProposal[proposalType] = true;
        _activeProposalId[proposalType] = proposalId;
        emit ProposalCreated(proposalId, proposalType, msg.sender);
    }

    function _approveProposal(uint256 proposalId) internal {
        require(!proposalApprovals[proposalId][msg.sender], "Vault: already approved");
        require(!cancelApprovals[proposalId][msg.sender], "Vault: cannot approve after cancel vote");
        proposalApprovals[proposalId][msg.sender] = true;
        emit ProposalApproved(proposalId, msg.sender);
    }

    function _approvalCount(uint256 proposalId) internal view returns (uint256 count) {
        for (uint256 i = 0; i < 3; i++) {
            if (proposalApprovals[proposalId][signers[i]]) count++;
        }
    }

    function _clearActiveProposal(uint8 proposalType) internal {
        _hasActiveProposal[proposalType] = false;
    }

    function _getDailyCap(address token) internal view returns (uint256) {
        uint256 cap = tokenDailyCap[token];
        return cap > 0 ? cap : defaultDailyCap;
    }

    function _getLargeThreshold(address token) internal view returns (uint256) {
        uint256 t = tokenLargeThreshold[token];
        return t > 0 ? t : defaultLargeThreshold;
    }

    function _checkAndUpdateDailyCap(address token, uint256 amount) internal {
        uint256 today = block.timestamp / SECONDS_PER_DAY;
        uint256 cap = _getDailyCap(token);
        uint256 used = dailyWithdrawn[token][today];
        require(used + amount <= cap, "Vault: daily cap exceeded");
        dailyWithdrawn[token][today] = used + amount;
    }

    // ---- Storage for daily tracking (must be here for inheritance) ----
    mapping(address => mapping(uint256 => uint256)) public dailyWithdrawn;
}
