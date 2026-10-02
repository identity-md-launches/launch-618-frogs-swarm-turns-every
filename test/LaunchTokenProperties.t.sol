// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev Delegated transfers must preserve balances and isolate each owner's approvals.
/// forge-config: default.fuzz.runs = 1000
contract LaunchTokenPropertiesTest is Test {
    uint256 private constant SUPPLY = 1e27;
    address private constant HOLDER = address(0xA11CE);
    address private constant SPENDER = address(0x5EED);
    address private constant RECIPIENT = address(0xB0B);
    address private constant OUTSIDER = address(0xCA401);
    LaunchToken private token;

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        token = new LaunchToken();
        token.transfer(HOLDER, SUPPLY);
    }

    function testFullSupplyDelegatedTransferExhaustsApproval() public {
        vm.prank(HOLDER);
        token.approve(SPENDER, SUPPLY);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(HOLDER, RECIPIENT, SUPPLY);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(HOLDER, RECIPIENT, SUPPLY));

        assertEq(token.balanceOf(HOLDER), 0);
        assertEq(token.balanceOf(RECIPIENT), SUPPLY);
        assertEq(token.allowance(HOLDER, SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);

        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, RECIPIENT, 1);
        assertEq(token.balanceOf(RECIPIENT), SUPPLY);
    }

    function testZeroDelegatedTransferWithoutApprovalEmitsAndDoesNotMoveFunds() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(HOLDER, RECIPIENT, 0);
        vm.prank(OUTSIDER);
        assertTrue(token.transferFrom(HOLDER, RECIPIENT, 0));

        assertEq(token.balanceOf(HOLDER), SUPPLY);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.allowance(HOLDER, OUTSIDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testInfiniteApprovalCanBeRevokedAfterSpending() public {
        vm.prank(HOLDER);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, RECIPIENT, 1);

        vm.prank(HOLDER);
        token.approve(SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, RECIPIENT, 1);

        assertEq(token.allowance(HOLDER, SPENDER), 0);
        assertEq(token.balanceOf(HOLDER), SUPPLY - 1);
        assertEq(token.balanceOf(RECIPIENT), 1);
    }

    function testMaximumTransferCannotOverflowBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, HOLDER, SUPPLY, type(uint256).max)
        );
        vm.prank(HOLDER);
        token.transfer(RECIPIENT, type(uint256).max);

        vm.prank(HOLDER);
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, HOLDER, SUPPLY, type(uint256).max)
        );
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, RECIPIENT, type(uint256).max);

        assertEq(token.balanceOf(HOLDER), SUPPLY);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.allowance(HOLDER, SPENDER), type(uint256).max);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzDelegatedSelfTransferPreservesBalanceAndConsumesFiniteApproval(
        uint256 rawAmount,
        uint256 rawAllowance
    ) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 approved = bound(rawAllowance, amount, type(uint256).max - 1);
        vm.prank(HOLDER);
        token.approve(SPENDER, approved);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(HOLDER, HOLDER, amount);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(HOLDER, HOLDER, amount));

        assertEq(token.balanceOf(HOLDER), SUPPLY);
        assertEq(token.balanceOf(SPENDER), 0);
        assertEq(token.allowance(HOLDER, SPENDER), approved - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzSplitDelegatedSpendingMatchesSingleTransfer(uint256 rawAmount, uint256 rawFirst) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 first = bound(rawFirst, 0, amount);
        LaunchToken singleTransferToken = new LaunchToken();
        singleTransferToken.transfer(HOLDER, SUPPLY);
        vm.startPrank(HOLDER);
        token.approve(SPENDER, amount);
        singleTransferToken.approve(SPENDER, amount);
        vm.stopPrank();

        vm.startPrank(SPENDER);
        assertTrue(token.transferFrom(HOLDER, RECIPIENT, first));
        assertTrue(token.transferFrom(HOLDER, RECIPIENT, amount - first));
        assertTrue(singleTransferToken.transferFrom(HOLDER, RECIPIENT, amount));
        vm.stopPrank();

        assertEq(token.balanceOf(HOLDER), singleTransferToken.balanceOf(HOLDER));
        assertEq(token.balanceOf(RECIPIENT), singleTransferToken.balanceOf(RECIPIENT));
        assertEq(token.balanceOf(RECIPIENT), amount);
        assertEq(token.balanceOf(HOLDER) + token.balanceOf(RECIPIENT), SUPPLY);
        assertEq(token.allowance(HOLDER, SPENDER), 0);
        assertEq(singleTransferToken.allowance(HOLDER, SPENDER), 0);
    }

    function testFuzzApprovalDoesNotAuthorizeAnotherCaller(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, SUPPLY);
        vm.prank(HOLDER);
        token.approve(SPENDER, amount);

        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, OUTSIDER, 0, amount));
        vm.prank(OUTSIDER);
        token.transferFrom(HOLDER, RECIPIENT, amount);

        assertEq(token.allowance(HOLDER, SPENDER), amount);
        assertEq(token.allowance(HOLDER, OUTSIDER), 0);
        assertEq(token.balanceOf(HOLDER), SUPPLY);
        assertEq(token.balanceOf(RECIPIENT), 0);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(HOLDER, RECIPIENT, amount));
        assertEq(token.balanceOf(RECIPIENT), amount);
    }

    function testFuzzApprovalDoesNotAuthorizeAnotherOwner(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, SUPPLY / 2);
        vm.startPrank(HOLDER);
        token.transfer(OUTSIDER, amount);
        token.approve(SPENDER, amount);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, SPENDER, 0, amount));
        vm.prank(SPENDER);
        token.transferFrom(OUTSIDER, RECIPIENT, amount);

        assertEq(token.allowance(HOLDER, SPENDER), amount);
        assertEq(token.allowance(OUTSIDER, SPENDER), 0);
        assertEq(token.balanceOf(OUTSIDER), amount);
        assertEq(token.balanceOf(HOLDER), SUPPLY - amount);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function testFuzzInvalidRecipientRollsBackAllowance(uint256 rawAmount, uint256 rawAllowance) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        uint256 approved = bound(rawAllowance, amount, type(uint256).max);
        vm.prank(HOLDER);
        token.approve(SPENDER, approved);

        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, address(0), amount);

        assertEq(token.allowance(HOLDER, SPENDER), approved);
        assertEq(token.balanceOf(HOLDER), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzOverspendingPartialBalanceRollsBackAllowance(uint256 rawBalance, uint256 rawExcess) public {
        uint256 remaining = bound(rawBalance, 1, SUPPLY - 1);
        uint256 amount = remaining + bound(rawExcess, 1, SUPPLY - remaining);
        vm.startPrank(HOLDER);
        token.transfer(OUTSIDER, SUPPLY - remaining);
        token.approve(SPENDER, amount);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, HOLDER, remaining, amount)
        );
        vm.prank(SPENDER);
        token.transferFrom(HOLDER, RECIPIENT, amount);

        assertEq(token.allowance(HOLDER, SPENDER), amount);
        assertEq(token.balanceOf(HOLDER), remaining);
        assertEq(token.balanceOf(OUTSIDER), SUPPLY - remaining);
        assertEq(token.balanceOf(RECIPIENT), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
