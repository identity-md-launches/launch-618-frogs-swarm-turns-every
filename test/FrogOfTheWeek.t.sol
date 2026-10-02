// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FrogOfTheWeek} from "../src/FrogOfTheWeek.sol";

contract FrogOfTheWeekTest is Test {
    LaunchToken private token;
    FrogOfTheWeek private contest;
    uint256 private deployedAt;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA401);

    event Voted(uint256 indexed week, address indexed voter, uint256 indexed agentId, uint256 amount);
    event WeekFinalized(uint256 indexed week, uint256 indexed winner, uint256 winningVotes, uint256 totalVotes);
    event Withdrawn(uint256 indexed week, address indexed voter, uint256 amount);

    function setUp() public {
        vm.warp(1_765_432_109);
        deployedAt = block.timestamp;
        token = new LaunchToken();
        contest = new FrogOfTheWeek(address(token));
        token.transfer(ALICE, 1000 ether);
        token.transfer(BOB, 1000 ether);
        token.transfer(CAROL, 1000 ether);
        vm.prank(ALICE);
        token.approve(address(contest), type(uint256).max);
        vm.prank(BOB);
        token.approve(address(contest), type(uint256).max);
        vm.prank(CAROL);
        token.approve(address(contest), type(uint256).max);
    }

    function _vote(address voter, uint256 agentId, uint256 amount) private {
        uint256 week = contest.currentWeek();
        vm.prank(voter);
        contest.vote(week, agentId, amount);
    }

    function _atWeek(uint256 week) private {
        vm.warp(deployedAt + week * 7 days);
    }

    function testDeploymentConstantsAndEmptySummary() public view {
        assertEq(address(contest.token()), address(token));
        assertEq(contest.startTime(), deployedAt);
        assertEq(contest.WEEK_DURATION(), 7 days);
        assertEq(contest.AGENT_COUNT(), 2000);
        assertEq(contest.NO_WINNER(), 2000);
        assertEq(contest.currentWeek(), 0);
        assertEq(contest.nextWeekToFinalize(), 0);
        assertEq(contest.totalLocked(), 0);
        (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertEq(total, 0);
        assertEq(leader, 2000);
        assertEq(leading, 0);
        assertFalse(finalized);
        assertEq(winner, 2000);
    }

    function testConstructorRejectsZeroAndEOA() public {
        vm.expectRevert(FrogOfTheWeek.InvalidToken.selector);
        new FrogOfTheWeek(address(0));
        vm.expectRevert(FrogOfTheWeek.InvalidToken.selector);
        new FrogOfTheWeek(ALICE);
    }

    function testVoteEmitsAndAccumulatesAcrossAgentsAndVoters() public {
        vm.expectEmit(true, true, true, true, address(contest));
        emit Voted(0, ALICE, 1999, 15 ether);
        _vote(ALICE, 1999, 15 ether);
        _vote(ALICE, 1999, 3 ether);
        _vote(ALICE, 0, 2 ether);
        _vote(BOB, 0, 9 ether);
        assertEq(contest.locked(0, ALICE), 20 ether);
        assertEq(contest.locked(0, BOB), 9 ether);
        assertEq(contest.totalLocked(), 29 ether);
        assertEq(token.balanceOf(address(contest)), 29 ether);
        uint256[2000] memory totals = contest.getVotes(0);
        assertEq(totals[1999], 18 ether);
        assertEq(totals[0], 11 ether);
        (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertEq(total, 29 ether);
        assertEq(leader, 1999);
        assertEq(leading, 18 ether);
        assertFalse(finalized);
        assertEq(winner, 2000);
    }

    function testTiesChooseLowestAgentRegardlessOfArrivalOrder() public {
        _vote(ALICE, 1999, 10 ether);
        _vote(BOB, 0, 10 ether);
        _atWeek(1);
        contest.finalize();
        (,,,, uint256 firstWinner) = contest.weekInfo(0);
        assertEq(firstWinner, 0);
        _vote(ALICE, 0, 10 ether);
        _vote(BOB, 1999, 10 ether);
        _atWeek(2);
        contest.finalize();
        (,,,, uint256 secondWinner) = contest.weekInfo(1);
        assertEq(secondWinner, 0);
    }

    function testLeaderChangesWhenPreviousLeaderIsOvertaken() public {
        _vote(ALICE, 7, 10 ether);
        _vote(BOB, 80, 11 ether);
        _vote(CAROL, 7, 2 ether);
        _atWeek(1);
        contest.finalize();
        (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertEq(total, 23 ether);
        assertEq(leader, 7);
        assertEq(leading, 12 ether);
        assertTrue(finalized);
        assertEq(winner, 7);
    }

    function testInvalidAgentsZeroAmountAndWrongWeek() public {
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.InvalidAgent.selector, 2000));
        contest.vote(0, 2000, 1);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.InvalidAgent.selector, type(uint256).max));
        contest.vote(0, type(uint256).max, 1);
        vm.expectRevert(FrogOfTheWeek.ZeroAmount.selector);
        contest.vote(0, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WrongWeek.selector, 1, 0));
        contest.vote(1, 1, 1);
        assertEq(contest.totalLocked(), 0);
    }

    function testMissingApprovalAndInsufficientFundsRollbackVotes() public {
        vm.prank(ALICE);
        token.approve(address(contest), 0);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 1, 1 ether);
        vm.prank(BOB);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 1, 1001 ether);
        assertEq(contest.locked(0, ALICE), 0);
        assertEq(contest.locked(0, BOB), 0);
        assertEq(contest.totalLocked(), 0);
        (uint256 total,,,,) = contest.weekInfo(0);
        assertEq(total, 0);
        assertEq(contest.getVotes(0)[1], 0);
    }

    function testExactBoundaryRejectsStaleVoteAndAllowsNewWeek() public {
        vm.warp(deployedAt + 7 days - 1);
        _vote(ALICE, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, 0));
        contest.finalize();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, 0));
        contest.withdraw(0);
        _atWeek(1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WrongWeek.selector, 0, 1));
        contest.vote(0, 1999, 99 ether);
        _vote(BOB, 1999, 2);
        assertEq(contest.getVotes(0)[0], 1);
        assertEq(contest.getVotes(1)[1999], 2);
        vm.prank(ALICE);
        contest.withdraw(0);
        contest.finalize();
        assertEq(contest.currentWeek(), 1);
    }

    function testAnyoneCanFinalizeWinnerAndEvent() public {
        _vote(ALICE, 1999, 31 ether);
        _atWeek(1);
        vm.expectEmit(true, true, false, true, address(contest));
        emit WeekFinalized(0, 1999, 31 ether, 31 ether);
        vm.prank(CAROL);
        contest.finalize();
        (,,, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertTrue(finalized);
        assertEq(winner, 1999);
        assertEq(contest.nextWeekToFinalize(), 1);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, 1));
        contest.finalize();
    }

    function testSkippedWeeksFinalizeInOrderWithoutDelayingNewVotes() public {
        _vote(ALICE, 42, 1 ether);
        _atWeek(3);
        _vote(BOB, 8, 7 ether);
        assertEq(contest.nextWeekToFinalize(), 0);
        contest.finalize();
        (,,,, uint256 winner0) = contest.weekInfo(0);
        assertEq(winner0, 42);
        contest.finalize();
        (uint256 total1, uint256 leader1,, bool final1, uint256 winner1) = contest.weekInfo(1);
        assertEq(total1, 0);
        assertEq(leader1, 2000);
        assertTrue(final1);
        assertEq(winner1, 2000);
        contest.finalize();
        (,,, bool final2, uint256 winner2) = contest.weekInfo(2);
        assertTrue(final2);
        assertEq(winner2, 2000);
        assertEq(contest.nextWeekToFinalize(), 3);
        assertEq(contest.getVotes(3)[8], 7 ether);
    }

    function testEmptyWeekUsesSentinelAndCannotInventAgentZero() public {
        _atWeek(1);
        vm.expectEmit(true, true, false, true, address(contest));
        emit WeekFinalized(0, 2000, 0, 0);
        contest.finalize();
        (,,,, uint256 winner) = contest.weekInfo(0);
        assertEq(winner, 2000);
    }

    function testWithdrawBeforeFinalizationReturnsAllAndKeepsHistoricTotals() public {
        _vote(ALICE, 3, 2 ether);
        _vote(ALICE, 9, 3 ether);
        _vote(BOB, 3, 4 ether);
        _atWeek(1);
        vm.expectEmit(true, true, false, true, address(contest));
        emit Withdrawn(0, ALICE, 5 ether);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(contest.locked(0, ALICE), 0);
        assertEq(contest.locked(0, BOB), 4 ether);
        assertEq(contest.totalLocked(), 4 ether);
        assertEq(token.balanceOf(address(contest)), 4 ether);
        assertEq(contest.getVotes(0)[3], 6 ether);
        assertEq(contest.getVotes(0)[9], 3 ether);
        contest.finalize();
        (uint256 total,,, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertEq(total, 9 ether);
        assertTrue(finalized);
        assertEq(winner, 3);
        vm.prank(BOB);
        contest.withdraw(0);
        assertEq(contest.totalLocked(), 0);
        assertEq(token.balanceOf(address(contest)), 0);
    }

    function testWithdrawRejectsCurrentFutureEmptyAndDuplicate() public {
        _vote(ALICE, 0, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, 0));
        contest.withdraw(0);
        _atWeek(1);
        vm.expectRevert(abi.encodeWithSelector(FrogOfTheWeek.WeekNotEnded.selector, type(uint256).max));
        contest.withdraw(type(uint256).max);
        vm.prank(BOB);
        vm.expectRevert(FrogOfTheWeek.NothingToWithdraw.selector);
        contest.withdraw(0);
        vm.prank(ALICE);
        contest.withdraw(0);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.NothingToWithdraw.selector);
        contest.withdraw(0);
    }

    function testWithdrawOldWeekDoesNotReleaseCurrentDeposit() public {
        _vote(ALICE, 5, 3 ether);
        _atWeek(1);
        _vote(ALICE, 6, 4 ether);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(contest.locked(1, ALICE), 4 ether);
        assertEq(contest.totalLocked(), 4 ether);
        assertEq(token.balanceOf(ALICE), 996 ether);
        _atWeek(100);
        vm.prank(ALICE);
        contest.withdraw(1);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(contest.nextWeekToFinalize(), 0);
    }

    function testDirectDonationsAreNotVotesAndCannotStealDeposits() public {
        token.transfer(address(contest), 7 ether);
        _vote(ALICE, 1, 3 ether);
        (uint256 total,,,,) = contest.weekInfo(0);
        assertEq(total, 3 ether);
        assertEq(contest.totalLocked(), 3 ether);
        _atWeek(1);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(address(contest)), 7 ether);
        assertEq(contest.totalLocked(), 0);
        vm.expectRevert(FrogOfTheWeek.NothingToWithdraw.selector);
        contest.withdraw(0);
    }

    function testNoAdminOrSweepAndNonpayableCalls() public {
        (bool sweepOK,) = address(contest).call(abi.encodeWithSignature("sweep(address)", ALICE));
        assertFalse(sweepOK);
        (bool ownerOK,) = address(contest).call(abi.encodeWithSignature("owner()"));
        assertFalse(ownerOK);
        vm.deal(address(this), 1 ether);
        (bool receiveOK,) = address(contest).call{value: 1}("");
        assertFalse(receiveOK);
    }

    function testRuntimeBoundAndNoEscapeOpcodes() public view {
        bytes memory code = address(contest).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzzVoteConservationAndWinner(uint256 rawA, uint256 rawB, uint256 rawIdA, uint256 rawIdB) public {
        uint256 amountA = bound(rawA, 1, 1000 ether);
        uint256 amountB = bound(rawB, 1, 1000 ether);
        uint256 idA = bound(rawIdA, 0, 1999);
        uint256 idB = bound(rawIdB, 0, 1999);
        _vote(ALICE, idA, amountA);
        _vote(BOB, idB, amountB);
        assertEq(token.balanceOf(address(contest)), amountA + amountB);
        assertEq(contest.totalLocked(), amountA + amountB);
        _atWeek(1);
        vm.prank(ALICE);
        contest.withdraw(0);
        contest.finalize();
        vm.prank(BOB);
        contest.withdraw(0);
        (uint256 total,,, bool finalized, uint256 winner) = contest.weekInfo(0);
        uint256 expected = amountA > amountB ? idA : idB;
        if (amountA == amountB) expected = idA < idB ? idA : idB;
        assertEq(winner, expected);
        assertTrue(finalized);
        assertEq(total, amountA + amountB);
        assertEq(contest.totalLocked(), 0);
        assertEq(token.balanceOf(address(contest)), 0);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        assertEq(token.balanceOf(BOB), 1000 ether);
    }
}
