// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title SwarmCore (CORE)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 CORE (18 decimals) is minted
/// once, in the constructor, to the deployer. There is no owner, no further mint, no pause, no
/// blacklist, no transfer fee and no burn: transfers move exactly the amount requested.
contract SwarmCoreToken is ERC20 {
    string public constant TOKEN_NAME = "SwarmCore";
    string public constant TOKEN_SYMBOL = "CORE";

    /// @notice The whole supply, in minor units: 1,000,000,000 * 10**18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
