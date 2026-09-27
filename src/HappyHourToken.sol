// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Happy Hour token (HAPPY)
/// @notice Plain ERC-20. The whole supply is minted once, in the constructor, to the deployer (the launch
/// factory). There is no owner, no mint path, no pause, no proxy, and no transfer hook or fee.
contract HappyHourToken is ERC20 {
    /// @notice The only supply that will ever exist: 10^27 minor units (one billion tokens at 18 decimals).
    uint256 public constant TOTAL_SUPPLY = 1e27;

    constructor() ERC20("Happy Hour", "HAPPY") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
