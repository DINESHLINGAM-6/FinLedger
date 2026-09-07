// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";

/**
 * @title InvoiceRegistryTest
 * @notice Complete test suite for InvoiceRegistry.
 *
 * TEST STRUCTURE:
 * We group tests by function and scenario:
 *   - Deployment (roles assigned correctly)
 *   - createInvoice (positive + all negative paths)
 *   - cancelInvoice (positive + all negative paths)
 *   - verifyInvoice (positive + all negative paths)
 *   - View functions
 *
 * NAMING CONVENTION:
 *   test_[function]_[scenario]_[expected outcome]
 *   Example: test_createInvoice_withZeroAmount_reverts
 *
 * This convention makes test output self-documenting — when a test fails
 * you immediately know what broke without reading the test body.
 */
contract InvoiceRegistryTest is Test {
    // ============================================================
    //  STATE
    // ============================================================

    InvoiceRegistry public registry;

    // Test actors — each represents a participant in FinLedger
    address public admin = makeAddr("admin"); // deploys, manages roles
    address public verifier = makeAddr("verifier"); // approves invoices
    address public business = makeAddr("business"); // creates invoices
    address public buyer = makeAddr("buyer"); // repays invoices
    address public stranger = makeAddr("stranger"); // unauthorized actor

    // Reusable valid invoice parameters
    // These match what a real invoice might contain (in MockUSDC units)
    uint256 public constant INVOICE_AMOUNT = 10_000 * 10 ** 6; // $10,000
    uint256 public constant FINANCING_AMOUNT = 9_500 * 10 ** 6; // $9,500 (5% discount)
    uint256 public constant THIRTY_DAYS = 30 days;

    // A fake document hash — in real usage this would be keccak256(pdf bytes)
    bytes32 public constant DOCUMENT_HASH =
        keccak256("invoice_document_2024_001.pdf");

    // ============================================================
    //  SETUP
    // ============================================================

    /**
     * @notice Runs before every test.
     *
     * Setup:
     * 1. Deploy InvoiceRegistry with admin as the initial admin
     * 2. Grant VERIFIER_ROLE to the separate verifier address
     *    (admin already has it from constructor, but using a separate
     *    verifier is more realistic)
     */
    function setUp() public {
        // Use startPrank/stopPrank to make BOTH calls (deploy + grantRole)
        // come from admin's address. vm.prank() only applies to one call.
        vm.startPrank(admin);
        registry = new InvoiceRegistry(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), verifier);
        vm.stopPrank();
    }

    // ============================================================
    //  HELPER FUNCTIONS
    // ============================================================

    /**
     * @notice Helper: create a valid invoice as `business` and return its ID.
     * Used in multiple tests to set up state before testing other functions.
     */
    function _createValidInvoice() internal returns (uint256 invoiceId) {
        vm.prank(business);
        invoiceId = registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
    }

    // ============================================================
    //  DEPLOYMENT TESTS
    // ============================================================

    /**
     * @notice Admin has DEFAULT_ADMIN_ROLE after deployment.
     *
     * WHAT THIS PROVES:
     * The constructor correctly set up the admin role.
     * Without this, admin couldn't grant/revoke roles.
     */
    function test_deployment_adminHasAdminRole() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
    }

    /**
     * @notice Admin also has VERIFIER_ROLE after deployment.
     *
     * WHAT THIS PROVES:
     * The constructor grants both roles to admin so we can test
     * verification without deploying a separate verifier address.
     */
    function test_deployment_adminHasVerifierRole() public view {
        assertTrue(registry.hasRole(registry.VERIFIER_ROLE(), admin));
    }

    /**
     * @notice Verifier address has VERIFIER_ROLE after grantRole.
     *
     * WHAT THIS PROVES:
     * The setUp() grantRole call works — the verifier address is now authorized.
     */
    function test_deployment_verifierHasVerifierRole() public view {
        assertTrue(registry.hasRole(registry.VERIFIER_ROLE(), verifier));
    }

    /**
     * @notice Stranger has no roles.
     *
     * WHAT THIS PROVES:
     * Addresses not explicitly granted roles have no permissions.
     * This is the default in AccessControl — deny by default.
     */
    function test_deployment_strangerHasNoRoles() public view {
        assertFalse(registry.hasRole(registry.VERIFIER_ROLE(), stranger));
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), stranger));
    }

    /**
     * @notice Total invoices starts at zero.
     */
    function test_deployment_initialInvoiceCountIsZero() public view {
        assertEq(registry.getTotalInvoices(), 0);
    }

    // ============================================================
    //  createInvoice — POSITIVE TESTS
    // ============================================================

    /**
     * @notice Successfully creates an invoice with valid parameters.
     *
     * WHAT THIS PROVES:
     * The happy path works. All fields are stored correctly on-chain.
     * We verify every field of the returned Invoice struct.
     */
    function test_createInvoice_withValidParams_storesCorrectly() public {
        uint256 dueDate = block.timestamp + THIRTY_DAYS;

        vm.prank(business);
        uint256 invoiceId = registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            dueDate,
            DOCUMENT_HASH
        );

        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(invoiceId);

        assertEq(invoice.id, 0); // first invoice = ID 0
        assertEq(invoice.business, business); // msg.sender stored
        assertEq(invoice.buyer, buyer);
        assertEq(invoice.amount, INVOICE_AMOUNT);
        assertEq(invoice.financingAmount, FINANCING_AMOUNT);
        assertEq(invoice.issuedAt, block.timestamp);
        assertEq(invoice.dueDate, dueDate);
        assertEq(invoice.documentHash, DOCUMENT_HASH);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.CREATED)
        );
    }

    /**
     * @notice Invoice IDs increment correctly with multiple invoices.
     *
     * WHAT THIS PROVES:
     * s_nextInvoiceId increments properly.
     * Multiple businesses can create invoices independently.
     */
    function test_createInvoice_multipleInvoices_idsIncrementSequentially()
        public
    {
        address business2 = makeAddr("business2");

        uint256 id0 = _createValidInvoice();

        vm.prank(business2);
        uint256 id1 = registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );

        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(registry.getTotalInvoices(), 2);
    }

    /**
     * @notice createInvoice emits InvoiceCreated event with correct args.
     *
     * WHAT THIS PROVES:
     * The event is emitted with the right data. The frontend and backend
     * rely on this event to know a new invoice was registered.
     *
     * HOW vm.expectEmit WORKS:
     * Arguments: (checkTopic1, checkTopic2, checkTopic3, checkData, emitterAddress)
     * We set all to true — meaning ALL event fields must match exactly.
     */
    function test_createInvoice_emitsInvoiceCreatedEvent() public {
        uint256 dueDate = block.timestamp + THIRTY_DAYS;

        vm.expectEmit(true, true, true, true, address(registry));
        emit InvoiceRegistry.InvoiceCreated(
            0, // first invoice ID = 0
            business,
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            dueDate,
            DOCUMENT_HASH
        );

        vm.prank(business);
        registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            dueDate,
            DOCUMENT_HASH
        );
    }

    /**
     * @notice createInvoice tracks the invoice under business's address.
     *
     * WHAT THIS PROVES:
     * s_businessInvoices[business] is updated.
     * The business can query their own invoice list.
     */
    function test_createInvoice_tracksInvoiceUnderBusiness() public {
        _createValidInvoice();
        _createValidInvoice(); // create two invoices from same business

        uint256[] memory ids = registry.getBusinessInvoiceIds(business);
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
    }

    /**
     * @notice financingAmount can equal the full invoice amount (no discount).
     *
     * WHAT THIS PROVES:
     * financingAmount == amount is valid. Some financing arrangements
     * have no discount (the return comes from fees instead).
     * Our validation only rejects financingAmount > amount.
     */
    function test_createInvoice_financingAmountEqualToAmount_succeeds() public {
        vm.prank(business);
        uint256 id = registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            INVOICE_AMOUNT, // financing = full amount
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(invoice.financingAmount, INVOICE_AMOUNT);
    }

    // ============================================================
    //  createInvoice — NEGATIVE TESTS
    // ============================================================

    /**
     * @notice Reverts when buyer is the zero address.
     *
     * WHAT THIS PROVES:
     * You can't create an invoice with no buyer.
     * address(0) is the "null" address in Solidity — no one owns it.
     */
    function test_createInvoice_withZeroBuyer_reverts() public {
        vm.prank(business);
        vm.expectRevert(InvoiceRegistry.InvoiceRegistry__InvalidBuyer.selector);
        registry.createInvoice(
            address(0),
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
    }

    /**
     * @notice Reverts when buyer is the same as the business.
     *
     * WHAT THIS PROVES:
     * A business can't be its own buyer. That would be pointless
     * (you can't finance yourself) and potentially exploitable.
     */
    function test_createInvoice_withBuyerEqualToBusiness_reverts() public {
        vm.prank(business);
        vm.expectRevert(InvoiceRegistry.InvoiceRegistry__InvalidBuyer.selector);
        registry.createInvoice(
            business, // buyer == msg.sender == business
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
    }

    /**
     * @notice Reverts when invoice amount is zero.
     *
     * WHAT THIS PROVES:
     * Zero-amount invoices make no sense and would break the financing math.
     */
    function test_createInvoice_withZeroAmount_reverts() public {
        vm.prank(business);
        vm.expectRevert(
            InvoiceRegistry.InvoiceRegistry__InvalidAmount.selector
        );
        registry.createInvoice(
            buyer,
            0,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
    }

    /**
     * @notice Reverts when financingAmount is zero.
     *
     * WHAT THIS PROVES:
     * An investor paying zero for an invoice makes no sense.
     */
    function test_createInvoice_withZeroFinancingAmount_reverts() public {
        vm.prank(business);
        vm.expectRevert(
            InvoiceRegistry.InvoiceRegistry__InvalidFinancingAmount.selector
        );
        registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            0,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
    }

    /**
     * @notice Reverts when financingAmount exceeds invoice amount.
     *
     * WHAT THIS PROVES:
     * Investor can't pay MORE than the invoice face value.
     * That would mean the investor loses money instantly.
     */
    function test_createInvoice_withFinancingAmountExceedingFaceValue_reverts()
        public
    {
        vm.prank(business);
        vm.expectRevert(
            InvoiceRegistry.InvoiceRegistry__InvalidFinancingAmount.selector
        );
        registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            INVOICE_AMOUNT + 1, // 1 unit more than face value
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
    }

    /**
     * @notice Reverts when dueDate is in the past.
     *
     * WHAT THIS PROVES:
     * You can't create an invoice that's already overdue.
     */
    function test_createInvoice_withPastDueDate_reverts() public {
        vm.prank(business);
        vm.expectRevert(
            InvoiceRegistry.InvoiceRegistry__InvalidDueDate.selector
        );
        registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp - 1, // 1 second in the past
            DOCUMENT_HASH
        );
    }

    /**
     * @notice Reverts when dueDate equals current block timestamp.
     *
     * WHAT THIS PROVES:
     * dueDate must be STRICTLY in the future (>), not just >= now.
     * An invoice due "right now" would immediately be overdue.
     */
    function test_createInvoice_withDueDateEqualToNow_reverts() public {
        vm.prank(business);
        vm.expectRevert(
            InvoiceRegistry.InvoiceRegistry__InvalidDueDate.selector
        );
        registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp, // exactly now — not strictly future
            DOCUMENT_HASH
        );
    }

    // ============================================================
    //  cancelInvoice — POSITIVE TESTS
    // ============================================================

    /**
     * @notice Business can cancel their own CREATED invoice.
     *
     * WHAT THIS PROVES:
     * The business has control over their invoice before verification.
     * Status changes from CREATED to CANCELLED.
     */
    function test_cancelInvoice_byBusiness_succeeds() public {
        uint256 id = _createValidInvoice();

        vm.prank(business);
        registry.cancelInvoice(id);

        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.CANCELLED)
        );
    }

    /**
     * @notice cancelInvoice emits InvoiceCancelled event.
     */
    function test_cancelInvoice_emitsInvoiceCancelledEvent() public {
        uint256 id = _createValidInvoice();

        vm.expectEmit(true, true, false, false, address(registry));
        emit InvoiceRegistry.InvoiceCancelled(id, business);

        vm.prank(business);
        registry.cancelInvoice(id);
    }

    // ============================================================
    //  cancelInvoice — NEGATIVE TESTS
    // ============================================================

    /**
     * @notice Stranger cannot cancel someone else's invoice.
     *
     * WHAT THIS PROVES:
     * Only the invoice owner (business) can cancel their invoice.
     * This is the basic ownership check — msg.sender must equal invoice.business.
     */
    function test_cancelInvoice_byStranger_reverts() public {
        uint256 id = _createValidInvoice();

        vm.prank(stranger);
        vm.expectRevert(
            InvoiceRegistry.InvoiceRegistry__NotInvoiceOwner.selector
        );
        registry.cancelInvoice(id);
    }

    /**
     * @notice Cannot cancel an already verified invoice.
     *
     * WHAT THIS PROVES:
     * State machine enforced: VERIFIED invoices can't go back to CANCELLED.
     * This protects investors — once an invoice is verified, it stays visible.
     */
    function test_cancelInvoice_whenAlreadyVerified_reverts() public {
        uint256 id = _createValidInvoice();

        // Verifier approves it
        vm.prank(verifier);
        registry.verifyInvoice(id);

        // Business tries to cancel — too late
        vm.prank(business);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceRegistry
                    .InvoiceRegistry__InvalidStatusTransition
                    .selector,
                InvoiceRegistry.InvoiceStatus.VERIFIED, // current
                InvoiceRegistry.InvoiceStatus.CREATED // required
            )
        );
        registry.cancelInvoice(id);
    }

    /**
     * @notice Cannot cancel a non-existent invoice.
     *
     * WHAT THIS PROVES:
     * Accessing invoice ID 999 when none exist reverts with InvoiceNotFound.
     * This prevents the silent "return zero struct" behavior of raw mappings.
     */
    function test_cancelInvoice_withNonExistentId_reverts() public {
        vm.prank(business);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceRegistry.InvoiceRegistry__InvoiceNotFound.selector,
                999
            )
        );
        registry.cancelInvoice(999);
    }

    // ============================================================
    //  verifyInvoice — POSITIVE TESTS
    // ============================================================

    /**
     * @notice Authorized verifier can verify a CREATED invoice.
     *
     * WHAT THIS PROVES:
     * The core verification flow works.
     * Status transitions from CREATED → VERIFIED.
     */
    function test_verifyInvoice_byVerifier_succeeds() public {
        uint256 id = _createValidInvoice();

        vm.prank(verifier);
        registry.verifyInvoice(id);

        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.VERIFIED)
        );
    }

    /**
     * @notice Admin (who also has VERIFIER_ROLE) can verify invoices.
     *
     * WHAT THIS PROVES:
     * Both admin and verifier can verify. VERIFIER_ROLE can have multiple holders.
     */
    function test_verifyInvoice_byAdmin_succeeds() public {
        uint256 id = _createValidInvoice();

        vm.prank(admin); // admin has VERIFIER_ROLE from constructor
        registry.verifyInvoice(id);

        InvoiceRegistry.Invoice memory invoice = registry.getInvoice(id);
        assertEq(
            uint8(invoice.status),
            uint8(InvoiceRegistry.InvoiceStatus.VERIFIED)
        );
    }

    /**
     * @notice verifyInvoice emits InvoiceVerified event.
     *
     * WHAT THIS PROVES:
     * The frontend can listen to this event to update the invoice list
     * (move from "pending" to "available for financing").
     */
    function test_verifyInvoice_emitsInvoiceVerifiedEvent() public {
        uint256 id = _createValidInvoice();

        vm.expectEmit(true, true, false, false, address(registry));
        emit InvoiceRegistry.InvoiceVerified(id, verifier);

        vm.prank(verifier);
        registry.verifyInvoice(id);
    }

    // ============================================================
    //  verifyInvoice — NEGATIVE TESTS
    // ============================================================

    /**
     * @notice Stranger (no role) cannot verify an invoice.
     *
     * WHAT THIS PROVES:
     * The onlyRole modifier blocks unauthorized callers.
     * This is the most important security check in the contract.
     *
     * If this didn't work, anyone could approve invoices — completely
     * defeating the purpose of verification.
     */
    function test_verifyInvoice_byStranger_reverts() public {
        uint256 id = _createValidInvoice();

        // IMPORTANT (Foundry nightly): vm.expectRevert() must come BEFORE vm.prank().
        // In this version of Foundry, vm.expectRevert() itself counts as a call and
        // would otherwise consume the prank. Placing expectRevert first avoids this.
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "AccessControlUnauthorizedAccount(address,bytes32)"
                    )
                ),
                stranger,
                registry.VERIFIER_ROLE()
            )
        );
        vm.prank(stranger);
        registry.verifyInvoice(id);
    }

    /**
     * @notice Business itself cannot verify its own invoice.
     *
     * WHAT THIS PROVES:
     * Even the invoice creator can't self-verify.
     * This would be a critical security hole — self-approval defeats verification.
     */
    function test_verifyInvoice_byBusiness_reverts() public {
        uint256 id = _createValidInvoice();

        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(
                    keccak256(
                        "AccessControlUnauthorizedAccount(address,bytes32)"
                    )
                ),
                business,
                registry.VERIFIER_ROLE()
            )
        );
        vm.prank(business); // business does NOT have VERIFIER_ROLE
        registry.verifyInvoice(id);
    }

    /**
     * @notice Cannot verify an already verified invoice.
     *
     * WHAT THIS PROVES:
     * State machine is enforced — can't verify twice.
     * This prevents an attacker from somehow double-verifying and
     * causing unexpected state in downstream contracts (FinancingPool).
     */
    function test_verifyInvoice_whenAlreadyVerified_reverts() public {
        uint256 id = _createValidInvoice();

        vm.prank(verifier);
        registry.verifyInvoice(id); // first verify — succeeds

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceRegistry
                    .InvoiceRegistry__InvalidStatusTransition
                    .selector,
                InvoiceRegistry.InvoiceStatus.VERIFIED, // current
                InvoiceRegistry.InvoiceStatus.CREATED // required
            )
        );
        registry.verifyInvoice(id); // second verify — must fail
    }

    /**
     * @notice Cannot verify a cancelled invoice.
     *
     * WHAT THIS PROVES:
     * CANCELLED is a terminal state — no transitions out of it.
     * (Other than via a bug — this test prevents regressions.)
     */
    function test_verifyInvoice_whenCancelled_reverts() public {
        uint256 id = _createValidInvoice();

        vm.prank(business);
        registry.cancelInvoice(id);

        vm.prank(verifier);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceRegistry
                    .InvoiceRegistry__InvalidStatusTransition
                    .selector,
                InvoiceRegistry.InvoiceStatus.CANCELLED,
                InvoiceRegistry.InvoiceStatus.CREATED
            )
        );
        registry.verifyInvoice(id);
    }

    // ============================================================
    //  VIEW FUNCTION TESTS
    // ============================================================

    /**
     * @notice getInvoice reverts for a non-existent ID.
     *
     * WHAT THIS PROVES:
     * The ID validation in _getInvoiceStorage() works.
     * Without this check, getInvoice(999) would return a zero-value struct,
     * making it look like a real invoice with amount=0, status=CREATED.
     * That would be misleading and dangerous.
     */
    function test_getInvoice_withNonExistentId_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                InvoiceRegistry.InvoiceRegistry__InvoiceNotFound.selector,
                0 // no invoices created yet, so ID 0 doesn't exist
            )
        );
        registry.getInvoice(0);
    }

    /**
     * @notice getBuyerInvoiceIds returns invoice IDs for a buyer.
     *
     * WHAT THIS PROVES:
     * s_buyerInvoices is populated when createInvoice is called.
     * Buyers can look up what they owe.
     */
    function test_getBuyerInvoiceIds_returnsCorrectIds() public {
        _createValidInvoice(); // invoice 0

        // Create another invoice for same buyer from a different business
        address business2 = makeAddr("business2");
        vm.prank(business2);
        registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        ); // invoice 1

        uint256[] memory buyerIds = registry.getBuyerInvoiceIds(buyer);
        assertEq(buyerIds.length, 2);
        assertEq(buyerIds[0], 0);
        assertEq(buyerIds[1], 1);
    }

    /**
     * @notice getTotalInvoices reflects the correct count.
     */
    function test_getTotalInvoices_returnsCorrectCount() public {
        assertEq(registry.getTotalInvoices(), 0);
        _createValidInvoice();
        assertEq(registry.getTotalInvoices(), 1);
        _createValidInvoice();
        assertEq(registry.getTotalInvoices(), 2);
    }

    // ============================================================
    //  ROLE MANAGEMENT TESTS
    // ============================================================

    /**
     * @notice Admin can grant VERIFIER_ROLE to a new address.
     *
     * WHAT THIS PROVES:
     * DEFAULT_ADMIN_ROLE can expand the verifier pool.
     * This is important — in production you might have multiple verifiers.
     */
    function test_roleManagement_adminCanGrantVerifierRole() public {
        address newVerifier = makeAddr("newVerifier");

        // Check before — no prank needed for view calls
        assertFalse(registry.hasRole(registry.VERIFIER_ROLE(), newVerifier));

        // Grant the role as admin
        vm.startPrank(admin);
        registry.grantRole(registry.VERIFIER_ROLE(), newVerifier);
        vm.stopPrank();

        // Check after
        assertTrue(registry.hasRole(registry.VERIFIER_ROLE(), newVerifier));
    }

    /**
     * @notice Admin can revoke VERIFIER_ROLE from an existing verifier.
     *
     * WHAT THIS PROVES:
     * Compromised or misbehaving verifiers can be removed.
     * This is critical for security — role revocation must work.
     */
    function test_roleManagement_adminCanRevokeVerifierRole() public {
        // Check before
        assertTrue(registry.hasRole(registry.VERIFIER_ROLE(), verifier));

        // Revoke as admin
        vm.startPrank(admin);
        registry.revokeRole(registry.VERIFIER_ROLE(), verifier);
        vm.stopPrank();

        // Check after
        assertFalse(registry.hasRole(registry.VERIFIER_ROLE(), verifier));

        // After revocation, verifier can no longer verify
        uint256 id = _createValidInvoice();
        vm.expectRevert();
        vm.prank(verifier);
        registry.verifyInvoice(id);
    }

    /**
     * @notice Stranger cannot grant roles.
     *
     * WHAT THIS PROVES:
     * Only DEFAULT_ADMIN_ROLE can manage roles.
     * This prevents an attacker from self-granting VERIFIER_ROLE.
     */
    function test_roleManagement_strangerCannotGrantRoles() public {
        // IMPORTANT: Cache the role value BEFORE vm.expectRevert().
        // registry.VERIFIER_ROLE() is a staticcall. If it's called after
        // vm.expectRevert() (as part of argument evaluation), Foundry nightly
        // treats it as the "next call" and fires the expectRevert on the
        // staticcall (which succeeds), causing the test to fail.
        bytes32 verifierRole = registry.VERIFIER_ROLE();

        vm.expectRevert();
        vm.prank(stranger);
        registry.grantRole(verifierRole, stranger);
    }

    // ============================================================
    //  GAS SNAPSHOT TEST
    // ============================================================

    /**
     * @notice Measure gas cost of createInvoice.
     *
     * HOW TO READ GAS NUMBERS:
     * Run `forge test --gas-report` to see a full breakdown.
     * createInvoice writes multiple storage slots — that's the main cost.
     * Each SSTORE of a new slot costs 20,000 gas.
     * We have ~8 fields in the Invoice struct = significant storage cost.
     *
     * This test just ensures we have a reference point.
     * We'll revisit gas optimization in Level 5.
     */
    function test_gas_createInvoice() public {
        vm.prank(business);
        registry.createInvoice(
            buyer,
            INVOICE_AMOUNT,
            FINANCING_AMOUNT,
            block.timestamp + THIRTY_DAYS,
            DOCUMENT_HASH
        );
        // Check forge test --gas-report for the gas cost breakdown
    }
}
