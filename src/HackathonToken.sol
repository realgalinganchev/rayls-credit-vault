// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RaylsErc20Handler} from "rayls-protocol-sdk/tokens/RaylsErc20Handler.sol";

// Uncomment for AccessControl example:
// import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title HackathonToken
/// @notice A bridgeable ERC20 token for the Rayls hackathon.
/// @dev Inherits RaylsErc20Handler which provides:
///   - teleportToPublicChain(to, amount, chainId)  — lock on private, mint on public
///   - receiveTeleportFromPublicChain(to, amount)   — unlock on private (called by relayer)
///   - mint(to, amount)                             — mint new tokens (onlyOwner)
///   - burn(from, amount)                           — burn tokens (onlyOwner)
///
///   The deployer becomes the contract owner and can mint/burn tokens.
///   Only users registered and approved in RNUserGovernanceV1 can call teleportToPublicChain.
contract HackathonToken is RaylsErc20Handler {

    /// @param _name            Token name (e.g. "Hackathon Token")
    /// @param _symbol          Token symbol (e.g. "HACK")
    /// @param _endpoint        EndpointV1 address (from DeploymentProxyRegistry: "Endpoint")
    /// @param _raylsNodeEndpoint RNEndpointV1 address (from DeploymentProxyRegistry: "RNEndpoint")
    /// @param _userGovernance  RNUserGovernanceV1 address (from DeploymentProxyRegistry: "RNUserGovernance")
    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        address _raylsNodeEndpoint,
        address _userGovernance
    )
        RaylsErc20Handler(
            _name,
            _symbol,
            _endpoint,
            _raylsNodeEndpoint,
            _userGovernance,
            msg.sender, // owner = deployer
            false       // isCustom = false (standard factory deployment)
        )
    {
        // Mint initial supply to the deployer.
        // Uses _mint (internal) instead of mint() to avoid sending a cross-chain
        // notification before the token has a resourceId assigned.
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }

    // =========================================================================
    // CUSTOMIZATION EXAMPLES (uncomment to use)
    // =========================================================================

    // --- Example 1: Custom decimals (default is 18) --------------------------
    //
    // function decimals() public pure override returns (uint8) {
    //     return 6; // e.g. for stablecoin-style tokens
    // }

    // --- Example 2: Custom validation on incoming public chain transfers -----
    //
    // function receiveTeleportFromPublicChain(
    //     address to,
    //     uint256 value
    // ) public override {
    //     require(to != address(0), "Cannot receive to zero address");
    //     require(value <= 1_000_000 * 10 ** 18, "Transfer exceeds maximum");
    //     super.receiveTeleportFromPublicChain(to, value);
    // }

    // --- Example 3: AccessControl for mint/burn ------------------------------
    //
    // To use this, also:
    //   1. Uncomment the AccessControl import at the top
    //   2. Add AccessControl to the contract inheritance
    //   3. Grant roles in the constructor
    //
    // bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    //
    // function mint(address to, uint256 value) public override {
    //     require(hasRole(MINTER_ROLE, msg.sender), "Must have MINTER_ROLE");
    //     _mint(to, value);
    // }
}
