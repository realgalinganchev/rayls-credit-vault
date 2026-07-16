// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDeploymentProxyRegistryV1} from "rayls-protocol-sdk/interfaces/IDeploymentProxyRegistryV1.sol";

/// @notice Minimal interface to read the public token address mapping.
interface IRNTokenGovernanceReader {
    function getPublicAddressByPrivateAddress(address privateAddress) external view returns (address);
}

/// @title CheckBalance
/// @notice Checks your token balance on the public chain.
///         First queries the Privacy Node for the mirror contract address,
///         then switches to the public chain to read the balance.
///
/// Usage:
///   source .env
///   forge script script/CheckBalance.s.sol --rpc-url $PRIVACY_NODE_RPC_URL
contract CheckBalance is Script {
    function run() external {
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address registryAddr = vm.envAddress("DEPLOYMENT_PROXY_REGISTRY");
        address checkAddress = vm.envAddress("TRANSFER_TO");
        string memory publicRpc = vm.envString("PUBLIC_CHAIN_RPC_URL");

        // Step 1: Query Privacy Node for the mirror contract address
        IDeploymentProxyRegistryV1 registry = IDeploymentProxyRegistryV1(registryAddr);
        address tokenGovAddr = registry.getContract("RNTokenGovernance");

        address publicTokenAddr = IRNTokenGovernanceReader(tokenGovAddr)
            .getPublicAddressByPrivateAddress(tokenAddr);

        require(publicTokenAddr != address(0), "Mirror not deployed yet. Wait 30-60s after token approval.");

        // Step 2: Switch to public chain and read balance
        vm.createSelectFork(publicRpc);

        uint256 balance = IERC20(publicTokenAddr).balanceOf(checkAddress);

        console.log("=== Public Chain Balance ===");
        console.log("  Private token: ", tokenAddr);
        console.log("  Public mirror: ", publicTokenAddr);
        console.log("  Address:       ", checkAddress);
        console.log("  Balance (wei): ", balance);
        console.log("  Balance:       ", balance / 1e18);
    }
}
