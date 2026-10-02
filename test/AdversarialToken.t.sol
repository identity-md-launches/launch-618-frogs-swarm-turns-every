// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrogOfTheWeek} from "../src/FrogOfTheWeek.sol";

/// @dev Deliberately noncompliant token used only to test transfer and callback failure paths.
contract AdversarialToken {
    enum Mode {
        Normal,
        FalseReturn,
        NoReturn,
        FeeOnDeposit,
        FeeOnWithdrawal,
        RevertTransfer,
        ShortReturn
    }

    mapping(address => uint256) public balanceOf;
    Mode public mode;
    address public callbackTarget;
    bytes public callbackData;
    bool public propagateCallbackFailure;
    bool public callbackSucceeded;
    bytes4 public callbackError;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setMode(Mode next) external {
        mode = next;
    }

    function setCallback(address target, bytes calldata data, bool propagate) external {
        callbackTarget = target;
        callbackData = data;
        propagateCallbackFailure = propagate;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(mode != Mode.RevertTransfer, "mock failure");
        balanceOf[from] -= amount;
        balanceOf[to] += mode == Mode.FeeOnDeposit ? amount - 1 : amount;
        return _finish();
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(mode != Mode.RevertTransfer, "mock failure");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += mode == Mode.FeeOnWithdrawal ? amount - 1 : amount;
        return _finish();
    }

    function _finish() private returns (bool) {
        if (callbackTarget != address(0)) {
            (bool ok, bytes memory result) = callbackTarget.call(callbackData);
            callbackSucceeded = ok;
            if (result.length >= 4) callbackError = bytes4(result);
            if (propagateCallbackFailure) require(ok, "callback failed");
        }
        if (mode == Mode.NoReturn) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == Mode.ShortReturn) {
            assembly ("memory-safe") {
                mstore(0, 1)
                return(1, 31)
            }
        }
        return mode != Mode.FalseReturn;
    }
}

contract AdversarialTokenTest is Test {
    AdversarialToken private token;
    FrogOfTheWeek private contest;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    function setUp() public {
        vm.warp(1_234_567);
        token = new AdversarialToken();
        contest = new FrogOfTheWeek(address(token));
        token.mint(ALICE, 100 ether);
        token.mint(BOB, 100 ether);
    }

    function _vote(address voter, uint256 amount) private {
        uint256 week = contest.currentWeek();
        vm.prank(voter);
        contest.vote(week, 1, amount);
    }

    function _endWeek() private {
        vm.warp(contest.startTime() + 7 days);
    }

    function _assertDepositRolledBack() private view {
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(address(contest)), 0);
        assertEq(contest.locked(0, ALICE), 0);
        assertEq(contest.totalLocked(), 0);
        (uint256 total, uint256 leader, uint256 leading,,) = contest.weekInfo(0);
        assertEq(total, 0);
        assertEq(leader, 2000);
        assertEq(leading, 0);
        assertEq(contest.getVotes(0)[1], 0);
    }

    function testFalseReturningDepositRollsBackTokenAndVotingState() public {
        token.setMode(AdversarialToken.Mode.FalseReturn);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 1, 10 ether);
        _assertDepositRolledBack();
    }

    function testRevertingDepositRollsBackAndGuardResets() public {
        token.setMode(AdversarialToken.Mode.RevertTransfer);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 1, 10 ether);
        _assertDepositRolledBack();
        token.setMode(AdversarialToken.Mode.Normal);
        _vote(ALICE, 10 ether);
        assertEq(contest.locked(0, ALICE), 10 ether);
    }

    function testShortMalformedReturnRollsBack() public {
        token.setMode(AdversarialToken.Mode.ShortReturn);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 1, 10 ether);
        _assertDepositRolledBack();
    }

    function testNoReturnTokenCanDepositAndWithdraw() public {
        token.setMode(AdversarialToken.Mode.NoReturn);
        _vote(ALICE, 10 ether);
        assertEq(contest.locked(0, ALICE), 10 ether);
        _endWeek();
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(contest.totalLocked(), 0);
    }

    function testFeeOnDepositRejectsUnderfundedVotes() public {
        token.setMode(AdversarialToken.Mode.FeeOnDeposit);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.UnexpectedTokenBalance.selector);
        contest.vote(0, 1, 10 ether);
        _assertDepositRolledBack();
    }

    function testFeeOnWithdrawalRollsBackAndDepositRemainsClaimable() public {
        _vote(ALICE, 10 ether);
        _endWeek();
        token.setMode(AdversarialToken.Mode.FeeOnWithdrawal);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.UnexpectedTokenBalance.selector);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), 90 ether);
        assertEq(token.balanceOf(address(contest)), 10 ether);
        assertEq(contest.locked(0, ALICE), 10 ether);
        assertEq(contest.totalLocked(), 10 ether);
        token.setMode(AdversarialToken.Mode.Normal);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_FailedWithdrawalDoesNotBlockFinalizationOrAnotherVoter() public {
        _vote(ALICE, 10 ether);
        _vote(BOB, 20 ether);
        _endWeek();
        token.setMode(AdversarialToken.Mode.FalseReturn);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.withdraw(0);
        assertEq(contest.locked(0, ALICE), 10 ether);
        assertEq(contest.totalLocked(), 30 ether);
        contest.finalize();
        (,,, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertTrue(finalized);
        assertEq(winner, 1);
        token.setMode(AdversarialToken.Mode.Normal);
        vm.prank(BOB);
        contest.withdraw(0);
        assertEq(contest.locked(0, ALICE), 10 ether);
        assertEq(token.balanceOf(BOB), 100 ether);
        assertEq(contest.totalLocked(), 10 ether);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(contest.totalLocked(), 0);
    }

    function testDepositCallbackCannotReenterVote() public {
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.vote, (0, 1999, 1 ether)), false);
        _vote(ALICE, 10 ether);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), FrogOfTheWeek.ReentrantCall.selector);
        assertEq(contest.locked(0, ALICE), 10 ether);
        assertEq(contest.locked(0, address(token)), 0);
        assertEq(contest.getVotes(0)[1999], 0);
        assertEq(contest.totalLocked(), 10 ether);
    }

    function testWithdrawalCallbackCannotReenterWithdrawal() public {
        _vote(ALICE, 10 ether);
        _endWeek();
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.withdraw, (0)), false);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), FrogOfTheWeek.ReentrantCall.selector);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(contest.locked(0, ALICE), 0);
        assertEq(contest.totalLocked(), 0);
    }

    function testWithdrawalCallbackCannotFinalizeOutOfOrderEvents() public {
        _vote(ALICE, 10 ether);
        _endWeek();
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.finalize, ()), false);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), FrogOfTheWeek.ReentrantCall.selector);
        assertEq(contest.nextWeekToFinalize(), 0);
        contest.finalize();
        assertEq(contest.nextWeekToFinalize(), 1);
    }

    function testPropagatedReentrancyFailureRestoresLockAndTransfer() public {
        _vote(ALICE, 10 ether);
        _endWeek();
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.withdraw, (0)), true);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), 90 ether);
        assertEq(token.balanceOf(address(contest)), 10 ether);
        assertEq(contest.locked(0, ALICE), 10 ether);
        assertEq(contest.totalLocked(), 10 ether);
        token.setCallback(address(0), "", false);
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }
}
