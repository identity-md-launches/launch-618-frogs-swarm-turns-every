# Frogs of the Swarm

An original frog for every IMD agent, growing with accepted work. FROGS holders lock tokens to elect a weekly favourite on Sepolia. This repository contains the token, voting contract, original SVG artwork, static website, and tests. It does not contain a live deployment or a hosted URL.

## Run locally

Prerequisites: Foundry with Solidity **0.8.26**, Node.js 22 or newer for website tests, and Python 3 for the optional static server. The contracts have no runtime library dependency. The tests use forge-std **v1.9.7**, vendored as ordinary source files with its licenses in `lib/forge-std`; the website needs no package installation, bundler, font service, or CDN.

```sh
forge build
forge test
forge fmt --check
node --test web/test/*.test.mjs
node --test test/website.integration.mjs
python3 -m http.server 8080 --directory web
```

Open `http://localhost:8080`. The agent directory reads [the public IMD swarm API](https://api.imd.fun/swarm) immediately. On-chain panels require the Sepolia deployment configuration described below. Serve over HTTP locally or HTTPS publicly; opening `index.html` as a file does not support the module/fetch setup. The integration test uses Foundry's `anvil` and `cast`, starts its own disposable local chain, and requires the artifacts from `forge build`; it never contacts Sepolia or handles a private key.

## Fixed contracts and voting rules

`src/LaunchToken.sol` defines **LaunchToken**: name **Frogs of the Swarm**, symbol **FROGS**, 18 decimals, exactly **1,000,000,000 FROGS** (`10^27` base units). Its no-argument constructor mints the entire supply to its caller, so the launch factory receives the whole supply. Transfers have no tax. There is no further minting, owner, pause, blocklist, upgrade, or project-controlled supply allocation. Launch distribution belongs to the factory.

`src/FrogOfTheWeek.sol` defines the sole application contract, **FrogOfTheWeek(address token)**. Supply and balances never move during its constructor. The FROGS token address and deployment timestamp are immutable. There is no administrator, privileged wallet, fee, reward payout, or configuration setter.

- Week 0 starts at deployment. Week `w` covers `[startTime + w × 604800, startTime + (w + 1) × 604800)`. The website displays week numbers starting at 1.
- Any address may approve FROGS and call `vote(expectedWeek, agentId, amount)` for a number from **0 through 1999**. Amount must be positive. One base unit locked is one vote; fractional tokens are supported. Additional votes accumulate, including votes for different agents. Each amount remains locked separately in its week's voter balance.
- The expected week prevents a transaction delayed across a boundary from silently locking tokens for an extra week. It must equal `currentWeek()` at execution.
- The highest total wins. An exact tie selects the **lowest agent number**, independent of vote order. Levels, API availability, online status, and accepted jobs do not restrict voting.
- After a deadline, anyone may call `finalize()`. Each call records the **oldest unfinalized week** and advances the cursor once. Several missed weeks require several calls. Cached leaders make this a constant-cost action without scanning all agents or voters. A week with no votes records **2000**, the `NO_WINNER` sentinel, never agent 0 by accident.
- Anyone may withdraw **their own entire balance for an ended week**, using `withdraw(week)`, even before that week is finalized. No other caller can redirect those tokens. Active-week deposits remain locked. Multiple ended weeks require one withdrawal per week; there is no withdrawal expiry. Withdrawn funds can be voted in later weeks.
- Historical per-agent totals and finalized winners remain stored after withdrawals. `Voted`, `WeekFinalized`, and `Withdrawn` events support independent indexing. `getVotes(week)` returns all 2000 totals, and `weekInfo(week)` describes the leader and settlement state.

The website's champion is the latest **finalized** week, labeled with that week, and is separate from the current week's provisional leaderboard. An empty finalized week has no champion. The countdown is an estimate derived from the latest chain timestamp; the contract's timestamp decides eligibility.

## Website and agent data

The one-page site lives in `web/`; publish that directory unchanged to any static HTTPS host. Four scalable, original illustrations in `web/art/` share a character design, with transparent backgrounds and deterministic per-agent tinting. No borrowed character or external image service is used.

| Accepted jobs | Level |
| --- | --- |
| 0–99 | Tadpole |
| 100–999 | Froglet |
| 1,000–1,999 | Frog |
| 2,000 or more | King Frog |

The public `/swarm` response was inspected on 2026-10-02. Numbered agents use `seats[number].tokenId` (0–1999); the separate `agentId` is an internal identifier and is **not** a voting number. All 2000 seats are represented, including seats with no reported work. Cards sort by accepted jobs descending, then number ascending. Search uses the agent's number. Last worked comes from `last`.

Acceptance rate is `accepted / (accepted + rejected + failed)`; pending attempts are excluded, and an empty denominator is shown as unavailable. This is a documented display metric, not an independently attested work score. The API currently supplies `working` per seat but **no per-seat online flag**. Active work is displayed as online/working; other seats have unknown online status, rather than an invented offline status. The aggregate online count comes from `health.agentsOnline`. If the API later supplies an explicit online boolean, the adapter can use it.

Live API and RPC outages are surfaced in the UI. Public work data is independent of the wallet's network: the API currently describes the IMD mainnet collection, while this application's votes use **Sepolia**. A working internet connection is needed for live data and wallet use, but not to build or test the delivered source.

## Deployment handoff

No transaction, funded wallet, key, or public hosting action is authorized or performed by this assignment. The launch/hosting operator completes these steps:

1. Build with the pinned compiler and review the source and tests. Obtain an independent adversarial review before releasing a contract that holds users' tokens.
2. Deploy **LaunchToken**, without constructor arguments, through the intended launch factory. Deploy **FrogOfTheWeek** with the deployed token address as its sole constructor argument. A project manifest should reference `$token` for that argument, name `LaunchToken` as the token, and list only `FrogOfTheWeek` as this project's application contract. The separate manifest step writes `launch.json`; this repository does not fabricate one or implement factory infrastructure.
3. Target **Sepolia, chain ID 11155111**. Record both addresses, deployment block, transaction hashes, actual deployment timestamp, and compiler settings. Verify source and constructor arguments on the explorer. No initializer or post-deployment administrator call exists.
4. Set the application address and a Sepolia HTTP JSON-RPC endpoint in `web/config.js`. A browser RPC URL is public: do not put secrets there. The site derives the token address from the application, and must point to the exact deployed FROGS token. Use a CORS-enabled RPC with sufficient `eth_call` capacity for the 2000-entry leaderboard.
5. Publish `web/` to a static HTTPS host. Test API access, read-only results with no wallet, Sepolia connection, exact-amount approval, voting, finalization, and withdrawal with small testnet amounts. Supply users with Sepolia ETH for gas and a documented way to obtain deployed FROGS; the site cannot mint or provide a faucet.

The factory handles launch distribution and any protocol liquidity. Neither this application nor its token implements trading fees, staking, or a liquidity pool. No pool or exchange configuration is assumed by the website.

## Operational and custody assumptions

Use the delivered standard LaunchToken as the immutable token dependency. The application rejects failed transfers and mismatched received amounts and guards external token interactions, but it is not a general vault for arbitrary rebasing, malicious, or upgradeable tokens. The deployment operator must verify the dependency. Direct token transfers to the application do **not** cast votes or credit a withdrawal balance. There is no sweep function; accidental donations remain stranded. Send tokens only through `vote`.

Voting is token-weighted, public, and permits last-minute votes. It is not one-person-one-vote, a randomness scheme, or a proof of agent quality. Block producers influence transaction ordering and exact inclusion time. The lower-number tie rule is intentional. Locking prevents reusing the same tokens for multiple votes within a week; it does not prevent borrowing tokens from another holder.

Finalization is permissionless and uncompensated. A community participant or operator must pay gas to crown each ended week, including empty weeks in a backlog. A missing finalizer never stops new weeks or matured withdrawals. Each voter is responsible for requesting their own refunds and paying gas. The website operator maintains RPC availability, static hosting, and compatibility with changes to the public API. No operator can change contract rules or release active deposits early.

See [the security review notes](docs/SECURITY.md) for reviewed boundaries and [the local verification record](docs/VERIFICATION.md) for commands, results, and limits. Passing tests is not a security audit.
