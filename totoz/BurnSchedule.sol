// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BurnSchedule — Two-phase token burn over 5 years (halving curve)
 * @notice Phase 1 (TRUSTLESS): First 41 months burn ~90% of supply.
 *         Anyone can call — no role required, unstoppable.
 *         Phase 2 (DISCRETIONARY): Months 42-60 burn remaining ~5%.
 *         Requires EXECUTOR_ROLE — can be paused or stopped.
 *
 *         Halving curve:
 *         Year 1: 50% burned (50.00% remaining)
 *         Year 2: 50% burned (25.00% remaining)
 *         Year 3: 50% burned (12.50% remaining)
 *         Year 4: 50% burned ( 6.25% remaining)  ← month 41 crosses 90%
 *         Year 5: final burn ( 5.00% remaining)
 *
 *         Monthly burns within each year are equal (annual amount / 12).
 *         Requires BURNER_ROLE on both token contracts.
 *
 *         Catch-up behavior: if burns are missed for N months, all N can be
 *         executed in rapid succession. The schedule stays on track regardless
 *         of delays. This is intentional — the burn schedule is time-based,
 *         not execution-based.
 *
 *         Security review rounds 1+2 applied June 13, 2026 — CEI reorder,
 *         check reorder, canBurn phase-aware, renounceRole blocked, pause added.
 *
 *         Constructor params: _totoz (TOTOz token), _ozt (OZT token),
 *         _burnSource (wallet holding unallocated supply), admin (Gnosis Safe multi-sig).
 */
contract BurnSchedule is AccessControl, ReentrancyGuard {
    // --- Custom Errors ---
    error ZeroAddress();
    error AlreadyStarted();
    error ScheduleNotStarted();
    error BurnScheduleComplete();
    error TooEarly();
    error BurnSchedulePausedError();
    error DiscretionaryPhaseExecutorOnly();
    error CannotRenounceAdminRole();

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    /// @notice TOTOz token contract
    IBurnable public immutable totoz;
    /// @notice OZT token contract
    IBurnable public immutable ozt;
    /// @notice Wallet holding unallocated supply (multi-sig)
    address public immutable burnSource;

    /// @notice Total months in the burn schedule (5 years)
    uint256 public constant TOTAL_MONTHS = 60;
    /// @notice Minimum interval between burns
    uint256 public constant BURN_INTERVAL = 30 days;
    /// @notice First 41 months are trustless (~90% burn). Anyone can call.
    uint256 public constant TRUSTLESS_MONTHS = 41;

    /// @dev Monthly burn amounts per year (TOTOz). Precomputed: 50% of remaining / 12 months.
    ///      Year 5 burns the remaining down to 5% of original 8Q supply.
    ///      Rounding: ±4 tokens over 60 months, negligible at quadrillion scale.
    uint256[5] public TOTOZ_MONTHLY = [
        333_333_333_333_333 * 10 ** 18,  // Year 1: 4,000T / 12
         166_666_666_666_667 * 10 ** 18, // Year 2: 2,000T / 12
          83_333_333_333_333 * 10 ** 18, // Year 3: 1,000T / 12
          41_666_666_666_667 * 10 ** 18, // Year 4: 500T / 12
           8_333_333_333_333 * 10 ** 18  // Year 5: 100T / 12 (cleanup to 5%)
    ];

    /// @dev Monthly burn amounts per year (OZT). Same halving pattern.
    ///      Burns 950M of 1B OZT total (95%) over 60 months.
    uint256[5] public OZT_MONTHLY = [
        41_666_667 * 10 ** 18,  // Year 1: 500M / 12
        20_833_333 * 10 ** 18,  // Year 2: 250M / 12
        10_416_667 * 10 ** 18,  // Year 3: 125M / 12
         5_208_333 * 10 ** 18,  // Year 4: 62.5M / 12
         1_041_667 * 10 ** 18   // Year 5: 12.5M / 12 (cleanup to 5%)
    ];

    /// @notice Number of monthly burns completed
    uint256 public monthsCompleted;
    /// @notice Timestamp of the last burn execution
    uint256 public lastBurnTimestamp;
    /// @notice Timestamp when the burn schedule started
    uint256 public startTimestamp;
    /// @notice Emergency pause for Phase 2 discretionary burns
    bool public paused;

    event MonthlyBurnExecuted(
        uint256 indexed month,
        uint256 totozzBurned,
        uint256 oztBurned,
        uint256 timestamp
    );
    event BurnScheduleStarted(uint256 startTimestamp);
    event BurnSchedulePaused(bool paused);

    constructor(
        address _totoz,
        address _ozt,
        address _burnSource,
        address admin
    ) {
        if (_totoz == address(0)) revert ZeroAddress();
        if (_ozt == address(0)) revert ZeroAddress();
        if (_burnSource == address(0)) revert ZeroAddress();
        if (admin == address(0)) revert ZeroAddress();

        totoz = IBurnable(_totoz);
        ozt = IBurnable(_ozt);
        burnSource = _burnSource;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EXECUTOR_ROLE, admin);
    }

    /**
     * @notice Start the burn schedule. Can only be called once.
     *         Sets the clock for the first burn.
     */
    function startSchedule() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (startTimestamp != 0) revert AlreadyStarted();
        startTimestamp = block.timestamp;
        lastBurnTimestamp = block.timestamp;
        emit BurnScheduleStarted(block.timestamp);
    }

    /**
     * @notice Pause or unpause Phase 2 discretionary burns.
     *         Phase 1 (trustless) cannot be paused.
     * @param _paused Whether to pause (true) or unpause (false)
     */
    function setPaused(bool _paused) external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = _paused;
        emit BurnSchedulePaused(_paused);
    }

    /**
     * @notice Execute the next monthly burn.
     *         Phase 1 (months 0-40): TRUSTLESS — anyone can call. Unstoppable. Cannot be paused.
     *         Phase 2 (months 41-59): DISCRETIONARY — EXECUTOR_ROLE or admin only. Can be paused.
     *         Reverts if called before 30 days since last burn.
     *         Reverts if all 60 months are complete.
     *
     *         If burns are missed, they can be caught up in rapid succession.
     *         lastBurnTimestamp increments by 30 days per call (not block.timestamp),
     *         keeping the schedule on track regardless of execution delays.
     *
     *         Follows Checks-Effects-Interactions pattern: state is updated before
     *         external calls to prevent reentrancy and ensure atomicity.
     */
    function executeBurn() external nonReentrant {
        // --- CHECKS ---
        if (startTimestamp == 0) revert ScheduleNotStarted();
        if (monthsCompleted >= TOTAL_MONTHS) revert BurnScheduleComplete();
        if (block.timestamp < lastBurnTimestamp + BURN_INTERVAL) revert TooEarly();

        // Phase 2: require role + not paused
        if (monthsCompleted >= TRUSTLESS_MONTHS) {
            if (paused) revert BurnSchedulePausedError();
            if (!hasRole(EXECUTOR_ROLE, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
                revert DiscretionaryPhaseExecutorOnly();
            }
        }
        // Phase 1 (trustless): no role check, no pause check — anyone can call

        uint256 year = monthsCompleted / 12;
        uint256 totozzToBurn = TOTOZ_MONTHLY[year];
        uint256 oztToBurn = OZT_MONTHLY[year];

        // --- EFFECTS (before external calls — CEI pattern) ---
        // Increment by interval (not block.timestamp) to allow catch-up if months were missed.
        lastBurnTimestamp = lastBurnTimestamp + BURN_INTERVAL;
        ++monthsCompleted;

        // --- INTERACTIONS ---
        totoz.burnFrom(burnSource, totozzToBurn);
        ozt.burnFrom(burnSource, oztToBurn);

        emit MonthlyBurnExecuted(monthsCompleted, totozzToBurn, oztToBurn, block.timestamp);
    }

    /// @notice Prevent accidental renounce of DEFAULT_ADMIN_ROLE.
    /// @param role The role to renounce
    /// @param callerConfirmation The address confirming the renounce
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Returns true if the burn is still in the trustless phase.
    /// @return Whether the schedule is in the trustless phase
    function isTrustlessPhase() external view returns (bool) {
        return monthsCompleted < TRUSTLESS_MONTHS;
    }

    /// @notice Returns the number of months remaining in the burn schedule.
    /// @return The number of months left
    function remainingMonths() external view returns (uint256) {
        return TOTAL_MONTHS - monthsCompleted;
    }

    /// @notice Returns the timestamp when the next burn can be executed.
    /// @return The next eligible burn timestamp, or 0 if complete or not started
    function nextBurnTimestamp() external view returns (uint256) {
        if (monthsCompleted >= TOTAL_MONTHS) return 0;
        if (startTimestamp == 0) return 0;
        return lastBurnTimestamp + BURN_INTERVAL;
    }

    /**
     * @notice Returns true if a burn can be executed now by the caller.
     *         Phase-aware: returns false for unauthorized callers in Phase 2.
     * @return Whether a burn can be executed by msg.sender right now
     */
    function canBurn() external view returns (bool) {
        if (startTimestamp == 0) return false;
        if (monthsCompleted >= TOTAL_MONTHS) return false;
        if (block.timestamp < lastBurnTimestamp + BURN_INTERVAL) return false;
        if (monthsCompleted >= TRUSTLESS_MONTHS) {
            if (paused) return false;
            return hasRole(EXECUTOR_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
        }
        return true;
    }
}

/**
 * @dev Interface for token contracts with burnFrom function.
 */
interface IBurnable {
    /// @notice Burn tokens from a designated account.
    /// @param account The account to burn from
    /// @param amount The amount of tokens to burn
    function burnFrom(address account, uint256 amount) external;
}
