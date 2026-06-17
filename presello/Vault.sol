// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VaultGovernance} from "./VaultGovernance.sol";
import {
    TimelockOp,
    LARGE_WITHDRAWAL_TIMELOCK, LARGE_RELEASE_REQUEUE_COOLDOWN,
    SECONDS_PER_DAY, MAX_BATCH_SIZE
} from "./VaultTypes.sol";

/**
 * @title PreselloVault
 * @notice Token custody vault for the Presello marketplace.
 *         Sellers deposit tokens; the authorized backend releases them to buyers.
 *         Immutable after deployment — no proxy, no selfdestruct, no delegatecall.
 *
 * @dev Architecture: Pooled custody model.
 *      The `totalDeposited` mapping records lifetime deposit amounts per user per token.
 *      It is NOT decremented on release — individual seller entitlements are tracked
 *      off-chain in the backend database. The vault is a dumb custodian; the backend
 *      is the sole source of truth for who is owed what.
 *
 * @dev Security features (see VaultGovernance.sol for governance features):
 *      - ReentrancyGuard on all token-transferring functions
 *      - Fee-on-transfer safe accounting (balance-delta pattern in deposit)
 *      - Daily withdrawal cap per token (configurable, with enforced minimums)
 *      - Large withdrawal timelock (24 hours above threshold)
 *      - Batch releases with per-item error handling (one failure doesn't block others)
 */
contract PreselloVault is VaultGovernance {
    using SafeERC20 for IERC20;

    // =========================================================================
    //                               STATE
    // =========================================================================

    /// @notice Lifetime deposited amount: depositor => token => totalAmount
    ///         NOT decremented on release. See contract NatDoc for architecture.
    mapping(address => mapping(address => uint256)) public totalDeposited;

    // =========================================================================
    //                               EVENTS
    // =========================================================================

    event Deposited(address indexed depositor, address indexed token, uint256 requested, uint256 received);
    event Released(address indexed token, address indexed to, uint256 amount);
    event ReleaseFailed(address indexed token, address indexed to, uint256 amount, uint256 batchIndex);
    event BatchReleased(uint256 succeeded, uint256 failed);

    // =========================================================================
    //                            CONSTRUCTOR
    // =========================================================================

    /**
     * @param _signers              Three multisig signer addresses
     * @param _backendAddress       Authorized backend that can call release()
     * @param _safeAddress          Destination for emergency withdrawals and rescue
     * @param _defaultDailyCap      Default daily withdrawal cap per token (raw units)
     * @param _defaultLargeThreshold Default large withdrawal threshold (raw units)
     * @param _minDailyCap          Floor for daily cap — single signer cannot set below this
     * @param _minLargeThreshold    Floor for large threshold — single signer cannot set below this
     * @param _maxDailyCap          Ceiling for daily cap — single signer cannot set above this
     * @param _maxLargeThreshold    Ceiling for large threshold — single signer cannot set above this
     */
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
    ) VaultGovernance(
        _signers,
        _backendAddress,
        _safeAddress,
        _defaultDailyCap,
        _defaultLargeThreshold,
        _minDailyCap,
        _minLargeThreshold,
        _maxDailyCap,
        _maxLargeThreshold
    ) {}

    // =========================================================================
    //                          DEPOSIT (Sellers)
    // =========================================================================

    /**
     * @notice Seller deposits tokens into the vault.
     *         Uses balance-delta pattern to correctly handle fee-on-transfer tokens.
     *         The actual received amount (after any token transfer fees) is recorded.
     * @param token  ERC-20 token address
     * @param amount Amount of tokens to deposit (raw units, pre-fee)
     */
    function deposit(address token, uint256 amount) external nonReentrant whenNotPaused {
        require(token != address(0), "Vault: zero token address");
        require(amount > 0, "Vault: zero amount");
        require(allowedTokens[token], "Vault: token not on allowlist");

        // Measure actual received amount (handles fee-on-transfer tokens)
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;

        require(received > 0, "Vault: zero tokens received");

        // Record the actual received amount, not the requested amount
        totalDeposited[msg.sender][token] += received;

        emit Deposited(msg.sender, token, amount, received);
    }

    // =========================================================================
    //                     RELEASE (Backend only — buyers)
    // =========================================================================

    /**
     * @notice Platform releases tokens to a buyer. Only callable by backend.
     * @param token  ERC-20 token address
     * @param to     Buyer's address
     * @param amount Amount to release (raw units)
     */
    function release(
        address token,
        address to,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyBackend {
        _release(token, to, amount);
        emit Released(token, to, amount);
    }

    /**
     * @notice Batch release tokens to multiple buyers. Only callable by backend.
     *         Individual failures are skipped and logged — one bad transfer does not
     *         block the entire batch.
     * @param tokens     Array of token addresses
     * @param recipients Array of buyer addresses
     * @param amounts    Array of amounts (raw units)
     * @return succeeded Number of successful releases
     * @return failed    Number of failed releases
     */
    function batchRelease(
        address[] calldata tokens,
        address[] calldata recipients,
        uint256[] calldata amounts
    ) external nonReentrant whenNotPaused onlyBackend returns (uint256 succeeded, uint256 failed) {
        uint256 len = tokens.length;
        require(len == recipients.length && len == amounts.length, "Vault: array length mismatch");
        require(len > 0, "Vault: empty arrays");
        require(len <= MAX_BATCH_SIZE, "Vault: batch too large");

        for (uint256 i = 0; i < len; i++) {
            bool ok = _tryRelease(tokens[i], recipients[i], amounts[i]);
            if (ok) {
                emit Released(tokens[i], recipients[i], amounts[i]);
                succeeded++;
            } else {
                emit ReleaseFailed(tokens[i], recipients[i], amounts[i], i);
                failed++;
            }
        }

        emit BatchReleased(succeeded, failed);
    }

    // =========================================================================
    //                    LARGE WITHDRAWAL TIMELOCK (Backend)
    // =========================================================================

    /**
     * @notice Backend queues a large withdrawal (above threshold) with 24h timelock.
     * @param token  Token address
     * @param to     Recipient
     * @param amount Amount (raw units)
     */
    function queueLargeRelease(
        address token,
        address to,
        uint256 amount
    ) external onlyBackend whenNotPaused returns (uint256 timelockId) {
        require(token != address(0), "Vault: zero token");
        require(to != address(0), "Vault: zero recipient");
        require(amount > 0, "Vault: zero amount");

        uint256 threshold = _getLargeThreshold(token);
        require(amount > threshold, "Vault: below threshold, use release()");

        // Prevent rapid re-queuing after cancellation (12-hour cooldown per token)
        require(
            block.timestamp >= lastLargeReleaseQueued[token] + LARGE_RELEASE_REQUEUE_COOLDOWN,
            "Vault: large release requeue cooldown active"
        );
        lastLargeReleaseQueued[token] = block.timestamp;

        timelockId = timelockCount++;
        timelocks[timelockId] = TimelockOp({
            token: token,
            to: to,
            amount: amount,
            executeAfter: block.timestamp + LARGE_WITHDRAWAL_TIMELOCK,
            executed: false,
            cancelled: false,
            isEmergency: false
        });

        emit LargeWithdrawalQueued(timelockId, token, to, amount, block.timestamp + LARGE_WITHDRAWAL_TIMELOCK);
    }

    /**
     * @notice Execute a large withdrawal after the 24h timelock has passed.
     * @param timelockId The timelock operation ID
     */
    function executeLargeRelease(uint256 timelockId) external nonReentrant onlyBackend whenNotPaused {
        TimelockOp storage op = timelocks[timelockId];
        require(!op.executed, "Vault: already executed");
        require(!op.cancelled, "Vault: cancelled");
        require(!op.isEmergency, "Vault: use executeEmergencyWithdraw");
        require(block.timestamp >= op.executeAfter, "Vault: timelock not expired");
        require(op.to != safeAddress, "Vault: invalid destination for large release");

        op.executed = true;

        _checkAndUpdateDailyCap(op.token, op.amount);

        IERC20(op.token).safeTransfer(op.to, op.amount);

        emit LargeWithdrawalExecuted(timelockId);
        emit Released(op.token, op.to, op.amount);
    }

    // =========================================================================
    //                            VIEW FUNCTIONS
    // =========================================================================

    /// @notice Get the vault's actual balance of a specific token.
    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Get a user's LIFETIME deposited total for a specific token.
    ///         NOT the user's current balance — see contract NatDoc.
    function totalDepositedByUser(address user, address token) external view returns (uint256) {
        return totalDeposited[user][token];
    }

    /// @notice Get the daily withdrawal cap for a token.
    function getDailyCap(address token) external view returns (uint256) {
        return _getDailyCap(token);
    }

    /// @notice Get the large withdrawal threshold for a token.
    function getLargeThreshold(address token) external view returns (uint256) {
        return _getLargeThreshold(token);
    }

    /// @notice Get remaining daily withdrawal capacity for a token today.
    function remainingDailyCapacity(address token) external view returns (uint256) {
        uint256 today = block.timestamp / SECONDS_PER_DAY;
        uint256 cap = _getDailyCap(token);
        uint256 used = dailyWithdrawn[token][today];
        return used >= cap ? 0 : cap - used;
    }

    // =========================================================================
    //                         INTERNAL FUNCTIONS
    // =========================================================================

    /**
     * @dev Core release logic. Reverts on failure (used by single release).
     */
    function _release(address token, address to, uint256 amount) internal {
        require(token != address(0), "Vault: zero token");
        require(to != address(0), "Vault: zero recipient");
        require(amount > 0, "Vault: zero amount");

        uint256 threshold = _getLargeThreshold(token);
        require(amount <= threshold, "Vault: exceeds threshold, use queueLargeRelease()");

        _checkAndUpdateDailyCap(token, amount);

        IERC20(token).safeTransfer(to, amount);
    }

    /**
     * @dev Try to release tokens. Returns true on success, false on failure.
     *      Used by batchRelease so one bad transfer doesn't block others.
     */
    function _tryRelease(address token, address to, uint256 amount) internal returns (bool) {
        if (token == address(0) || to == address(0) || amount == 0) return false;

        uint256 threshold = _getLargeThreshold(token);
        if (amount > threshold) return false;

        uint256 today = block.timestamp / SECONDS_PER_DAY;
        uint256 cap = _getDailyCap(token);
        uint256 used = dailyWithdrawn[token][today];
        if (used + amount > cap) return false;

        // Update daily cap before transfer (CEI pattern)
        dailyWithdrawn[token][today] = used + amount;

        // Try the actual token transfer (handles non-standard return values)
        (bool success, bytes memory returndata) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        // Safe decode: no data = success (non-standard tokens like USDT),
        // 32+ bytes = decode as bool, malformed (<32 bytes) = treat as failure
        bool transferred = success && (
            returndata.length == 0 ||
            (returndata.length >= 32 && abi.decode(returndata, (bool)))
        );

        if (!transferred) {
            // Rollback daily cap on transfer failure
            dailyWithdrawn[token][today] = used;
            return false;
        }

        return true;
    }
}
