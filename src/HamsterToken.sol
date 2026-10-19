// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice HAMSTER: a fixed supply ERC-20. The constructor caller receives the entire supply.
/// @dev No owner, external mint, burn, transfer fee, pause, blacklist, or upgrade mechanism.
contract HamsterToken is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("HAMSTER", "HAMSTER") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
