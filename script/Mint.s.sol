// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HackathonToken} from "../src/HackathonToken.sol";

/// @title Mint
/// @notice Mints tokens to a recipient address. Must be called by the token owner (deployer).
///         Use this to fund your registered private-chain address before transferring to public chain.
///
/// Usage:
///   source .env
///   forge script script/Mint.s.sol --rpc-url $PRIVACY_NODE_RPC_URL --broadcast --legacy
contract Mint is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address tokenAddr = vm.envAddress("TOKEN_ADDRESS");
        address recipient = vm.envAddress("MINT_RECIPIENT");
        uint256 amount = vm.envUint("MINT_AMOUNT") * 10 ** 18;

        HackathonToken token = HackathonToken(tokenAddr);

        vm.startBroadcast(deployerKey);
        token.mint(recipient, amount);
        vm.stopBroadcast();

        console.log("Minted %s tokens (wei) to %s", amount, recipient);
    }
}
