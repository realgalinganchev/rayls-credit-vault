// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal NAV feed interface for the collateral asset. In production
///         this would be a real oracle (Chainlink or an AmFi-published NAV
///         feed) instead of the owner-settable mock used here.
/// @dev UNIT CONVENTION (load-bearing — the market's health and liquidation
///      math depend on it): `navPerToken()` returns the value of ONE WHOLE
///      collateral token (1e18 base units — the market requires 18-decimal
///      collateral at construction) denominated in the market's LOAN TOKEN
///      base units (e.g. 1_000_000 = 1.00 for a 6-decimal loan token).
///      Implementations MUST return a non-zero value; the market reverts all
///      pricing operations on a zero NAV rather than treating collateral as
///      worthless-but-unliquidatable.
interface INavOracle {
    function navPerToken() external view returns (uint256);
}

/// @title LendingMarket
/// @notice Minimal, Morpho-Blue-inspired single-market lending primitive:
///         lenders supply the loan asset (USDr) and earn interest; borrowers
///         post collateral (AmFi tokenized credit) and borrow against it,
///         overcollateralized at a fixed liquidation LTV. Liquidation is
///         permissionless — anyone can call it, which is what keeps the
///         market solvent without a designated liquidator role acting as a
///         single point of failure.
/// @dev PoC scope, not production:
///      - Single hardcoded market (one loan asset, one collateral asset, one
///        oracle) rather than Morpho's permissionless multi-market factory.
///      - Linear utilization-based interest rate model. Interest is SIMPLE
///        (non-compounding) within each accrual window, and the rate applied
///        over a window is the one prevailing when accrual materializes —
///        this diverges from Morpho Blue's Taylor-compounded accrual.
///      - liquidate() seizes collateral to the liquidator's wallet. Per this
///        project's research, AmFi tokens have no live secondary market
///        today, so the intended path is the liquidator subsequently calling
///        MockAmFiCredit.redeem() (issuer-mediated exit) rather than selling
///        on an open market — that's the correct simplification given how
///        AmFi's real exit mechanics work, not a shortcut.
///      - Share accounting mirrors Morpho Blue's virtual-shares/virtual-assets
///        approach specifically to prevent the classic empty-market donation
///        (share-inflation) attack on the first depositor.
///      - Bad debt IS socialized (Morpho-style): when a liquidation exhausts
///        a borrower's collateral, any remaining debt is written off against
///        all lenders pro-rata immediately, instead of lingering as phantom
///        assets that turn lender exits into a first-out-wins bank run.
///      - Owner (curator) trust assumptions: owner sets the fee (capped at
///        MAX_FEE_BPS) and fee recipient. There is no timelock or multisig,
///        but ownership transfer is two-step (Ownable2Step) so the privileged
///        role can't be handed to a wrong/unrecoverable address in one call.
contract LendingMarket is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant LIQUIDATION_BONUS_BPS = 500; // 5% discount to liquidators
    uint256 public constant MAX_FEE_BPS = 2_500; // fee ceiling (25%, mirrors Morpho) — bounds owner trust

    // Morpho-style virtual shares/assets offset — prevents the first
    // depositor from being griefed by a share-inflation ("donation") attack
    // on an empty market. Public so integrators/tests can replicate the
    // conversion math exactly instead of duplicating the constants.
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    // ---------------------------------------------------------------------
    // Immutable market configuration
    // ---------------------------------------------------------------------

    IERC20 public immutable loanToken; // USDr
    IERC20 public immutable collateralToken; // AmFi tokenized credit
    INavOracle public immutable oracle; // NAV feed for collateralToken
    uint256 public immutable liquidationLtvBps; // e.g. 7000 = 70%

    // Divisor pairing with INavOracle's unit convention (see interface
    // natspec): navPerToken() prices 1e18 collateral base units, so the
    // constructor REQUIRES the collateral token to have 18 decimals.
    uint256 public constant ORACLE_SCALE = 1e18;

    // ---------------------------------------------------------------------
    // Interest rate model (linear, utilization-based)
    // ---------------------------------------------------------------------

    uint256 public immutable baseRateWadPerYear; // rate at 0% utilization
    uint256 public immutable slopeWadPerYear; // additional rate at 100% utilization

    // ---------------------------------------------------------------------
    // Protocol / curator fee
    // ---------------------------------------------------------------------

    uint256 public feeBps; // cut of accrued interest, e.g. 1500 = 15% (matches Steakhouse's real curator rate)
    address public feeRecipient;

    // ---------------------------------------------------------------------
    // Accounting (share-based, Morpho-style)
    // ---------------------------------------------------------------------

    uint256 public totalSupplyAssets;
    uint256 public totalSupplyShares;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public lastAccrualTimestamp;

    mapping(address => uint256) public supplyShares;
    mapping(address => uint256) public borrowShares;
    mapping(address => uint256) public collateralBalance;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Supply(address indexed user, uint256 assets, uint256 shares);
    event Withdraw(address indexed user, uint256 assets, uint256 shares);
    event SupplyCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 assets, uint256 shares);
    event Repay(address indexed user, uint256 assets, uint256 shares);
    event Liquidate(address indexed borrower, address indexed liquidator, uint256 repaidAssets, uint256 seizedCollateral);
    event BadDebtRealized(address indexed borrower, uint256 badDebtAssets, uint256 badDebtShares);
    event InterestAccrued(uint256 interest, uint256 feeShares);
    event FeeConfigUpdated(uint256 feeBps, address feeRecipient);

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(
        address _loanToken,
        address _collateralToken,
        address _oracle,
        uint256 _liquidationLtvBps,
        uint256 _baseRateWadPerYear,
        uint256 _slopeWadPerYear,
        uint256 _feeBps,
        address _feeRecipient
    ) Ownable(msg.sender) {
        require(_loanToken != address(0) && _collateralToken != address(0) && _oracle != address(0), "zero address");
        require(_liquidationLtvBps > 0 && _liquidationLtvBps < BPS, "invalid LLTV");
        require(_feeBps <= MAX_FEE_BPS, "invalid fee");
        require(_feeRecipient != address(0), "zero fee recipient");
        // ORACLE_SCALE (1e18) hard-assumes 18-decimal collateral; any other
        // precision silently mis-prices every health check by 10^|18-d|.
        require(IERC20Metadata(_collateralToken).decimals() == 18, "collateral must be 18 decimals");

        loanToken = IERC20(_loanToken);
        collateralToken = IERC20(_collateralToken);
        oracle = INavOracle(_oracle);
        liquidationLtvBps = _liquidationLtvBps;
        baseRateWadPerYear = _baseRateWadPerYear;
        slopeWadPerYear = _slopeWadPerYear;
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        lastAccrualTimestamp = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Lender actions
    // ---------------------------------------------------------------------

    /// @notice Supply `assets` of the loan token, minting proportional supply shares.
    function supply(uint256 assets) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero assets");
        _accrueInterest();

        shares = _toSharesDown(assets, totalSupplyAssets, totalSupplyShares);
        supplyShares[msg.sender] += shares;
        totalSupplyShares += shares;
        totalSupplyAssets += assets;

        loanToken.safeTransferFrom(msg.sender, address(this), assets);
        emit Supply(msg.sender, assets, shares);
    }

    /// @notice Redeem `shares` of supply shares for the underlying loan token.
    ///         Assets are rounded down so the market is never shorted.
    function withdraw(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");
        _accrueInterest();

        assets = _toAssetsDown(shares, totalSupplyAssets, totalSupplyShares);
        _executeWithdraw(shares, assets);
    }

    /// @notice Withdraw an exact amount of the loan token (rather than an
    ///         exact number of shares) — convenience entrypoint for
    ///         integrators like a vault, which need a precise asset amount
    ///         rather than whatever a share redemption happens to round to.
    ///         Shares are rounded up so the market is never shorted.
    function withdrawAssets(uint256 assets) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero assets");
        _accrueInterest();

        shares = _toSharesUp(assets, totalSupplyAssets, totalSupplyShares);
        _executeWithdraw(shares, assets);
    }

    /// @dev Shared body of both withdrawal entrypoints. Callers are
    ///      responsible for accruing interest and choosing the rounding
    ///      direction; this only applies the state change and pays out.
    function _executeWithdraw(uint256 shares, uint256 assets) private {
        supplyShares[msg.sender] -= shares; // reverts on underflow if insufficient
        totalSupplyShares -= shares;
        totalSupplyAssets -= assets;

        require(totalBorrowAssets <= totalSupplyAssets, "insufficient liquidity");

        loanToken.safeTransfer(msg.sender, assets);
        emit Withdraw(msg.sender, assets, shares);
    }

    // ---------------------------------------------------------------------
    // Borrower actions
    // ---------------------------------------------------------------------

    /// @notice Post `amount` of collateral token.
    function supplyCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        collateralBalance[msg.sender] += amount;
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit SupplyCollateral(msg.sender, amount);
    }

    /// @notice Withdraw `amount` of collateral, provided the position stays healthy.
    function withdrawCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        _accrueInterest();

        collateralBalance[msg.sender] -= amount; // reverts if insufficient
        require(_isHealthy(msg.sender), "unhealthy position");

        collateralToken.safeTransfer(msg.sender, amount);
        emit WithdrawCollateral(msg.sender, amount);
    }

    /// @notice Borrow `assets` of the loan token against posted collateral.
    function borrow(uint256 assets) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "zero assets");
        _accrueInterest();

        shares = _toSharesUp(assets, totalBorrowAssets, totalBorrowShares);
        borrowShares[msg.sender] += shares;
        totalBorrowShares += shares;
        totalBorrowAssets += assets;

        require(_isHealthy(msg.sender), "insufficient collateral");
        require(totalBorrowAssets <= totalSupplyAssets, "insufficient liquidity");

        loanToken.safeTransfer(msg.sender, assets);
        emit Borrow(msg.sender, assets, shares);
    }

    /// @notice Repay `shares` of borrow shares.
    function repay(uint256 shares) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");
        _accrueInterest();

        assets = _toAssetsUp(shares, totalBorrowAssets, totalBorrowShares);
        borrowShares[msg.sender] -= shares; // reverts on underflow if insufficient
        totalBorrowShares -= shares;
        totalBorrowAssets -= assets;

        loanToken.safeTransferFrom(msg.sender, address(this), assets);
        emit Repay(msg.sender, assets, shares);
    }

    // ---------------------------------------------------------------------
    // Liquidation
    // ---------------------------------------------------------------------

    /// @notice Liquidate an unhealthy position: repay up to `repayShares` of
    ///         the borrower's debt and seize the equivalent collateral value
    ///         plus a liquidation bonus. Permissionless: anyone can call
    ///         this, and the discount is the entire incentive — there is no
    ///         separate protocol fee or reward on liquidations.
    /// @param borrower The undercollateralized position to liquidate.
    /// @param repayShares Amount of the borrower's borrowShares to repay (partial liquidation allowed).
    function liquidate(address borrower, uint256 repayShares)
        external
        nonReentrant
        returns (uint256 repaidAssets, uint256 seizedCollateral)
    {
        require(repayShares > 0, "zero shares");
        _accrueInterest();

        require(!_isHealthy(borrower), "position healthy");

        repaidAssets = _toAssetsUp(repayShares, totalBorrowAssets, totalBorrowShares);

        // Cache NAV once (enforces the non-zero invariant): reused for the
        // seize math and the post-seize collateral-value check below.
        uint256 nav = _oracleNav();

        // Fused conversion — no divide-before-multiply: repaid value plus the
        // liquidation bonus, priced into collateral units, rounded down
        // (market/borrower favored).
        seizedCollateral = (repaidAssets * (BPS + LIQUIDATION_BONUS_BPS) * ORACLE_SCALE) / (BPS * nav);
        if (seizedCollateral > collateralBalance[borrower]) {
            seizedCollateral = collateralBalance[borrower];
        }

        borrowShares[borrower] -= repayShares;
        totalBorrowShares -= repayShares;
        totalBorrowAssets -= repaidAssets;
        collateralBalance[borrower] -= seizedCollateral;

        // Bad-debt socialization (Morpho-style): if this liquidation left the
        // borrower's collateral effectively exhausted but debt remains, no
        // rational liquidator will ever repay the rump — its seizure would be
        // zero, making repayment a pure donation. Left alone, that rump
        // accrues phantom interest forever and turns lender exits into a
        // first-out-wins bank run. Write it off against all lenders pro-rata
        // immediately instead.
        //
        // Keyed on collateral VALUE, not raw balance: a liquidator who seizes
        // all but a dust wei would otherwise skip this branch and leave the
        // remaining debt unbacked-but-phantom. Dust rounds to zero value, so
        // it is correctly treated as exhausted.
        if ((collateralBalance[borrower] * nav) / ORACLE_SCALE == 0 && borrowShares[borrower] > 0) {
            uint256 badDebtShares = borrowShares[borrower];
            uint256 badDebtAssets = _toAssetsUp(badDebtShares, totalBorrowAssets, totalBorrowShares);
            if (badDebtAssets > totalBorrowAssets) badDebtAssets = totalBorrowAssets; // clamp rounding-up overshoot

            totalBorrowAssets -= badDebtAssets;
            totalSupplyAssets -= badDebtAssets; // S >= D invariant makes this safe
            totalBorrowShares -= badDebtShares;
            borrowShares[borrower] = 0;

            emit BadDebtRealized(borrower, badDebtAssets, badDebtShares);
        }

        loanToken.safeTransferFrom(msg.sender, address(this), repaidAssets);
        collateralToken.safeTransfer(msg.sender, seizedCollateral);

        emit Liquidate(borrower, msg.sender, repaidAssets, seizedCollateral);
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function setFeeConfig(uint256 _feeBps, address _feeRecipient) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "invalid fee");
        require(_feeRecipient != address(0), "zero fee recipient");
        _accrueInterest(); // materialize pending interest at the OLD fee first — no retroactive application
        feeBps = _feeBps;
        feeRecipient = _feeRecipient;
        emit FeeConfigUpdated(_feeBps, _feeRecipient);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function debtOf(address user) external view returns (uint256) {
        return _debtOf(user);
    }

    /// @notice A supplier's current claimable balance, projecting interest
    ///         that has accrued since `lastAccrualTimestamp` but hasn't been
    ///         materialized into storage yet (accrual is lazy, on-call).
    ///         Used by integrators like the vault for an accurate
    ///         `totalAssets()` between accrual-triggering calls.
    /// @dev The projection replicates `_accrueInterest()` EXACTLY, including
    ///      the fee-share dilution: suppliers only ever receive interest net
    ///      of the fee, so projecting gross interest would overstate every
    ///      supplier's claim between accruals — enough to (a) make a vault's
    ///      full redeem revert and (b) let withdraw-before-accrual /
    ///      redeposit-after extract value from remaining depositors.
    function supplyBalance(address user) external view returns (uint256) {
        if (supplyShares[user] == 0) return 0;

        uint256 pending = _pendingInterest();
        uint256 projectedAssets = totalSupplyAssets + pending;
        uint256 projectedShares = totalSupplyShares;
        if (pending > 0 && feeBps > 0) {
            uint256 feeAssets = (pending * feeBps) / BPS;
            projectedShares += _toSharesDown(feeAssets, projectedAssets - feeAssets, totalSupplyShares);
        }
        return _toAssetsDown(supplyShares[user], projectedAssets, projectedShares);
    }

    /// @notice Loan-token liquidity currently withdrawable from the market
    ///         (cash on hand). Exact even without projecting pending
    ///         interest: accrual adds equally to supply and borrow totals,
    ///         so their difference — actual cash — is unaffected by it.
    ///         Used by integrators (e.g. the vault's EIP-4626 max* views).
    function availableLiquidity() external view returns (uint256) {
        return totalSupplyAssets - totalBorrowAssets;
    }

    function collateralValue(address user) external view returns (uint256) {
        return _collateralValue(user);
    }

    function isHealthy(address user) external view returns (bool) {
        return _isHealthy(user);
    }

    /// @notice Current utilization, in WAD (1e18 = 100%).
    function utilizationWad() public view returns (uint256) {
        if (totalSupplyAssets == 0) return 0;
        return (totalBorrowAssets * WAD) / totalSupplyAssets;
    }

    /// @notice Current borrow rate, in WAD-per-year (1e18 = 100% APR, simple, not compounded).
    function borrowRateWadPerYear() public view returns (uint256) {
        return baseRateWadPerYear + (slopeWadPerYear * utilizationWad()) / WAD;
    }

    // ---------------------------------------------------------------------
    // Internal — interest accrual
    // ---------------------------------------------------------------------

    /// @notice Interest that would accrue if `_accrueInterest()` were called
    ///         right now, without mutating any state. Used both by
    ///         `_accrueInterest()` itself and by the `supplyBalance` view.
    function _pendingInterest() internal view returns (uint256) {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0 || totalBorrowAssets == 0 || totalSupplyAssets == 0) return 0;

        uint256 rate = borrowRateWadPerYear();
        return (totalBorrowAssets * rate * elapsed) / (SECONDS_PER_YEAR * WAD);
    }

    function _accrueInterest() internal {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        if (totalBorrowAssets == 0 || totalSupplyAssets == 0) {
            // Nothing can accrue; advance the clock so a future first
            // borrow doesn't accrue retroactively over the idle window.
            lastAccrualTimestamp = block.timestamp;
            return;
        }

        uint256 interest = _pendingInterest();
        // Sub-unit interest: leave the clock untouched so the fractional
        // amount keeps accumulating instead of being forfeited on every
        // state-changing call — with a 6-decimal loan token and ~1s Rayls
        // blocks, small markets would otherwise earn exactly zero forever.
        if (interest == 0) return;
        lastAccrualTimestamp = block.timestamp;

        totalBorrowAssets += interest;
        totalSupplyAssets += interest;

        uint256 feeShares = 0;
        if (feeBps > 0) {
            uint256 feeAssets = (interest * feeBps) / BPS;
            // Mint shares to feeRecipient corresponding to feeAssets at the
            // post-interest exchange rate — no assets move, they're already
            // reflected in totalSupplyAssets above.
            feeShares = _toSharesDown(feeAssets, totalSupplyAssets - feeAssets, totalSupplyShares);
            supplyShares[feeRecipient] += feeShares;
            totalSupplyShares += feeShares;
        }

        emit InterestAccrued(interest, feeShares);
    }

    // ---------------------------------------------------------------------
    // Internal — health check
    // ---------------------------------------------------------------------

    /// @notice A borrower's current debt, projecting interest that has
    ///         accrued since `lastAccrualTimestamp` but hasn't been
    ///         materialized into storage yet. Safe to call both externally
    ///         (between transactions, where the projection matters) and
    ///         internally from within a state-changing function that has
    ///         already called `_accrueInterest()` this transaction (where
    ///         the projection is simply zero, since nothing is pending).
    function _debtOf(address user) internal view returns (uint256) {
        if (borrowShares[user] == 0) return 0;
        uint256 projectedTotalBorrowAssets = totalBorrowAssets + _pendingInterest();
        return _toAssetsUp(borrowShares[user], projectedTotalBorrowAssets, totalBorrowShares);
    }

    function _collateralValue(address user) internal view returns (uint256) {
        return (collateralBalance[user] * _oracleNav()) / ORACLE_SCALE;
    }

    /// @dev Reads the oracle and enforces the INavOracle non-zero invariant.
    ///      A zero NAV must revert loudly: treating it as "collateral is
    ///      worthless" would make every borrower maximally unhealthy while
    ///      simultaneously bricking liquidations with a division-by-zero
    ///      panic — the worst possible failure mode at the worst time.
    function _oracleNav() internal view returns (uint256 nav) {
        nav = oracle.navPerToken();
        require(nav > 0, "invalid oracle price");
    }

    function _isHealthy(address user) internal view returns (bool) {
        uint256 debt = _debtOf(user);
        if (debt == 0) return true;
        uint256 maxBorrow = (_collateralValue(user) * liquidationLtvBps) / BPS;
        return debt <= maxBorrow;
    }

    // ---------------------------------------------------------------------
    // Internal — share/asset conversion (Morpho-style virtual offset)
    // ---------------------------------------------------------------------

    function _toSharesDown(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return (assets * (totalShares + VIRTUAL_SHARES)) / (totalAssets + VIRTUAL_ASSETS);
    }

    function _toSharesUp(uint256 assets, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivUp(assets, totalShares + VIRTUAL_SHARES, totalAssets + VIRTUAL_ASSETS);
    }

    function _toAssetsDown(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return (shares * (totalAssets + VIRTUAL_ASSETS)) / (totalShares + VIRTUAL_SHARES);
    }

    function _toAssetsUp(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return _mulDivUp(shares, totalAssets + VIRTUAL_ASSETS, totalShares + VIRTUAL_SHARES);
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}
