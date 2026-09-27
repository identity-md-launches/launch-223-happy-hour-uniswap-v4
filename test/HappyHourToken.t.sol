// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/IERC6093.sol";
import {HappyHourToken} from "../src/HappyHourToken.sol";

contract HappyHourTokenTest is Test {
    HappyHourToken token;
    address factory = makeAddr("factory");
    address alice = makeAddr("alice");

    function setUp() public {
        vm.prank(factory);
        token = new HappyHourToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Happy Hour");
        assertEq(token.symbol(), "HAPPY");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.TOTAL_SUPPLY(), 1e27);
        assertEq(token.balanceOf(factory), 1e27);
    }

    function test_noMintOrAdminSurface() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)",
            "setFee(uint256)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(factory);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferMovesExactAmount() public {
        vm.prank(factory);
        assertTrue(token.transfer(alice, 5 ether));
        assertEq(token.balanceOf(alice), 5 ether);
        assertEq(token.balanceOf(factory), 1e27 - 5 ether);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFrom_respectsAllowance() public {
        vm.prank(factory);
        token.approve(alice, 3 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(factory, alice, 3 ether));
        assertEq(token.balanceOf(alice), 3 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(factory, alice, 1);
    }

    function test_transfer_insufficientBalanceReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(factory, 1);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != factory);
        amount = bound(amount, 0, 1e27);
        vm.prank(factory);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(factory) + token.balanceOf(to), 1e27);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
