// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title MockUSDr
/// @notice Local stand-in for Rayls' native USD-pegged gas stablecoin (USDr).
/// @dev Plain OpenZeppelin ERC20 — deliberately has NO dependency on Rayls
///      bridge infrastructure (Endpoint/RNEndpoint/RNUserGovernance), so it
///      deploys and runs on vanilla Anvil. On real Rayls testnet/mainnet,
///      the lending market/vault would instead be pointed at the real USDr
///      token address via constructor args — no contract code changes needed.
contract MockUSDr is ERC20, Ownable {
    uint8 private constant _DECIMALS = 6; // USDr is dollar-pegged; 6 decimals matches typical stablecoin convention

    constructor(uint256 initialSupply) ERC20("Mock USDr", "mUSDr") Ownable(msg.sender) {
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    /// @notice Mint additional mUSDr for testing (lenders/borrowers need funded balances).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
