// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {FinancingPool} from "../src/FinancingPool.sol";

/**
 * @title FinancingPoolTest
 * @notice Tests for the FinancingPool contract.
 *
 * WHAT WE TEST:
 * - Deployment: addresses stored correctly, roles granted
 * - fundInvoice: happy path, all negative paths
 * - repayInvoice: happy path, all negative paths
 * - markOverdue: happy path, before dueDate, wrong status
 * - markDefaulted: admin can, non-admin can't, wrong status
 *
 * NEW CHEATCODE: vm.warp()
 * vm.warp(timestamp) sets block.timestamp to any value.
 * Essential for testing time-dependent logic like markOverdue().
 *
 * TEST SETUP OVERVIEW:
 * - MockUSDC: deployed, investor + buyer get test tokens
 * - InvoiceRegistry: deployed with admin, verifier granted role
 * - FinancingPool: deployed, granted FINANCING_CONTRACT_ROLE in registry
 * - A verified invoice is set up in every test that needs it
 */
contract FinancingPoolTest is Test {
    // ============================================================
    //  STATE
    // ============================================================

    MockUSDC public usdc;
    InvoiceRegistry public registry;
    FinancingPool public pool;

    // Actors
    address public admin = makeAddr("admin");
    address public verifier = makeAddr("verifier");
    address public business = makeAddr("business");
    address public buyer = makeAddr("buyer");
    address public investor = makeAddr("investor");
    address public stranger = makeAddr("stranger");

    // Token amounts — all in MockUSDC units (6 decimals)
    uint256 public constant INVOICE_AMOUNT = 10_000 * 10 ** 6; // $10,000 face value
    uint256 public constant FINANCING_AMOUNT = 9_500 * 10 ** 6; // $9,500 investor pays
    uint256 public constant INVESTOR_BALANCE = 50_000 * 10 ** 6; // $50,000 test balance
    uint256 public constant BUYER_BALANCE = 50_000 * 10 ** 6; // $50,000 test balance

    // 30 days from now — the invoice due date
    uint256 public constant THIRTY_DAYS = 30 days;
    bytes32 public constant DOCUMENT_HASH = keccak256("invoice_001.pdf");

    // ============================================================
    //  SETUP
    // ============================================================

    /**
     * @notice Full system setup before every test.
     *
     * DEPLOYMENT ORDER (important):
     * 1. MockUSDC   — no dependencies
     * 2. InvoiceRegistry — no dependencies
     * 3. FinancingPool — needs registry + usdc addresses
     * 4. Grant FINANCING_CONTRACT_ROLE to pool in registry
     * 5. Mint test tokens to investor and buyer
     *
     * WHY GRANT ROLE AFTER DEPLOYMENT?
     * We need pool's address to grant the role.
     * We only know pool's address after deploying it.
     * So: deploy first, then grant.
     */
    function setUp() public {
        vm.startPrank(admin);

        // Deploy contracts
        usdc = new MockUSDC(admin);
        registry = new InvoiceRegistry(admin);
        pool = new FinancingPool(admin, address(registry), address(usdc));

        // Grant VERIFIER_ROLE to verifier
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);

        // Grant FINANCING_CONTRACT_ROLE to the pool contract address
        // Without this, pool.fundInvoice() would fail when calling
        // registry.updateInvoiceStatus() because pool lacks the role
        registry.grantRole(registry.FINANCING_CONTRACT_ROLE(), address(pool));

        // Mint test tokens
        usdc.mint(investor, INVESTOR_BALANCE);
        usdc.mint(buyer, BUYER_BALANCE);

        vm.stopPrank();
    }

    // ============================================================
    //  HELPER FUNCTIONS
    // ============================================================

    /**
     * @notice Create an invoice and verify it. Returns the invoice ID.
     * Used as setup for most tests.
     */
    function _createAndVerifyInvoice() internal returns (uint256 invoiceId) {
        // Business creates the invoice
        vm.prank(business);
        invoiceId = registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );

        // Verifier approves it
        vm.prank(verifier);
        registry.verifyInvoice(invoiceId);
    }

    /**
     * @notice Investor approves FinancingPool and funds the invoice.
     * Returns invoice ID for further assertions.
     *
     * Two transactions:
     * 1. investor → approve(pool, financingAmount) on MockUSDC
     * 2. investor → fundInvoice(id) on FinancingPool
     */
    function _investorFundsInvoice() internal returns (uint256 invoiceId) {
        invoiceId = _createAndVerifyInvoice();

        vm.startPrank(investor);
        usdc.approve(address(pool), FINANCING_AMOUNT);
        pool.fundInvoice(invoiceId);
        vm.stopPrank();
    }

    // ============================================================
    //  DEPLOYMENT TESTS
    // ============================================================

    /**
     * @notice FinancingPool stores the correct InvoiceRegistry address.
     */
    function test_deployment_storesCorrectRegistryAddress() public view {
        assertEq(pool.getInvoiceRegistry(), address(registry));
    }

    /**
     * @notice FinancingPool stores the correct stablecoin address.
     */
    function test_deployment_storesCorrectStablecoinAddress() public view {
        assertEq(pool.getStablecoin(), address(usdc));
    }

    /**
     * @notice FinancingPool has FINANCING_CONTRACT_ROLE in registry.
     *
     * WHAT THIS PROVES:
     * The setup correctly granted the role. Without this, every
     * fundInvoice call would fail at updateInvoiceStatus().
     */
    function test_deployment_poolHasFinancingContractRole() public view {
        assertTrue(
            registry.hasRole(registry.FINANCING_CONTRACT_ROLE(), address(pool))
        );
    }

    /**
     * @notice Admin is owner of FinancingPool.
     */
    function test_deployment_adminIsOwner() public view {
        assertEq(pool.owner(), admin);
    }

    /**
     * @notice Investor starts with correct MockUSDC balance.
     */
    function test_deployment_investorHasCorrectBalance() public view {
        assertEq(usdc.balanceOf(investor), INVESTOR_BALANCE);
    }

    // ============================================================
    //  fundInvoice — POSITIVE TESTS
    // ============================================================

    /**
     * @notice Investor can fund a verified invoice.
     *
     * WHAT THIS PROVES:
     * The complete funding flow works:
     *   1. MockUSDC transferred from investor to business
     *   2. Invoice status changed to FUNDED
     *   3. Investor address recorded in FinancingPool
     *
     * BALANCE CHANGES:
     *   investor: INVESTOR_BALANCE → INVESTOR_BALANCE - FINANCING_AMOUNT
     *   business: 0 → FINANCING_AMOUNT
     */
    function test_fundInvoice_happyPath_transfersTokensAndUpdatesStatus()
        public
    {
        uint256 id = _createAndVerifyInvoice();

        // Record balances BEFORE funding
        uint256 investorBalanceBefore = usdc.balanceOf(investor);
        uint256 businessBalanceBefore = usdc.balanceOf(business);

        // Investor approves and funds
        vm.startPrank(investor);
        usdc.approve(address(pool), FINANCING_AMOUNT);
        pool.fundInvoice(id);
        vm.stopPrank();

        // ---- Verify token balances ----
        assertEq(
            usdc.balanceOf(investor),
            investorBalanceBefore - FINANCING_AMOUNT,
            "Investor should have sent financingAmount"
        );
        assertEq(
            usdc.balanceOf(business),
            businessBalanceBefore + FINANCING_AMOUNT,
            "Business should have received financingAmount"
        );

        // ---- Verify invoice status ----
        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.FUNDED),
            "Invoice should be FUNDED"
        );

        // ---- Verify investor recorded ----
        assertEq(
            pool.getInvoiceInvestor(id),
            investor,
            "Investor should be recorded"
        );
    }

    /**
     * @notice fundInvoice emits InvoiceFunded event.
     *
     * WHAT THIS PROVES:
     * Frontend can listen to this event to update the investor's dashboard.
     */
    function test_fundInvoice_emitsInvoiceFundedEvent() public {
        uint256 id = _createAndVerifyInvoice();

        vm.startPrank(investor);
        usdc.approve(address(pool), FINANCING_AMOUNT);

        vm.expectEmit(true, true, true, true, address(pool));
        emit FinancingPool.InvoiceFunded(
            id,
            investor,
            business,
            FINANCING_AMOUNT
        );

        pool.fundInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Before funding, investor has no record in pool.
     *
     * WHAT THIS PROVES:
     * Default state of s_invoiceInvestor is address(0).
     */
    function test_fundInvoice_beforeFunding_investorIsZeroAddress() public {
        uint256 id = _createAndVerifyInvoice();
        assertEq(pool.getInvoiceInvestor(id), address(0));
    }

    // ============================================================
    //  fundInvoice — NEGATIVE TESTS
    // ============================================================

    /**
     * @notice Cannot fund an invoice that is still in CREATED state.
     *
     * WHAT THIS PROVES:
     * Unverified invoices are not eligible for financing.
     * The verification gate is enforced in FinancingPool, not just UI.
     */
    function test_fundInvoice_whenNotVerified_reverts() public {
        // Create invoice but do NOT verify it
        vm.prank(business);
        uint256 id = registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );

        vm.startPrank(investor);
        usdc.approve(address(pool), FINANCING_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__InvoiceNotVerified.selector,
                id,
                InvoiceRegistry.InvoiceStatus.CREATED
            )
        );
        pool.fundInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Cannot fund an invoice that is already funded.
     *
     * WHAT THIS PROVES:
     * Double-funding is prevented. This is the critical financial safety check.
     * Even if two investors submit fundInvoice() in the same block,
     * only one can succeed because:
     *   - First succeeds: s_invoiceInvestor[id] = investor1
     *   - Second fails: s_invoiceInvestor[id] != address(0)
     */
    function test_fundInvoice_whenAlreadyFunded_reverts() public {
        uint256 id = _investorFundsInvoice(); // investor funds it

        // A second investor tries to fund the same invoice
        address investor2 = makeAddr("investor2");
        vm.prank(admin);
        usdc.mint(investor2, INVESTOR_BALANCE);

        vm.startPrank(investor2);
        usdc.approve(address(pool), FINANCING_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__InvoiceAlreadyFunded.selector,
                id
            )
        );
        pool.fundInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Business cannot fund their own invoice.
     *
     * WHAT THIS PROVES:
     * Self-financing prevention. If business could fund their own invoice,
     * they'd just be moving their own tokens around — pointless.
     * More importantly, it could be a mechanism for laundering or fraud.
     */
    function test_fundInvoice_whenCalledByBusiness_reverts() public {
        uint256 id = _createAndVerifyInvoice();

        vm.prank(admin);
        usdc.mint(business, INVESTOR_BALANCE); // give business tokens

        vm.startPrank(business);
        usdc.approve(address(pool), FINANCING_AMOUNT);

        vm.expectRevert(
            FinancingPool.FinancingPool__BusinessCannotFundOwnInvoice.selector
        );
        pool.fundInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Buyer cannot act as investor on their own invoice.
     *
     * WHAT THIS PROVES:
     * If the buyer funded the invoice, they'd be paying themselves — circular.
     */
    function test_fundInvoice_whenCalledByBuyer_reverts() public {
        uint256 id = _createAndVerifyInvoice();

        // buyer already has BUYER_BALANCE from setUp
        vm.startPrank(buyer);
        usdc.approve(address(pool), FINANCING_AMOUNT);

        vm.expectRevert(
            FinancingPool.FinancingPool__BuyerCannotBeInvestor.selector
        );
        pool.fundInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Funding fails when investor has insufficient allowance.
     *
     * WHAT THIS PROVES:
     * The ERC-20 allowance check is enforced. SafeERC20.safeTransferFrom
     * reverts when allowance < financingAmount.
     * This is the most common user error in DeFi — forgetting to approve.
     */
    function test_fundInvoice_withInsufficientAllowance_reverts() public {
        uint256 id = _createAndVerifyInvoice();

        vm.startPrank(investor);
        // Approve less than required
        usdc.approve(address(pool), FINANCING_AMOUNT - 1);

        vm.expectRevert(); // ERC20InsufficientAllowance from OpenZeppelin
        pool.fundInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Funding fails when investor has no tokens (even with approval).
     *
     * WHAT THIS PROVES:
     * Balance check via SafeERC20. Approval alone isn't enough — you need tokens.
     *
     * NOTE: We create a fresh address with no tokens but with approval.
     */
    function test_fundInvoice_withInsufficientBalance_reverts() public {
        uint256 id = _createAndVerifyInvoice();

        // An address with approval but no tokens
        address brokeInvestor = makeAddr("brokeInvestor");

        vm.startPrank(brokeInvestor);
        usdc.approve(address(pool), FINANCING_AMOUNT);

        vm.expectRevert(); // ERC20InsufficientBalance
        pool.fundInvoice(id);
        vm.stopPrank();
    }

    // ============================================================
    //  repayInvoice — POSITIVE TESTS
    // ============================================================

    /**
     * @notice Buyer successfully repays a funded invoice.
     *
     * WHAT THIS PROVES:
     * The full repayment flow works:
     *   1. Buyer's MockUSDC transferred to investor (full face value)
     *   2. Invoice status = CLOSED
     *   3. Investor's balance increases by invoice.amount
     *
     * INVESTOR'S RETURN:
     *   Paid:     financingAmount ($9,500)
     *   Received: invoice.amount ($10,000)
     *   Profit:   $500 (≈ 5.26% return over 30 days)
     */
    function test_repayInvoice_happyPath_transfersTokensAndClosesInvoice()
        public
    {
        uint256 id = _investorFundsInvoice();

        // Record balances before repayment
        uint256 investorBalanceBefore = usdc.balanceOf(investor);
        uint256 buyerBalanceBefore = usdc.balanceOf(buyer);

        // Buyer approves and repays
        vm.startPrank(buyer);
        usdc.approve(address(pool), INVOICE_AMOUNT);
        pool.repayInvoice(id);
        vm.stopPrank();

        // ---- Verify token balances ----
        assertEq(
            usdc.balanceOf(buyer),
            buyerBalanceBefore - INVOICE_AMOUNT,
            "Buyer should have sent full invoice amount"
        );
        assertEq(
            usdc.balanceOf(investor),
            investorBalanceBefore + INVOICE_AMOUNT,
            "Investor should receive full invoice amount"
        );

        // ---- Verify invoice status is CLOSED ----
        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.CLOSED),
            "Invoice should be CLOSED after repayment"
        );
    }

    /**
     * @notice repayInvoice emits RepaymentReceived event.
     */
    function test_repayInvoice_emitsRepaymentReceivedEvent() public {
        uint256 id = _investorFundsInvoice();

        vm.startPrank(buyer);
        usdc.approve(address(pool), INVOICE_AMOUNT);

        vm.expectEmit(true, true, true, true, address(pool));
        emit FinancingPool.RepaymentReceived(
            id,
            buyer,
            investor,
            INVOICE_AMOUNT
        );

        pool.repayInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Investor's net profit is correct after repayment.
     *
     * WHAT THIS PROVES:
     * End-to-end balance accounting:
     *   Investor starts with INVESTOR_BALANCE
     *   Investor pays FINANCING_AMOUNT ($9,500)
     *   Investor receives INVOICE_AMOUNT ($10,000)
     *   Net change: +$500
     */
    function test_repayInvoice_investorNetProfit_isCorrect() public {
        uint256 investorStartBalance = usdc.balanceOf(investor);
        uint256 id = _investorFundsInvoice(); // investor pays $9,500

        vm.startPrank(buyer);
        usdc.approve(address(pool), INVOICE_AMOUNT);
        pool.repayInvoice(id); // investor receives $10,000
        vm.stopPrank();

        uint256 investorEndBalance = usdc.balanceOf(investor);
        uint256 netProfit = investorEndBalance - investorStartBalance;

        assertEq(
            netProfit,
            INVOICE_AMOUNT - FINANCING_AMOUNT,
            "Net profit should be $500"
        );
        console.log("Investor net profit ($):", netProfit / 10 ** 6);
    }

    // ============================================================
    //  repayInvoice — NEGATIVE TESTS
    // ============================================================

    /**
     * @notice Cannot repay an invoice that is not in FUNDED state.
     *
     * WHAT THIS PROVES:
     * You cannot repay a VERIFIED invoice that hasn't been funded yet.
     * State machine is enforced.
     */
    function test_repayInvoice_whenNotFunded_reverts() public {
        // Create and verify, but DON'T fund
        uint256 id = _createAndVerifyInvoice();

        vm.startPrank(buyer);
        usdc.approve(address(pool), INVOICE_AMOUNT);

        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__InvoiceNotFunded.selector,
                id,
                InvoiceRegistry.InvoiceStatus.VERIFIED
            )
        );
        pool.repayInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Stranger cannot repay someone else's invoice.
     *
     * WHAT THIS PROVES:
     * Only the registered buyer can repay. This prevents unauthorized
     * payments that could accidentally change invoice state.
     */
    function test_repayInvoice_byStranger_reverts() public {
        uint256 id = _investorFundsInvoice();

        vm.prank(admin);
        usdc.mint(stranger, INVOICE_AMOUNT); // give stranger tokens

        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__OnlyBuyerCanRepay.selector,
                stranger,
                buyer
            )
        );
        vm.prank(stranger);
        pool.repayInvoice(id);
    }

    /**
     * @notice Cannot repay with insufficient allowance.
     *
     * WHAT THIS PROVES:
     * Buyer must approve the full invoice.amount (not just financingAmount).
     * A common mistake: approving financingAmount instead of invoice.amount.
     */
    function test_repayInvoice_withInsufficientAllowance_reverts() public {
        uint256 id = _investorFundsInvoice();

        vm.startPrank(buyer);
        usdc.approve(address(pool), INVOICE_AMOUNT - 1); // 1 unit short

        vm.expectRevert();
        pool.repayInvoice(id);
        vm.stopPrank();
    }

    /**
     * @notice Cannot repay an already closed invoice (repaying twice).
     *
     * WHAT THIS PROVES:
     * CLOSED is a terminal state. Buyer cannot accidentally pay twice.
     */
    function test_repayInvoice_whenAlreadyClosed_reverts() public {
        uint256 id = _investorFundsInvoice();

        // First repayment — succeeds
        vm.startPrank(buyer);
        usdc.approve(address(pool), INVOICE_AMOUNT * 2); // approve enough for two
        pool.repayInvoice(id);

        // Second repayment — must fail
        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__InvoiceNotFunded.selector,
                id,
                InvoiceRegistry.InvoiceStatus.CLOSED
            )
        );
        pool.repayInvoice(id);
        vm.stopPrank();
    }

    // ============================================================
    //  markOverdue — TESTS
    // ============================================================

    /**
     * @notice Anyone can mark an invoice overdue after its dueDate.
     *
     * NEW CONCEPT: vm.warp()
     * vm.warp(timestamp) sets block.timestamp to any value in the test.
     * This is the ONLY way to test time-dependent logic in Foundry.
     * In production, time passes naturally — but in tests, we control it.
     *
     * WHAT THIS PROVES:
     * markOverdue is permissionless and works correctly when dueDate has passed.
     */
    function test_markOverdue_afterDueDate_succeeds() public {
        uint256 id = _investorFundsInvoice();

        // Jump time forward past the due date
        // Due date was block.timestamp + 30 days at creation
        // We warp to 31 days from now to be safely past it
        vm.warp(block.timestamp + 31 days);

        // Anyone can call this — stranger is fine
        vm.prank(stranger);
        pool.markOverdue(id);

        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.OVERDUE)
        );
    }

    /**
     * @notice Cannot mark overdue before dueDate.
     *
     * WHAT THIS PROVES:
     * Time check is enforced. You can't mark a $9,500 invoice as defaulted
     * the day after funding — the buyer has until the due date.
     */
    function test_markOverdue_beforeDueDate_reverts() public {
        uint256 id = _investorFundsInvoice();

        // Don't warp time — we're still before the due date
        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);

        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__DueDateNotPassed.selector,
                invoice.dueDate,
                block.timestamp
            )
        );
        pool.markOverdue(id);
    }

    /**
     * @notice Cannot mark an unverified or closed invoice as overdue.
     *
     * WHAT THIS PROVES:
     * markOverdue only applies to FUNDED invoices. You can't skip states.
     */
    function test_markOverdue_whenNotFunded_reverts() public {
        // Create and verify but don't fund
        uint256 id = _createAndVerifyInvoice();

        vm.warp(block.timestamp + 31 days); // time has passed

        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__InvoiceNotFunded.selector,
                id,
                InvoiceRegistry.InvoiceStatus.VERIFIED
            )
        );
        pool.markOverdue(id);
    }

    /**
     * @notice markOverdue emits InvoiceMarkedOverdue event.
     */
    function test_markOverdue_emitsEvent() public {
        uint256 id = _investorFundsInvoice();
        vm.warp(block.timestamp + 31 days);

        vm.expectEmit(true, false, false, false, address(pool));
        emit FinancingPool.InvoiceMarkedOverdue(id);

        pool.markOverdue(id);
    }

    // ============================================================
    //  markDefaulted — TESTS
    // ============================================================

    /**
     * @notice Admin can mark an overdue invoice as defaulted.
     *
     * WHAT THIS PROVES:
     * The full default path works: FUNDED → OVERDUE → DEFAULTED.
     * This is the worst-case scenario — investor's money is at risk.
     */
    function test_markDefaulted_byAdmin_succeeds() public {
        uint256 id = _investorFundsInvoice();

        // First mark overdue
        vm.warp(block.timestamp + 31 days);
        pool.markOverdue(id); // anyone can call this

        // Then admin marks defaulted
        vm.prank(admin);
        pool.markDefaulted(id);

        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.DEFAULTED)
        );
    }

    /**
     * @notice Stranger cannot mark an invoice as defaulted.
     *
     * WHAT THIS PROVES:
     * markDefaulted is admin-only (Ownable). Default has serious consequences —
     * it must be a deliberate admin action, not something a random address can trigger.
     */
    function test_markDefaulted_byStranger_reverts() public {
        uint256 id = _investorFundsInvoice();
        vm.warp(block.timestamp + 31 days);
        pool.markOverdue(id);

        vm.expectRevert(); // OwnableUnauthorizedAccount
        vm.prank(stranger);
        pool.markDefaulted(id);
    }

    /**
     * @notice Cannot mark as defaulted if not yet overdue.
     *
     * WHAT THIS PROVES:
     * You can't skip directly from FUNDED to DEFAULTED.
     * The state machine requires FUNDED → OVERDUE → DEFAULTED.
     */
    function test_markDefaulted_whenNotOverdue_reverts() public {
        uint256 id = _investorFundsInvoice();

        // Don't mark overdue first
        vm.expectRevert(
            abi.encodeWithSelector(
                FinancingPool.FinancingPool__InvoiceNotOverdue.selector,
                id,
                InvoiceRegistry.InvoiceStatus.FUNDED
            )
        );
        vm.prank(admin);
        pool.markDefaulted(id);
    }

    /**
     * @notice markDefaulted emits InvoiceMarkedDefaulted event.
     */
    function test_markDefaulted_emitsEvent() public {
        uint256 id = _investorFundsInvoice();
        vm.warp(block.timestamp + 31 days);
        pool.markOverdue(id);

        vm.expectEmit(true, false, false, false, address(pool));
        emit FinancingPool.InvoiceMarkedDefaulted(id);

        vm.prank(admin);
        pool.markDefaulted(id);
    }

    // ============================================================
    //  FULL LIFECYCLE TESTS
    // ============================================================

    /**
     * @notice Happy path: complete invoice financing lifecycle.
     *
     * WHAT THIS PROVES:
     * The entire FinLedger workflow works end-to-end:
     * CREATED → VERIFIED → FUNDED → REPAID → CLOSED
     *
     * This is the "golden path" test. If this passes, the core
     * financial workflow is correct.
     */
    function test_fullLifecycle_happyPath() public {
        console.log("=== Full FinLedger Lifecycle Test ===");
        console.log("Invoice face value ($):", INVOICE_AMOUNT / 10 ** 6);
        console.log("Financing amount ($):", FINANCING_AMOUNT / 10 ** 6);

        // --- STEP 1: Create invoice ---
        vm.prank(business);
        uint256 id = registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
        assertEq(
            uint8(registry.getInvoice(id).status),
            uint8(InvoiceRegistry.InvoiceStatus.CREATED)
        );
        console.log("Step 1: Invoice CREATED with ID:", id);

        // --- STEP 2: Verify ---
        vm.prank(verifier);
        registry.verifyInvoice(id);
        assertEq(
            uint8(registry.getInvoice(id).status),
            uint8(InvoiceRegistry.InvoiceStatus.VERIFIED)
        );
        console.log("Step 2: Invoice VERIFIED");

        // --- STEP 3: Fund ---
        vm.startPrank(investor);
        usdc.approve(address(pool), FINANCING_AMOUNT);
        pool.fundInvoice(id);
        vm.stopPrank();
        assertEq(
            uint8(registry.getInvoice(id).status),
            uint8(InvoiceRegistry.InvoiceStatus.FUNDED)
        );
        assertEq(usdc.balanceOf(business), FINANCING_AMOUNT);
        console.log(
            "Step 3: Invoice FUNDED - business received $",
            usdc.balanceOf(business) / 10 ** 6
        );

        // --- STEP 4: Repay ---
        vm.startPrank(buyer);
        usdc.approve(address(pool), INVOICE_AMOUNT);
        pool.repayInvoice(id);
        vm.stopPrank();
        assertEq(
            uint8(registry.getInvoice(id).status),
            uint8(InvoiceRegistry.InvoiceStatus.CLOSED)
        );
        console.log(
            "Step 4: Invoice CLOSED - investor balance $",
            usdc.balanceOf(investor) / 10 ** 6
        );

        // Final balance check
        // Investor started at INVESTOR_BALANCE
        // Paid:     FINANCING_AMOUNT ($9,500)
        // Received: INVOICE_AMOUNT   ($10,000)
        // Expected end balance: INVESTOR_BALANCE - FINANCING_AMOUNT + INVOICE_AMOUNT
        uint256 expectedEndBalance = INVESTOR_BALANCE -
            FINANCING_AMOUNT +
            INVOICE_AMOUNT;
        assertEq(usdc.balanceOf(investor), expectedEndBalance);
        uint256 investorProfit = INVOICE_AMOUNT - FINANCING_AMOUNT;
        console.log("Investor profit ($):", investorProfit / 10 ** 6);
        assertEq(investorProfit, INVOICE_AMOUNT - FINANCING_AMOUNT);
    }

    /**
     * @notice Default lifecycle: FUNDED → OVERDUE → DEFAULTED
     *
     * WHAT THIS PROVES:
     * The default path works. Investor's balance does not recover —
     * blockchain records the default but cannot force real-world payment.
     */
    function test_fullLifecycle_defaultPath() public {
        uint256 id = _investorFundsInvoice();

        uint256 investorBalanceAfterFunding = usdc.balanceOf(investor);

        // Time passes — buyer doesn't repay
        vm.warp(block.timestamp + 31 days);
        pool.markOverdue(id);
        assertEq(
            uint8(registry.getInvoice(id).status),
            uint8(InvoiceRegistry.InvoiceStatus.OVERDUE)
        );

        // Admin marks defaulted
        vm.prank(admin);
        pool.markDefaulted(id);
        assertEq(
            uint8(registry.getInvoice(id).status),
            uint8(InvoiceRegistry.InvoiceStatus.DEFAULTED)
        );

        // Investor's balance is unchanged - no recovery on-chain
        assertEq(
            usdc.balanceOf(investor),
            investorBalanceAfterFunding,
            "Investor balance unchanged - blockchain cannot recover funds"
        );
        console.log(
            "Default recorded on-chain. Investor loses $",
            FINANCING_AMOUNT / 10 ** 6
        );
        console.log("Off-chain legal action required for recovery.");
    }

    // ============================================================
    //  GAS ANALYSIS
    // ============================================================

    /**
     * @notice Gas cost of the full funding flow.
     * Run: forge test --gas-report to see gas breakdown.
     */
    function test_gas_fundInvoice() public {
        uint256 id = _createAndVerifyInvoice();
        vm.startPrank(investor);
        usdc.approve(address(pool), FINANCING_AMOUNT);
        pool.fundInvoice(id);
        vm.stopPrank();
    }
}
