// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// Shared structs, constants, and events for the PreselloVault system.

// =========================================================================
//                              CONSTANTS
// =========================================================================

uint256 constant PROPOSAL_EXPIRY = 7 days;
uint256 constant EMERGENCY_TIMELOCK = 72 hours;
uint256 constant LARGE_WITHDRAWAL_TIMELOCK = 24 hours;
uint256 constant SIGNER_ROTATION_TIMELOCK = 7 days;
uint256 constant CHANGE_BACKEND_TIMELOCK = 24 hours;
uint256 constant PAUSE_COOLDOWN = 4 hours;
uint256 constant RESCUE_TIMELOCK = 24 hours;
uint256 constant LARGE_RELEASE_REQUEUE_COOLDOWN = 12 hours;
uint256 constant SECONDS_PER_DAY = 86400;
uint256 constant MAX_BATCH_SIZE = 50;

// =========================================================================
//                           PROPOSAL TYPES
// =========================================================================

uint8 constant PROPOSAL_UNPAUSE = 1;
uint8 constant PROPOSAL_CHANGE_BACKEND = 2;
uint8 constant PROPOSAL_EMERGENCY_WITHDRAW = 3;
uint8 constant PROPOSAL_ROTATE_SIGNER = 4;
uint8 constant PROPOSAL_RESCUE_TOKEN = 5;

// =========================================================================
//                              STRUCTS
// =========================================================================

struct Proposal {
    uint8 proposalType;
    address proposer;
    address token;          // used for: emergency withdraw, rescue token
    address newAddress;     // used for: change backend, rotate signer (new signer)
    address oldAddress;     // used for: rotate signer (old signer)
    uint256 createdAt;
    uint256 executeAfter;   // >0 for delayed proposals (signer rotation)
    bool approved;          // true when 2-of-3 reached
    bool executed;
    bool cancelled;
}

struct TimelockOp {
    address token;
    address to;
    uint256 amount;
    uint256 executeAfter;
    bool executed;
    bool cancelled;
    bool isEmergency;       // emergency timelocks require 2-of-3 to cancel
}
