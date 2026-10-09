// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Uniswap v4 encodes a hook's permissions in the low 14 bits of its address. These helpers
/// check that an address carries exactly the requested permissions and no others.
/// @dev Launch-harness support, not a launch contract: nothing here is deployed with the token.
library HookFlags {
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant BEFORE_INITIALIZE = uint160(1 << 13);

    /// @notice True when `hook`'s permission bits are exactly `flags`.
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return uint160(hook) & ALL_HOOK_MASK == flags;
    }
}
