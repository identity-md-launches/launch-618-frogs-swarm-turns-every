// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FrogOfTheWeek} from "../src/FrogOfTheWeek.sol";

contract LeaderReferenceTest is Test {
    function testFuzz_IndependentLeaderModel(uint256 seed) public {
        LaunchToken token = new LaunchToken();
        FrogOfTheWeek app = new FrogOfTheWeek(address(token));
        address[4] memory voters = [address(0x100), address(0x101), address(0x102), address(0x103)];
        for (uint256 i; i < 4; i++) {
            token.transfer(voters[i], 1_000_000 ether);
            vm.prank(voters[i]);
            token.approve(address(app), type(uint256).max);
        }

        uint256[2000] memory model;
        uint256[4] memory locked;
        uint256 total;
        for (uint256 i; i < 60; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 agent = (seed & 0xFFFF) % 2000;
            // Ensure repeated incremental ties among a small subgroup as well.
            if (i % 2 == 0) agent %= 8;
            uint256 person = (seed >> 32) % 4;
            uint256 amount = ((seed >> 64) % 20 + 1) * 1 ether;
            vm.prank(voters[person]);
            app.vote(0, agent, amount);
            model[agent] += amount;
            locked[person] += amount;
            total += amount;
        }

        uint256 leader = 2000;
        uint256 leadingVotes;
        uint256[2000] memory actual = app.getVotes(0);
        for (uint256 i; i < 2000; i++) {
            assertEq(actual[i], model[i]);
            if (model[i] > leadingVotes) {
                leader = i;
                leadingVotes = model[i];
            }
        }
        _assertSummary(app, total, leader, leadingVotes, false);
        assertEq(token.balanceOf(address(app)), total);
        assertEq(app.totalLocked(), total);

        vm.warp(app.startTime() + 7 days);
        for (uint256 i; i < 4; i++) {
            assertEq(app.locked(0, voters[i]), locked[i]);
            if (locked[i] != 0) {
                vm.prank(voters[i]);
                app.withdraw(0);
            }
            assertEq(token.balanceOf(voters[i]), 1_000_000 ether);
        }
        app.finalize();
        _assertSummary(app, total, leader, leadingVotes, true);
        assertEq(app.totalLocked(), 0);
        assertEq(token.balanceOf(address(app)), 0);
    }

    function _assertSummary(FrogOfTheWeek app, uint256 total, uint256 leader, uint256 leadingVotes, bool expectedDone)
        private
        view
    {
        (uint256 actualTotal, uint256 actualLeader, uint256 actualLeadingVotes, bool done, uint256 winner) =
            app.weekInfo(0);
        assertEq(actualTotal, total);
        assertEq(actualLeader, leader);
        assertEq(actualLeadingVotes, leadingVotes);
        assertEq(done, expectedDone);
        assertEq(winner, expectedDone ? leader : 2000);
    }

    function test_AllAgentNumbersAtEqualWeightCrownZeroRegardlessOfDescendingOrder() public {
        LaunchToken token = new LaunchToken();
        FrogOfTheWeek app = new FrogOfTheWeek(address(token));
        token.approve(address(app), type(uint256).max);
        for (uint256 i = 2000; i > 0; i--) {
            app.vote(0, i - 1, 1 ether);
        }
        vm.warp(app.startTime() + 7 days);
        app.finalize();
        (uint256 total, uint256 leader, uint256 leading, bool finalized, uint256 winner) = app.weekInfo(0);
        assertEq(total, 2000 ether);
        assertEq(leader, 0);
        assertEq(leading, 1 ether);
        assertTrue(finalized);
        assertEq(winner, 0);
        app.withdraw(0);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }
}
