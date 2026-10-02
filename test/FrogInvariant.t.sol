// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FrogOfTheWeek} from "../src/FrogOfTheWeek.sol";

/// @dev The ghosts only change after a successful operation. Time and finalization are modeled
/// independently of the contract's getters, so an incorrect cursor cannot redefine the oracle.
contract FrogHandler is Test {
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant MAX_RANDOM_WEEK = 12;
    LaunchToken public immutable token;
    FrogOfTheWeek public immutable contest;
    uint256 public immutable deployedAt;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    mapping(uint256 => mapping(address => uint256)) public owed;
    mapping(uint256 => mapping(uint256 => uint256)) public historicVotes;
    mapping(uint256 => uint256) public historicTotal;
    mapping(address => uint256) public depositedBy;
    mapping(address => uint256) public withdrawnBy;
    mapping(address => uint256) public donatedBy;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public donations;
    uint256 public finalizedWeeks;

    constructor(LaunchToken token_, FrogOfTheWeek contest_) {
        token = token_;
        contest = contest_;
        deployedAt = vm.getBlockTimestamp();
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            token.approve(address(contest), type(uint256).max);
        }
    }

    function modelWeek() public view returns (uint256) {
        return (vm.getBlockTimestamp() - deployedAt) / 7 days;
    }

    function vote(uint256 rawActor, uint256 rawAgent, uint256 rawAmount) external {
        address voter = actors[rawActor % actors.length];
        uint256 available = token.balanceOf(voter);
        if (available == 0) return;
        uint256 amount = rawAmount % 4 == 0 ? 1 : rawAmount % 4 == 1 ? available : bound(rawAmount, 1, available);
        // Three candidates create repeated votes, overtaking and ties; the winner fuzz tests
        // separately cover every ID. Both ends of the permitted range are included here.
        uint256 agentId = rawAgent % 3 == 0 ? 1999 : rawAgent % 3 - 1;
        uint256 week = modelWeek();
        vm.prank(voter);
        contest.vote(week, agentId, amount);
        owed[week][voter] += amount;
        historicVotes[week][agentId] += amount;
        historicTotal[week] += amount;
        depositedBy[voter] += amount;
        deposits += amount;
        uint256[2000] memory totals = contest.getVotes(week);
        assertEq(totals[0], historicVotes[week][0]);
        assertEq(totals[1], historicVotes[week][1]);
        assertEq(totals[1999], historicVotes[week][1999]);
    }

    function withdraw(uint256 rawActor, uint256 rawWeek) external {
        // Include the current and next week, empty weeks, and previously withdrawn deposits.
        uint256 week = rawWeek % (modelWeek() + 2);
        address voter = actors[rawActor % actors.length];
        if (week >= modelWeek()) {
            bytes32 beforeState = _stateDigest(week);
            vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, week));
            vm.prank(voter);
            contest.withdraw(week);
            assertEq(_stateDigest(week), beforeState);
        } else if (owed[week][voter] == 0) {
            bytes32 beforeState = _stateDigest(week);
            vm.expectRevert(FrogOfTheWeek.NothingToWithdraw.selector);
            vm.prank(voter);
            contest.withdraw(week);
            assertEq(_stateDigest(week), beforeState);
        } else {
            _withdraw(voter, week);
        }
    }

    function advance(uint256 rawSeconds) external {
        // Hit exact weekly boundaries as well as either side. A finite horizon keeps exhaustive
        // history checks bounded while allowing a substantial unfinalized backlog.
        uint256 timestamp = vm.getBlockTimestamp();
        uint256 target = timestamp + bound(rawSeconds, 1, 7 days + 1);
        uint256 horizon = deployedAt + MAX_RANDOM_WEEK * 7 days;
        if (target > horizon) target = horizon;
        if (target > timestamp) vm.warp(target);
    }

    function finalize(uint256 rawCaller) external {
        address caller = actors[rawCaller % actors.length];
        if (finalizedWeeks == modelWeek()) {
            bytes32 beforeState = _stateDigest(finalizedWeeks);
            vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, finalizedWeeks));
            vm.prank(caller);
            contest.finalize();
            assertEq(_stateDigest(finalizedWeeks), beforeState);
        } else {
            _finalize(caller);
        }
    }

    function donate(uint256 rawActor, uint256 rawAmount) external {
        address donor = actors[rawActor % actors.length];
        uint256 available = token.balanceOf(donor);
        if (available < 4) return;
        // Do not let one donation make every subsequent voting action vacuous.
        uint256 amount = bound(rawAmount, 1, available / 4);
        vm.prank(donor);
        token.transfer(address(contest), amount);
        donatedBy[donor] += amount;
        donations += amount;
    }

    function rejectVote(uint256 rawActor, uint256 rawKind, uint256 rawAgent) external {
        address voter = actors[rawActor % actors.length];
        uint256 week = modelWeek();
        uint256 expectedWeek = week;
        uint256 agentId = rawAgent % 2000;
        uint256 amount = 1;
        uint256 kind = rawKind % 6;
        bytes memory reason;
        if (kind == 0) {
            expectedWeek = week == 0 ? 1 : week - 1;
            reason = abi.encodeWithSelector(FrogOfTheWeek.WrongWeek.selector, expectedWeek, week);
        } else if (kind == 1) {
            expectedWeek = week + 1;
            reason = abi.encodeWithSelector(FrogOfTheWeek.WrongWeek.selector, expectedWeek, week);
        } else if (kind == 2) {
            agentId = bound(rawAgent, 2000, type(uint256).max);
            reason = abi.encodeWithSelector(FrogOfTheWeek.InvalidAgent.selector, agentId);
        } else if (kind == 3) {
            amount = 0;
            reason = abi.encodeWithSelector(FrogOfTheWeek.ZeroAmount.selector);
        } else if (kind == 4) {
            vm.prank(voter);
            token.approve(address(contest), 0);
            reason = abi.encodeWithSelector(FrogOfTheWeek.TokenTransferFailed.selector);
        } else {
            amount = token.balanceOf(voter) + 1;
            reason = abi.encodeWithSelector(FrogOfTheWeek.TokenTransferFailed.selector);
        }
        bytes32 beforeState = _stateDigest(week);
        vm.expectRevert(reason);
        vm.prank(voter);
        contest.vote(expectedWeek, agentId, amount);
        assertEq(_stateDigest(week), beforeState, "failed vote must roll back all accounting");
        if (kind == 4) {
            vm.prank(voter);
            token.approve(address(contest), type(uint256).max);
        }
    }

    /// @dev Called only by afterInvariant, not in the random selector set. Every deposited token
    /// must remain recoverable without depending on finalization, even after arbitrary failures.
    function finish() external {
        vm.warp(deployedAt + (modelWeek() + 1) * 7 days);
        uint256 current = modelWeek();
        for (uint256 week; week < current; ++week) {
            for (uint256 i; i < actors.length; ++i) {
                if (owed[week][actors[i]] != 0) _withdraw(actors[i], week);
            }
        }
        while (finalizedWeeks < current) _finalize(actors[finalizedWeeks % actors.length]);
    }

    function expectedLeader(uint256 week) external view returns (uint256 leader, uint256 leadingVotes) {
        leader = 2000;
        uint256[3] memory ids = [uint256(0), 1, 1999];
        for (uint256 i; i < ids.length; ++i) {
            uint256 count = historicVotes[week][ids[i]];
            if (count > leadingVotes) {
                leader = ids[i];
                leadingVotes = count;
            }
        }
    }

    function _withdraw(address voter, uint256 week) private {
        uint256 amount = owed[week][voter];
        bytes32 history = _historyDigest(week);
        vm.prank(voter);
        contest.withdraw(week);
        owed[week][voter] = 0;
        withdrawnBy[voter] += amount;
        withdrawals += amount;
        assertEq(_historyDigest(week), history, "withdrawal must preserve historic votes and winner");
    }

    function _finalize(address caller) private {
        uint256 week = finalizedWeeks;
        bytes32 votesBefore = keccak256(abi.encode(contest.getVotes(week)));
        uint256 lockedBefore = contest.totalLocked();
        vm.prank(caller);
        contest.finalize();
        ++finalizedWeeks;
        assertEq(contest.nextWeekToFinalize(), finalizedWeeks);
        assertEq(contest.totalLocked(), lockedBefore, "finalization cannot consume deposits");
        assertEq(keccak256(abi.encode(contest.getVotes(week))), votesBefore);
    }

    function _historyDigest(uint256 week) private view returns (bytes32) {
        (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = contest.weekInfo(week);
        return keccak256(abi.encode(contest.getVotes(week), total, leader, leading, finalized, winner));
    }

    function _stateDigest(uint256 week) private view returns (bytes32) {
        uint256[3] memory balances;
        uint256[3] memory allowances;
        uint256[3] memory liabilities;
        for (uint256 i; i < actors.length; ++i) {
            balances[i] = token.balanceOf(actors[i]);
            allowances[i] = token.allowance(actors[i], address(contest));
            liabilities[i] = contest.locked(week, actors[i]);
        }
        return keccak256(
            abi.encode(
                _historyDigest(week),
                contest.totalLocked(),
                contest.nextWeekToFinalize(),
                token.balanceOf(address(contest)),
                token.totalSupply(),
                balances,
                allowances,
                liabilities
            )
        );
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract FrogInvariantTest is StdInvariant, Test {
    LaunchToken private token;
    FrogOfTheWeek private contest;
    FrogHandler private handler;

    function setUp() public {
        vm.warp(2_000_000);
        token = new LaunchToken();
        contest = new FrogOfTheWeek(address(token));
        handler = new FrogHandler(token, contest);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), handler.INITIAL_BALANCE());
        }
        // Seed a real outstanding deposit so conservation and the final unwind are never vacuous.
        handler.vote(0, 0, 10 ether + 2);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = FrogHandler.vote.selector;
        selectors[1] = FrogHandler.withdraw.selector;
        selectors[2] = FrogHandler.advance.selector;
        selectors[3] = FrogHandler.finalize.selector;
        selectors[4] = FrogHandler.donate.selector;
        selectors[5] = FrogHandler.rejectVote.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantCustodyEqualsAllOutstandingDepositsPlusDonations() public view {
        uint256 liability;
        uint256 participantBalances;
        for (uint256 i; i < 3; ++i) {
            address voter = handler.actors(i);
            uint256 actorLiability;
            for (uint256 week; week <= handler.modelWeek(); ++week) {
                uint256 expected = handler.owed(week, voter);
                assertEq(contest.locked(week, voter), expected);
                actorLiability += expected;
            }
            liability += actorLiability;
            uint256 balance = token.balanceOf(voter);
            participantBalances += balance;
            assertLe(handler.withdrawnBy(voter), handler.depositedBy(voter), "no voter can withdraw a profit");
            assertEq(handler.depositedBy(voter) - handler.withdrawnBy(voter), actorLiability);
            assertEq(balance + actorLiability + handler.donatedBy(voter), handler.INITIAL_BALANCE());
        }
        assertEq(contest.totalLocked(), liability);
        assertEq(handler.deposits() - handler.withdrawals(), liability);
        assertEq(token.balanceOf(address(contest)), liability + handler.donations());
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)) + participantBalances + token.balanceOf(address(contest)), 1e27);
    }

    function invariantHistoricalTotalsAndWinnersMatchIndependentModel() public view {
        assertEq(contest.currentWeek(), handler.modelWeek());
        assertEq(contest.nextWeekToFinalize(), handler.finalizedWeeks());
        assertLe(handler.finalizedWeeks(), handler.modelWeek());
        for (uint256 week; week <= handler.modelWeek(); ++week) {
            (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = contest.weekInfo(week);
            (uint256 expectedLeader, uint256 expectedLeading) = handler.expectedLeader(week);
            assertEq(total, handler.historicTotal(week));
            assertEq(leader, expectedLeader);
            assertEq(leading, expectedLeading);
            assertEq(finalized, week < handler.finalizedWeeks());
            assertEq(winner, finalized ? expectedLeader : 2000);
        }
    }

    function afterInvariant() public {
        handler.finish();
        invariantCustodyEqualsAllOutstandingDepositsPlusDonations();
        invariantHistoricalTotalsAndWinnersMatchIndependentModel();
        assertEq(contest.totalLocked(), 0, "all deposits must be withdrawable after their week ends");
        assertEq(handler.deposits(), handler.withdrawals());
        assertEq(token.balanceOf(address(contest)), handler.donations());
        for (uint256 week; week <= handler.modelWeek(); ++week) {
            uint256[2000] memory totals = contest.getVotes(week);
            uint256[2000] memory expected;
            expected[0] = handler.historicVotes(week, 0);
            expected[1] = handler.historicVotes(week, 1);
            expected[1999] = handler.historicVotes(week, 1999);
            // Compare every slot, including the 1,997 agents that never received a vote.
            assertEq(keccak256(abi.encode(totals)), keccak256(abi.encode(expected)), "historic per-agent votes");
            assertEq(expected[0] + expected[1] + expected[1999], handler.historicTotal(week));
        }
    }
}
