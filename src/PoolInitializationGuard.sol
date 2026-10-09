// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

/// @notice A Uniswap v4 hook with only the beforeInitialize permission. It lets the address that
/// deployed it (the launch factory) open pools that name it, and refuses everyone else, so nobody
/// can open the launch pool first at a price of their choosing.
/// @dev Launch-harness support, not a launch contract: the factory supplies the real one.
contract PoolInitializationGuard {
    error NotPoolManager();
    error NotLauncher(address sender);

    address public immutable poolManager;
    address public immutable launcher;

    constructor(address poolManager_) {
        poolManager = poolManager_;
        launcher = msg.sender;
    }

    function beforeInitialize(address sender, PoolKey calldata, uint160) external view returns (bytes4) {
        if (msg.sender != poolManager) revert NotPoolManager();
        if (sender != launcher) revert NotLauncher(sender);
        return IHooks.beforeInitialize.selector;
    }
}
