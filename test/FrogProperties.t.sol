// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {FrogOfTheWeek} from "src/FrogOfTheWeek.sol";

/// @dev Properties supplementing the existing lifecycle examples with populated-state
/// rollback, the entire real token supply, and equivalent transaction orderings.
/// forge-config: default.fuzz.runs = 1000
contract FrogPropertiesTest is Test {
    LaunchToken private token;
    FrogOfTheWeek private contest;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        vm.warp(1_765_432_109);
        token = new LaunchToken();
        contest = new FrogOfTheWeek(address(token));
        token.transfer(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(address(contest), type(uint256).max);
    }

    function testEntireSupplyCanVoteBeRefundedAndVoteAgain() public {
        _vote(contest, 0, 1999, SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(contest)), SUPPLY);
        assertEq(contest.totalLocked(), SUPPLY);
        assertEq(contest.locked(0, ALICE), SUPPLY);
        assertEq(contest.getVotes(0)[1999], SUPPLY);
        bytes32 history = _historyHash(contest, 0);

        // A vote cannot reuse tokens that are still held for this voter.
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 0, 1);
        assertEq(_historyHash(contest, 0), history);
        assertEq(contest.totalLocked(), SUPPLY);

        vm.warp(contest.startTime() + 7 days);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(_historyHash(contest, 0), history);

        // Refunds work without finalization, and historical votes remain even when
        // the very same supply is locked in the next week.
        _vote(contest, 1, 0, SUPPLY);
        contest.finalize();
        (uint256 total0,,, bool finalized0, uint256 winner0) = contest.weekInfo(0);
        assertEq(total0, SUPPLY);
        assertTrue(finalized0);
        assertEq(winner0, 1999);
        assertEq(contest.locked(0, ALICE), 0);
        assertEq(contest.locked(1, ALICE), SUPPLY);
        assertEq(contest.totalLocked(), SUPPLY);

        vm.warp(contest.startTime() + 14 days);
        contest.finalize();
        vm.prank(ALICE);
        contest.withdraw(1);
        (uint256 total1,,, bool finalized1, uint256 winner1) = contest.weekInfo(1);
        assertEq(total1, SUPPLY);
        assertTrue(finalized1);
        assertEq(winner1, 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(address(contest)), 0);
        assertEq(contest.totalLocked(), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testMaximumAmountIsRejectedWithoutCreatingUnbackedVotes() public {
        bytes32 beforeState = _stateHash(0);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 1999, type(uint256).max);
        assertEq(_stateHash(0), beforeState);
        _vote(contest, 0, 1999, 1);
        assertEq(contest.locked(0, ALICE), 1);
        assertEq(token.balanceOf(address(contest)), 1);
    }

    function testFuzzShortAllowanceRollsBackExistingLeaderAndAllowsRetry(uint256 rawAmount, uint256 rawId) public {
        _seedCompetingVotes();
        uint256 amount = bound(rawAmount, 1, token.balanceOf(ALICE));
        uint256 agent = bound(rawId, 0, 1999);
        vm.prank(ALICE);
        token.approve(address(contest), amount - 1);
        bytes32 beforeState = _stateHash(0);

        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, agent, amount);
        assertEq(_stateHash(0), beforeState, "failed transfer changed funded contest");

        // A failed call must not leave the guard engaged or consume an allowance.
        vm.prank(ALICE);
        token.approve(address(contest), amount);
        _vote(contest, 0, agent, amount);
        assertEq(contest.locked(0, ALICE), 32 ether + amount);
        assertEq(contest.totalLocked(), 48 ether + amount);
        assertEq(token.balanceOf(address(contest)), 48 ether + amount);
        assertEq(token.allowance(ALICE, address(contest)), 0);
    }

    function testInsufficientBalanceRestoresSpentAllowanceAndExistingVotes() public {
        _seedCompetingVotes();
        uint256 amount = token.balanceOf(ALICE) + 1;
        vm.prank(ALICE);
        token.approve(address(contest), amount);
        bytes32 beforeState = _stateHash(0);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 1999, amount);
        assertEq(_stateHash(0), beforeState);
        assertEq(token.allowance(ALICE, address(contest)), amount);

        // Withdrawing the legitimate votes remains possible after the failed pull.
        vm.warp(contest.startTime() + 7 days);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), SUPPLY - 100 ether);
        assertEq(contest.locked(0, BOB), 16 ether);
        assertEq(contest.totalLocked(), 16 ether);
    }

    function testFuzzInvalidAgentPreservesAllExistingAccounting(uint256 rawAgent) public {
        _seedCompetingVotes();
        uint256 agent = bound(rawAgent, 2000, type(uint256).max);
        bytes32 beforeState = _stateHash(0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.InvalidAgent.selector, agent));
        contest.vote(0, agent, 100 ether);
        assertEq(_stateHash(0), beforeState);
    }

    function testFuzzWeekBoundaryIsRelativeToDeployment(uint64 rawStart, uint32 rawWeek, uint16 rawAgent) public {
        uint256 start = bound(uint256(rawStart), 1, type(uint64).max);
        uint256 week = bound(uint256(rawWeek), 0, 1_000_000);
        uint256 agent = bound(uint256(rawAgent), 0, 1999);
        vm.warp(start);
        FrogOfTheWeek shifted = new FrogOfTheWeek(address(token));
        vm.prank(ALICE);
        token.approve(address(shifted), 2);
        uint256 boundary = start + (week + 1) * 7 days;

        vm.warp(boundary - 1);
        assertEq(shifted.currentWeek(), week);
        _vote(shifted, week, agent, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, week));
        shifted.withdraw(week);

        vm.warp(boundary);
        assertEq(shifted.currentWeek(), week + 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WrongWeek.selector, week, week + 1));
        shifted.vote(week, agent, 1);
        assertEq(token.allowance(ALICE, address(shifted)), 1);
        _vote(shifted, week + 1, agent, 1);
        vm.prank(ALICE);
        shifted.withdraw(week);
        assertEq(shifted.locked(week, ALICE), 0);
        assertEq(shifted.locked(week + 1, ALICE), 1);
        assertEq(shifted.totalLocked(), 1);
        assertEq(token.balanceOf(address(shifted)), 1);
        assertEq(shifted.getVotes(week)[agent], 1);
        assertEq(shifted.getVotes(week + 1)[agent], 1);
        assertEq(shifted.nextWeekToFinalize(), 0);
    }

    function testFuzzSplittingVotesAndRefundOrderPreserveOutcome(
        uint256 rawAmount,
        uint256 rawSplit,
        uint256 rawOpponent,
        uint16 rawId
    ) public {
        uint256 amount = bound(rawAmount, 2, SUPPLY / 4);
        uint256 split = bound(rawSplit, 1, amount - 1);
        uint256 opponent = bound(rawOpponent, 1, SUPPLY / 4);
        uint256 agent = bound(uint256(rawId), 0, 1999);
        uint256 otherAgent = (agent + 1) % 2000;
        FrogOfTheWeek fragmented = new FrogOfTheWeek(address(token));
        vm.prank(ALICE);
        token.approve(address(fragmented), type(uint256).max);

        _vote(contest, 0, agent, amount);
        _vote(contest, 0, otherAgent, opponent);
        _vote(fragmented, 0, otherAgent, opponent);
        _vote(fragmented, 0, agent, split);
        _vote(fragmented, 0, agent, amount - split);
        assertEq(_historyHash(contest, 0), _historyHash(fragmented, 0));
        assertEq(contest.locked(0, ALICE), amount + opponent);
        assertEq(fragmented.locked(0, ALICE), amount + opponent);

        vm.warp(contest.startTime() + 7 days);
        contest.finalize();
        vm.prank(ALICE);
        contest.withdraw(0);
        vm.prank(ALICE);
        fragmented.withdraw(0);
        fragmented.finalize();
        assertEq(_historyHash(contest, 0), _historyHash(fragmented, 0));
        (uint256 total,,, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertEq(total, amount + opponent);
        assertTrue(finalized);
        uint256 expected = amount > opponent ? agent : otherAgent;
        if (amount == opponent) expected = agent < otherAgent ? agent : otherAgent;
        assertEq(winner, expected);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(contest.totalLocked(), 0);
        assertEq(fragmented.totalLocked(), 0);
        assertEq(token.balanceOf(address(contest)), 0);
        assertEq(token.balanceOf(address(fragmented)), 0);
    }

    function _seedCompetingVotes() private {
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        _vote(contest, 0, 7, 32 ether);
        vm.startPrank(BOB);
        token.approve(address(contest), 16 ether);
        contest.vote(0, 42, 16 ether);
        vm.stopPrank();
    }

    function _vote(FrogOfTheWeek target, uint256 week, uint256 agent, uint256 amount) private {
        vm.prank(ALICE);
        target.vote(week, agent, amount);
    }

    function _historyHash(FrogOfTheWeek target, uint256 week) private view returns (bytes32) {
        (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = target.weekInfo(week);
        return keccak256(abi.encode(target.getVotes(week), total, leader, leading, finalized, winner));
    }

    function _stateHash(uint256 week) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _historyHash(contest, week),
                contest.totalLocked(),
                contest.nextWeekToFinalize(),
                contest.locked(week, ALICE),
                contest.locked(week, BOB),
                token.balanceOf(address(contest)),
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.allowance(ALICE, address(contest)),
                token.allowance(BOB, address(contest)),
                token.totalSupply()
            )
        );
    }
}
