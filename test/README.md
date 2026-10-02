# Contract test coverage

Run `forge build` and `forge test` with the repository's existing Foundry configuration.
The tests use the already-vendored forge-std and require no RPC, fork, network access,
environment variables, or additional dependencies.

The added tests complement the original lifecycle, event, deployment, and leader-reference tests:

- `FrogProperties.t.sol`: populated-state rollback after rejected votes; exact allowance
  and balance failures; voting and refunding the entire fixed supply across multiple weeks;
  deployment-relative expiry boundaries; equivalence of split votes, arrival orders,
  and finalization before or after refunds. Fuzz properties run 1,000 cases each.
- `LaunchTokenProperties.t.sol`: delegated spending, approval isolation and revocation,
  self-transfers, full-supply and maximum-integer amounts, zero-amount events, and atomic
  rollback. Fuzz properties run 1,000 cases each.
- `TokenBoundary.t.sol`: cross-function reentrancy attempts with otherwise-valid inputs,
  malformed return data, incorrect token balance changes, rollback, and recovery. The
  malformed-boolean property runs 1,000 cases.
- `FrogInvariant.t.sol`: 256 randomized sequences of 64 calls through a three-voter
  handler. Independent accounting tracks deposits, refunds, donations, historical votes,
  and finalization. Sequences mix valid actions with rejected votes, premature or repeated
  withdrawals, premature finalization, and elapsed weeks. Invariants check custody against
  liabilities plus donations, each voter's conservation, fixed supply, and historical
  summaries. After every sequence, all remaining deposits are withdrawn, pending weeks are
  finalized, and every agent's historical vote total is checked.

The stateful campaign uses candidates 0, 1, and 1999 to produce repeated votes, ties, and
lead changes. The separate leader tests cover the complete 0–1999 range. A seeded deposit
ensures the withdrawal checks always exercise custody; the random time horizon is bounded
to keep complete historical checks practical.

The intended asset is `LaunchToken`. Adversarial token doubles test defensive failure paths;
they do not establish support for fee-on-transfer, rebasing, or dishonest tokens. Direct
token donations are modeled separately from refundable voting deposits.

These are local Solidity tests. They do not validate the website, external API, wallet UI,
deployed addresses, or artwork. No confirmed contract defect was found in this test work.
