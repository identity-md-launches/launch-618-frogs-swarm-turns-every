// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrogOfTheWeek} from "src/FrogOfTheWeek.sol";
import {AdversarialToken} from "./AdversarialToken.t.sol";

/// @dev Callbacks exercise the shared guard with otherwise-valid cross-function calls.
contract CrossEntryReentrancyTest is Test {
    AdversarialToken private token;
    FrogOfTheWeek private contest;
    address private constant ALICE = address(0xA11CE);

    function setUp() public {
        vm.warp(12_345_678);
        token = new AdversarialToken();
        contest = new FrogOfTheWeek(address(token));
        token.mint(ALICE, 100 ether);
        token.mint(address(token), 20 ether);
    }

    function _vote(address voter, uint256 week, uint256 agent, uint256 amount) private {
        vm.prank(voter);
        contest.vote(week, agent, amount);
    }

    function _assertCallbackBlocked() private view {
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), FrogOfTheWeek.ReentrantCall.selector);
    }

    function testDepositCallbackCannotWithdrawAnExistingPriorWeekLock() public {
        _vote(address(token), 0, 9, 5 ether);
        vm.warp(contest.startTime() + 7 days);
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.withdraw, (0)), false);

        _vote(ALICE, 1, 4, 10 ether);

        _assertCallbackBlocked();
        assertEq(contest.locked(0, address(token)), 5 ether);
        assertEq(contest.locked(1, ALICE), 10 ether);
        assertEq(contest.totalLocked(), 15 ether);
        assertEq(token.balanceOf(address(contest)), 15 ether);
        token.setCallback(address(0), "", false);
        vm.prank(address(token));
        contest.withdraw(0);
        assertEq(token.balanceOf(address(token)), 20 ether);
        assertEq(contest.totalLocked(), 10 ether);
    }

    function testDepositCallbackCannotFinalizeAnEndedPendingWeek() public {
        _vote(ALICE, 0, 3, 7 ether);
        vm.warp(contest.startTime() + 7 days);
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.finalize, ()), false);

        _vote(ALICE, 1, 4, 10 ether);

        _assertCallbackBlocked();
        assertEq(contest.nextWeekToFinalize(), 0);
        (,,, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertFalse(finalized);
        assertEq(winner, 2000);
        contest.finalize();
        (,,, finalized, winner) = contest.weekInfo(0);
        assertTrue(finalized);
        assertEq(winner, 3);
        assertEq(contest.getVotes(1)[4], 10 ether);
    }

    function testWithdrawalCallbackCannotCreateCurrentWeekVotes() public {
        _vote(ALICE, 0, 3, 10 ether);
        vm.warp(contest.startTime() + 7 days);
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.vote, (1, 1999, 1 ether)), false);

        vm.prank(ALICE);
        contest.withdraw(0);

        _assertCallbackBlocked();
        assertEq(contest.locked(1, address(token)), 0);
        assertEq(contest.getVotes(1)[1999], 0);
        (uint256 total, uint256 leader, uint256 leading,,) = contest.weekInfo(1);
        assertEq(total, 0);
        assertEq(leader, 2000);
        assertEq(leading, 0);
        assertEq(contest.totalLocked(), 0);
        assertEq(token.balanceOf(ALICE), 100 ether);
        token.setCallback(address(0), "", false);
        _vote(address(token), 1, 1999, 1 ether);
        assertEq(contest.getVotes(1)[1999], 1 ether);
    }

    function testPropagatedDepositCallbackFailureRestoresAnExistingLeader() public {
        _vote(ALICE, 0, 7, 5 ether);
        vm.warp(contest.startTime() + 7 days);
        _vote(ALICE, 1, 4, 9 ether);
        token.setCallback(address(contest), abi.encodeCall(FrogOfTheWeek.finalize, ()), true);

        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(1, 2, 10 ether);

        assertEq(token.balanceOf(ALICE), 86 ether);
        assertEq(token.balanceOf(address(contest)), 14 ether);
        assertEq(contest.totalLocked(), 14 ether);
        assertEq(contest.locked(0, ALICE), 5 ether);
        assertEq(contest.locked(1, ALICE), 9 ether);
        assertEq(contest.getVotes(1)[2], 0);
        assertEq(contest.getVotes(1)[4], 9 ether);
        (uint256 total, uint256 leader, uint256 leading,,) = contest.weekInfo(1);
        assertEq(total, 9 ether);
        assertEq(leader, 4);
        assertEq(leading, 9 ether);
        assertEq(contest.nextWeekToFinalize(), 0);
        token.setCallback(address(0), "", false);
        _vote(ALICE, 1, 2, 10 ether);
        assertEq(contest.totalLocked(), 24 ether);
        assertEq(contest.getVotes(1)[2], 10 ether);
    }
}

/// @dev Unsupported token behavior is used to exercise rejection and rollback, never to model FROGS.
contract BoundaryProbeToken {
    enum Movement {
        Exact,
        ExcessCredit,
        SkipDebit
    }

    mapping(address => uint256) public balanceOf;
    Movement public movement;
    bytes private returnData = abi.encode(true);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setMovement(Movement value) external {
        movement = value;
    }

    function setReturnData(bytes calldata value) external {
        returnData = value;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _move(from, to, amount);
        _respond();
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        _respond();
    }

    function _move(address from, address to, uint256 amount) private {
        if (movement != Movement.SkipDebit) balanceOf[from] -= amount;
        balanceOf[to] += movement == Movement.ExcessCredit ? amount + 1 : amount;
    }

    function _respond() private view {
        bytes memory result = returnData;
        assembly ("memory-safe") {
            return(add(result, 32), mload(result))
        }
    }
}

/// forge-config: default.fuzz.runs = 1000
contract TokenBoundaryAccountingTest is Test {
    BoundaryProbeToken private token;
    FrogOfTheWeek private contest;
    address private constant ALICE = address(0xA11CE);

    function setUp() public {
        vm.warp(12_345_678);
        token = new BoundaryProbeToken();
        contest = new FrogOfTheWeek(address(token));
        token.mint(ALICE, 100 ether);
        _vote(7, 5 ether);
    }

    function _vote(uint256 agent, uint256 amount) private {
        vm.prank(ALICE);
        contest.vote(0, agent, amount);
    }

    function _assertOriginalDepositUnchanged() private view {
        assertEq(token.balanceOf(ALICE), 95 ether);
        assertEq(token.balanceOf(address(contest)), 5 ether);
        assertEq(contest.totalLocked(), 5 ether);
        assertEq(contest.locked(0, ALICE), 5 ether);
        uint256[2000] memory votes = contest.getVotes(0);
        assertEq(votes[7], 5 ether);
        assertEq(votes[2], 0);
        (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = contest.weekInfo(0);
        assertEq(total, 5 ether);
        assertEq(leader, 7);
        assertEq(leading, 5 ether);
        assertFalse(finalized);
        assertEq(winner, 2000);
    }

    function _withdrawSuccessfullyAfterRecovery() private {
        token.setMovement(BoundaryProbeToken.Movement.Exact);
        token.setReturnData(abi.encode(true));
        vm.prank(ALICE);
        contest.withdraw(0);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(address(contest)), 0);
        assertEq(contest.totalLocked(), 0);
        assertEq(contest.locked(0, ALICE), 0);
        assertEq(contest.getVotes(0)[7], 5 ether);
    }

    function _rejectMalformedDepositAndWithdrawal(bytes memory malformed) private {
        token.setReturnData(malformed);
        vm.prank(ALICE);
        // A noncanonical boolean fails ABI decoding; wrong-length data uses the custom error.
        if (malformed.length == 32) vm.expectRevert();
        else vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.vote(0, 2, 10 ether);
        _assertOriginalDepositUnchanged();

        vm.warp(contest.startTime() + 7 days);
        vm.prank(ALICE);
        if (malformed.length == 32) vm.expectRevert();
        else vm.expectRevert(FrogOfTheWeek.TokenTransferFailed.selector);
        contest.withdraw(0);
        _assertOriginalDepositUnchanged();
        _withdrawSuccessfullyAfterRecovery();
    }

    function testOversizedSuccessfulReturnDataRollsBackVoteAndWithdrawal() public {
        _rejectMalformedDepositAndWithdrawal(abi.encode(true, uint256(0)));
    }

    function testFuzzNonBooleanWordRollsBackVoteAndWithdrawal(uint256 word) public {
        word = bound(word, 2, type(uint256).max);
        _rejectMalformedDepositAndWithdrawal(abi.encode(word));
    }

    function testExcessDepositCreditRollsBackTokenAndLeaderChanges() public {
        token.setMovement(BoundaryProbeToken.Movement.ExcessCredit);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.UnexpectedTokenBalance.selector);
        contest.vote(0, 2, 10 ether);
        _assertOriginalDepositUnchanged();
        token.setMovement(BoundaryProbeToken.Movement.Exact);
        _vote(2, 10 ether);
        assertEq(contest.locked(0, ALICE), 15 ether);
        assertEq(contest.getVotes(0)[2], 10 ether);
    }

    function testWithdrawalRequiresCustodyToBeDebited() public {
        vm.warp(contest.startTime() + 7 days);
        token.setMovement(BoundaryProbeToken.Movement.SkipDebit);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.UnexpectedTokenBalance.selector);
        contest.withdraw(0);
        _assertOriginalDepositUnchanged();
        _withdrawSuccessfullyAfterRecovery();
    }

    function testWithdrawalRejectsExcessRecipientCredit() public {
        vm.warp(contest.startTime() + 7 days);
        token.setMovement(BoundaryProbeToken.Movement.ExcessCredit);
        vm.prank(ALICE);
        vm.expectRevert(FrogOfTheWeek.UnexpectedTokenBalance.selector);
        contest.withdraw(0);
        _assertOriginalDepositUnchanged();
        _withdrawSuccessfullyAfterRecovery();
    }
}
