// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SwarmCoreToken} from "../src/SwarmCoreToken.sol";

/// @notice Reviewable deployment of SwarmCore (CORE) for a manual, non-factory deployment.
/// @dev The launch itself deploys the token from its creation code through the launch factory,
/// which becomes the deployer and so receives the whole supply. The token takes no constructor
/// arguments, so this script reads no configuration and no environment.
contract DeploySwarmCore is Script {
    function run() external returns (SwarmCoreToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }

    /// @notice Deploys the token. The caller of this function becomes the holder of the supply.
    function deploy() public returns (SwarmCoreToken) {
        return new SwarmCoreToken();
    }
}
