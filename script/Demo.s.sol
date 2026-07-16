// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDr} from "../src/MockUSDr.sol";
import {MockAmFiCredit} from "../src/MockAmFiCredit.sol";
import {LendingMarket} from "../src/LendingMarket.sol";
import {CuratedCreditVault} from "../src/CuratedCreditVault.sol";

/// @title Demo
/// @notice Self-contained showcase: deploys the full stack, then walks
///         through the end-to-end story — lender deposits, curator
///         allocates, borrower posts AmFi collateral and draws USDr,
///         interest accrues, a NAV writedown pushes the position
///         underwater, a liquidator liquidates it, and the liquidator exits
///         via the issuer-redemption pool (no open secondary market for
///         AmFi tokens exists today — confirmed in project research, and
///         the correct simplification rather than a shortcut).
///
/// Usage:
///   anvil
///   forge script script/Demo.s.sol --rpc-url http://127.0.0.1:8545 --broadcast -vv
///
/// @dev Uses Anvil's well-known deterministic default private keys
///      (from the standard "test test test ... junk" mnemonic) to play
///      four roles: deployer/curator, lender, borrower, liquidator.
///      LOCAL DEMO ONLY — these keys are public knowledge; never fund an
///      address derived from them on a real network.
/// @dev State is held in storage (not threaded through locals) specifically
///      to avoid "stack too deep" — this script has more moving pieces than
///      a single function's 16 EVM stack slots comfortably hold.
contract Demo is Script {
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant LENDER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant BORROWER_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant LIQUIDATOR_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    uint256 constant USDR_TOTAL_SUPPLY = 1_000_000 * 1e6;
    uint256 constant AMFI_TOTAL_SUPPLY = 500_000 * 1e18;
    uint256 constant AMFI_INITIAL_NAV = 1_000_000; // $1.00 per mAMFI, 6-decimal terms

    uint256 constant LENDER_DEPOSIT = 100_000 * 1e6;
    uint256 constant VAULT_ALLOCATE_AMOUNT = 80_000 * 1e6;
    uint256 constant BORROWER_COLLATERAL = 50_000 * 1e18;
    uint256 constant BORROWER_BORROW_AMOUNT = 30_000 * 1e6;
    uint256 constant LIQUIDATOR_FUNDING = 50_000 * 1e6;

    uint256 constant NAV_AFTER_WRITEDOWN = 700_000; // $0.70 -- simulates credit deterioration

    // Market/vault parameters -- keep in sync with DeployCreditVault.s.sol.
    uint256 constant LIQUIDATION_LTV_BPS = 7_000; // 70%
    uint256 constant BASE_RATE_WAD_PER_YEAR = 0.02e18; // 2% APR at 0% utilization
    uint256 constant SLOPE_WAD_PER_YEAR = 0.10e18; // +10% APR at 100% utilization
    uint256 constant CURATOR_FEE_BPS = 1_500; // 15% of interest
    uint256 constant VAULT_ALLOCATION_CAP_BPS = 8_000; // 80%

    address deployer;
    address lender;
    address borrower;
    address liquidator;

    MockUSDr usdr;
    MockAmFiCredit amfi;
    LendingMarket market;
    CuratedCreditVault vault;

    uint256 seizedCollateral;
    uint256 repaidAssets;

    function run() external {
        deployer = vm.addr(DEPLOYER_KEY);
        lender = vm.addr(LENDER_KEY);
        borrower = vm.addr(BORROWER_KEY);
        liquidator = vm.addr(LIQUIDATOR_KEY);

        console.log("================================================================");
        console.log("  Rayls Curated Credit Vault -- end-to-end demo");
        console.log("================================================================");
        console.log("  deployer/curator:", deployer);
        console.log("  lender:          ", lender);
        console.log("  borrower:        ", borrower);
        console.log("  liquidator:      ", liquidator);
        console.log("");

        _deployAndFund();
        _lenderDeposits();
        _curatorAllocates();
        _borrowerBorrows();
        _showRateModel();
        _navWritedown();
        _liquidate();
        _redeemViaIssuer();
        _summary();
    }

    // ---------------------------------------------------------------------
    // Step 0: Deploy the stack and fund the demo actors
    // ---------------------------------------------------------------------
    function _deployAndFund() internal {
        console.log("=== Step 0: Deploy MockUSDr, MockAmFiCredit, LendingMarket, CuratedCreditVault ===");
        vm.startBroadcast(DEPLOYER_KEY);

        usdr = new MockUSDr(USDR_TOTAL_SUPPLY);
        amfi = new MockAmFiCredit(AMFI_TOTAL_SUPPLY, AMFI_INITIAL_NAV, address(usdr));
        market = new LendingMarket(
            address(usdr),
            address(amfi),
            address(amfi),
            LIQUIDATION_LTV_BPS,
            BASE_RATE_WAD_PER_YEAR,
            SLOPE_WAD_PER_YEAR,
            CURATOR_FEE_BPS,
            deployer
        );
        vault = new CuratedCreditVault(usdr, market, VAULT_ALLOCATION_CAP_BPS, "Curated AmFi Credit Vault", "cvAMFI");

        usdr.approve(address(amfi), 100_000 * 1e6);
        amfi.fundRedemptionPool(100_000 * 1e6);

        usdr.transfer(lender, LENDER_DEPOSIT);
        amfi.transfer(borrower, BORROWER_COLLATERAL);
        usdr.transfer(liquidator, LIQUIDATOR_FUNDING);

        vm.stopBroadcast();

        console.log("  MockUSDr:           ", address(usdr));
        console.log("  MockAmFiCredit:     ", address(amfi));
        console.log("  LendingMarket:      ", address(market));
        console.log("  CuratedCreditVault: ", address(vault));
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Step 1: Lender deposits USDr into the vault
    // ---------------------------------------------------------------------
    function _lenderDeposits() internal {
        console.log("=== Step 1: Lender deposits 100,000 mUSDr into the vault ===");
        vm.startBroadcast(LENDER_KEY);
        usdr.approve(address(vault), LENDER_DEPOSIT);
        uint256 shares = vault.deposit(LENDER_DEPOSIT, lender);
        vm.stopBroadcast();
        console.log("  Lender received vault shares:", shares);
        console.log("  Vault totalAssets:           ", vault.totalAssets());
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Step 2: Curator allocates vault liquidity into the lending market
    // ---------------------------------------------------------------------
    function _curatorAllocates() internal {
        console.log("=== Step 2: Curator allocates 80,000 mUSDr into the lending market ===");
        vm.startBroadcast(DEPLOYER_KEY);
        vault.allocate(VAULT_ALLOCATE_AMOUNT);
        vm.stopBroadcast();
        console.log("  Market totalSupplyAssets:", market.totalSupplyAssets());
        console.log("  Vault idle balance:      ", usdr.balanceOf(address(vault)));
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Step 3: Borrower posts AmFi collateral and draws USDr
    // ---------------------------------------------------------------------
    function _borrowerBorrows() internal {
        console.log("=== Step 3: Borrower posts 50,000 mAMFI collateral, borrows 30,000 mUSDr ===");
        vm.startBroadcast(BORROWER_KEY);
        amfi.approve(address(market), BORROWER_COLLATERAL);
        market.supplyCollateral(BORROWER_COLLATERAL);
        market.borrow(BORROWER_BORROW_AMOUNT);
        vm.stopBroadcast();
        console.log("  Borrower debt:            ", market.debtOf(borrower));
        console.log("  Borrower collateral value:", market.collateralValue(borrower));
        console.log("  Position healthy?         ", market.isHealthy(borrower));
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Step 4: Interest accrual mechanics (deterministic, not time-jumped)
    // ---------------------------------------------------------------------
    /// @dev Deliberately doesn't `vm.warp()` to fast-forward real interest:
    ///      that cheatcode only warps forge's *local* simulation, not the
    ///      real chain a broadcast transaction actually executes on --
    ///      irrelevant for a local demo, actively wrong on a real testnet
    ///      (you cannot rewrite a real chain's clock). Multi-day accrual is
    ///      proven properly in the unit tests via `vm.warp`, where there's
    ///      only ever one EVM and no broadcast-boundary divergence. Here we
    ///      just show the deterministic rate model this market is running.
    function _showRateModel() internal view {
        console.log("=== Step 4: Interest rate model (accrues in real time as the market runs) ===");
        console.log("  Current utilization (WAD):  ", market.utilizationWad());
        console.log("  Current borrow rate (WAD/yr):", market.borrowRateWadPerYear());
        console.log("  (2%% base + up to 10%% slope by utilization; borrowers pay this, lenders");
        console.log("   earn it minus the 15%% curator fee. Full multi-day accrual math is proven");
        console.log("   in the unit tests via vm.warp, where it's safe to fast-forward.)");
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Step 5: NAV writedown pushes the borrower underwater
    // ---------------------------------------------------------------------
    function _navWritedown() internal {
        console.log("=== Step 5: AmFi NAV writedown ($1.00 -> $0.70) -- credit deterioration in the underlying pool ===");
        vm.startBroadcast(DEPLOYER_KEY);
        amfi.setNav(NAV_AFTER_WRITEDOWN);
        vm.stopBroadcast();
        console.log("  Borrower debt (incl. accrued interest):", market.debtOf(borrower));
        console.log("  Borrower collateral value (new NAV):   ", market.collateralValue(borrower));
        console.log("  Position healthy?                      ", market.isHealthy(borrower));
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Step 6: Liquidator liquidates the position
    // ---------------------------------------------------------------------
    function _liquidate() internal {
        console.log("=== Step 6: Liquidator repays the debt and seizes collateral at a 5%% bonus ===");
        uint256 borrowerSharesBefore = market.borrowShares(borrower);

        vm.startBroadcast(LIQUIDATOR_KEY);
        usdr.approve(address(market), type(uint256).max);
        (repaidAssets, seizedCollateral) = market.liquidate(borrower, borrowerSharesBefore);
        vm.stopBroadcast();

        console.log("  Repaid (mUSDr):           ", repaidAssets);
        console.log("  Seized collateral (mAMFI):", seizedCollateral);
        console.log("  Borrower position healthy now?", market.isHealthy(borrower));
        console.log("  Borrower's remaining (un-seized) collateral:", market.collateralBalance(borrower));
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Step 7: Liquidator exits via issuer redemption, not an open market
    // ---------------------------------------------------------------------
    function _redeemViaIssuer() internal {
        console.log("=== Step 7: Liquidator redeems seized mAMFI via the issuer redemption pool ===");
        console.log("  (No live secondary market for AmFi tokens exists today -- issuer-redemption");
        console.log("   is the correct exit path, not a workaround. See project research notes.)");

        // Redeem the liquidator's actual, current on-chain mAMFI balance --
        // not the `seizedCollateral` value returned by the earlier
        // liquidate() broadcast. Those are two separately-broadcast
        // transactions; reading live state right before use is correct
        // practice regardless of *why* they might diverge (a stale
        // simulated value was one concrete cause caught during this build).
        uint256 liquidatorAmfiBalance = amfi.balanceOf(liquidator);
        console.log("  Liquidator's actual mAMFI balance to redeem:", liquidatorAmfiBalance);

        vm.startBroadcast(LIQUIDATOR_KEY);
        uint256 redeemedAssets = amfi.redeem(liquidatorAmfiBalance);
        vm.stopBroadcast();

        console.log("  mUSDr received from redemption:", redeemedAssets);
        console.log("");
    }

    // ---------------------------------------------------------------------
    // Summary
    // ---------------------------------------------------------------------
    function _summary() internal view {
        console.log("================================================================");
        console.log("  Summary");
        console.log("================================================================");
        console.log("  Liquidator started with (mUSDr):", LIQUIDATOR_FUNDING);
        console.log("  Spent repaying the debt (mUSDr):", repaidAssets);
        console.log("  Liquidator's final mUSDr balance:                  ", usdr.balanceOf(liquidator));
        console.log("  Vault totalAssets (lender's yield, still growing):", vault.totalAssets());
        console.log("  Curator (deployer) accrued fee shares in the market:", market.supplyShares(deployer));
    }
}
