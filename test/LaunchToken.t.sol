// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {FrogOfTheWeek} from "../src/FrogOfTheWeek.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new LaunchToken();
    }

    function testMetadataAndExactSupply() public view {
        assertEq(token.name(), "Frogs of the Swarm");
        assertEq(token.symbol(), "FROGS");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFactoryDeploymentKeepsWholeSupplyAtFactory() public {
        address factory = address(0xFAC);
        vm.prank(factory);
        LaunchToken factoryToken = new LaunchToken();
        vm.prank(factory);
        FrogOfTheWeek contest = new FrogOfTheWeek(address(factoryToken));
        assertEq(factoryToken.balanceOf(factory), 1e27);
        assertEq(factoryToken.totalSupply(), 1e27);
        assertEq(factoryToken.balanceOf(address(contest)), 0);
    }

    function testTransferEmitsAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), ALICE, 35 ether);
        assertTrue(token.transfer(ALICE, 35 ether));
        assertEq(token.balanceOf(ALICE), 35 ether);
        assertEq(token.balanceOf(address(this)), 1e27 - 35 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function testZeroAndSelfTransfersPreserveSupply() public {
        assertTrue(token.transfer(ALICE, 0));
        assertTrue(token.transfer(address(this), 1e27));
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function testInvalidTransferAndApprovalRejectZero() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function testInsufficientBalanceReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testFiniteAllowanceDecrementsAndCanBeReplaced() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), ALICE, 10 ether);
        assertTrue(token.approve(ALICE, 10 ether));
        vm.prank(ALICE);
        assertTrue(token.transferFrom(address(this), BOB, 4 ether));
        assertEq(token.allowance(address(this), ALICE), 6 ether);
        assertEq(token.balanceOf(BOB), 4 ether);
        token.approve(ALICE, 1 ether);
        assertEq(token.allowance(address(this), ALICE), 1 ether);
        token.approve(ALICE, 0);
        assertEq(token.allowance(address(this), ALICE), 0);
    }

    function testInfiniteAllowanceIsUnchanged() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(address(this), BOB, 2 ether);
        assertEq(token.allowance(address(this), ALICE), type(uint256).max);
    }

    function test_FailedTransferFromRollsBackAllowance() public {
        vm.prank(ALICE);
        token.approve(BOB, 10);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientBalance.selector, ALICE, 0, 10));
        token.transferFrom(ALICE, BOB, 10);
        assertEq(token.allowance(ALICE, BOB), 10);
    }

    function testInsufficientAllowanceReverts() public {
        token.approve(ALICE, 3);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.ERC20InsufficientAllowance.selector, ALICE, 3, 4));
        token.transferFrom(address(this), BOB, 4);
        assertEq(token.allowance(address(this), ALICE), 3);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testNoAdminMintUpgradeOrInitializer() public {
        string[11] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, type(uint128).max);
            (bool deployerOK,) = address(token).call(data);
            assertFalse(deployerOK);
            vm.prank(ALICE);
            (bool attackerOK,) = address(token).call(data);
            assertFalse(attackerOK);
            assertEq(token.totalSupply(), 1e27);
            assertEq(token.balanceOf(ALICE), 0);
        }
    }

    function testRuntimeBoundAndNoEscapeOpcodes() public view {
        bytes memory code = address(token).code;
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

    function testFuzzTransfersConserveSupply(uint256 rawAmount, uint256 rawReturn) public {
        uint256 amount = bound(rawAmount, 0, 1e27);
        uint256 returned = bound(rawReturn, 0, amount);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(address(this), returned);
        assertEq(token.balanceOf(ALICE), amount - returned);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(ALICE), token.totalSupply());
    }
}
