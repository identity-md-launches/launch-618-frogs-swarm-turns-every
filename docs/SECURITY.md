# Security boundaries

The application holds refundable token deposits. Its rules are immutable. The constructor accepts one token address and grants no role to either that address or its deployer. All state-changing entry points are permissionless except that withdrawals use the caller's own ledger entry and recipient address.

## Accounting and interactions

Votes update the per-week agent total, cached leader, voter liability, and aggregate liability before calling the token. A reentrancy guard covers voting, finalization, and withdrawals. The deposit then checks the actual token balance increase equals the credited amount; failures revert the entire operation. Withdrawals clear the liability before sending tokens and verify both the contract's decrease and recipient's increase. Failed withdrawals remain claimable after revert. External token failure does not affect other weeks' recorded results.

The ordinary LaunchToken has no callbacks, fees, rebasing, further minting, or privileged functions. Its only external surface is standard token metadata, balances, allowances, transfers and approvals. The application accepts optional-empty return data for token compatibility, but the only supported deployment dependency is the delivered LaunchToken. An arbitrary malicious token can lie about balances or stop transferring; the address parameter is a deployment trust boundary, not a promise to secure any ERC-20.

`totalLocked` tracks outstanding liabilities. For the delivered token, balance equals liabilities after normal vote/withdraw sequences. Unsolicited token transfers make balance exceed liabilities, with no added votes or claim. Those donations are unrecoverable because no owner or rescue mechanism exists.

## Time and bounded execution

Weeks use deployment-relative 604800-second intervals, independent of settlement. Voting checks an explicit expected week so a late transaction cannot roll into another week. Withdrawals only require that the selected week ended. Finalizing an old result cannot interfere with voting in the current week or with already matured deposits.

The maximum agent number is fixed, and incremental leader maintenance makes vote and finalize cost independent of participation. Finalization settles one week per call; the backlog is explicit through `nextWeekToFinalize`. The read-only `getVotes` scans exactly 2000 fixed entries. Neither settlement nor withdrawal loops over an unbounded user-controlled collection.

The deterministic lower-number tie rule avoids relying on transaction order for equal final totals. Block timestamps and ordering are still consensus inputs. There is no random winner, price oracle, external API dependency in Solidity, signature relayer, ETH payout, delegatecall, proxy, or administrator.

## Website trust boundary

The API is public display data and does not authorize votes or move funds. The site uses numbered seats, with explicit missing-data and unavailable-online states. Token values use integer base units; decimal input with more than 18 places must be rejected rather than rounded. Contract addresses are deployment configuration. Transactions require a connected wallet on Sepolia and use the application-derived token address. Approval requests are bounded to the intended vote amount. A vote includes the week selected before approval.

A compromised static host or injected wallet can deceive a user despite correct contracts. Operators must publish reviewed assets, verify deployed addresses, and use HTTPS. Users can interact directly with verified contracts if the host or API is unavailable. No secret belongs in the public site configuration.

## Verification scope

Local verification includes Foundry unit, fuzz, and stateful custody tests, malicious-token failure and reentrancy tests, runtime opcode checks, JavaScript data/amount/client tests, and a local Anvil integration exercise of the website's chain client. The exact commands and final results are recorded in the task handoff. No production transaction or network-dependent test is required.

Foundry's build linter emits reentrancy/event-order and strict-balance-equality warnings in `FrogOfTheWeek`. The reentrancy guard covers every state-changing entry point, and liabilities change before external token calls. Adversarial callback tests exercise that protection. Exact before/after balance differences intentionally reject short or taxed transfers; unsolicited donations already present in the starting balance do not prevent ordinary deposits or withdrawals. These warnings were reviewed rather than suppressed.

This is an implementation review, including a separate agent's adversarial read, not an independent third-party audit. Slither, Mythril, production browser/wallet certification, explorer verification, and public deployment are not claimed. The launch operator remains responsible for an independent security review before custody use.
