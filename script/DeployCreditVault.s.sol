// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDr} from "../src/MockUSDr.sol";
import {MockAmFiCredit} from "../src/MockAmFiCredit.sol";
import {LendingMarket} from "../src/LendingMarket.sol";
import {CuratedCreditVault} from "../src/CuratedCreditVault.sol";

/// @title DeployCreditVault
/// @notice Deploys the full local PoC stack: MockUSDr, MockAmFiCredit,
///         LendingMarket, and CuratedCreditVault, wired together with
///         illustrative demo parameters. No dependency on Rayls bridge
///         infrastructure (Endpoint/RNEndpoint/RNUserGovernance) — this
///         deploys cleanly on vanilla Anvil. To target real deployed tokens
///         (real USDr / the real AmFi mirror token on Rayls), edit this
///         script to skip the mock deployments and pass those addresses to
///         the LendingMarket/CuratedCreditVault constructors instead.
///
/// Usage (local Anvil):
///   anvil
///   forge script script/DeployCreditVault.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployCreditVault is Script {
    // Demo parameters — illustrative, not tuned for production.
    uint256 constant USDR_INITIAL_SUPPLY = 1_000_000 * 1e6; // 1,000,000 mUSDr (6 decimals)
    uint256 constant AMFI_INITIAL_SUPPLY = 500_000 * 1e18; // 500,000 mAMFI (18 decimals)
    uint256 constant AMFI_INITIAL_NAV = 1_000_000; // 1.00 mUSDr per whole mAMFI token (6-decimal terms)

    uint256 constant LIQUIDATION_LTV_BPS = 7_000; // 70%
    uint256 constant BASE_RATE_WAD_PER_YEAR = 0.02e18; // 2% APR at 0% utilization
    uint256 constant SLOPE_WAD_PER_YEAR = 0.10e18; // +10% APR at 100% utilization (12% max)
    uint256 constant CURATOR_FEE_BPS = 1_500; // 15% of interest — matches Steakhouse's real curator fee (research: DefiLlama)

    uint256 constant VAULT_ALLOCATION_CAP_BPS = 8_000; // 80% deployed into the market, 20% kept idle for withdrawals

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        MockUSDr usdr = new MockUSDr(USDR_INITIAL_SUPPLY);
        MockAmFiCredit amfi = new MockAmFiCredit(AMFI_INITIAL_SUPPLY, AMFI_INITIAL_NAV, address(usdr));

        LendingMarket market = new LendingMarket(
            address(usdr),
            address(amfi),
            address(amfi), // MockAmFiCredit itself implements INavOracle.navPerToken()
            LIQUIDATION_LTV_BPS,
            BASE_RATE_WAD_PER_YEAR,
            SLOPE_WAD_PER_YEAR,
            CURATOR_FEE_BPS,
            deployer // fee recipient = deployer for the demo
        );

        // Guard the NAV unit-coupling invariant (audit L-03): the collateral
        // oracle's redemption/quote asset MUST equal the market's loan token,
        // or every health check silently mis-scales. Always true when the
        // mocks are wired as below; this catches a future edit that points at
        // real addresses and mismatches them.
        require(
            address(amfi.redemptionAsset()) == address(market.loanToken()),
            "oracle quote asset != loan token"
        );

        CuratedCreditVault vault = new CuratedCreditVault(
            usdr,
            market,
            VAULT_ALLOCATION_CAP_BPS,
            "Curated AmFi Credit Vault",
            "cvAMFI"
        );

        // Seed the AmFi redemption pool so the liquidation demo can actually
        // close the loop (liquidator seizes mAMFI -> redeems for mUSDr).
        usdr.approve(address(amfi), 100_000 * 1e6);
        amfi.fundRedemptionPool(100_000 * 1e6);

        vm.stopBroadcast();

        console.log("=== Deployed ===");
        console.log("  MockUSDr:            ", address(usdr));
        console.log("  MockAmFiCredit:      ", address(amfi));
        console.log("  LendingMarket:       ", address(market));
        console.log("  CuratedCreditVault:  ", address(vault));
        console.log("");
        console.log("=== Demo parameters ===");
        console.log("  Liquidation LTV:     70%%");
        console.log("  Borrow rate:         2%% base + up to 10%% slope (12%% at 100%% utilization)");
        console.log("  Curator fee:         15%% of interest");
        console.log("  Vault allocation cap: 80%%");
        console.log("  AmFi redemption pool: 100,000 mUSDr seeded");
        console.log("");
        console.log("Deployer / initial holder of all mUSDr + mAMFI supply:", deployer);
    }
}
