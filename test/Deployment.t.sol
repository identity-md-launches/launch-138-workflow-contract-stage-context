// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PVP} from "../src/PVP.sol";
import {PvPad} from "../src/PvPad.sol";
import {PvPadHook} from "../src/PvPadHook.sol";
import {PvPadFeeRouter} from "../src/PvPadFeeRouter.sol";
import {KingOfThePad} from "../src/KingOfThePad.sol";
import {WorkerSubsidy} from "../src/WorkerSubsidy.sol";
import {PvPadBurner} from "../src/PvPadBurner.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Opcodes} from "./utils/Opcodes.sol";

/// @dev Walks the documented deployment order (docs/deployment.md) step by step, from the factory
/// minting PVP to the pad opening the pool, and checks every link the reviewer will check.
contract DeploymentTest is Test {
    /// @dev The Sepolia PoolManager named in the manifest. Its code is placed here so the hook's
    /// creation code can carry the real constructor argument; only the constructor is exercised.
    address constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    address factory = makeAddr("factory");
    address deployer = makeAddr("deployer");
    address owner = makeAddr("owner");
    address updater = makeAddr("updater");

    function _mine(address create2Deployer, bytes memory creationCode) internal pure returns (bytes32 salt) {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), create2Deployer, bytes32(i), initCodeHash))
                    )
                )
            );
            if (HookFlags.matches(predicted, HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP)) {
                return bytes32(i);
            }
        }
        revert("no salt");
    }

    function test_fullWiringInDocumentedOrder() public {
        PoolManager manager = new PoolManager(address(this));

        // 1. The factory deploys PVP and holds the whole supply.
        vm.prank(factory);
        PVP pvp = new PVP();
        assertEq(pvp.balanceOf(factory), 1e27);
        assertEq(pvp.totalSupply(), 1e27);

        // 2. Supporting contracts, in dependency order.
        vm.startPrank(deployer);
        WorkerSubsidy subsidy = new WorkerSubsidy(owner, updater);
        KingOfThePad king = new KingOfThePad(payable(address(subsidy)), 0.01 ether, 1000);
        PvPadFeeRouter router = new PvPadFeeRouter(pvp, king);
        PvPad pad = new PvPad(manager, IERC20(address(pvp)), router, 100);
        vm.stopPrank();
        assertEq(pad.configurator(), deployer);

        // 3. The hook, from the PoolManager only, at a mined CREATE2 address.
        bytes memory creationCode =
            abi.encodePacked(type(PvPadHook).creationCode, abi.encode(address(manager)));
        bytes32 salt = _mine(address(this), creationCode);
        address hookAddress;
        assembly ("memory-safe") {
            hookAddress := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        PvPadHook hook = PvPadHook(hookAddress);
        assertEq(HookFlags.flagsOf(hookAddress), 0x2080);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.pad(), address(0));
        Opcodes.assertNoEscapeHatch(hookAddress.code);

        // Before the bind, nothing can drive the hook: not even the manager for a pad-shaped call.
        PoolKey memory unboundKey = pad.poolKey();
        vm.prank(address(manager));
        vm.expectRevert(PvPadHook.NotBound.selector);
        hook.beforeSwap(address(pad), unboundKey, SwapParams(true, -1, SQRT_PRICE_1_1), "");

        // 4. The pad's configurator binds and opens the pool in one transaction.
        vm.prank(deployer);
        pad.initialize(hook, SQRT_PRICE_1_1);
        assertEq(hook.pad(), address(pad));
        assertEq(hook.token(), address(pvp));
        assertEq(address(pad.hook()), hookAddress);
        PoolKey memory k = pad.poolKey();
        assertEq(address(k.hooks), hookAddress);
        assertEq(abi.encode(k), abi.encode(hook.poolKey()), "pad and hook agree on the canonical key");

        // 5. Optional burner, owned by an operator.
        PvPadBurner burner = new PvPadBurner(pad, owner);
        assertEq(address(burner.feeRouter()), address(router));

        // Every link the reviewer checks.
        assertEq(king.workerSubsidy(), address(subsidy));
        assertEq(address(router.king()), address(king));
        assertEq(address(router.token()), address(pvp));
        assertEq(address(pad.feeRouter()), address(router));
        assertEq(address(pad.token()), address(pvp));
        assertEq(subsidy.updater(), updater);
        assertEq(subsidy.owner(), owner);
    }

    function test_hookCreationCodeForSepoliaManagerDeploys() public {
        // Give the manifest's manager address code, as the admission floor does, and deploy the exact
        // creation code the manifest describes: initcode + one address word.
        PoolManager local = new PoolManager(address(this));
        vm.etch(SEPOLIA_POOL_MANAGER, address(local).code);
        bytes memory creationCode =
            abi.encodePacked(type(PvPadHook).creationCode, abi.encode(SEPOLIA_POOL_MANAGER));
        bytes32 salt = _mine(address(this), creationCode);
        address hookAddress;
        assembly ("memory-safe") {
            hookAddress := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        assertTrue(hookAddress != address(0), "deployment reverted");
        assertEq(address(PvPadHook(hookAddress).poolManager()), SEPOLIA_POOL_MANAGER);
        assertEq(HookFlags.flagsOf(hookAddress), 0x2080);
        // The callbacks refuse this test as a caller, as the floor requires.
        (bool ok,) = hookAddress.call(
            abi.encodeCall(
                IHooks.beforeInitialize, (address(this), PvPadHook(hookAddress).poolKey(), SQRT_PRICE_1_1)
            )
        );
        assertFalse(ok);
    }

    function test_tokenCreationCodeMintsToItsDeployer() public {
        bytes memory creationCode = type(PVP).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        assertEq(PVP(deployed).balanceOf(address(this)), 1e27);
        assertEq(PVP(deployed).decimals(), 18);
        assertEq(PVP(deployed).name(), "Pepe Values Pepe");
        assertEq(PVP(deployed).symbol(), "PVP");
        Opcodes.assertNoEscapeHatch(deployed.code);
    }
}
