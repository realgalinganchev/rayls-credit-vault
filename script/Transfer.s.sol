// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HackathonToken} from "../src/HackathonToken.sol";

/// @title Transfer
/// @notice Transfers tokens from the Privacy Node to the public chain via teleportToPublicChain().
///
///         IMPORTANT: This script must be signed with REGISTERED_PRIVATE_KEY — the private key
///         of your registered private-chain address (from the onboarding response).
///         The onlyRegisteredUsers modifier checks that msg.sender is an approved user
///         in RNUserGovernanceV1.
///
///         Before running this:
///         1. User must be registered and approved (Steps 1-2 in README)
///         2. Token must be deployed, registered, and approved (Steps 4-6 in README)
///         3. Wait for the relayer to deploy the mirror contract on the public chain
///         4. Tokens must be minted to your registered private-chain address (Step 8)
///
/// Usage:
///   source .env
///   forge script script/Transfer.s.sol --rpc-url $PRIVACY_NODE_RPC_URL --broadcast --legacy
contract Transfer is Script {
    function run() external {
        uint256 registeredKey = vm.envUint("REGISTERED_PRIVATE_KEY");
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address to = vm.envAddress("TRANSFER_TO");
        uint256 amount = vm.envUint("TRANSFER_AMOUNT") * 10 ** 18;
        uint256 publicChainId = vm.envUint("PUBLIC_CHAIN_ID");

        HackathonToken token = HackathonToken(tokenAddr);

        vm.startBroadcast(registeredKey);
        bool success = token.teleportToPublicChain(to, amount, publicChainId);
        vm.stopBroadcast();

        require(success, "teleportToPublicChain failed");

        console.log("=== Teleport Initiated ===");
        console.log("  Token:       ", tokenAddr);
        console.log("  Amount (wei):", amount);
        console.log("  To:          ", to);
        console.log("  Chain ID:    ", publicChainId);
        console.log("");
        console.log("Tokens are locked on the Privacy Node.");
        console.log("The relayer will mint them on the public chain shortly.");
    }
}
