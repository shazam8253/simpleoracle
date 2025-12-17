// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Types} from "../libraries/Types.sol";

interface IOracle {
    // Events
    event RequestInitialized(
        bytes32 indexed id,
        address indexed requester,
        uint256 reward,
        uint256 bond,
        bytes32 descriptionHash
    );

    event ResultProposed(bytes32 indexed id, address indexed proposer);
    event Disputed(bytes32 indexed id, address indexed disputer);
    event Staked(
        bytes32 indexed id,
        address indexed staker,
        Types.Side side,
        uint256 amount
    );
    event Escalated(bytes32 indexed id, uint256 totalStake);
    event Resolved(bytes32 indexed id, bool proposerWins);
    event Claimed(bytes32 indexed id, address indexed staker, uint256 payout);

    // External Functions
    // Initialize a new oracle request with reward and bond amounts
    function initalizeRequest(
        uint256 _reward,
        uint256 _bond,
        bytes memory _description
    ) external returns (bytes32 requestId);

    // Get the resolved result for a request (only available after resolution)
    function getResult(bytes32 _requestId) external view returns (bytes memory result);
    
    // Propose a result for a request (requires bond)
    function proposeResult(bytes32 _requestId, bytes memory _result) external;
    
    // Dispute a proposed result (must be within liveness period, requires bond)
    function dispute(bytes32 _requestId, bytes memory _disputerResult) external;
    
    // Stake on a side in a dispute (Proposer or Disputer)
    function stake(bytes32 _requestId, Types.Side _side, uint256 _amount) external;
    
    // Finalize a request after liveness period (undisputed) or dominance period (disputed)
    function finalize(bytes32 _requestId) external;
    
    // Manually resolve an escalated request (admin only, when stake exceeds threshold)
    function resolveManually(bytes32 _requestId, bool _proposerWins) external;
    
    // Claim payout after resolution (for stakers on winning side)
    function claim(bytes32 _requestId) external;
}

