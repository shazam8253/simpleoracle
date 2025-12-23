// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {Oracle} from "../src/Oracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {Types} from "../src/libraries/Types.sol";
import {Errors} from "../src/libraries/Errors.sol";

/// @title Oracle Unit Tests
/// @notice Tight unit test coverage for individual Oracle functions
contract OracleUnitTest is Test {
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
        _fundAndApprove(alice, 1_000_000 * 1e6);
        _fundAndApprove(bob, 1_000_000 * 1e6);
        _fundAndApprove(carol, 1_000_000 * 1e6);
    }

    function _fundAndApprove(address account, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(oracle), type(uint256).max);
    }

    // Constructor Tests 

    function test_constructor_setsUsdcAndOwner() public view {
        assertEq(address(oracle.usdc()), address(usdc));
        assertEq(oracle.owner(), owner);
    }

    function test_constructor_revertsOnZeroUsdc() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Oracle(MockUSDC(address(0)), owner);
    }

    function test_constructor_revertsOnZeroOwner() public {
        // Ownable constructor reverts with OwnableInvalidOwner before our check
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new Oracle(usdc, address(0));
    }

    //  initalizeRequest Tests 

    function test_initalizeRequest_createsRequest() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        Types.Request memory req = oracle.getRequest(requestId);
        
        assertEq(req.requester, requester);
        assertEq(req.reward, REWARD);
        assertEq(req.bond, BOND);
        assertEq(req.descriptionHash, keccak256(DESCRIPTION));
        assertEq(uint8(req.status), uint8(Types.Status.Requested));
    }

    function test_initalizeRequest_pullsReward() public {
        uint256 balanceBefore = usdc.balanceOf(requester);
        
        vm.prank(requester);
        oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        assertEq(usdc.balanceOf(requester), balanceBefore - REWARD);
        assertEq(usdc.balanceOf(address(oracle)), REWARD);
    }

    function test_initalizeRequest_emitsEvent() public {
        bytes32 descriptionHash = keccak256(DESCRIPTION);
        bytes32 expectedId = keccak256(
            abi.encode(requester, 0, block.chainid, descriptionHash)
        );

        vm.expectEmit(true, true, true, true);
        emit IOracle.RequestInitialized(expectedId, requester, REWARD, BOND, descriptionHash);

        vm.prank(requester);
        oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);
    }

    function test_initalizeRequest_revertsOnZeroReward() public {
        vm.prank(requester);
        vm.expectRevert(Errors.InvalidAmount.selector);
        oracle.initalizeRequest(0, BOND, DESCRIPTION);
    }

    function test_initalizeRequest_revertsOnZeroBond() public {
        vm.prank(requester);
        vm.expectRevert(Errors.InvalidAmount.selector);
        oracle.initalizeRequest(REWARD, 0, DESCRIPTION);
    }

    function test_initalizeRequest_incrementsNonce() public {
        assertEq(oracle.nonce(), 0);
        
        vm.prank(requester);
        oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);
        assertEq(oracle.nonce(), 1);

        vm.prank(requester);
        oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);
        assertEq(oracle.nonce(), 2);
    }

    // proposeResult Tests

    function test_proposeResult_setsFields() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        Types.Request memory req = oracle.getRequest(requestId);
        
        assertEq(req.proposer, proposer);
        assertEq(req.proposedAt, block.timestamp);
        assertEq(keccak256(req.proposerResult), keccak256(PROPOSER_RESULT));
        assertEq(uint8(req.status), uint8(Types.Status.Proposed));
    }

    function test_proposeResult_pullsBond() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        uint256 balanceBefore = usdc.balanceOf(proposer);
        
        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        assertEq(usdc.balanceOf(proposer), balanceBefore - BOND);
        assertEq(usdc.balanceOf(address(oracle)), REWARD + BOND);
    }

    function test_proposeResult_emitsEvent() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.expectEmit(true, true, true, true);
        emit IOracle.ResultProposed(requestId, proposer);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);
    }

    function test_proposeResult_revertsOnInvalidStatus() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);

        // Try to propose again - should fail
        vm.prank(proposer);
        vm.expectRevert(Errors.InvalidStatus.selector);
        oracle.proposeResult(requestId, PROPOSER_RESULT);
    }

    // dispute Tests 

    function test_dispute_setsFields() public {
        bytes32 requestId = _initAndPropose();

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        Types.Request memory req = oracle.getRequest(requestId);
        
        assertEq(req.disputer, disputer);
        assertEq(req.disputedAt, block.timestamp);
        assertEq(keccak256(req.disputerResult), keccak256(DISPUTER_RESULT));
        assertEq(uint8(req.status), uint8(Types.Status.Disputed));
    }

    function test_dispute_pullsBond() public {
        bytes32 requestId = _initAndPropose();

        uint256 balanceBefore = usdc.balanceOf(disputer);
        
        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        assertEq(usdc.balanceOf(disputer), balanceBefore - BOND);
        assertEq(usdc.balanceOf(address(oracle)), REWARD + 2 * BOND);
    }

    function test_dispute_emitsEvent() public {
        bytes32 requestId = _initAndPropose();

        vm.expectEmit(true, true, true, true);
        emit IOracle.Disputed(requestId, disputer);

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);
    }

    function test_dispute_revertsOnInvalidStatus() public {
        vm.prank(requester);
        bytes32 requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        // Try to dispute before proposal - should fail
        vm.prank(disputer);
        vm.expectRevert(Errors.InvalidStatus.selector);
        oracle.dispute(requestId, DISPUTER_RESULT);
    }

    function test_dispute_revertsAfterLivenessPeriod() public {
        bytes32 requestId = _initAndPropose();

        // Warp past liveness period
        vm.warp(block.timestamp + oracle.LIVENESS_PERIOD() + 1);

        vm.prank(disputer);
        vm.expectRevert(Errors.NotWithinLiveness.selector);
        oracle.dispute(requestId, DISPUTER_RESULT);
    }

    function test_dispute_worksAtExactLivenessBoundary() public {
        bytes32 requestId = _initAndPropose();

        // Warp to exact end of liveness period
        vm.warp(block.timestamp + oracle.LIVENESS_PERIOD());

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(uint8(req.status), uint8(Types.Status.Disputed));
    }

    // stake Tests

    function test_stake_updatesPoolsForProposer() public {
        bytes32 requestId = _initAndDispute();

        uint256 stakeAmount = 10 * 1e6;
        
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, stakeAmount);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.stakeForProposer, stakeAmount);
        assertEq(req.stakeForDisputer, 0);
        assertEq(oracle.stakeP(requestId, alice), stakeAmount);
    }

    function test_stake_updatesPoolsForDisputer() public {
        bytes32 requestId = _initAndDispute();

        uint256 stakeAmount = 10 * 1e6;
        
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Disputer, stakeAmount);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.stakeForProposer, 0);
        assertEq(req.stakeForDisputer, stakeAmount);
        assertEq(oracle.stakeD(requestId, alice), stakeAmount);
    }

    function test_stake_pullsTokens() public {
        bytes32 requestId = _initAndDispute();

        uint256 stakeAmount = 10 * 1e6;
        uint256 balanceBefore = usdc.balanceOf(alice);
        
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, stakeAmount);

        assertEq(usdc.balanceOf(alice), balanceBefore - stakeAmount);
    }

    function test_stake_emitsEvent() public {
        bytes32 requestId = _initAndDispute();

        uint256 stakeAmount = 10 * 1e6;

        vm.expectEmit(true, true, true, true);
        emit IOracle.Staked(requestId, alice, Types.Side.Proposer, stakeAmount);

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, stakeAmount);
    }

    function test_stake_revertsOnInvalidStatus() public {
        bytes32 requestId = _initAndPropose();

        vm.prank(alice);
        vm.expectRevert(Errors.InvalidStatus.selector);
        oracle.stake(requestId, Types.Side.Proposer, 10 * 1e6);
    }

    function test_stake_revertsOnDustAmount() public {
        bytes32 requestId = _initAndDispute();

        uint256 dustAmount = oracle.MIN_STAKE() - 1;
        
        vm.prank(alice);
        vm.expectRevert(Errors.InvalidAmount.selector);
        oracle.stake(requestId, Types.Side.Proposer, dustAmount);
    }

    function test_stake_accumulatesMultipleStakes() public {
        bytes32 requestId = _initAndDispute();

        uint256 stakeAmount = 10 * 1e6;
        
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, stakeAmount);

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, stakeAmount);

        assertEq(oracle.stakeP(requestId, alice), 2 * stakeAmount);
    }

    // Dominance Tracking Tests

    function test_dominance_startsWhenProposerHasDouble() public {
        bytes32 requestId = _initAndDispute();

        // Stake 10 for disputer
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 10 * 1e6);

        // Stake 21 for proposer (more than 2x of 10)
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 21 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 1);
        assertEq(req.dominanceStartAt, block.timestamp);
    }

    function test_dominance_startsWhenDisputerHasDouble() public {
        bytes32 requestId = _initAndDispute();

        // Stake 10 for proposer
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 10 * 1e6);

        // Stake 21 for disputer (more than 2x of 10)
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 21 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 2);
        assertEq(req.dominanceStartAt, block.timestamp);
    }

    function test_dominance_resetsWhenBalanceRestored() public {
        bytes32 requestId = _initAndDispute();

        // Proposer dominates
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 30 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 1);

        // Disputer catches up
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 20 * 1e6);

        req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 0);
        assertEq(req.dominanceStartAt, 0);
    }

    function test_dominance_switchesSides() public {
        bytes32 requestId = _initAndDispute();

        // Proposer dominates
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 30 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 1);
        uint64 firstDominanceStart = req.dominanceStartAt;

        // Warp time
        vm.warp(block.timestamp + 10 minutes);

        // Disputer now dominates (needs >2x of 30 = >60)
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 61 * 1e6);

        req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 2);
        assertGt(req.dominanceStartAt, firstDominanceStart);
    }

    function test_stake_revertsAfterDominanceDuration() public {
        bytes32 requestId = _initAndDispute();

        // Stake 10 for disputer
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 10 * 1e6);

        // Stake 21 for proposer (more than 2x of 10) - establishes dominance
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 21 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 1); // Proposer is leading
        uint64 dominanceStart = req.dominanceStartAt;

        // Warp past the dominance duration
        vm.warp(dominanceStart + oracle.DOMINANCE_DURATION() + 1);

        // Try to stake after finalization is ready - should revert
        vm.prank(carol);
        vm.expectRevert(Errors.NotFinalizable.selector);
        oracle.stake(requestId, Types.Side.Proposer, 5 * 1e6);
    }

    function test_stake_allowsStakingBeforeDominanceDuration() public {
        bytes32 requestId = _initAndDispute();

        // Stake 10 for disputer
        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 10 * 1e6);

        // Stake 21 for proposer (more than 2x of 10) - establishes dominance
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 21 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        uint64 dominanceStart = req.dominanceStartAt;

        // Warp to just before the dominance duration ends
        vm.warp(dominanceStart + oracle.DOMINANCE_DURATION() - 1);

        // Staking should still be allowed (before finalization is ready)
        vm.prank(carol);
        oracle.stake(requestId, Types.Side.Disputer, 5 * 1e6);

        // Verify stake was accepted
        assertEq(oracle.stakeD(requestId, carol), 5 * 1e6);
    }

    function test_stake_allowsStakingWhenNoDominance() public {
        bytes32 requestId = _initAndDispute();

        // Stake equal amounts - no dominance
        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, 10 * 1e6);

        vm.prank(bob);
        oracle.stake(requestId, Types.Side.Disputer, 10 * 1e6);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(req.leadingSide, 0); // No dominance

        // Warp time forward - should still allow staking since no dominance
        vm.warp(block.timestamp + oracle.DOMINANCE_DURATION() + 1);

        // Staking should still be allowed when there's no dominance
        vm.prank(carol);
        oracle.stake(requestId, Types.Side.Proposer, 5 * 1e6);

        // Verify stake was accepted
        assertEq(oracle.stakeP(requestId, carol), 5 * 1e6);
    }

    // Escalation Tests

    function test_stake_escalatesWhenThresholdReached() public {
        bytes32 requestId = _initAndDispute();

        uint256 threshold = oracle.MANUAL_THRESHOLD();

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, threshold);

        Types.Request memory req = oracle.getRequest(requestId);
        assertEq(uint8(req.status), uint8(Types.Status.Escalated));
    }

    function test_stake_emitsEscalatedEvent() public {
        bytes32 requestId = _initAndDispute();

        uint256 threshold = oracle.MANUAL_THRESHOLD();

        vm.expectEmit(true, true, true, true);
        emit IOracle.Escalated(requestId, threshold);

        vm.prank(alice);
        oracle.stake(requestId, Types.Side.Proposer, threshold);
    }

    // getResult Tests

    function test_getResult_revertsBeforeResolution() public {
        bytes32 requestId = _initAndPropose();

        vm.expectRevert(Errors.NotResolved.selector);
        oracle.getResult(requestId);
    }

    // Helper Functions

    function _initAndPropose() internal returns (bytes32 requestId) {
        vm.prank(requester);
        requestId = oracle.initalizeRequest(REWARD, BOND, DESCRIPTION);

        vm.prank(proposer);
        oracle.proposeResult(requestId, PROPOSER_RESULT);
    }

    function _initAndDispute() internal returns (bytes32 requestId) {
        requestId = _initAndPropose();

        vm.prank(disputer);
        oracle.dispute(requestId, DISPUTER_RESULT);
    }
}

