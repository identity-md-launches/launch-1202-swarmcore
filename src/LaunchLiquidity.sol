// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// @notice Seeds a Uniswap v4 pool from inside an unlock callback and settles the caller's deltas,
/// the way the launch factory seeds a launch pool.
/// @dev Launch-harness support, not a launch contract. Every function is internal, so nothing is
/// linked.
library LaunchLiquidity {
    error TransferFailed();

    struct Seed {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @notice Adds the encoded `Seed` as liquidity and pays for it from this contract's balance.
    function settleSeed(IPoolManager manager, bytes memory data) internal {
        Seed memory seed = abi.decode(data, (Seed));
        (BalanceDelta delta,) = manager.modifyLiquidity(
            seed.key,
            ModifyLiquidityParams({
                tickLower: seed.tickLower,
                tickUpper: seed.tickUpper,
                liquidityDelta: int256(uint256(seed.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        settle(manager, seed.key.currency0, delta.amount0());
        settle(manager, seed.key.currency1, delta.amount1());
    }

    /// @notice Clears one currency delta: pays the manager what is owed (negative) or takes what is
    /// due (positive) to this contract.
    function settle(IPoolManager manager, Currency currency, int128 amount) internal {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                if (!IERC20Transfer(Currency.unwrap(currency)).transfer(address(manager), owed)) {
                    revert TransferFailed();
                }
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }
}
