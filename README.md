# Oracle Protocol

A smart contract oracle system for sourcing arbitrary data and submitting it on-chain using a propose-dispute-stake mechanism.

## Overview

This Oracle allows callers to request arbitrary off-chain data by posting a reward. Proposers submit results with a bond, and if unchallenged during a liveness period, they receive the reward. Disputes trigger a staking-based resolution mechanism where users stake USDC to vote on correctness. People can stake on the outcome of the oracle. Winners of the event share the losing pool proportionally.

## Architecture

```
/src
├── Oracle.sol              # Main contract with all request state
├── interfaces/
│   └── IOracle.sol         # Interface definitions
├── libraries/
│   ├── Errors.sol          # Custom error definitions
│   └── Types.sol           # Enum and struct definitions
└── mocks/
    └── MockUSDC.sol        # Test USDC token

/test
├── Oracle.unit.t.sol       # Unit tests
├── Oracle.flow.t.sol       # End-to-end scenario tests
├── Oracle.invariants.t.sol # Invariant tests
└── handlers/
    └── OracleHandler.sol   # Fuzz handler for invariants
```

## State Machine

```
┌──────────┐
│   None   │ (Request doesn't exist)
└────┬─────┘
     │ initalizeRequest()
     ▼
┌──────────┐
│ Requested│ (Awaiting proposer)
└────┬─────┘
     │ proposeResult()
     ▼
┌──────────┐
│ Proposed │◄────────────┐
└────┬─────┘             │
     │                   │
     │ dispute()         │ finalize() [after LIVENESS_PERIOD]
     ▼                   │
┌──────────┐             │
│ Disputed │─────────────┴──────────────────┐
└────┬─────┘                                │
     │                                      │
     │ stake() [if total >= MANUAL_THRESHOLD]  │ finalize() [after DOMINANCE_DURATION]
     ▼                                      │
┌──────────┐                                │
│ Escalated│                                │
└────┬─────┘                                │
     │ resolveManually()                    │
     ▼                                      ▼
┌──────────────────────────────────────────────┐
│                  Resolved                    │
└──────────────────────────────────────────────┘
```

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `LIVENESS_PERIOD` | 1 hour | Time window for disputing a proposal |
| `DOMINANCE_DURATION` | 30 minutes | Duration that >2x stake advantage must hold |
| `MANUAL_THRESHOLD` | 100,000 USDC | Total stake triggering admin escalation |
| `MIN_STAKE` | 1 USDC | Minimum stake to prevent dust griefing |

## Timing Rules

### Liveness Period
- Starts when `proposeResult()` is called
- Dispute must be submitted within `proposedAt + LIVENESS_PERIOD`
- If no dispute, proposer can claim after liveness expires

### Dominance Duration
- Clock starts when one side achieves >2x stake advantage
- Clock resets if advantage is lost
- Finalization allowed after `dominanceStartAt + DOMINANCE_DURATION`

## Dominance Definition

A side is "dominant" when its total stake is greater than 2x the opposing side:

```
Proposer dominant: stakeForProposer > 2 * stakeForDisputer
Disputer dominant: stakeForDisputer > 2 * stakeForProposer
```

Example:
- Proposer: 100 USDC, Disputer: 45 USDC → Proposer dominant (100 > 90)
- Proposer: 100 USDC, Disputer: 50 USDC → Neither dominant (100 = 100)

Once dominance is established, the timestamp of when dominance initially started is recorded. 

## Escalation

When total stake (both sides combined) reaches `MANUAL_THRESHOLD`:

1. Status becomes `Escalated`
2. Normal `finalize()` is blocked
3. Only `owner` can call `resolveManually(requestId, proposerWins)`
4. This prevents whale manipulation and provides a safety valve

## Payout Formulas

### Undisputed Resolution (Proposer wins by default)
```
Proposer receives: reward + bond
```

### Disputed Resolution
```
Winner (proposer or disputer): reward + 2 * bond

Stakers on winning side:
payout = userStake + (userStake * losingPool / winningPool)
```

### Example

- Proposer wins
- Proposer pool: 1000 USDC (Alice: 600, Bob: 400)
- Disputer pool: 500 USDC

Payouts:
- Alice: 600 + (600 * 500 / 1000) = 600 + 300 = **900 USDC**
- Bob: 400 + (400 * 500 / 1000) = 400 + 200 = **600 USDC**
- Disputer stakers: 0 (lost their stake)

## Complexity Analysis

All operations are **O(1)**:

| Operation |  Notes |
|-----------|-------|
| `initalizeRequest` |  Single storage write + transfer |
| `proposeResult` |  Single storage write + transfer |
| `dispute` | Single storage write + transfer |
| `stake` | Two storage writes + transfer |
| `finalize` | Status check + single transfer |
| `claim` | Per-user claim with proportional math |

The claim-based payout system avoids loops over all stakers.

## Gas Costs

Gas measurements from `forge test --gas-report`:

### Deployment
| Metric | Value |
|--------|-------|
| Deployment Cost | 1,623,142 gas |
| Contract Size | 7,468 bytes |

### Core Functions

| Function | Min | Avg | Median | Max |
|----------|-----|-----|--------|-----|
| `initalizeRequest` | 22,934 | 163,227 | 158,816 | 193,056 |
| `proposeResult` | 24,891 | 103,505 | 93,984 | 162,080 |
| `dispute` | 25,260 | 86,221 | 94,516 | 184,610 |
| `stake` | 24,528 | 99,827 | 113,576 | 118,076 |
| `finalize` | 29,399 | 34,422 | 29,414 | 72,850 |
| `claim` | 31,621 | 73,354 | 75,076 | 75,229 |
| `resolveManually` | 24,330 | 61,638 | 58,168 | 75,268 |

### View Functions

| Function | Gas |
|----------|-----|
| `getResult` | ~8,356 |
| `getRequest` | ~28,794 |

### Notes
- First-time storage: Higher max costs on `initalizeRequest` and `proposeResult` due to cold storage writes
- Dispute variance: Higher max when triggering escalation threshold
- Finalize variance: Simple undisputed path (~29k) vs disputed resolution (~73k)
- All operations remain O(1) regardless of total stakers

## Running Tests

```bash
# Install dependencies
forge install

# Run all tests
forge test -vvv

# Run only unit tests
forge test --match-path test/Oracle.unit.t.sol -vvv

# Run only flow tests
forge test --match-path test/Oracle.flow.t.sol -vvv

# Run invariant tests
forge test --match-path test/Oracle.invariants.t.sol -vvv

# Run with gas reporting
forge test --gas-report

# Run coverage (optional)
forge coverage
```

## Test Coverage

**58 total tests** across 3 test suites.

### Unit Tests (`Oracle.unit.t.sol`) — 33 tests
- Constructor validation (USDC/owner checks)
- `initalizeRequest`: pulls reward, stores fields, emits events, increments nonce
- `proposeResult`: pulls bond, stores result bytes, transitions status
- `dispute`: only within liveness period, pulls bond, boundary testing
- `stake`: updates pools and per-user mappings, accumulates multiple stakes
- Dominance tracking: starts when >2x, resets when balanced, switches sides
- Escalation: status flip when threshold reached, emits event
- `getResult`: reverts before resolution

### Flow Tests (`Oracle.flow.t.sol`) — 19 tests
- Undisputed path: init → propose → warp → finalize, cannot finalize early
- Disputed proposer wins: full staking + claim flow, loser cannot claim
- Disputed disputer wins: symmetric scenario with result verification
- Multiple stakers: correct distribution verification
- Escalated path: admin resolution, non-owner rejection
- Edge cases: dominance reset, double claim prevention, no-stake scenario, equal stakes
- Payout verification: total payouts ≤ total staked, single winner gets all, exact math verification

### Invariant Tests (`Oracle.invariants.t.sol`) — 6 tests
Fuzz-tested properties that must always hold:
- No double claims: Handler's ghost state matches contract's claimed mapping
- Valid status: Existing requests never have `None` status; resolved requests have proposer
- Contract solvency: Total paid out never exceeds total deposited
- Stake consistency: Sum of individual stakes equals pool totals
- Dominance rules: leadingSide only set when stake ratio exceeds 2x
- Result correctness: Resolved requests return winner's submitted result

## Known Limitations & Future Work

### Current Limitations
1. No request cancellation: Once initialized, requests cannot be cancelled
2. No permit support: Requires pre-approval for USDC transfers
3. Single admin: Owner is a single address (no timelock/multisig built-in)
4. Fixed constants: Timing parameters are immutable after deployment
5. Not upgradeable: Contract logic is fixed at deployment

### Future Enhancements

#### UUPS Upgradeability
Implement OpenZeppelin's UUPS (Universal Upgradeable Proxy Standard) pattern to enable upgrades for new features, bug fixes, and tuning parameters.


#### Other Enhancements
- **`cancelRequest()`**: Allow requesters to cancel before proposal (with partial refund)
- EIP-2612 permit: Gasless approvals via signature for better UX
- Timelock admin: Add delay to `resolveManually()` for transparency and dispute
- Configurable timing: Make `LIVENESS_PERIOD` and `DOMINANCE_DURATION` adjustable (with bounds)
- Request expiry: Auto-refund if no proposal within a configurable timeframe
- Batch operations: `claimMultiple(bytes32[] requestIds)` for gas efficiency
- Governance integration: Replace single owner with DAO/multisig for escalated disputes


