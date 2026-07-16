// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HackathonToken} from "../src/HackathonToken.sol";
import {IDeploymentProxyRegistryV1} from "rayls-protocol-sdk/interfaces/IDeploymentProxyRegistryV1.sol";

/// @title Deploy
/// @notice Deploys HackathonToken to the Privacy Node.
///         Infrastructure addresses are discovered from the on-chain DeploymentProxyRegistry.
///
/// Usage:
///   source .env
///   forge script script/Deploy.s.sol --rpc-url $PRIVACY_NODE_RPC_URL --broadcast --legacy
contract Deploy is Script {
    function run() external {
        // Read configuration
        address registryAddr = vm.envAddress("DEPLOYMENT_PROXY_REGISTRY");
        string memory tokenName = vm.envString("TOKEN_NAME");
        string memory tokenSymbol = vm.envString("TOKEN_SYMBOL");
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Discover infrastructure addresses from on-chain registry
        IDeploymentProxyRegistryV1 registry = IDeploymentProxyRegistryV1(registryAddr);

        address endpoint = registry.getContract("Endpoint");
        address rnEndpoint = registry.getContract("RNEndpoint");
        address userGovernance = registry.getContract("RNUserGovernance");

        require(endpoint != address(0), "Endpoint not found in registry");
        require(rnEndpoint != address(0), "RNEndpoint not found in registry");
        require(userGovernance != address(0), "RNUserGovernance not found in registry");

        console.log("=== Infrastructure Addresses ===");
        console.log("  Endpoint:        ", endpoint);
        console.log("  RNEndpoint:      ", rnEndpoint);
        console.log("  RNUserGovernance:", userGovernance);

        // Deploy
        vm.startBroadcast(deployerKey);

        HackathonToken token = new HackathonToken(
            tokenName,
            tokenSymbol,
            endpoint,
            rnEndpoint,
            userGovernance
        );

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployed ===");
        console.log("  HackathonToken:", address(token));
        console.log("");
        console.log("Next step: Set TOKEN_ADDRESS=%s in your .env", vm.toString(address(token)));
    }
}
