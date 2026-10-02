// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FrogOfTheWeek} from "../src/FrogOfTheWeek.sol";

/// @dev Stateful model of deposits, withdrawals, donations, elapsed weeks and finalization.
contract FrogHandler is Test {
    LaunchToken public immutable token;
    FrogOfTheWeek public immutable contest;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
    mapping(uint256 => mapping(address => uint256)) public owed;
    mapping(uint256 => mapping(uint256 => uint256)) public historicVotes;
    mapping(uint256 => uint256) public historicTotal;
    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public donations;

    constructor(LaunchToken token_, FrogOfTheWeek contest_) {
        token = token_;
        contest = contest_;
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            token.approve(address(contest), type(uint256).max);
        }
    }

    function vote(uint256 rawActor, uint256 rawAgent, uint256 rawAmount) external {
        address voter = actors[rawActor % actors.length];
        uint256 available = token.balanceOf(voter);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        // All IDs are exercised in the separate winner fuzz test; this model has three independent candidates.
        uint256 agentId = rawAgent % 3 == 0 ? 1999 : rawAgent % 3 - 1;
        uint256 week = contest.currentWeek();
        vm.prank(voter);
        contest.vote(week, agentId, amount);
        owed[week][voter] += amount;
        historicVotes[week][agentId] += amount;
        historicTotal[week] += amount;
        deposits += amount;
    }

    function withdraw(uint256 rawActor, uint256 rawWeek) external {
        uint256 current = contest.currentWeek();
        if (current == 0) return;
        uint256 week = rawWeek % current;
        address voter = actors[rawActor % actors.length];
        uint256 amount = owed[week][voter];
        if (amount == 0) return;
        vm.prank(voter);
        contest.withdraw(week);
        owed[week][voter] = 0;
        withdrawals += amount;
    }

    function advance(uint256 rawSeconds) external {
        // At most 64 weeks at depth 64, making exhaustive model assertions bounded.
        vm.warp(block.timestamp + bound(rawSeconds, 1, 7 days));
    }

    function finalize() external {
        if (contest.nextWeekToFinalize() < contest.currentWeek()) contest.finalize();
    }

    function donate(uint256 rawActor, uint256 rawAmount) external {
        address donor = actors[rawActor % actors.length];
        uint256 available = token.balanceOf(donor);
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        vm.prank(donor);
        token.transfer(address(contest), amount);
        donations += amount;
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
}

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
            token.transfer(handler.actors(i), 1000 ether);
        }
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = FrogHandler.vote.selector;
        selectors[1] = FrogHandler.withdraw.selector;
        selectors[2] = FrogHandler.advance.selector;
        selectors[3] = FrogHandler.finalize.selector;
        selectors[4] = FrogHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariantCustodyEqualsAllOutstandingDepositsPlusDonations() public view {
        uint256 liability;
        for (uint256 week; week <= contest.currentWeek(); ++week) {
            for (uint256 i; i < 3; ++i) {
                address voter = handler.actors(i);
                uint256 expected = handler.owed(week, voter);
                assertEq(contest.locked(week, voter), expected);
                liability += expected;
            }
        }
        assertEq(contest.totalLocked(), liability);
        assertEq(handler.deposits() - handler.withdrawals(), liability);
        assertEq(token.balanceOf(address(contest)), liability + handler.donations());
        assertEq(token.totalSupply(), 1e27);
    }

    function invariantHistoricalTotalsAndWinnersMatchIndependentModel() public view {
        uint256 cursor = contest.nextWeekToFinalize();
        assertLe(cursor, contest.currentWeek());
        for (uint256 week; week <= contest.currentWeek(); ++week) {
            (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = contest.weekInfo(week);
            (uint256 expectedLeader, uint256 expectedLeading) = handler.expectedLeader(week);
            assertEq(total, handler.historicTotal(week));
            assertEq(leader, expectedLeader);
            assertEq(leading, expectedLeading);
            assertEq(finalized, week < cursor);
            assertEq(winner, finalized ? expectedLeader : 2000);
        }
    }
}
