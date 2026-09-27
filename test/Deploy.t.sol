// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployTest is Test {
    Deploy script;
    PoolManager manager;

    function setUp() public {
        script = new Deploy();
        manager = new PoolManager(address(this));
    }

    function test_deploy_landsOnFlaggedAddress() public {
        Deploy.Config memory config =
            Deploy.Config({chainId: 31_337, poolManager: manager, create2Deployer: address(script)});
        HappyHourHook hook = script.deploy(config);
        assertEq(HookFlags.flagsOf(address(hook)), HookFlags.HAPPY_HOUR);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(hook.currentFeeBps() + (hook.isHappyHour() ? 100 : 0), 100);
    }

    function test_deploy_revertsWhenDeployerAssumptionIsWrong() public {
        // Mined for the CREATE2 proxy but executed from the script contract: the address disagrees, and the
        // constructor's own permission check rejects it before the script's address check can.
        Deploy.Config memory config =
            Deploy.Config({chainId: 31_337, poolManager: manager, create2Deployer: script.CREATE2_DEPLOYER()});
        vm.expectRevert();
        script.deploy(config);
    }

    function test_configure_sepolia() public {
        Deploy.Config memory config = script.configure(11_155_111, 11_155_111);
        assertEq(address(config.poolManager), script.SEPOLIA_POOL_MANAGER());
        assertEq(config.create2Deployer, script.CREATE2_DEPLOYER());
        assertEq(config.chainId, 11_155_111);
    }

    function test_configure_localDeploysScaffoldManager() public {
        Deploy.Config memory config = script.configure(0, 31_337);
        assertTrue(address(config.poolManager).code.length > 0, "local manager exists");
        assertEq(config.chainId, 31_337);
    }

    function test_configure_zeroSkipsAssertion() public {
        Deploy.Config memory config = script.configure(0, 11_155_111);
        assertEq(address(config.poolManager), script.SEPOLIA_POOL_MANAGER());
    }

    function test_configure_rejectsMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainMismatch.selector, 11_155_111, 31_337));
        script.configure(11_155_111, 31_337);
    }

    function test_configure_rejectsUnsupportedChain() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        script.configure(1, 1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 8453));
        script.configure(0, 8453);
    }
}
