// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LendingMarket} from "./LendingMarket.sol";

/// @title CuratedCreditVault
/// @notice ERC-4626 vault: depositors put in USDr and get one-click,
///         risk-managed exposure to LendingMarket's yield, without touching
///         the raw market themselves. The curator (owner) decides how much
///         of the vault's assets are deployed into the market versus kept
///         idle for withdrawal liquidity — the MetaMorpho role, applied to
///         AmFi tokenized-credit collateral on Rayls.
/// @dev PoC scope: allocates into a single LendingMarket instance behind one
///      allocation cap, mirroring MetaMorpho's curation role without its
///      multi-market routing. A production version would support several
///      markets with individual per-market caps — documented as a known
///      simplification, not an oversight.
contract CuratedCreditVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Intentionally lowerCamelCase — public getter market() is part of the ABI;
    // see LendingMarket for the full rationale.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    LendingMarket public immutable market;

    /// @notice Max fraction (in bps) of totalAssets the curator will deploy
    ///         into the market; the remainder stays idle as withdrawal liquidity.
    uint256 public allocationCapBps;
    uint256 public constant BPS = 10_000;

    event Allocated(uint256 amount);
    event Deallocated(uint256 amount);
    event AllocationCapUpdated(uint256 capBps);

    constructor(
        IERC20 _asset,
        LendingMarket _market,
        uint256 _allocationCapBps,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) ERC4626(_asset) Ownable(msg.sender) {
        require(address(_market.loanToken()) == address(_asset), "asset mismatch");
        require(_allocationCapBps <= BPS, "invalid cap");

        market = _market;
        allocationCapBps = _allocationCapBps;

        // Pre-approve the market to pull the vault's idle assets on allocate().
        IERC20(address(_asset)).forceApprove(address(_market), type(uint256).max);
    }

    /// @notice Total assets under management: idle balance held directly by
    ///         the vault, plus the vault's claim on the lending market
    ///         (including interest accrued but not yet materialized on-chain).
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + market.supplyBalance(address(this));
    }

    /// @notice Curator action: push idle vault assets into the lending
    ///         market, up to the allocation cap.
    /// @dev The cap is enforced only at allocate-time. As interest accrues,
    ///      the deployed claim grows while idle doesn't, so the deployed
    ///      ratio can passively drift above `allocationCapBps` — expected
    ///      behavior for this design, corrected by the curator deallocating.
    function allocate(uint256 amount) external onlyOwner {
        require(amount > 0, "zero amount");

        uint256 idle = IERC20(asset()).balanceOf(address(this));
        require(amount <= idle, "exceeds idle balance");

        uint256 currentlyDeployed = market.supplyBalance(address(this));
        uint256 targetMax = ((idle + currentlyDeployed) * allocationCapBps) / BPS;
        require(currentlyDeployed + amount <= targetMax, "exceeds allocation cap");

        market.supply(amount);
        emit Allocated(amount);
    }

    /// @notice Curator action: pull `amount` of assets back out of the lending
    ///         market to top up idle withdrawal liquidity. Asset-denominated to
    ///         mirror allocate() (avoids the assets-vs-shares footgun). To fully
    ///         exit, pass `market.supplyBalance(address(this))`. Deliberately
    ///         has no cap check — reducing deployment is always allowed.
    /// @dev KNOWN, ACCEPTED DUST: a "full" exit may leave a few wei of market
    ///      shares behind — withdrawAssets rounds shares up, and
    ///      toSharesUp(toAssetsDown(s)) <= s, so the burn never exceeds what
    ///      the vault holds but can fall slightly short of all of it. The
    ///      residue stays counted in totalAssets(), so no value is lost. Do
    ///      NOT "fix" this by reverting to a share-denominated signature:
    ///      that reintroduces the assets-vs-shares confusion this API was
    ///      changed to remove (audit finding L-02).
    function deallocate(uint256 amount) external onlyOwner {
        require(amount > 0, "zero amount");
        market.withdrawAssets(amount);
        emit Deallocated(amount);
    }

    function setAllocationCap(uint256 capBps) external onlyOwner {
        require(capBps <= BPS, "invalid cap");
        allocationCapBps = capBps;
        emit AllocationCapUpdated(capBps);
    }

    /// @notice EIP-4626 compliance under market illiquidity: the OZ defaults
    ///         assume all of totalAssets is liquid, but part of this vault's
    ///         assets are deployed into the market, whose cash on hand can be
    ///         lent out. max* views MUST NOT overstate what a withdrawal can
    ///         actually deliver without reverting.
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(super.maxWithdraw(owner), _liquidAssets());
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return Math.min(super.maxRedeem(owner), _convertToShares(_liquidAssets(), Math.Rounding.Floor));
    }

    /// @dev Assets deliverable right now: idle balance plus the smaller of
    ///      (our claim on the market, the market's actual cash on hand).
    function _liquidAssets() internal view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this))
            + Math.min(market.supplyBalance(address(this)), market.availableLiquidity());
    }

    /// @dev Cheap insurance against vault-level donation griefing on top of
    ///      OZ v5's virtual accounting (the vault is its own share economy —
    ///      the market's virtual shares don't protect it). With a 6-decimal
    ///      asset, offset 6 makes rounding a depositor to zero shares
    ///      require a ~10^6x donation, i.e. economically absurd.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev nonReentrant on the internal deposit/withdraw funnels guards all
    ///      four ERC-4626 entrypoints (deposit/mint → _deposit,
    ///      withdraw/redeem → _withdraw). Cheap insurance: the loan asset is a
    ///      plain non-callback ERC-20 today (USDr), but this keeps the vault
    ///      safe if it is ever pointed at an asset with transfer hooks.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Ensure enough idle liquidity exists before a withdrawal/redeem by
    ///      pulling the shortfall out of the market first. Reverts if the
    ///      market itself doesn't have enough liquidity (i.e. too much of
    ///      the market's supply is currently borrowed out) — the same
    ///      illiquidity risk any curated lending vault carries.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets) {
            uint256 shortfall = assets - idle;
            market.withdrawAssets(shortfall);
        }
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}
