// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Hook permission flags
/// @notice The 14 permission bits Uniswap v4 reads from the low bits of a hook's address, plus helpers to
/// compare an address against a declared flag set. Mirrors `Hooks.sol` in v4-core; kept separate so tooling
/// (the launch manifest, the admission floor, the deploy script) can name the bits without importing the
/// whole library.
library HookFlags {
    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice Mask of every permission bit.
    uint160 internal constant ALL = (1 << 14) - 1;

    /// @notice The flag set the Happy Hour hook declares and must be deployed under: 0xCC.
    uint160 internal constant HAPPY_HOUR = BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURN_DELTA
        | AFTER_SWAP_RETURN_DELTA;

    /// @notice The permission bits an address carries.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice True when `hook` carries exactly the permission bits in `flags` (bits outside the mask ignored).
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}
