// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Oracle} from "../src/Oracle.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Types} from "../src/libraries/Types.sol";
import {OracleHandler} from "./handlers/OracleHandler.sol";

// Invariant tests to verify Oracle system properties hold under fuzzing
contract OracleInvariantTest is Test {
    Oracle public oracle;
    MockUSDC public usdc;
    OracleHandler public handler;

    address public owner = makeAddr("owner");

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new Oracle(usdc, owner);
        handler = new OracleHandler(oracle, usdc, owner);

        // Add initial actors
        handler.addActor(makeAddr("alice"));
        handler.addActor(makeAddr("bob"));
        handler.addActor(makeAddr("carol"));
        handler.addActor(makeAddr("dave"));
        handler.addActor(makeAddr("eve"));

        // Configure invariant testing
        targetContract(address(handler));

        // Selectively target handler functions
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = OracleHandler.initializeRequest.selector;
        selectors[1] = OracleHandler.proposeResult.selector;
        selectors[2] = OracleHandler.dispute.selector;
        selectors[3] = OracleHandler.stake.selector;
        selectors[4] = OracleHandler.finalize.selector;
        selectors[5] = OracleHandler.claim.selector;
        selectors[6] = OracleHandler.resolveManually.selector;
        selectors[7] = OracleHandler.warpTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // Invariant: No Double Claims
    // A user should never be able to claim twice for the same request
    function invariant_noDoubleClaims() public view {
        uint256 requestCount = handler.requestCount();
        
        for (uint256 i = 0; i < requestCount; i++) {
            bytes32 requestId = handler.allRequestIds(i);
            Types.Request memory req = oracle.getRequest(requestId);
            
            if (req.status == Types.Status.Resolved) {
                // Check all actors haven't double claimed
                uint256 actorCount = handler.actorCount();
                for (uint256 j = 0; j < actorCount; j++) {
                    address actor = handler.actors(j);
                    // If handler shows claimed, oracle's claimed must also be true
                    if (handler.ghost_hasClaimed(requestId, actor)) {
                        assertTrue(oracle.claimed(requestId, actor));
                    }
                }
            }
        }
    }

    // Invariant: Existing Requests Have Valid Status
    // Any request that exists should have a non-None status
    function invariant_existingRequestsHaveValidStatus() public view {
        uint256 requestCount = handler.requestCount();
        
        for (uint256 i = 0; i < requestCount; i++) {
            bytes32 requestId = handler.allRequestIds(i);
            Types.Request memory req = oracle.getRequest(requestId);
            
            // Status should never be None for existing requests
            assertTrue(uint8(req.status) > 0, "Request status should not be None");
            
            // Resolved requests must have a proposer (someone proposed a result)
            if (req.status == Types.Status.Resolved) {
                assertTrue(req.proposer != address(0), "Resolved request must have proposer");
            }
        }
    }

    // Invariant: Contract Balance Solvency
    // The contract should never pay out more than it has received
    function invariant_contractSolvency() public view {
        // Total paid out should never exceed total deposited
        assertTrue(
            handler.ghost_totalPaidOut() <= handler.ghost_totalDeposited(),
            "Paid out more than deposited"
        );
    }

    // Invariant: Stake Tracking Consistency
    // Total stakes for each side should match sum of individual stakes
    function invariant_stakeConsistency() public view {
        uint256 requestCount = handler.requestCount();
        
        for (uint256 i = 0; i < requestCount; i++) {
            bytes32 requestId = handler.allRequestIds(i);
            Types.Request memory req = oracle.getRequest(requestId);
            
            if (req.status == Types.Status.Disputed || 
                req.status == Types.Status.Escalated ||
                req.status == Types.Status.Resolved) {
                
                // Sum individual stakes and verify against pool totals
                uint256 sumP = 0;
                uint256 sumD = 0;
                uint256 actorCount = handler.actorCount();
                
                for (uint256 j = 0; j < actorCount; j++) {
                    address actor = handler.actors(j);
                    sumP += oracle.stakeP(requestId, actor);
                    sumD += oracle.stakeD(requestId, actor);
                }
                
                assertEq(sumP, req.stakeForProposer, "Proposer stake mismatch");
                assertEq(sumD, req.stakeForDisputer, "Disputer stake mismatch");
            }
        }
    }

    // Invariant: Dominance Rules
    // Dominance should only be set when one side has >2x stake
    function invariant_dominanceRules() public view {
        uint256 requestCount = handler.requestCount();
        
        for (uint256 i = 0; i < requestCount; i++) {
            bytes32 requestId = handler.allRequestIds(i);
            Types.Request memory req = oracle.getRequest(requestId);
            
            if (req.status == Types.Status.Disputed) {
                if (req.leadingSide == 1) {
                    // Proposer leading: P > 2*D
                    assertTrue(
                        req.stakeForProposer > 2 * req.stakeForDisputer,
                        "Proposer dominance invalid"
                    );
                } else if (req.leadingSide == 2) {
                    // Disputer leading: D > 2*P
                    assertTrue(
                        req.stakeForDisputer > 2 * req.stakeForProposer,
                        "Disputer dominance invalid"
                    );
                } else {
                    // No dominance: neither >2x
                    assertTrue(
                        req.stakeForProposer <= 2 * req.stakeForDisputer &&
                        req.stakeForDisputer <= 2 * req.stakeForProposer,
                        "Should have dominance"
                    );
                }
            }
        }
    }

    // Invariant: Resolved Requests Return Valid Result
    // A resolved request should return a non-reverting result
    function invariant_resolvedReturnsResult() public view {
        uint256 requestCount = handler.requestCount();
        
        for (uint256 i = 0; i < requestCount; i++) {
            bytes32 requestId = handler.allRequestIds(i);
            Types.Request memory req = oracle.getRequest(requestId);
            
            if (req.status == Types.Status.Resolved) {
                // getResult should not revert for resolved requests
                bytes memory result = oracle.getResult(requestId);
                
                // Result should match either proposer or disputer result
                if (req.proposerWins) {
                    assertEq(keccak256(result), keccak256(req.proposerResult), "Result mismatch");
                } else {
                    assertEq(keccak256(result), keccak256(req.disputerResult), "Result mismatch");
                }
            }
        }
    }

}

