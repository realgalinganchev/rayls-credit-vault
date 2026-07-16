// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title MockAmFiCredit
/// @notice Local stand-in for an AmFi tokenized-private-credit receipt token
///         (a claim on a pool of Brazilian private credit — receivables
///         financing, structured credit notes, etc.).
/// @dev Two things a real AmFi token has that plain ERC20 doesn't:
///      1. A NAV that isn't a liquid market price — modeled here as an
///         owner-settable price (stand-in for an issuer-attested/Chainlink
///         NAV feed), not a DEX-derived price.
///      2. No live secondary market (confirmed in research: AmFi's own
///         marketplace is still "coming soon", no Algebra pool exists).
///         Instead of simulating an open market, this contract exposes an
///         issuer-funded redemption pool (`redeem()`) — the correct
///         simplification for how AmFi's real exit mechanics work today
///         (originator/issuer-mediated, not market-mediated). This is what
///         LendingMarket.liquidate()'s seized collateral is expected to
///         flow through after being seized to the liquidator's wallet.
/// @dev Ownership (the NAV setter / issuer role) uses two-step transfer
///      (Ownable2Step) so the privileged role can't be handed to a wrong or
///      unrecoverable address in a single call.
contract MockAmFiCredit is ERC20, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev One whole mAMFI token in base units (18 decimals) — the unit
    ///      navPerToken prices. Greppable counterpart of LendingMarket's
    ///      ORACLE_SCALE; the two MUST stay equal.
    uint256 public constant ONE_TOKEN = 1e18;

    /// @notice NAV per token, expressed in redemptionAsset's decimal terms
    ///         per whole (ONE_TOKEN) mAMFI token.
    /// @dev UNIT COUPLING: LendingMarket interprets this same value as LOAN
    ///      TOKEN units. The two conventions only coincide when
    ///      `redemptionAsset == the market's loanToken` — the deploy script
    ///      passes USDr as both. A deployment where they differ would
    ///      silently conflate units; keep them identical.
    uint256 public navPerToken;

    /// @notice Asset paid out on redemption (mUSDr). Set once at deploy —
    ///         in production this would be whatever stable/cash asset the
    ///         issuer actually settles redemptions in.
    IERC20 public immutable redemptionAsset;

    event NavUpdated(uint256 oldNav, uint256 newNav);
    event Redeemed(address indexed holder, uint256 amountBurned, uint256 assetsPaid);
    event RedemptionPoolFunded(address indexed funder, uint256 amount);

    constructor(uint256 initialSupply, uint256 initialNav, address _redemptionAsset)
        ERC20("Mock AmFi Tokenized Credit", "mAMFI")
        Ownable(msg.sender)
    {
        require(initialNav > 0, "nav must be > 0");
        require(_redemptionAsset != address(0), "zero redemption asset");
        navPerToken = initialNav;
        redemptionAsset = IERC20(_redemptionAsset);
        if (initialSupply > 0) {
            _mint(msg.sender, initialSupply);
        }
    }

    /// @notice Mint mock tokenized-credit units for testing.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Update the NAV — stands in for an issuer-attested price feed.
    ///         In production this would be replaced by a real oracle
    ///         (Chainlink or an AmFi-published NAV feed), not owner-set.
    function setNav(uint256 newNav) external onlyOwner {
        require(newNav > 0, "nav must be > 0");
        emit NavUpdated(navPerToken, newNav);
        navPerToken = newNav;
    }

    /// @notice The issuer (or anyone) tops up the redemption pool with the
    ///         redemption asset, so holders (e.g. a liquidator who just
    ///         seized mAMFI) have somewhere to actually exit to.
    function fundRedemptionPool(uint256 amount) external {
        require(amount > 0, "zero amount");
        redemptionAsset.safeTransferFrom(msg.sender, address(this), amount);
        emit RedemptionPoolFunded(msg.sender, amount);
    }

    /// @notice Burn `amount` of mAMFI and receive its NAV value in the
    ///         redemption asset, capped by whatever liquidity the pool
    ///         currently holds — this is the "issuer redemption" exit path,
    ///         not an open-market sale (none exists for AmFi tokens today).
    function redeem(uint256 amount) external nonReentrant returns (uint256 assetsPaid) {
        require(amount > 0, "zero amount");
        assetsPaid = (amount * navPerToken) / ONE_TOKEN;
        require(assetsPaid <= redemptionAsset.balanceOf(address(this)), "redemption pool insufficient");

        _burn(msg.sender, amount);
        redemptionAsset.safeTransfer(msg.sender, assetsPaid);

        emit Redeemed(msg.sender, amount, assetsPaid);
    }
}
