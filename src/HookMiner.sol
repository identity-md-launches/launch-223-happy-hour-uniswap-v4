// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "./HookFlags.sol";

/// @title Hook address miner
/// @notice Finds a CREATE2 salt that lands a hook on an address carrying exactly the declared permission bits.
/// Pure and internal: used by the deploy script and the tests, never deployed.
library HookMiner {
    /// @notice Upper bound on salts tried before giving up. With 14 bits to match the expected number of
    /// attempts is 16384, so this bound is roughly ten times the mean.
    uint256 internal constant MAX_LOOP = 160_444;

    error NoSaltFound(uint160 flags);

    /// @param deployer The address that will execute CREATE2 (the CREATE2 proxy under `forge script`, or the
    /// calling contract for a direct CREATE2).
    /// @param flags The permission bits the address must carry.
    /// @param creationCode The hook's creation code, without constructor arguments.
    /// @param constructorArgs ABI-encoded constructor arguments.
    /// @return hookAddress The address the salt produces.
    /// @return salt The salt to deploy with.
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i = 0; i < MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hookAddress, flags)) return (hookAddress, salt);
        }
        revert NoSaltFound(flags);
    }

    /// @notice The CREATE2 address for `deployer`, `salt` and `initCodeHash`.
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
