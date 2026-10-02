# Local verification record

Checked on 2026-10-02 with Foundry 1.8.3, Solidity 0.8.26, and Node.js 22.22.1. These are implementation checks, not independent acceptance or a security audit.

| Command | Result |
| --- | --- |
| `forge build` | Pass; reviewed linter warnings described in SECURITY.md |
| `forge test` | 45 passed, 0 failed, 0 skipped across 5 suites |
| `forge fmt --check` | Pass |
| `node --test web/test/*.test.mjs` | 22 passed, 0 failed |
| `node --test test/website.integration.mjs` | 2 passed, 0 failed |

Foundry runs 256 cases for each fuzz test. Stateful testing checks two independent properties over 128 runs of 64 actions (8,192 actions, no unexpected reverts): custody equals outstanding deposits plus donations, and retained weekly totals/results match the reference model. Separate differential testing compares 60 randomized votes with a full 2000-agent tally. The exhaustive descending-order tie test exercises every eligible agent number.

Adversarial token tests cover failed and malformed transfers, no-return tokens, taxed deposits and withdrawals, rollback, withdrawal retry, and attempted reentrancy into voting, withdrawals, and finalization. Token tests cover fixed supply, transfers/allowances, factory deployment, absent administrative selectors, runtime size and prohibited opcodes.

The integration test starts its own Anvil instance using Sepolia's chain ID and deploys the compiled bytecode through unlocked local test accounts. It checks every frontend function selector against `cast sig`, exact-amount approval and voting, fractional token amounts, tied results, withdrawal before finalization, duplicate withdrawal failure, historical totals, and finalizing missed/empty weeks. It uses neither public RPCs nor private keys.

The JavaScript unit tests cover the actual API response shape, all 2000 numbers, level boundaries, unique colors, sorting/search, missing/malformed data, acceptance denominator, exact token arithmetic, block-pinned contract reads, fixed voting rules, wallet account/network/week changes, rejected/reverted/pending transactions, and RPC failures.

Additional local checks: JavaScript syntax, all HTML asset and module import paths, unique DOM IDs and all application DOM references, and SVG XML validity. The four SVGs were rendered with system librsvg/cairo and visually inspected together. No browser package was installed; an interactive production browser/wallet walkthrough remains an operator deployment check.

The live public API was read separately to verify its schema and CORS response, and the example RPC was checked to report chain ID 11155111. Those discovery requests are not dependencies of any test. No transactions were sent to a public chain and no hosting deployment was performed.
