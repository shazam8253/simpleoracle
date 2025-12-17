// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Types} from "./libraries/Types.sol";
import {Errors} from "./libraries/Errors.sol";
import {IOracle} from "./interfaces/IOracle.sol";

// Oracle for sourcing arbitrary data and submitting it on-chain
contract Oracle is IOracle, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Constants

    uint64 public constant LIVENESS_PERIOD = 1 hours; // Time window for disputes after proposal
    uint64 public constant DOMINANCE_DURATION = 30 minutes; // Time one side must maintain >2x stake
    uint256 public constant MANUAL_THRESHOLD = 100_000 * 1e6; // Total stake that triggers escalation
    uint256 public constant MIN_STAKE = 1 * 1e6; // Minimum stake to prevent dust attacks

    // State Variables

    IERC20 public immutable usdc;
    uint256 public nonce; // Global nonce for unique request ID generation
    mapping(bytes32 => Types.Request) public requests; // Request ID -> request data
    mapping(bytes32 => mapping(address => uint256)) public stakeP; // Request ID -> staker -> proposer stake
    mapping(bytes32 => mapping(address => uint256)) public stakeD; // Request ID -> staker -> disputer stake
    mapping(bytes32 => mapping(address => bool)) public claimed; // Request ID -> staker -> claimed flag

    // Constructor for oracle 
    constructor(IERC20 _usdc, address _owner) Ownable(_owner) {
        if (address(_usdc) == address(0) || _owner == address(0)) {
            revert Errors.ZeroAddress();
        }
        usdc = _usdc;
    }

    // Creates a new oracle request, pulls reward from requester, generates unique ID
    function initalizeRequest(
        uint256 _reward,
        uint256 _bond,
        bytes memory _description
    ) external returns (bytes32 requestId) {
        if (_reward == 0 || _bond == 0) {
            revert Errors.InvalidAmount();
        }

        bytes32 descriptionHash = keccak256(_description);
        
        // Generate unique request ID from sender, nonce, chainid, and description hash
        requestId = keccak256(
            abi.encode(msg.sender, nonce++, block.chainid, descriptionHash)
        );

        // Initialize request storage
        Types.Request storage req = requests[requestId];
        req.requester = msg.sender;
        req.reward = _reward;
        req.bond = _bond;
        req.descriptionHash = descriptionHash;
        req.status = Types.Status.Requested;

        // Pull reward from requester
        usdc.safeTransferFrom(msg.sender, address(this), _reward);

        emit RequestInitialized(requestId, msg.sender, _reward, _bond, descriptionHash);
    }

    // Returns the result for a request if it has been resolved
    function getResult(bytes32 _requestId) external view returns (bytes memory result) {
        Types.Request storage req = requests[_requestId];
        
        if (req.status != Types.Status.Resolved) {
            revert Errors.NotResolved();
        }

        return req.proposerWins ? req.proposerResult : req.disputerResult;
    }

    // Proposes a result for a request, requires bond, starts liveness period
    function proposeResult(bytes32 _requestId, bytes memory _result) external {
        Types.Request storage req = requests[_requestId];

        if (req.status != Types.Status.Requested) {
            revert Errors.InvalidStatus();
        }

        req.proposer = msg.sender;
        req.proposedAt = uint64(block.timestamp);
        req.proposerResult = _result;
        req.status = Types.Status.Proposed;

        // Pull bond from proposer
        usdc.safeTransferFrom(msg.sender, address(this), req.bond);

        emit ResultProposed(_requestId, msg.sender);
    }

    // Disputes a proposed result, must be within liveness period, requires bond
    function dispute(bytes32 _requestId, bytes memory _disputerResult) external {
        Types.Request storage req = requests[_requestId];

        if (req.status != Types.Status.Proposed) {
            revert Errors.InvalidStatus();
        }

        // Must be within liveness period (1 hour after proposal)
        if (block.timestamp > req.proposedAt + LIVENESS_PERIOD) {
            revert Errors.NotWithinLiveness();
        }

        req.disputer = msg.sender;
        req.disputedAt = uint64(block.timestamp);
        req.disputerResult = _disputerResult;
        req.status = Types.Status.Disputed;

        // Pull bond from disputer
        usdc.safeTransferFrom(msg.sender, address(this), req.bond);

        emit Disputed(_requestId, msg.sender);
    }

    // Stakes on a side in a dispute, updates dominance tracking, checks for escalation
    function stake(bytes32 _requestId, Types.Side _side, uint256 _amount) external {
        Types.Request storage req = requests[_requestId];

        if (req.status != Types.Status.Disputed) {
            revert Errors.InvalidStatus();
        }

        if (_amount < MIN_STAKE) {
            revert Errors.InvalidAmount();
        }

        // Pull stake from staker
        usdc.safeTransferFrom(msg.sender, address(this), _amount);

        // Update stake tracking for the chosen side
        if (_side == Types.Side.Proposer) {
            stakeP[_requestId][msg.sender] += _amount;
            req.stakeForProposer += _amount;
        } else {
            stakeD[_requestId][msg.sender] += _amount;
            req.stakeForDisputer += _amount;
        }

        emit Staked(_requestId, msg.sender, _side, _amount);

        // Update dominance tracking (checks if one side has >2x stake)
        _updateDominance(_requestId);

        // Check if total stake exceeds threshold for manual resolution
        uint256 totalStake = req.stakeForProposer + req.stakeForDisputer;
        if (totalStake >= MANUAL_THRESHOLD) {
            req.status = Types.Status.Escalated;
            emit Escalated(_requestId, totalStake);
        }
    }

    // Finalizes a request: either undisputed (after liveness) or disputed (after dominance period)
    function finalize(bytes32 _requestId) external nonReentrant {
        Types.Request storage req = requests[_requestId];

        // Undisputed finalize - proposer wins if no dispute within liveness period
        if (req.status == Types.Status.Proposed) {
            if (block.timestamp <= req.proposedAt + LIVENESS_PERIOD) {
                revert Errors.NotFinalizable();
            }

            req.status = Types.Status.Resolved;
            req.proposerWins = true;

            // Proposer gets reward + bond back
            usdc.safeTransfer(req.proposer, req.reward + req.bond);

            emit Resolved(_requestId, true);
            return;
        }

        // Disputed finalize - winner determined by dominance (>2x stake for 30 minutes)
        if (req.status == Types.Status.Disputed) {
            // Check dominance is satisfied
            // when dominanceStartAt == 0 (which would pass the timestamp check)
            if (req.leadingSide == 0) {
                revert Errors.NotFinalizable();
            }
            // Safe: leadingSide != 0 guarantees dominanceStartAt was set to block.timestamp
            if (block.timestamp < req.dominanceStartAt + DOMINANCE_DURATION) {
                revert Errors.NotFinalizable();
            }

            bool proposerWins = req.leadingSide == 1;
            req.proposerWins = proposerWins;
            req.status = Types.Status.Resolved;

            // Winner gets reward + both bonds
            address winner = proposerWins ? req.proposer : req.disputer;
            usdc.safeTransfer(winner, req.reward + 2 * req.bond);

            emit Resolved(_requestId, proposerWins);
            return;
        }

        // Neither Proposed nor Disputed - invalid status for finalize
        revert Errors.InvalidStatus();
    }

    // Manually resolves escalated requests (when total stake exceeds threshold) - admin only
    function resolveManually(bytes32 _requestId, bool _proposerWins) external onlyOwner nonReentrant {
        Types.Request storage req = requests[_requestId];

        if (req.status != Types.Status.Escalated) {
            revert Errors.OnlyEscalated();
        }

        req.proposerWins = _proposerWins;
        req.status = Types.Status.Resolved;

        // Winner gets reward + both bonds
        address winner = _proposerWins ? req.proposer : req.disputer;
        usdc.safeTransfer(winner, req.reward + 2 * req.bond);

        emit Resolved(_requestId, _proposerWins);
    }

    // Claims payout for stakers on winning side: stake + proportional share of losing pool
    function claim(bytes32 _requestId) external nonReentrant {
        Types.Request storage req = requests[_requestId];

        if (req.status != Types.Status.Resolved) {
            revert Errors.NotResolved();
        }

        if (claimed[_requestId][msg.sender]) {
            revert Errors.AlreadyClaimed();
        }

        // Cache proposerWins to avoid multiple storage reads
        bool proposerWins = req.proposerWins;
        uint256 winningPool = proposerWins ? req.stakeForProposer : req.stakeForDisputer;
        
        uint256 userStake;
        uint256 payout;
        
        if (winningPool == 0) {
            // Edge case: no one staked on winning side (can happen with manual resolution)
            // Allow losers to reclaim their stakes since there's no winner to distribute to
            userStake = proposerWins 
                ? stakeD[_requestId][msg.sender]  // disputer side lost
                : stakeP[_requestId][msg.sender]; // proposer side lost
            payout = userStake; // Just return their stake, no bonus
        } else {
            // Normal case: user is on winning side
            userStake = proposerWins 
                ? stakeP[_requestId][msg.sender] 
                : stakeD[_requestId][msg.sender];
            
            if (userStake == 0) {
                revert Errors.NoStakeToClaim();
            }
            
            // Payout = userStake + (userStake * losingPool / winningPool)
            // Winners get their stake back plus proportional share of losing side's stake
            payout = userStake;
            uint256 losingPool = proposerWins ? req.stakeForDisputer : req.stakeForProposer;
            
            if (losingPool != 0) {
                payout += (userStake * losingPool) / winningPool;
            }
        }

        if (userStake == 0) {
            revert Errors.NoStakeToClaim();
        }

        claimed[_requestId][msg.sender] = true;

        usdc.safeTransfer(msg.sender, payout);

        emit Claimed(_requestId, msg.sender, payout);
    }

    // Returns the full request struct for a given request ID
    function getRequest(bytes32 _requestId) external view returns (Types.Request memory) {
        return requests[_requestId];
    }

    // Updates dominance tracking when one side has >2x the stake of the other
    function _updateDominance(bytes32 _requestId) internal {
        Types.Request storage req = requests[_requestId];
        
        uint256 P = req.stakeForProposer;
        uint256 D = req.stakeForDisputer;

        if (P > 2 * D) {
            // Proposer is dominant
            if (req.leadingSide != 1) {
                req.leadingSide = 1;
                req.dominanceStartAt = uint64(block.timestamp);
            }
        } else if (D > 2 * P) {
            // Disputer is dominant
            if (req.leadingSide != 2) {
                req.leadingSide = 2;
                req.dominanceStartAt = uint64(block.timestamp);
            }
        } else {
            // Neither is dominant - reset
            req.leadingSide = 0;
            req.dominanceStartAt = 0;
        }
    }
}

