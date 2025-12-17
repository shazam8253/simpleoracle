// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Custom error definitions for the Oracle system
library Errors {
    // Thrown when a required amount is zero or invalid
    error InvalidAmount();
    // Thrown when the request status doesn't allow the operation
    error InvalidStatus();
    // Thrown when an operation is attempted outside the liveness period
    error NotWithinLiveness();
    // Thrown when finalize conditions are not met
    error NotFinalizable();
    // Thrown when a user attempts to claim twice
    error AlreadyClaimed();
    // Thrown when accessing result before resolution
    error NotResolved();
    // Thrown when a non-escalated request is passed to manual resolution
    error OnlyEscalated();
    // Thrown when a zero address is provided
    error ZeroAddress();
    // Thrown when caller has no stake to claim
    error NoStakeToClaim();
}

