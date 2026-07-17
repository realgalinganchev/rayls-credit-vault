// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockUSDr} from "../src/MockUSDr.sol";
import {MockAmFiCredit} from "../src/MockAmFiCredit.sol";
import {LendingMarket} from "../src/LendingMarket.sol";

contract LendingMarketTest is Test {
    MockUSDr usdr;
    MockAmFiCredit amfi;
    LendingMarket market;

    address lender = makeAddr("lender");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");
    address feeRecipient = makeAddr("feeRecipient");

    uint256 constant LLTV_BPS = 7_000; // 70%
    uint256 constant BASE_RATE = 0.02e18; // 2%
    uint256 constant SLOPE_RATE = 0.10e18; // +10% at 100% utilization
    uint256 constant FEE_BPS = 1_500; // 15%

    function setUp() public {
        usdr = new MockUSDr(1_000_000 * 1e6);
        amfi = new MockAmFiCredit(500_000 * 1e18, 1_000_000, address(usdr));
        market = new LendingMarket(
            address(usdr), address(amfi), address(amfi), LLTV_BPS, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient
        );

        usdr.transfer(lender, 200_000 * 1e6);
        amfi.transfer(borrower, 100_000 * 1e18);
        usdr.transfer(liquidator, 100_000 * 1e6);
    }

    // -----------------------------------------------------------------
    // Constructor validation
    // -----------------------------------------------------------------

    function test_Constructor_RevertsOnInvalidLltv() public {
        vm.expectRevert("invalid LLTV");
        new LendingMarket(address(usdr), address(amfi), address(amfi), 0, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient);

        vm.expectRevert("invalid LLTV");
        new LendingMarket(
            address(usdr), address(amfi), address(amfi), 10_000, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient
        );
    }

    function test_Constructor_RevertsOnZeroFeeRecipient() public {
        vm.expectRevert("zero fee recipient");
        new LendingMarket(address(usdr), address(amfi), address(amfi), LLTV_BPS, BASE_RATE, SLOPE_RATE, FEE_BPS, address(0));
    }

    function test_Constructor_RevertsOnZeroAddresses() public {
        vm.expectRevert("zero address");
        new LendingMarket(address(0), address(amfi), address(amfi), LLTV_BPS, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient);
        vm.expectRevert("zero address");
        new LendingMarket(address(usdr), address(0), address(amfi), LLTV_BPS, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient);
        vm.expectRevert("zero address");
        new LendingMarket(address(usdr), address(amfi), address(0), LLTV_BPS, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient);
    }

    function test_Constructor_RevertsOnFeeAboveCap() public {
        uint256 tooHigh = market.MAX_FEE_BPS() + 1;
        vm.expectRevert("invalid fee");
        new LendingMarket(address(usdr), address(amfi), address(amfi), LLTV_BPS, BASE_RATE, SLOPE_RATE, tooHigh, feeRecipient);
    }

    /// @dev Regression for the decimals LOW finding: ORACLE_SCALE hard-assumes
    ///      18-decimal collateral; anything else must be rejected at deploy.
    function test_Constructor_RevertsOnNon18DecimalCollateral() public {
        // MockUSDr has 6 decimals -- invalid as collateral for this market.
        vm.expectRevert("collateral must be 18 decimals");
        new LendingMarket(address(usdr), address(usdr), address(amfi), LLTV_BPS, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient);
    }

    // -----------------------------------------------------------------
    // Supply / withdraw
    // -----------------------------------------------------------------

    function test_Supply_MintsSharesAndTransfersAssets() public {
        vm.startPrank(lender);
        usdr.approve(address(market), 100_000 * 1e6);
        uint256 shares = market.supply(100_000 * 1e6);
        vm.stopPrank();

        assertEq(shares, market.supplyShares(lender));
        assertEq(market.totalSupplyAssets(), 100_000 * 1e6);
        assertEq(usdr.balanceOf(address(market)), 100_000 * 1e6);
    }

    function test_Supply_RevertsOnZeroAssets() public {
        vm.prank(lender);
        vm.expectRevert("zero assets");
        market.supply(0);
    }

    function test_Withdraw_BurnsSharesAndReturnsAssets() public {
        _supply(lender, 100_000 * 1e6);

        vm.startPrank(lender);
        uint256 shares = market.supplyShares(lender);
        uint256 assets = market.withdraw(shares);
        vm.stopPrank();

        assertEq(assets, 100_000 * 1e6);
        assertEq(market.supplyShares(lender), 0);
        assertEq(usdr.balanceOf(lender), 200_000 * 1e6); // back to original balance
    }

    function test_Withdraw_RevertsOnInsufficientLiquidity() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 100_000 * 1e18); // $100,000 collateral -> max borrow $70,000 at 70% LLTV
        _borrow(borrower, 69_000 * 1e6); // within LTV, but leaves only 31,000 idle vs. lender's 100,000 claim

        vm.startPrank(lender);
        uint256 shares = market.supplyShares(lender);
        vm.expectRevert("insufficient liquidity");
        market.withdraw(shares);
        vm.stopPrank();
    }

    function test_WithdrawAssets_MatchesShareWithdraw() public {
        uint256 sharesBeforeWithdraw = _supply(lender, 100_000 * 1e6);

        vm.startPrank(lender);
        uint256 sharesBurned = market.withdrawAssets(40_000 * 1e6);
        vm.stopPrank();

        assertEq(usdr.balanceOf(lender), 200_000 * 1e6 - 100_000 * 1e6 + 40_000 * 1e6);
        assertGt(sharesBurned, 0);
        assertEq(market.supplyShares(lender), sharesBeforeWithdraw - sharesBurned);
        assertEq(market.totalSupplyAssets(), 60_000 * 1e6);
    }

    // -----------------------------------------------------------------
    // Collateral
    // -----------------------------------------------------------------

    function test_SupplyCollateral_TransfersIn() public {
        _supplyCollateral(borrower, 50_000 * 1e18);
        assertEq(market.collateralBalance(borrower), 50_000 * 1e18);
        assertEq(amfi.balanceOf(address(market)), 50_000 * 1e18);
    }

    function test_WithdrawCollateral_SucceedsWhenHealthy() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);

        vm.prank(borrower);
        market.withdrawCollateral(10_000 * 1e18);

        assertEq(market.collateralBalance(borrower), 40_000 * 1e18);
    }

    function test_WithdrawCollateral_RevertsWhenUnhealthy() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6); // 60% of 50,000 collateral value, healthy at 70% LLTV

        vm.prank(borrower);
        vm.expectRevert("unhealthy position");
        market.withdrawCollateral(30_000 * 1e18); // would leave 20,000 collateral against 30,000 debt = 150% LTV
    }

    // -----------------------------------------------------------------
    // Borrow / repay
    // -----------------------------------------------------------------

    function test_Borrow_SucceedsWithinLtv() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);

        vm.prank(borrower);
        market.borrow(30_000 * 1e6); // 60% LTV, under 70% cap

        assertEq(market.debtOf(borrower), 30_000 * 1e6);
        assertTrue(market.isHealthy(borrower));
        assertEq(usdr.balanceOf(borrower), 30_000 * 1e6);
    }

    function test_Borrow_RevertsIfExceedsLtv() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);

        vm.prank(borrower);
        vm.expectRevert("insufficient collateral");
        market.borrow(40_000 * 1e6); // 80% LTV, exceeds 70% cap
    }

    function test_Borrow_RevertsIfInsufficientLiquidity() public {
        _supply(lender, 10_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);

        vm.prank(borrower);
        vm.expectRevert("insufficient liquidity");
        market.borrow(20_000 * 1e6); // healthy LTV-wise, but exceeds available supply
    }

    function test_Repay_ReducesDebt() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6);

        vm.startPrank(borrower);
        usdr.approve(address(market), 30_000 * 1e6);
        market.repay(market.borrowShares(borrower));
        vm.stopPrank();

        assertEq(market.debtOf(borrower), 0);
    }

    // -----------------------------------------------------------------
    // Interest accrual
    // -----------------------------------------------------------------

    function test_InterestAccrual_OverTime() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 100_000 * 1e18); // $100,000 collateral -> max borrow $70,000 at 70% LLTV
        _borrow(borrower, 65_000 * 1e6); // 65% utilization, safely within LTV

        uint256 totalBorrowBefore = market.totalBorrowAssets();
        uint256 totalSupplyBefore = market.totalSupplyAssets();

        vm.warp(block.timestamp + 365 days);

        // Utilization = 65,000 / 100,000 = 65% -> rate = 2% + 0.65*10% = 8.5%/yr
        uint256 expectedRate = BASE_RATE + (SLOPE_RATE * 0.65e18) / 1e18;
        assertEq(market.borrowRateWadPerYear(), expectedRate);

        // Exact interest, replicating _pendingInterest()'s formula bit for
        // bit using the market's own public constants -- elapsed equals
        // exactly SECONDS_PER_YEAR here, so this is a precise value, not an
        // approximation, and assertEq is the right assertion.
        uint256 elapsed = 365 days;
        uint256 expectedInterest =
            (totalBorrowBefore * expectedRate * elapsed) / (market.SECONDS_PER_YEAR() * market.WAD());
        assertGt(expectedInterest, 0);

        uint256 totalBorrowProjected = totalBorrowBefore + expectedInterest;
        assertGt(market.debtOf(borrower), 0); // sanity: borrower still has debt to project against

        // Capture totalBorrowShares *before* repay() mutates it -- interest
        // accrual never mints/burns borrow shares (only supply shares, via
        // the curator fee), so this value is unaffected by the warp.
        uint256 totalBorrowSharesBeforeRepay = market.totalBorrowShares();

        // A mutating call materializes the projection into storage exactly.
        // (Repaying pulls USDr from the borrower, who never needed an
        // approval before now -- borrow() only sends USDr out.)
        vm.startPrank(borrower);
        usdr.approve(address(market), type(uint256).max);
        market.repay(1); // trivial repay of 1 share to trigger accrual
        vm.stopPrank();

        // repay(1 share) also removes a tiny sliver of assets from the
        // total; account for that exactly via the identical virtual-share
        // ceil-division the contract uses (_toAssetsUp), rather than
        // re-approximating.
        uint256 oneShareAssets =
            _mulDivUp(1, totalBorrowProjected + market.VIRTUAL_ASSETS(), totalBorrowSharesBeforeRepay + market.VIRTUAL_SHARES());
        assertEq(market.totalBorrowAssets(), totalBorrowProjected - oneShareAssets);
        assertEq(market.totalSupplyAssets(), totalSupplyBefore + expectedInterest);
    }

    function test_InterestAccrual_FeeGoesToFeeRecipient() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 100_000 * 1e18);
        _borrow(borrower, 65_000 * 1e6);

        assertEq(market.supplyShares(feeRecipient), 0);

        vm.warp(block.timestamp + 365 days);

        // Trigger accrual via any state-changing call. (The lender's
        // original approval was fully consumed by their first supply().)
        vm.startPrank(lender);
        usdr.approve(address(market), 1);
        market.supply(1);
        vm.stopPrank();

        assertGt(market.supplyShares(feeRecipient), 0);
    }

    function test_InterestAccrual_NoOpWhenNoBorrows() public {
        _supply(lender, 100_000 * 1e6);
        uint256 totalBefore = market.totalSupplyAssets();

        vm.warp(block.timestamp + 365 days);

        assertEq(market.totalSupplyAssets(), totalBefore); // no borrows -> no interest
    }

    /// @dev Regression for the interest-forfeiture MED finding: when pending
    ///      interest truncates to zero (tiny market, 6-decimal token, ~1s
    ///      blocks), the accrual clock must NOT advance -- otherwise every
    ///      state-changing call forfeits the fraction and small markets earn
    ///      exactly 0% forever.
    function test_InterestAccrual_SubUnitInterestNotForfeited() public {
        _supply(lender, 100 * 1e6); // tiny market
        _supplyCollateral(borrower, 100 * 1e18);
        _borrow(borrower, 50 * 1e6); // ~7% rate -> well under 1 unit/sec

        uint256 t0 = market.lastAccrualTimestamp();

        // 1 second later: pending interest is < 1 unit -> clock must hold.
        vm.warp(block.timestamp + 1);
        vm.startPrank(lender);
        usdr.approve(address(market), 2);
        market.supply(1); // triggers _accrueInterest
        assertEq(market.lastAccrualTimestamp(), t0, "clock must not advance on zero interest");

        // Enough seconds accumulate for >= 1 unit -> accrues and advances.
        vm.warp(block.timestamp + 3600);
        market.supply(1);
        vm.stopPrank();
        assertGt(market.lastAccrualTimestamp(), t0, "clock advances once interest materializes");
        assertGt(market.totalBorrowAssets(), 50 * 1e6, "accumulated fraction was not forfeited");
    }

    /// @dev Regression for the supplyBalance fee-dilution HIGH finding: the
    ///      projection must equal the post-accrual claim EXACTLY, i.e. it
    ///      must account for the fee shares that accrual will mint.
    function test_SupplyBalance_ProjectsFeeDilutionExactly() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 100_000 * 1e18);
        _borrow(borrower, 65_000 * 1e6);

        vm.warp(block.timestamp + 365 days);

        uint256 projected = market.supplyBalance(lender);

        // Materialize accrual via a call that doesn't touch the supply side
        // (repay affects only borrow totals beyond the accrual itself).
        vm.startPrank(borrower);
        usdr.approve(address(market), type(uint256).max);
        market.repay(1);
        vm.stopPrank();

        assertEq(market.supplyBalance(lender), projected, "projection must match materialized claim exactly");
        // And the projection is genuinely net-of-fee: gross projection would
        // exceed the materialized claim whenever feeBps > 0.
        assertGt(market.supplyShares(feeRecipient), 0);
    }

    // -----------------------------------------------------------------
    // Liquidation
    // -----------------------------------------------------------------

    function test_Liquidate_RevertsIfHealthy() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6);

        // Compute the argument *before* arming expectRevert -- otherwise
        // Foundry's "next call" tracking catches this staticcall instead of
        // the actual liquidate() call, since Solidity evaluates call
        // arguments before making the call.
        uint256 shares = market.borrowShares(borrower);

        vm.startPrank(liquidator);
        usdr.approve(address(market), type(uint256).max);
        vm.expectRevert("position healthy");
        market.liquidate(borrower, shares);
        vm.stopPrank();
    }

    function test_Liquidate_SeizesCollateralWithBonus() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6);

        amfi.setNav(700_000); // $1.00 -> $0.70, pushes borrower underwater
        assertFalse(market.isHealthy(borrower));

        vm.startPrank(liquidator);
        usdr.approve(address(market), type(uint256).max);
        (uint256 repaid, uint256 seized) = market.liquidate(borrower, market.borrowShares(borrower));
        vm.stopPrank();

        assertEq(repaid, 30_000 * 1e6);
        // seizeValue = 30,000 * 1.05 = 31,500; seized = 31,500 / 0.70 = 45,000 mAMFI
        assertEq(seized, 45_000 * 1e18);
        assertEq(market.debtOf(borrower), 0);
        assertTrue(market.isHealthy(borrower));
        assertEq(amfi.balanceOf(liquidator), 45_000 * 1e18);
    }

    function test_Liquidate_CapsSeizureAtCollateralBalance() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6);

        // Extreme writedown: seizeValue/nav would exceed the borrower's entire collateral balance.
        amfi.setNav(100_000); // $0.10

        vm.startPrank(liquidator);
        usdr.approve(address(market), type(uint256).max);
        (, uint256 seized) = market.liquidate(borrower, market.borrowShares(borrower));
        vm.stopPrank();

        assertEq(seized, 50_000 * 1e18); // capped, not the uncapped ~315,000
        assertEq(market.collateralBalance(borrower), 0);
    }

    function test_Liquidate_PartialLiquidation() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6);
        amfi.setNav(700_000);

        uint256 halfShares = market.borrowShares(borrower) / 2;

        vm.startPrank(liquidator);
        usdr.approve(address(market), type(uint256).max);
        market.liquidate(borrower, halfShares);
        vm.stopPrank();

        assertGt(market.debtOf(borrower), 0); // still has remaining debt
        assertLt(market.debtOf(borrower), 30_000 * 1e6);
    }

    /// @dev Regression for the bad-debt HIGH finding: a rational liquidator
    ///      takes only the profitable slice (seizure capped at the whole
    ///      collateral balance) and leaves an unbacked rump that nobody
    ///      would ever repay. The market must write that rump off against
    ///      lenders immediately — and lenders must still be able to exit
    ///      afterwards (previously: perpetual "insufficient liquidity").
    function test_Liquidate_RealizesBadDebt() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6);

        amfi.setNav(100_000); // $0.10 -- collateral now worth 5,000, debt 30,000

        // Repay only half the shares: seizure (15,000 * 1.05 / 0.10 =
        // 157,500e18 uncapped) exhausts the whole 50,000e18 collateral,
        // leaving a 15,000e6 unbacked rump.
        uint256 halfShares = market.borrowShares(borrower) / 2;

        vm.startPrank(liquidator);
        usdr.approve(address(market), type(uint256).max);
        vm.expectEmit(true, true, true, true);
        emit LendingMarket.BadDebtRealized(borrower, 15_000 * 1e6, halfShares);
        market.liquidate(borrower, halfShares);
        vm.stopPrank();

        // Rump fully written off: no phantom debt left to accrue interest.
        assertEq(market.borrowShares(borrower), 0);
        assertEq(market.debtOf(borrower), 0);
        assertEq(market.totalBorrowAssets(), 0);
        assertEq(market.totalBorrowShares(), 0);
        // Loss socialized: 100,000 supplied - 15,000 bad debt.
        assertEq(market.totalSupplyAssets(), 85_000 * 1e6);

        // The lender can exit their ENTIRE position -- no first-out-wins
        // bank run against a stuck "insufficient liquidity" check.
        vm.startPrank(lender);
        uint256 recovered = market.withdraw(market.supplyShares(lender));
        vm.stopPrank();
        assertApproxEqAbs(recovered, 85_000 * 1e6, 1); // pro-rata loss, floor rounding
    }

    /// @dev Regression for audit finding M-01 (bad-debt dust bypass): a
    ///      liquidator who seizes all but a dust wei of collateral must STILL
    ///      trigger socialization. The branch keys on collateral VALUE (dust
    ///      rounds to zero), not raw balance — pre-fix, leaving 1 wei skipped
    ///      the write-off and left unbacked phantom debt that re-created the
    ///      first-out-wins bank run the mechanism exists to prevent.
    function test_Liquidate_DustCollateralStillSocializes() public {
        _supply(lender, 100_000 * 1e6);
        _supplyCollateral(borrower, 50_000 * 1e18);
        _borrow(borrower, 30_000 * 1e6);
        amfi.setNav(100_000); // $0.10 -- collateral worth 5,000 vs 30,000 debt

        // Choose repayShares to seize all but a dust wei (see M-01): the
        // remaining balance is nonzero but its value rounds to zero.
        uint256 fullColl = market.collateralBalance(borrower);
        uint256 nav = 100_000;
        uint256 repaidTarget = ((fullColl - 1) * nav) / (105 * 1e16); // divide by 1.05e18
        uint256 repayShares = (repaidTarget * (market.totalBorrowShares() + market.VIRTUAL_SHARES()))
            / (market.totalBorrowAssets() + market.VIRTUAL_ASSETS());

        vm.startPrank(liquidator);
        usdr.approve(address(market), type(uint256).max);
        market.liquidate(borrower, repayShares);
        vm.stopPrank();

        // Dust balance remains, but it is worth zero -> the rump was socialized.
        assertGt(market.collateralBalance(borrower), 0, "dust collateral remains (balance nonzero)");
        assertEq(market.collateralValue(borrower), 0, "dust is worth zero");
        assertEq(market.borrowShares(borrower), 0, "rump written off despite dust");
        assertEq(market.totalBorrowAssets(), 0, "no phantom debt left to accrue");

        // Lender can fully exit -- no first-out-wins bank run. (Read shares
        // before the prank: the staticcall would otherwise consume it, the
        // same Foundry next-call gotcha the other tests guard against.)
        uint256 lenderShares = market.supplyShares(lender);
        vm.prank(lender);
        uint256 recovered = market.withdraw(lenderShares);
        assertApproxEqAbs(recovered, 74_761_904_761, 2, "lender exits with principal minus socialized loss");
    }

    /// @dev Regression for the oracle-zero LOW finding: a zero NAV must
    ///      revert loudly instead of div-by-zero panicking in liquidate()
    ///      while health checks treat collateral as worthless.
    function test_OracleZeroNav_RevertsLoudly() public {
        ZeroNavOracle zeroOracle = new ZeroNavOracle();
        LendingMarket badMarket = new LendingMarket(
            address(usdr), address(amfi), address(zeroOracle), LLTV_BPS, BASE_RATE, SLOPE_RATE, FEE_BPS, feeRecipient
        );

        vm.startPrank(borrower);
        amfi.approve(address(badMarket), 10_000 * 1e18);
        badMarket.supplyCollateral(10_000 * 1e18); // no oracle read yet -- fine
        vm.expectRevert("invalid oracle price");
        badMarket.borrow(1);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Virtual shares / donation-attack resistance
    // -----------------------------------------------------------------

    function test_VirtualShares_ResistsDonationAttack() public {
        // Attacker deposits a tiny amount first, becoming the sole depositor.
        address attacker = makeAddr("attacker");
        usdr.transfer(attacker, 1_000 * 1e6);
        vm.startPrank(attacker);
        usdr.approve(address(market), 1_000 * 1e6);
        market.supply(1); // 1 unit
        vm.stopPrank();

        // Attacker then "donates" (direct transfer, not via supply()) a huge
        // amount directly to the market, trying to inflate the share price
        // so the next depositor's shares round down to zero.
        vm.prank(attacker);
        usdr.transfer(address(market), 999 * 1e6);

        // A genuine lender deposits — with virtual shares/assets, they must
        // still receive a nonzero number of shares (the classic ERC4626
        // inflation attack is neutralized).
        vm.startPrank(lender);
        usdr.approve(address(market), 10_000 * 1e6);
        uint256 shares = market.supply(10_000 * 1e6);
        vm.stopPrank();

        assertGt(shares, 0, "victim should not be rounded down to zero shares");
    }

    // -----------------------------------------------------------------
    // Admin
    // -----------------------------------------------------------------

    function test_SetFeeConfig_OnlyOwner() public {
        market.setFeeConfig(2_000, feeRecipient);
        assertEq(market.feeBps(), 2_000);

        vm.prank(lender);
        vm.expectRevert();
        market.setFeeConfig(1_000, lender);
    }

    function test_SetFeeConfig_RevertsAboveCapAndOnZeroRecipient() public {
        // Evaluate the argument BEFORE arming expectRevert (same Foundry
        // next-call gotcha as test_Liquidate_RevertsIfHealthy).
        uint256 tooHigh = market.MAX_FEE_BPS() + 1;
        vm.expectRevert("invalid fee");
        market.setFeeConfig(tooHigh, feeRecipient);

        vm.expectRevert("zero fee recipient");
        market.setFeeConfig(1_000, address(0));
    }

    // -----------------------------------------------------------------
    // Branch-coverage completion (post-review sweep)
    // -----------------------------------------------------------------

    /// @dev Covers the zero-value revert guard on every user entrypoint that
    ///      still lacked a negative test. All guards are the first statement
    ///      of their function, so no position setup is needed.
    function test_ZeroValueReverts_AllEntrypoints() public {
        vm.expectRevert("zero shares");
        market.withdraw(0);

        vm.expectRevert("zero assets");
        market.withdrawAssets(0);

        vm.expectRevert("zero amount");
        market.supplyCollateral(0);

        vm.expectRevert("zero amount");
        market.withdrawCollateral(0);

        vm.expectRevert("zero assets");
        market.borrow(0);

        vm.expectRevert("zero shares");
        market.repay(0);

        vm.expectRevert("zero shares");
        market.liquidate(borrower, 0);
    }

    /// @dev Covers the idle-market clock-advance branch of _accrueInterest:
    ///      with zero borrows nothing can accrue, but the accrual timestamp
    ///      must still move forward so a future first borrow doesn't accrue
    ///      retroactively over the idle window.
    function test_InterestAccrual_AdvancesClockWhenIdle() public {
        _supply(lender, 100_000 * 1e6); // no borrows exist
        uint256 t0 = market.lastAccrualTimestamp();

        vm.warp(block.timestamp + 30 days);
        _supply(lender, 1 * 1e6); // triggers _accrueInterest on an idle market

        assertGt(market.lastAccrualTimestamp(), t0, "clock must advance while idle");
        assertEq(market.totalSupplyAssets(), 100_001 * 1e6, "no interest may materialize");
    }

    /// @dev Covers the bad-debt clamp (`badDebtAssets > totalBorrowAssets`).
    ///      Reachable via share-ratio drift: repay() removes assets rounded UP
    ///      per share burned, so a 1-share repay on a tiny position removes a
    ///      full asset unit and pushes shares-per-asset above the initial 1e6.
    ///      From there, _toAssetsUp over the remaining shares can exceed the
    ///      remaining assets by 1, and without the clamp the socialization
    ///      write-off would underflow totalBorrowAssets.
    function test_Liquidate_BadDebtClampOnRoundingOvershoot() public {
        _supply(lender, 1_000 * 1e6);
        _supplyCollateral(borrower, 1e18); // value 1.00 USDr at NAV 1e6 -> maxBorrow 0.70 USDr
        _borrow(borrower, 3); // 3 base units -> 3e6 borrow shares (1e6 shares/unit)

        // Drift the ratio: burning 1 share removes ceil(1 * 4 / 4e6) = 1 full
        // asset unit -> A: 3 -> 2, S: 3e6 -> 3e6-1 (now > A * 1e6).
        vm.startPrank(borrower);
        usdr.approve(address(market), type(uint256).max);
        market.repay(1);
        vm.stopPrank();

        amfi.setNav(1); // crash NAV to the minimum -> position deeply unhealthy

        // Liquidate 1 share: seizes the entire 1e18 collateral (capped), the
        // remaining collateral value is 0, and the rump shares' ceil-valuation
        // (2) exceeds the remaining assets (1) -> clamp branch fires.
        vm.startPrank(liquidator);
        usdr.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 1);
        vm.stopPrank();

        // Clean zero-state proves the clamp prevented underflow and the rump
        // was fully written off.
        assertEq(market.totalBorrowAssets(), 0);
        assertEq(market.totalBorrowShares(), 0);
        assertEq(market.borrowShares(borrower), 0);
        assertEq(market.debtOf(borrower), 0);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _supply(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdr.approve(address(market), amount);
        shares = market.supply(amount);
        vm.stopPrank();
    }

    function _supplyCollateral(address who, uint256 amount) internal {
        vm.startPrank(who);
        amfi.approve(address(market), amount);
        market.supplyCollateral(amount);
        vm.stopPrank();
    }

    function _borrow(address who, uint256 amount) internal {
        vm.prank(who);
        market.borrow(amount);
    }

    /// @dev Mirrors LendingMarket's internal `_mulDivUp` so tests can assert
    ///      bit-exact expected values; the virtual-share constants themselves
    ///      are read from the contract (market.VIRTUAL_SHARES()/_ASSETS())
    ///      to avoid silent drift.
    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }
}

/// @dev Malicious/broken oracle used to prove the market's zero-NAV guard.
contract ZeroNavOracle {
    function navPerToken() external pure returns (uint256) {
        return 0;
    }
}
