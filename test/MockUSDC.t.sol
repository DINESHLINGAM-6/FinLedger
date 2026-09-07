// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";

/**
 * @title MockUSDCTest
 * @notice Tests for the MockUSDC contract.
 *
 * HOW FOUNDRY TESTS WORK:
 * - Every contract that inherits from `Test` is a test suite.
 * - Every function starting with `test` is run as a test.
 * - Functions starting with `testFail` expect the call to revert.
 * - `setUp()` runs before every single test function.
 *
 * WHAT IS `Test`?
 * `forge-std/Test.sol` is Foundry's testing library. It gives us:
 *   - `vm` — a special cheatcode object (explained below)
 *   - `assertEq`, `assertGt`, `assertTrue` — assertion helpers
 *   - `console.log` — for debugging output
 *
 * WHAT IS `vm`?
 * `vm` is a cheatcode contract that lets us manipulate the EVM
 * during tests. For example:
 *   vm.prank(alice)  — makes the next call come from alice's address
 *   vm.deal(alice, 1 ether) — gives alice ETH
 *   vm.expectRevert() — asserts the next call reverts
 *
 * This is ONLY available in tests — never in production contracts.
 */
contract MockUSDCTest is Test {
    // ============================================================
    //  STATE VARIABLES
    // ============================================================

    MockUSDC public usdc;

    // Test addresses — these are fake wallets for our tests
    // `makeAddr()` creates a deterministic address from a string label
    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice"); // represents an investor
    address public bob = makeAddr("bob");     // represents a business

    // A convenient constant — $100 in MockUSDC (6 decimals)
    // $100 = 100 * 10^6 = 100_000_000
    uint256 public constant ONE_HUNDRED_USDC = 100 * 10 ** 6;

    // ============================================================
    //  SETUP
    // ============================================================

    /**
     * @notice Runs before every test function.
     *
     * WHY vm.prank(owner)?
     * The MockUSDC constructor calls Ownable(initialOwner).
     * When we deploy from `owner`, the contract's owner becomes `owner`.
     * Without prank, the deployer would be the test contract itself (address(this)).
     */
    function setUp() public {
        vm.prank(owner);
        usdc = new MockUSDC(owner);
    }

    // ============================================================
    //  DEPLOYMENT TESTS
    // ============================================================

    /**
     * @notice Verifies the token was deployed with correct metadata.
     *
     * WHAT THIS PROVES:
     * - The name and symbol match what we defined in the constructor
     * - The decimals are 6 (not 18)
     * - Initial total supply is zero (no tokens minted at deploy)
     */
    function test_deployment_hasCorrectMetadata() public view {
        assertEq(usdc.name(), "Mock USDC");
        assertEq(usdc.symbol(), "mUSDC");
        assertEq(usdc.decimals(), 6);
        assertEq(usdc.totalSupply(), 0);
    }

    /**
     * @notice Verifies the deployer is set as owner.
     *
     * WHAT THIS PROVES:
     * - OpenZeppelin's Ownable correctly stored our initialOwner.
     */
    function test_deployment_ownerIsSetCorrectly() public view {
        assertEq(usdc.owner(), owner);
    }

    // ============================================================
    //  MINTING TESTS
    // ============================================================

    /**
     * @notice Owner can mint tokens to any address.
     *
     * WHAT THIS PROVES:
     * - After mint(), the recipient's balance increases
     * - totalSupply increases by the same amount
     * - The TokensMinted event is emitted
     *
     * HOW vm.prank WORKS:
     * vm.prank(owner) sets msg.sender to `owner` for exactly ONE call.
     * After that one call, msg.sender reverts back to the test contract.
     */
    function test_mint_ownerCanMintToAnyAddress() public {
        // Tell the EVM: next call comes from `owner`
        vm.prank(owner);

        // We expect the TokensMinted event to be emitted
        // Arguments: (checkTopic1, checkTopic2, checkTopic3, checkData)
        // true = check this argument matches
        vm.expectEmit(true, false, false, true, address(usdc));
        emit MockUSDC.TokensMinted(alice, ONE_HUNDRED_USDC);

        usdc.mint(alice, ONE_HUNDRED_USDC);

        assertEq(usdc.balanceOf(alice), ONE_HUNDRED_USDC);
        assertEq(usdc.totalSupply(), ONE_HUNDRED_USDC);
    }

    /**
     * @notice Owner can mint to multiple addresses.
     *
     * WHAT THIS PROVES:
     * - Multiple mint calls accumulate correctly
     * - totalSupply equals the sum of all minted amounts
     *
     * WHY vm.startPrank / vm.stopPrank?
     * When we need multiple consecutive calls from the same address,
     * vm.startPrank() keeps that address active until vm.stopPrank() is called.
     * This is cleaner than calling vm.prank() before every single line.
     */
    function test_mint_canMintToMultipleAddresses() public {
        vm.startPrank(owner);
        usdc.mint(alice, ONE_HUNDRED_USDC);
        usdc.mint(bob, ONE_HUNDRED_USDC * 2);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), ONE_HUNDRED_USDC);
        assertEq(usdc.balanceOf(bob), ONE_HUNDRED_USDC * 2);
        assertEq(usdc.totalSupply(), ONE_HUNDRED_USDC * 3);
    }

    /**
     * @notice Non-owner cannot mint tokens.
     *
     * WHAT THIS PROVES:
     * - Unauthorized callers are blocked by OpenZeppelin's Ownable
     * - The revert reason is OwnableUnauthorizedAccount (OZ custom error)
     *
     * HOW vm.expectRevert WORKS:
     * Placed before a call, it tells Foundry: "the next call MUST revert".
     * If it doesn't revert, the TEST fails.
     * We can also specify the exact revert reason to be more precise.
     */
    function test_mint_revertsWhenCalledByNonOwner() public {
        vm.prank(alice); // alice is NOT the owner

        vm.expectRevert(
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice)
        );
        usdc.mint(alice, ONE_HUNDRED_USDC);
    }

    /**
     * @notice Minting zero amount reverts with our custom error.
     *
     * WHAT THIS PROVES:
     * - Our custom error MockUSDC__ZeroMintAmount works correctly
     * - Zero-amount mints are blocked before anything executes
     *
     * WHY TEST ZERO AMOUNTS?
     * If we forget this guard, someone could call mint(alice, 0) and
     * emit a misleading TokensMinted event with amount 0. No real harm
     * here, but building the habit of defensive coding matters.
     */
    function test_mint_revertsOnZeroAmount() public {
        vm.prank(owner);
        vm.expectRevert(MockUSDC.MockUSDC__ZeroMintAmount.selector);
        usdc.mint(alice, 0);
    }

    // ============================================================
    //  ERC-20 TRANSFER TESTS
    // ============================================================

    /**
     * @notice Basic token transfer between addresses.
     *
     * WHAT THIS PROVES:
     * - transfer() moves tokens from sender to recipient
     * - Sender's balance decreases, recipient's increases
     * - totalSupply is unchanged (transfers don't create or destroy)
     */
    function test_transfer_movesTokensBetweenAccounts() public {
        // First give alice some tokens
        vm.prank(owner);
        usdc.mint(alice, ONE_HUNDRED_USDC);

        uint256 transferAmount = 30 * 10 ** 6; // $30

        vm.prank(alice);
        usdc.transfer(bob, transferAmount);

        assertEq(usdc.balanceOf(alice), ONE_HUNDRED_USDC - transferAmount);
        assertEq(usdc.balanceOf(bob), transferAmount);
        assertEq(usdc.totalSupply(), ONE_HUNDRED_USDC); // unchanged
    }

    /**
     * @notice Transfer reverts when sender has insufficient balance.
     *
     * WHAT THIS PROVES:
     * - ERC-20 standard enforces balance checks
     * - No transfer of tokens you don't have
     */
    function test_transfer_revertsWhenInsufficientBalance() public {
        // alice has 0 tokens — any transfer should revert
        vm.prank(alice);
        vm.expectRevert();
        usdc.transfer(bob, ONE_HUNDRED_USDC);
    }

    // ============================================================
    //  ERC-20 APPROVE / TRANSFERFROM TESTS
    // ============================================================

    /**
     * @notice approve() sets an allowance for a spender.
     *
     * WHAT THIS PROVES:
     * - After approve(), the spender has an allowance recorded on-chain
     * - allowance() correctly returns that amount
     *
     * WHY IS APPROVE IMPORTANT FOR FINLEDGER?
     * When an investor funds an invoice, they don't call transfer() directly.
     * Instead:
     *   1. Investor calls approve(FinancingPool, amount) on MockUSDC
     *   2. Investor calls fundInvoice() on FinancingPool
     *   3. FinancingPool calls transferFrom(investor, business, amount)
     *
     * This two-step pattern lets a smart contract move tokens on behalf
     * of a user, but ONLY up to the approved amount. The user stays in control.
     */
    function test_approve_setsAllowanceForSpender() public {
        vm.prank(owner);
        usdc.mint(alice, ONE_HUNDRED_USDC);

        vm.prank(alice);
        usdc.approve(bob, ONE_HUNDRED_USDC);

        // allowance(owner, spender) — how much can bob spend of alice's tokens?
        assertEq(usdc.allowance(alice, bob), ONE_HUNDRED_USDC);
    }

    /**
     * @notice transferFrom() moves tokens using a pre-set allowance.
     *
     * WHAT THIS PROVES:
     * - A spender can move tokens up to the approved amount
     * - Allowance decreases after transferFrom
     * - Balances update correctly
     *
     * IN FINLEDGER:
     * bob here represents the FinancingPool smart contract.
     * alice represents the investor.
     * The FinancingPool calls transferFrom(alice, business, amount).
     */
    function test_transferFrom_spenderCanMoveApprovedTokens() public {
        vm.prank(owner);
        usdc.mint(alice, ONE_HUNDRED_USDC);

        // Alice approves bob (simulate: investor approves FinancingPool)
        vm.prank(alice);
        usdc.approve(bob, ONE_HUNDRED_USDC);

        uint256 transferAmount = 60 * 10 ** 6; // $60

        // Bob moves alice's tokens to himself (simulate: FinancingPool pulls funds)
        vm.prank(bob);
        usdc.transferFrom(alice, bob, transferAmount);

        assertEq(usdc.balanceOf(alice), ONE_HUNDRED_USDC - transferAmount);
        assertEq(usdc.balanceOf(bob), transferAmount);
        // Allowance reduced by the amount spent
        assertEq(usdc.allowance(alice, bob), ONE_HUNDRED_USDC - transferAmount);
    }

    /**
     * @notice transferFrom() reverts when spender exceeds allowance.
     *
     * WHAT THIS PROVES:
     * - You can't spend more than you've been approved to spend
     * - This is the key safety mechanism in the approve/transferFrom pattern
     *
     * IN FINLEDGER:
     * This prevents a malicious FinancingPool from draining more than the
     * investor approved. The investor's approve() acts as an upper bound.
     */
    function test_transferFrom_revertsWhenExceedingAllowance() public {
        vm.prank(owner);
        usdc.mint(alice, ONE_HUNDRED_USDC);

        vm.prank(alice);
        usdc.approve(bob, 50 * 10 ** 6); // Approve only $50

        vm.prank(bob);
        vm.expectRevert(); // Trying to spend $100 when only $50 approved
        usdc.transferFrom(alice, bob, ONE_HUNDRED_USDC);
    }

    // ============================================================
    //  DECIMAL PRECISION TEST
    // ============================================================

    /**
     * @notice Demonstrates decimal precision — important for FinLedger amounts.
     *
     * WHAT THIS PROVES:
     * - 6 decimals means $1 = 1_000_000 (one million smallest units)
     * - This is the same unit system as real USDC
     * - Amounts in tests must account for this
     *
     * WHY THIS MATTERS:
     * If you write `amount = 10000` thinking that's $10,000, you're wrong.
     * That would be $0.01 (10,000 / 10^6 = 0.01 USDC).
     * The real value is: $10,000 = 10_000 * 10^6 = 10_000_000_000
     */
    function test_decimals_understandingUSDCPrecision() public {
        uint256 ONE_DOLLAR = 1 * 10 ** 6;          // 1_000_000
        uint256 TEN_THOUSAND_DOLLARS = 10_000 * 10 ** 6; // 10_000_000_000

        vm.prank(owner);
        usdc.mint(alice, TEN_THOUSAND_DOLLARS);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND_DOLLARS);
        assertEq(usdc.decimals(), 6);

        // $10,000 / $1 = 10,000 — sanity check
        assertEq(TEN_THOUSAND_DOLLARS / ONE_DOLLAR, 10_000);

        console.log("Alice balance (raw):", usdc.balanceOf(alice));
        console.log("Alice balance ($):", usdc.balanceOf(alice) / 10 ** 6);
    }
}
