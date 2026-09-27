// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {HappyHourHook} from "../src/HappyHourHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title Happy Hour hook deployment
/// @notice Deploys `HappyHourHook` at a CREATE2 address carrying exactly its permission bits (0xCC).
///
/// The script reads one environment variable, `EXPECTED_CHAIN_ID`, and no keys:
///  - `11155111` (Sepolia): the canonical Uniswap v4 PoolManager on Sepolia is used.
///  - `31337` (local anvil / offline simulation): a fresh PoolManager is created as simulation scaffolding
///    before the broadcast section, so the only broadcast transaction is the hook deployment.
///  - `0`: skip the chain assertion and configure for whatever chain the script is simulated on.
/// Any other value, or a value that disagrees with `block.chainid`, reverts before anything is deployed.
///
/// The token (`HappyHourToken`) is not deployed here: its constructor mints the whole supply to `msg.sender`,
/// and that sender must be the launch factory.
contract Deploy is Script {
    struct Config {
        uint256 chainId;
        IPoolManager poolManager;
        /// @dev The address that executes CREATE2. Under `forge script` broadcast this is the canonical
        /// CREATE2 proxy; a test that calls `deploy` directly passes the script contract's own address.
        address create2Deployer;
    }

    /// @notice Uniswap v4 PoolManager on Sepolia.
    address public constant SEPOLIA_POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    /// @notice The deterministic CREATE2 proxy `forge script` routes salted deployments through.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    uint256 public constant SEPOLIA = 11_155_111;
    uint256 public constant ANVIL = 31_337;

    error ChainMismatch(uint256 expected, uint256 actual);
    error UnsupportedChain(uint256 chainId);
    error AddressMismatch(address predicted, address deployed);

    /// @notice Entry point for the operator. Reads `EXPECTED_CHAIN_ID` and deploys the hook.
    function run() external returns (HappyHourHook hook) {
        uint256 expected = vm.envUint("EXPECTED_CHAIN_ID");
        Config memory config = configure(expected, block.chainid);

        vm.startBroadcast();
        hook = deploy(config);
        vm.stopBroadcast();
    }

    /// @notice Turn the operator's expectation and the live chain id into a deployment config.
    function configure(uint256 expectedChainId, uint256 actualChainId) public returns (Config memory) {
        if (expectedChainId != 0 && expectedChainId != actualChainId) {
            revert ChainMismatch(expectedChainId, actualChainId);
        }
        if (actualChainId == SEPOLIA) {
            return Config({
                chainId: actualChainId,
                poolManager: IPoolManager(SEPOLIA_POOL_MANAGER),
                create2Deployer: CREATE2_DEPLOYER
            });
        }
        if (actualChainId == ANVIL) {
            // Simulation scaffolding only: a local chain has no canonical PoolManager.
            PoolManager local = new PoolManager(address(0));
            return Config({chainId: actualChainId, poolManager: local, create2Deployer: CREATE2_DEPLOYER});
        }
        revert UnsupportedChain(actualChainId);
    }

    /// @notice Mine a salt for the declared flags and deploy the hook with it. Reverts if the deployed
    /// address is not the one mined for, which is what happens when `config.create2Deployer` is wrong.
    function deploy(Config memory config) public returns (HappyHourHook hook) {
        (address predicted, bytes32 salt) = HookMiner.find(
            config.create2Deployer,
            HookFlags.HAPPY_HOUR,
            type(HappyHourHook).creationCode,
            abi.encode(config.poolManager)
        );
        hook = new HappyHourHook{salt: salt}(config.poolManager);
        if (address(hook) != predicted) revert AddressMismatch(predicted, address(hook));
    }
}
