// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Oracle} from "../../src/Oracle.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {Types} from "../../src/libraries/Types.sol";

// Handler contract for Oracle invariant testing
// Maintains ghost variables for accounting verification
contract OracleHandler is Test {
    Oracle public oracle;
    MockUSDC public usdc;
    address public owner;

    // Actor management
    address[] public actors;
    mapping(address => bool) public isActor;

    // Request tracking
    bytes32[] public allRequestIds;
    mapping(bytes32 => bool) public requestExists;

    // Ghost variables for accounting
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalPaidOut;
    uint256 public ghost_activeRewards;
    uint256 public ghost_activeBonds;
    uint256 public ghost_activeStakes;

    // Claim tracking
    mapping(bytes32 => mapping(address => bool)) public ghost_hasClaimed;

    // Call counters
    uint256 public calls_initialize;
    uint256 public calls_propose;
    uint256 public calls_dispute;
    uint256 public calls_stake;
    uint256 public calls_finalize;
    uint256 public calls_claim;
    uint256 public calls_resolveManually;

    constructor(Oracle _oracle, MockUSDC _usdc, address _owner) {
        oracle = _oracle;
        usdc = _usdc;
        owner = _owner;
    }

    // Actor Management

    // Adds an actor for fuzzing, mints USDC and sets approval
    function addActor(address actor) external {
        if (!isActor[actor]) {
            actors.push(actor);
            isActor[actor] = true;
            usdc.mint(actor, 100_000_000 * 1e6);
            vm.prank(actor);
            usdc.approve(address(oracle), type(uint256).max);
        }
    }

    // Gets a random actor from the list based on seed
    function _getActor(uint256 seed) internal view returns (address) {
        if (actors.length == 0) return address(0);
        return actors[seed % actors.length];
    }

    // Gets a random request ID from the list based on seed
    function _getRequestId(uint256 seed) internal view returns (bytes32) {
        if (allRequestIds.length == 0) return bytes32(0);
        return allRequestIds[seed % allRequestIds.length];
    }

    // Handler Actions

    // Handler for initializing requests - tracks deposits in ghost variables
    function initializeRequest(
        uint256 actorSeed,
        uint256 reward,
        uint256 bond
    ) external {
        address actor = _getActor(actorSeed);
        if (actor == address(0)) return;

        // Bound inputs to reasonable values
        reward = bound(reward, 1, 10_000 * 1e6);
        bond = bound(bond, 1, 10_000 * 1e6);

        bytes memory description = abi.encodePacked("Request ", calls_initialize);

        vm.prank(actor);
        try oracle.initalizeRequest(reward, bond, description) returns (bytes32 requestId) {
            allRequestIds.push(requestId);
            requestExists[requestId] = true;
            ghost_totalDeposited += reward;
            ghost_activeRewards += reward;
            calls_initialize++;
        } catch {}
    }

    // Handler for proposing results - tracks bond deposits
    function proposeResult(
        uint256 actorSeed,
        uint256 requestSeed,
        bytes calldata result
    ) external {
        address actor = _getActor(actorSeed);
        bytes32 requestId = _getRequestId(requestSeed);
        if (actor == address(0) || requestId == bytes32(0)) return;

        Types.Request memory req = oracle.getRequest(requestId);
        if (req.status != Types.Status.Requested) return;

        vm.prank(actor);
        try oracle.proposeResult(requestId, result) {
            ghost_totalDeposited += req.bond;
            ghost_activeBonds += req.bond;
            calls_propose++;
        } catch {}
    }

    // Handler for disputing results - tracks bond deposits
    function dispute(
        uint256 actorSeed,
        uint256 requestSeed,
        bytes calldata disputerResult
    ) external {
        address actor = _getActor(actorSeed);
        bytes32 requestId = _getRequestId(requestSeed);
        if (actor == address(0) || requestId == bytes32(0)) return;

        Types.Request memory req = oracle.getRequest(requestId);
        if (req.status != Types.Status.Proposed) return;

        vm.prank(actor);
        try oracle.dispute(requestId, disputerResult) {
            ghost_totalDeposited += req.bond;
            ghost_activeBonds += req.bond;
            calls_dispute++;
        } catch {}
    }

    // Handler for staking - tracks stake deposits and updates active stakes
    function stake(
        uint256 actorSeed,
        uint256 requestSeed,
        uint256 amount,
        bool forProposer
    ) external {
        address actor = _getActor(actorSeed);
        bytes32 requestId = _getRequestId(requestSeed);
        if (actor == address(0) || requestId == bytes32(0)) return;

        Types.Request memory req = oracle.getRequest(requestId);
        if (req.status != Types.Status.Disputed) return;

        amount = bound(amount, oracle.MIN_STAKE(), 50_000 * 1e6);
        Types.Side side = forProposer ? Types.Side.Proposer : Types.Side.Disputer;

        vm.prank(actor);
        try oracle.stake(requestId, side, amount) {
            ghost_totalDeposited += amount;
            ghost_activeStakes += amount;
            calls_stake++;
        } catch {}
    }

    // Handler for finalizing - tracks payouts and updates active rewards/bonds
    function finalize(uint256 requestSeed) external {
        bytes32 requestId = _getRequestId(requestSeed);
        if (requestId == bytes32(0)) return;

        Types.Request memory req = oracle.getRequest(requestId);
        
        try oracle.finalize(requestId) {
            req = oracle.getRequest(requestId);
            
            // Track payouts based on whether request was disputed
            if (req.stakeForProposer == 0 && req.stakeForDisputer == 0) {
                // Undisputed: reward + bond paid out
                ghost_totalPaidOut += req.reward + req.bond;
                ghost_activeRewards -= req.reward;
                ghost_activeBonds -= req.bond;
            } else {
                // Disputed: reward + 2*bond paid out to winner
                ghost_totalPaidOut += req.reward + 2 * req.bond;
                ghost_activeRewards -= req.reward;
                ghost_activeBonds -= 2 * req.bond;
            }
            calls_finalize++;
        } catch {}
    }

    // Handler for claiming - tracks payouts and updates active stakes
    function claim(uint256 actorSeed, uint256 requestSeed) external {
        address actor = _getActor(actorSeed);
        bytes32 requestId = _getRequestId(requestSeed);
        if (actor == address(0) || requestId == bytes32(0)) return;

        Types.Request memory req = oracle.getRequest(requestId);
        if (req.status != Types.Status.Resolved) return;
        if (ghost_hasClaimed[requestId][actor]) return;

        uint256 userStake = req.proposerWins 
            ? oracle.stakeP(requestId, actor)
            : oracle.stakeD(requestId, actor);
        
        if (userStake == 0) return;

        uint256 balanceBefore = usdc.balanceOf(actor);
        
        vm.prank(actor);
        try oracle.claim(requestId) {
            uint256 payout = usdc.balanceOf(actor) - balanceBefore;
            ghost_totalPaidOut += payout;
            ghost_activeStakes -= userStake;
            // we track userStake removed, but losingPool share is also removed
            ghost_hasClaimed[requestId][actor] = true;
            calls_claim++;
        } catch {}
    }

    // Handler for manual resolution - tracks payouts for escalated requests
    function resolveManually(uint256 requestSeed, bool proposerWins) external {
        bytes32 requestId = _getRequestId(requestSeed);
        if (requestId == bytes32(0)) return;

        Types.Request memory req = oracle.getRequest(requestId);
        if (req.status != Types.Status.Escalated) return;

        vm.prank(owner);
        try oracle.resolveManually(requestId, proposerWins) {
            ghost_totalPaidOut += req.reward + 2 * req.bond;
            ghost_activeRewards -= req.reward;
            ghost_activeBonds -= 2 * req.bond;
            calls_resolveManually++;
        } catch {}
    }

    // Handler for warping time - allows fuzzer to advance block timestamp
    function warpTime(uint256 seconds_) external {
        seconds_ = bound(seconds_, 0, 2 hours);
        vm.warp(block.timestamp + seconds_);
    }

    // View Functions

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function requestCount() external view returns (uint256) {
        return allRequestIds.length;
    }

    function getCallStats() external view returns (
        uint256 init,
        uint256 propose,
        uint256 disp,
        uint256 stk,
        uint256 fin,
        uint256 clm,
        uint256 manual
    ) {
        return (
            calls_initialize,
            calls_propose,
            calls_dispute,
            calls_stake,
            calls_finalize,
            calls_claim,
            calls_resolveManually
        );
    }
}

