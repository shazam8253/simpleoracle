// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Oracle} from "../src/Oracle.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Types} from "../src/libraries/Types.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @title Oracle Flow Tests
/// @notice End-to-end scenario tests for the Oracle lifecycle
contract OracleFlowTest is Test {
    Oracle public oracle;
    MockUSDC public usdc;

    address public owner = makeAddr("owner");
    address public requester = makeAddr("requester");
    address public proposer = makeAddr("proposer");
    address public disputer = makeAddr("disputer");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");

    uint256 public constant REWARD = 100 * 1e6; // 100 USDC
    uint256 public constant BOND = 50 * 1e6;    // 50 USDC
    bytes public constant DESCRIPTION = "What is the price of ETH?";
    bytes public constant PROPOSER_RESULT = abi.encode(3000);
    bytes public constant DISPUTER_RESULT = abi.encode(2999);

    function setUp() public {
        usdc = new MockUSDC();
        oracle = new Oracle(usdc, owner);

        // Fund all actors with USDC and set approvals
        _fundAndApprove(requester, 1_000_000 * 1e6);
        _fundAndApprove(proposer, 1_000_000 * 1e6);
        _fundAndApprove(disputer, 1_000_000 * 1e6);
        _fundAndApprove(alice, 10_000_000 * 1e6);
        _fundAndApprove(bob, 10_000_000 * 1e6);
        _fundAndApprove(carol, 10_000_000 * 1e6);
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(oracle), type(uint256).max);
    }

    // Undisputed Path

    function test_flow_undisputedPath() public {
        // 1. Initialize request
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        // 2. Propose result
        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        // 3. Warp beyond liveness period
        vm.warp(block.timestamp + oracle.LIVENESS_PERIOD() + 1);

        // 4. Finalize
        uint256 proposerBalanceBefore = usdc.balanceOf(proposer);
        oracle.finalize(requestId);

        // Verify proposer received reward + bond
        assertEq(usdc.balanceOf(proposer), proposerBalanceBefore + REWARD + BOND);

        // Verify getResult returns proposer's result
        bytes memory result = oracle.getResult(requestId);
        assertEq(keccak256(result), keccak256(PROPOSER_RESULT));

        // Verify status is Resolved
        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(uint8(req.status), uint8(Types.Status.Resolved));
        assertTrue(req.proposerWins);
    }

    function test_flow_undisputedPath_cannotFinalizeEarly() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        // Try to finalize within liveness period
        vm.expectRevert(Errors.NotFinalizable.selector);
        oracle.finalize(requestId);
    }

    // Disputed - Proposer Wins

    function test_flow_disputedProposerWins() public {
        // Setup: init → propose → dispute
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Staking: make proposer side >2x disputer
        // Alice stakes 10 for disputer
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Disputer, 10 * 1e6);

        // Bob stakes 25 for proposer (25 > 2*10 = 20)
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, 25 * 1e6);

        // Verify dominance started
        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 1); // proposer leading

        // Warp past dominance duration
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);

        // Finalize
        uint256 proposerBalanceBefore = usdc.balanceOf(proposer);
        oracle.finalize(requestId);

        // Proposer gets reward + 2*bond
        assertEq(usdc.balanceOf(proposer), proposerBalanceBefore + REWARD + 2 * BOND);

        // Verify result
        bytes memory result = oracle.getResult(requestId);
        assertEq(keccak256(result), keccak256(PROPOSER_RESULT));

        // Stakers can claim
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        oracle.claim(requestId);
        
        // Bob's payout: 25 + (25 * 10 / 25) = 25 + 10 = 35
        assertEq(usdc.balanceOf(bob), bobBalanceBefore + 35 * 1e6);

        // Alice (loser) cannot claim
        vm.prank(alice);
        vm.expectRevert(Errors.NoStakeToClaim.selector);
        oracle.claim(requestId);
    }

    // Disputed - Disputer Wins

    function test_flow_disputedDisputerWins() public {
        // Setup: init → propose → dispute
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Staking: make disputer side >2x proposer
        // Alice stakes 10 for proposer
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 10 * 1e6);

        // Bob stakes 25 for disputer (25 > 2*10 = 20)
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 25 * 1e6);

        // Verify dominance started
        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 2); // disputer leading

        // Warp past dominance duration
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);

        // Finalize
        uint256 disputerBalanceBefore = usdc.balanceOf(disputer);
        oracle.finalize(requestId);

        // Disputer gets reward + 2*bond
        assertEq(usdc.balanceOf(disputer), disputerBalanceBefore + REWARD + 2 * BOND);

        // Verify result is disputer's
        bytes memory result = oracle.getResult(requestId);
        assertEq(keccak256(result), keccak256(DISPUTER_RESULT));

        // Bob can claim as winner
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        oracle.claim(requestId);
        
        // Bob's payout: 25 + (25 * 10 / 25) = 25 + 10 = 35
        assertEq(usdc.balanceOf(bob), bobBalanceBefore + 35 * 1e6);
    }

    // Disputed - Multiple Stakers

    function test_flow_multipleStakersProRata() public {
        // Setup
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Staking scenario:
        // Disputer side: Alice = 20, losing side total = 20
        // Proposer side: Bob = 30, Carol = 15, winning side total = 45
        
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Disputer, 20 * 1e6);

        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, 30 * 1e6);

        vm.prank(carol);
        oracle.stake(requestId, Types.Side.Proposer, 15 * 1e6);

        // 45 > 2*20 = 40, proposer dominates
        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 1);

        // Warp and finalize
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        oracle.finalize(requestId);

        // Bob claims: 30 + (30 * 20 / 45) = 30 + 13.33... = 43.33...
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        oracle.claim(requestId);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBalanceBefore;
        
        // Expected: 30 + (30 * 20 / 45) = 30 + 13333333 (with rounding)
        uint256 expectedBobPayout = uint256(30 * 1e6) + (uint256(30) * 20 * 1e6) / 45;
        assertApproxEqAbs(bobPayout, expectedBobPayout, 1);

        // Carol claims: 15 + (15 * 20 / 45) = 15 + 6.66... = 21.66...
        uint256 carolBalanceBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        oracle.claim(requestId);
        uint256 carolPayout = usdc.balanceOf(carol) - carolBalanceBefore;
        
        uint256 expectedCarolPayout = uint256(15 * 1e6) + (uint256(15) * 20 * 1e6) / 45;
        assertApproxEqAbs(carolPayout, expectedCarolPayout, 1);
    }

    // Escalated Path

    function test_flow_escalatedPath() public {
        // Setup
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Stake up to threshold
        uint256 threshold = oracle.MANUAL_THRESHOLD();
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, threshold);

        // Verify escalated
        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(uint8(req.status), uint8(Types.Status.Escalated));

        // Finalize should revert
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        vm.expectRevert(Errors.InvalidStatus.selector);
        oracle.finalize(requestId);

        // Only owner can resolve manually
        vm.prank(alice);
        vm.expectRevert();
        oracle.resolveManually(requestId, true);

        // Owner resolves - proposer wins
        uint256 proposerBalanceBefore = usdc.balanceOf(proposer);
        vm.prank(owner);
        oracle.resolveManually(requestId, true);

        // Proposer gets reward + 2*bond
        assertEq(usdc.balanceOf(proposer), proposerBalanceBefore + REWARD + 2 * BOND);

        // Staker can claim
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oracle.claim(requestId);
        // No losing pool, so just gets stake back
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + threshold);
    }

    function test_flow_escalatedDisputerWins() public {
        // Setup
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Stake up to threshold
        uint256 threshold = oracle.MANUAL_THRESHOLD();
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Disputer, threshold);

        // Owner resolves - disputer wins
        uint256 disputerBalanceBefore = usdc.balanceOf(disputer);
        vm.prank(owner);
        oracle.resolveManually(requestId, false);

        // Disputer gets reward + 2*bond
        assertEq(usdc.balanceOf(disputer), disputerBalanceBefore + REWARD + 2 * BOND);

        // Verify result
        bytes memory result = oracle.getResult(requestId);
        assertEq(keccak256(result), keccak256(DISPUTER_RESULT));
    }

    function test_flow_manualResolution_losersReclaimWhenNoWinners() public {
        // Edge case: all stakers bet on the losing side
        // Admin resolves in favor of the side with no stakers
        // Losers should be able to reclaim their stakes
        
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Everyone stakes on DISPUTER side only
        uint256 aliceStake = 60_000 * 1e6;
        uint256 bobStake = 40_000 * 1e6;
        
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Disputer, aliceStake);

        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, bobStake);

        // Total stake = 100k, triggers escalation
        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(uint8(req.status), uint8(Types.Status.Escalated));
        assertEq(req.stakeForProposer, 0); // No one on proposer side!
        assertEq(req.stakeForDisputer, aliceStake + bobStake);

        // Admin resolves in favor of PROPOSER (the side with 0 stakers)
        vm.prank(owner);
        oracle.resolveManually(requestId, true);

        // Alice (on losing side) should be able to reclaim her stake
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oracle.claim(requestId);
        assertEq(usdc.balanceOf(alice), aliceBalanceBefore + aliceStake);

        // Bob (on losing side) should be able to reclaim his stake
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        oracle.claim(requestId);
        assertEq(usdc.balanceOf(bob), bobBalanceBefore + bobStake);
    }

    // Edge Cases

    function test_flow_dominanceReset() public {
        // Setup
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Proposer dominates
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, 30 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 1);

        // Warp some time but not enough
        vm.warp(block.timestamp + 10 minutes);

        // Disputer catches up - dominance resets
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Disputer, 20 * 1e6);

        req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 0);

        // Cannot finalize even after original dominance duration would have passed
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        vm.expectRevert(Errors.NotFinalizable.selector);
        oracle.finalize(requestId);
    }

    function test_flow_cannotDoubleClaimStake() public {
        // Setup disputed and resolved
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, 25 * 1e6);

        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        oracle.finalize(requestId);

        // First claim succeeds
        vm.prank(bob);
        oracle.claim(requestId);

        // Second claim fails
        vm.prank(bob);
        vm.expectRevert(Errors.AlreadyClaimed.selector);
        oracle.claim(requestId);
    }

    function test_flow_noStakingScenario() public {
        // Disputed but no staking - should be stuck
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Warp past dominance duration
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);

        // Cannot finalize - no dominance
        vm.expectRevert(Errors.NotFinalizable.selector);
        oracle.finalize(requestId);
    }

    function test_flow_equalStakingScenario() public {
        // Disputed with equal stakes - no dominance
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 50 * 1e6);

        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 50 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 0);

        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);

        vm.expectRevert(Errors.NotFinalizable.selector);
        oracle.finalize(requestId);
    }

    // resolveManually Edge Cases

    function test_flow_resolveManually_revertsIfNotEscalated() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Not escalated
        vm.prank(owner);
        vm.expectRevert(Errors.OnlyEscalated.selector);
        oracle.resolveManually(requestId, true);
    }

    // Payout Calculation Verification

    function test_payout_totalPayoutsEqualTotalStaked() public {
        // Verify that sum of all payouts equals sum of all stakes (minus rounding dust)
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Stakes on proposer side (winners) - need >2x losing side
        uint256 aliceStake = 33 * 1e6;  // 33 USDC
        uint256 bobStake = 33 * 1e6;    // 33 USDC  
        uint256 carolStake = 35 * 1e6;  // 35 USDC (increased to ensure >2x)
        uint256 totalWinningStake = aliceStake + bobStake + carolStake; // 101 USDC

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, aliceStake);
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, bobStake);
        vm.prank(carol);
        oracle.stake(requestId, Types.Side.Proposer, carolStake);

        // Stakes on disputer side (losers) - must be < half of winning
        address dave = makeAddr("dave");
        _fundAndApprove(dave, 1_000_000 * 1e6);
        uint256 daveStake = 49 * 1e6;   // 49 USDC (101 > 2*49 = 98 ✓)
        
        vm.prank(dave);
        oracle.stake(requestId, Types.Side.Disputer, daveStake);

        uint256 totalStaked = totalWinningStake + daveStake; // 150 USDC

        // Proposer side has >2x disputer (101 > 2*49 = 98), so proposer dominant
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        oracle.finalize(requestId);

        // Track contract balance before claims
        uint256 contractBalanceBefore = usdc.balanceOf(address(oracle));

        // All winners claim
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oracle.claim(requestId);
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBalBefore;

        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        oracle.claim(requestId);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBalBefore;

        uint256 carolBalBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        oracle.claim(requestId);
        uint256 carolPayout = usdc.balanceOf(carol) - carolBalBefore;

        uint256 totalPaidOut = alicePayout + bobPayout + carolPayout;
        uint256 contractBalanceAfter = usdc.balanceOf(address(oracle));

        // Total paid out should be <= total staked (rounding takes dust)
        assertLe(totalPaidOut, totalStaked, "Paid out more than staked");
        
        // Dust should be minimal (< 10 wei per staker)
        uint256 dust = totalStaked - totalPaidOut;
        assertLt(dust, 30, "Too much dust from rounding");

        // Contract balance should have decreased by totalPaidOut
        assertEq(contractBalanceBefore - contractBalanceAfter, totalPaidOut);
    }

    function test_payout_singleWinnerGetsEverything() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Single winner stakes
        uint256 aliceStake = 100 * 1e6;
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, aliceStake);

        // Multiple losers stake
        address dave = makeAddr("dave");
        address eve = makeAddr("eve");
        _fundAndApprove(dave, 1_000_000 * 1e6);
        _fundAndApprove(eve, 1_000_000 * 1e6);
        
        uint256 daveStake = 20 * 1e6;
        uint256 eveStake = 25 * 1e6;
        uint256 totalLosingStake = daveStake + eveStake;

        vm.prank(dave);
        oracle.stake(requestId, Types.Side.Disputer, daveStake);
        vm.prank(eve);
        oracle.stake(requestId, Types.Side.Disputer, eveStake);

        // Alice dominates: 100 > 2*45 = 90
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        oracle.finalize(requestId);

        // Alice should get her stake + entire losing pool
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oracle.claim(requestId);
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBalBefore;

        // Expected: 100 + (100 * 45 / 100) = 100 + 45 = 145
        assertEq(alicePayout, aliceStake + totalLosingStake);
    }

    function test_payout_proRataDistribution() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Winners: Alice 60%, Bob 40% (total winning pool = 100 USDC)
        uint256 aliceStake = 60 * 1e6;
        uint256 bobStake = 40 * 1e6;

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, aliceStake);
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, bobStake);

        // Losers
        address dave = makeAddr("dave");
        _fundAndApprove(dave, 1_000_000 * 1e6);
        uint256 losingPool = 40 * 1e6;
        
        vm.prank(dave);
        oracle.stake(requestId, Types.Side.Disputer, losingPool);

        // Winners dominate: 100 > 2*40 = 80
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        oracle.finalize(requestId);

        // Alice: 60% of winning pool, should get 60% of losing pool
        // Expected: 60 + (60 * 40 / 100) = 60 + 24 = 84
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oracle.claim(requestId);
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBalBefore;
        assertEq(alicePayout, 84 * 1e6);

        // Bob: 40% of winning pool, should get 40% of losing pool
        // Expected: 40 + (40 * 40 / 100) = 40 + 16 = 56
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        oracle.claim(requestId);
        uint256 bobPayout = usdc.balanceOf(bob) - bobBalBefore;
        assertEq(bobPayout, 56 * 1e6);

        // Total distributed = 84 + 56 = 140 = 100 (winning) + 40 (losing) ✓
    }

    function test_payout_noLosingPoolJustReturnsStake() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Only winners stake, no losers
        uint256 aliceStake = 100 * 1e6;
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, aliceStake);

        // Escalate to allow manual resolution (since no disputer stakes = no dominance possible)
        uint256 threshold = oracle.MANUAL_THRESHOLD();
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, threshold - aliceStake);

        // Admin resolves
        vm.prank(owner);
        oracle.resolveManually(requestId, true);

        // Alice should just get her stake back (no losing pool to distribute)
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oracle.claim(requestId);
        uint256 alicePayout = usdc.balanceOf(alice) - aliceBalBefore;
        
        assertEq(alicePayout, aliceStake, "Should just return stake when no losing pool");
    }

    function test_payout_losersCannotClaimNormally() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Alice wins
        uint256 aliceStake = 100 * 1e6;
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, aliceStake);

        // Bob loses
        uint256 bobStake = 40 * 1e6;
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, bobStake);

        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        oracle.finalize(requestId);

        // Bob (loser) should NOT be able to claim when winners exist
        vm.prank(bob);
        vm.expectRevert(Errors.NoStakeToClaim.selector);
        oracle.claim(requestId);
    }

    function test_payout_verifyExactMath() public {
        // Verify exact calculation with known values
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        // Winning pool: 1000 USDC
        // Losing pool: 400 USDC (need 1000 > 2*400 = 800 for dominance)
        // Alice stakes 700, Bob stakes 300
        uint256 aliceStake = 700 * 1e6;
        uint256 bobStake = 300 * 1e6;
        uint256 losingPool = 400 * 1e6;

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, aliceStake);
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Proposer, bobStake);

        address dave = makeAddr("dave");
        _fundAndApprove(dave, 1_000_000 * 1e6);
        vm.prank(dave);
        oracle.stake(requestId, Types.Side.Disputer, losingPool);

        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);
        oracle.finalize(requestId);

        // Alice payout = 700 + (700 * 400 / 1000) = 700 + 280 = 980
        uint256 aliceBalBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        oracle.claim(requestId);
        assertEq(usdc.balanceOf(alice) - aliceBalBefore, 980 * 1e6);

        // Bob payout = 300 + (300 * 400 / 1000) = 300 + 120 = 420
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        oracle.claim(requestId);
        assertEq(usdc.balanceOf(bob) - bobBalBefore, 420 * 1e6);
    }
}

