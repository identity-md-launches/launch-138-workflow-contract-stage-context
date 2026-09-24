// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PVP} from "../src/PVP.sol";
import {Opcodes} from "./utils/Opcodes.sol";

contract PVPTest is Test {
    PVP token;
    address factory = makeAddr("factory");

    function setUp() public {
        vm.prank(factory);
        token = new PVP();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Pepe Values Pepe");
        assertEq(token.symbol(), "PVP");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyTenToTheTwentySevenToDeployer() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** 18);
        assertEq(token.INITIAL_SUPPLY(), 1e27);
        assertEq(token.balanceOf(factory), 1e27, "factory must receive the whole supply");
    }

    function test_hasNoMintPath() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setMinter(address)",
            "transferOwnership(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], factory, uint256(1));
            vm.prank(factory);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), 1e27, signatures[i]);
        }
    }

    function test_transferMovesExactly() public {
        vm.prank(factory);
        assertTrue(token.transfer(address(0xCAFE), 1e21));
        assertEq(token.balanceOf(address(0xCAFE)), 1e21);
        assertEq(token.balanceOf(factory), 1e27 - 1e21);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_burnOnlyReducesSupply() public {
        vm.prank(factory);
        token.burn(5e18);
        assertEq(token.totalSupply(), 1e27 - 5e18);
        assertEq(token.balanceOf(factory), 1e27 - 5e18);
    }

    function test_burnFromRequiresAllowance() public {
        vm.prank(factory);
        token.approve(address(this), 1e18);
        token.burnFrom(factory, 1e18);
        assertEq(token.totalSupply(), 1e27 - 1e18);
        vm.expectRevert();
        token.burnFrom(factory, 1);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        Opcodes.assertNoEscapeHatch(address(token).code);
    }

    function test_creationCodeTakesNoArguments() public {
        bytes memory creationCode = type(PVP).creationCode;
        address deployed;
        assembly {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        assertTrue(deployed != address(0));
        assertEq(PVP(deployed).balanceOf(address(this)), 1e27);
    }
}
