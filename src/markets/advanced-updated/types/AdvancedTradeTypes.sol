// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

/**
 * @title AdvancedTradeTypes
 * @notice Shared enums / structs / supply constants for AdvancedTrade Phase 1–2.
 * @dev Tokenomics: 20 : 1 : 1 of 22M — open / AT inventory seed / PlayerVault.
 *      Sell-side hard cap: 4M = 1M seeded + 3M expandable (≤ 20% of open float).
 * @custom:experimental Learn more at https://docs.highpotential.io/
 * @custom:security-contact security@islalabs.co
 */

/// @notice Position direction
enum Side {
    LONG,
    SHORT
}

/// @notice How a long was opened (affects close path; both are funding-eligible once escrowed)
enum LongOpenMode {
    USDC_IN, // swap USDC → player tokens into escrow
    TOKEN_DEPOSIT // deposit already-held player tokens into escrow (no swap)
}

/// @notice How a long is closed
enum LongCloseMode {
    SELL_TO_USDC, // sell escrowed tokens → USDC to user
    RETURN_TOKENS // return player tokens in kind
}

/// @notice Per-position ledger entry
struct Position {
    address owner;
    Side side;
    LongOpenMode longMode; // meaningful for LONG only
    uint256 size; // player-token notional (inventory sold for SHORT; escrowed for LONG)
    uint256 entryMark; // EMA mark at open (WAD)
    uint256 collateral; // USDC escrow remaining (shorts; longs may be 0 if TOKEN_DEPOSIT)
    uint256 saleProceeds; // USDC from inventory sell (SHORT only; position-committed)
    uint256 openedAt;
    bool open;
}

/// @notice Caller-supplied swap bounds (required ≠ 0 — sandwich protection)
struct SlippageBound {
    uint256 amountOutMin; // for sells of player tokens / buys for buyback
    uint256 deadline;
}

/// @notice Two-slope borrow curve params (APR in WAD, e.g. 0.05e18 = 5%)
struct BorrowCurve {
    uint256 r0;
    uint256 slope1;
    uint256 slope2;
    uint256 uKink; // utilization kink in WAD (e.g. 0.8e18)
}

/// @notice Margin / liquidation launch params (governed; placeholders pending simulation)
struct MarginParams {
    uint256 initialMarginWad; // e.g. 0.40e18
    uint256 maintenanceMarginWad; // e.g. 0.20e18
    uint256 liquidationBountyWad; // e.g. 0.05e18 of notional
    uint256 insuranceSliceWad; // e.g. 0.025e18 of notional
    uint256 maxCloseImpactWad; // e.g. 0.02e18 pool impact at open
    uint256 perAccountShortCapWad; // e.g. 0.10e18 of inventorySize
}

/// @notice Vault initialization payload (factory → BeaconProxy)
struct VaultInitParams {
    address playerToken;
    address collateral; // USDC
    address swapRouter; // HP / V4 router — wired later
    address fundingController; // address(0) until Phase 2
    address pbrTreasury; // borrow-fee share destination (Phase 1)
    address owner; // LifecycleTimelock / governance
    uint256 seededInventory; // typically SEEDED_INVENTORY
}

// --------------------------------------------
//  Supply constants (18-decimal token assumption)
// --------------------------------------------

// Total per-market supply (20 + 1 + 1)
uint256 constant TOTAL_SUPPLY = 22_000_000 ether;

// Open-market allocation (Doppler → V4)
uint256 constant OPEN_MARKET_SUPPLY = 20_000_000 ether;

// Protocol-seeded AdvancedTradeVault short inventory
uint256 constant SEEDED_INVENTORY = 1_000_000 ether;

// PlayerVault allocation (pre-seed / testing)
uint256 constant PLAYER_VAULT_SUPPLY = 1_000_000 ether;

// Max outstanding short OI / inventory size (1 + 3 expandable)
uint256 constant INVENTORY_HARD_CAP = 4_000_000 ether;

// Expandable headroom above seed (Phase 3 lending candidate)
uint256 constant INVENTORY_EXPANDABLE = 3_000_000 ether;

// Fixed-point scale
uint256 constant WAD = 1e18;
