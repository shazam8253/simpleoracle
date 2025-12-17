// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Type definitions for the Oracle system
library Types {
    // Status transitions: None -> Requested -> Proposed -> (Disputed | Resolved) -> Resolved
    // If Disputed and stake exceeds threshold: Disputed -> Escalated -> Resolved
    enum Status {
        None,       // Request does not exist
        Requested,  // Request initialized, awaiting proposer
        Proposed,   // Result proposed, in liveness period
        Disputed,   // Result disputed, voting in progress
        Resolved,   // Final state - result available
        Escalated   // Stake threshold exceeded, requires manual resolution
    }

    enum Side {
        Proposer,   // Siding with the original proposer
        Disputer    // Siding with the disputer
    }

    struct Request {
        address requester;          // Address that initialized the request
        uint256 reward;             // USDC reward for successful resolution
        uint256 bond;               // Required bond amount in USDC
        bytes32 descriptionHash;    // keccak256 hash of the request description
        Status status;              // Current status of the request
        
        // Proposer data
        address proposer;           // Address that proposed the result
        uint64 proposedAt;          // Timestamp when result was proposed
        bytes proposerResult;       // The proposed result data
        
        // Disputer data
        address disputer;           // Address that disputed the result
        uint64 disputedAt;          // Timestamp when dispute was raised
        bytes disputerResult;       // Alternative result proposed by disputer
        
        // Staking state
        uint256 stakeForProposer;   // Total stake supporting proposer
        uint256 stakeForDisputer;   // Total stake supporting disputer
        
        // Dominance tracking for dispute resolution
        uint8 leadingSide;          // 0 = none, 1 = proposer, 2 = disputer
        uint64 dominanceStartAt;    // When >2x condition started
        
        // Resolution
        bool proposerWins;          // True if proposer wins (valid only if Resolved)
    }
}

