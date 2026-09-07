// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title InvoiceRegistry
 * @notice Manages the lifecycle of invoices on-chain.
 *
 * WHAT THIS CONTRACT DOES:
 * - Any wallet can submit an invoice (they become the "business/borrower")
 * - An authorized Verifier can approve the invoice for financing
 * - The invoice progresses through a strict state machine
 * - Every state change emits an event (permanent, auditable log)
 *
 * WHAT THIS CONTRACT DOES NOT DO:
 * - It does not handle money (that's FinancingPool's job)
 * - It does not store the invoice document (we store only a hash)
 * - It does not verify real-world KYC/KYB (the Verifier is simulated)
 *
 * WHY ACCESSCONTROL INSTEAD OF OWNABLE?
 * In FinLedger we need two distinct authorities:
 *   - Admin: deploys contracts, assigns roles (DEFAULT_ADMIN_ROLE)
 *   - Verifier: approves invoices (VERIFIER_ROLE)
 *   - FinancingPool: updates invoice status when funded/repaid (FINANCING_CONTRACT_ROLE)
 * OpenZeppelin's AccessControl handles this cleanly with named roles.
 * Ownable only supports a single "owner" — not flexible enough.
 */
contract InvoiceRegistry is AccessControl {
    // ============================================================
    //  ROLES
    // ============================================================

    /**
     * @notice Role for addresses that can verify invoices.
     *
     * HOW ROLES WORK:
     * A role in OpenZeppelin AccessControl is a bytes32 value.
     * We create it by hashing a human-readable string with keccak256.
     * keccak256("VERIFIER_ROLE") = 0x539...  (a fixed 32-byte hash)
     *
     * The DEFAULT_ADMIN_ROLE (= bytes32(0)) is built into AccessControl.
     * The address with DEFAULT_ADMIN_ROLE can grant/revoke all other roles.
     */
    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");

    /**
     * @notice Role for the FinancingPool contract.
     * This role allows FinancingPool to update invoice status when
     * an invoice is funded, repaid, or defaulted.
     * We define it now but assign it in Level 3 when FinancingPool is deployed.
     */
    bytes32 public constant FINANCING_CONTRACT_ROLE =
        keccak256("FINANCING_CONTRACT_ROLE");

    // ============================================================
    //  TYPES
    // ============================================================

    /**
     * @notice Represents the lifecycle state of an invoice.
     *
     * VALID TRANSITIONS (enforced in code):
     * CREATED   → VERIFIED   (by Verifier)
     * CREATED   → CANCELLED  (by Business, before verification)
     * VERIFIED  → FUNDED     (by FinancingPool, when investor funds it)
     * FUNDED    → REPAID     (by FinancingPool, when buyer repays)
     * FUNDED    → OVERDUE    (by anyone, after dueDate passes)
     * OVERDUE   → DEFAULTED  (by Admin, after grace period)
     * REPAID    → CLOSED     (automatically when repayment confirmed)
     *
     * WHY AN ENUM?
     * Without an enum, we might use uint8 constants (0, 1, 2...).
     * That's error-prone — nothing stops you from writing status = 99.
     * An enum restricts the values to only the ones we define.
     * Solidity stores it as uint8 internally — no overhead.
     */
    enum InvoiceStatus {
        CREATED, // 0 — Invoice submitted, awaiting verification
        VERIFIED, // 1 — Approved by verifier, eligible for financing
        FUNDED, // 2 — Investor has funded the invoice
        REPAID, // 3 — Buyer has repaid the full amount
        OVERDUE, // 4 — Due date has passed without repayment
        DEFAULTED, // 5 — Marked as defaulted after overdue period
        CANCELLED, // 6 — Business cancelled before verification
        CLOSED // 7 — Final state after repayment settled
    }

    /**
     * @notice The core data structure representing a single invoice.
     *
     * FIELD-BY-FIELD EXPLANATION:
     *
     * id            — Unique identifier. Starts at 0, increments by 1.
     *                 This is the "primary key" we use in all mappings.
     *
     * business      — The wallet address of the business that created the invoice.
     *                 Smart contract sends financing funds HERE.
     *
     * buyer         — The wallet address of the buyer who must repay.
     *                 In a real system this would be a business address.
     *                 For FinLedger MVP, buyer repays via smart contract directly.
     *
     * amount        — The FULL face value of the invoice (what buyer owes).
     *                 Stored in MockUSDC units (6 decimals).
     *                 $10,000 = 10_000 * 10**6 = 10_000_000_000
     *
     * financingAmount — The DISCOUNTED amount the investor pays upfront.
     *                   Always ≤ amount. The difference is the investor's return.
     *                   Example: amount=$10,000, financingAmount=$9,500 → $500 return.
     *
     * issuedAt      — block.timestamp when createInvoice was called.
     *                 Immutable proof of when the invoice was registered.
     *
     * dueDate       — Unix timestamp of when the buyer must repay.
     *                 Used to determine OVERDUE status.
     *                 Example: block.timestamp + 30 days
     *
     * documentHash  — keccak256 hash of the actual invoice PDF/document.
     *                 The document is stored off-chain (IPFS, cloud storage).
     *                 The hash proves the document existed at this time
     *                 and detects any tampering (even 1 byte change = different hash).
     *
     * status        — Current state in the lifecycle. Starts as CREATED.
     *
     * WHAT WE DO NOT STORE ON-CHAIN:
     * - The actual document (too large, too expensive)
     * - Business legal name (not needed by smart contract)
     * - Business email/contact (private, not needed by contract)
     * - Invoice line items (not needed by contract)
     * - KYC data (never on a public chain)
     */
    struct Invoice {
        uint256 id;
        address business;
        address buyer;
        uint256 amount;
        uint256 financingAmount;
        uint256 issuedAt;
        uint256 dueDate;
        bytes32 documentHash;
        InvoiceStatus status;
    }

    // ============================================================
    //  STATE VARIABLES
    // ============================================================

    /**
     * @notice Counter for assigning unique invoice IDs.
     *
     * WHY s_ PREFIX?
     * `s_` denotes a storage variable. Storage reads cost 100-2100 gas.
     * Being aware of which variables are in storage helps you write
     * gas-efficient code. Memory variables are essentially free.
     *
     * WHY START AT 0?
     * Invoice IDs start at 0. The first invoice gets ID 0, second gets ID 1, etc.
     * We increment BEFORE assigning in createInvoice to avoid any confusion.
     * Actually we assign first, then increment — making first invoice ID=0.
     */
    uint256 private s_nextInvoiceId;

    /**
     * @notice Maps invoice ID → Invoice struct.
     *
     * This is the main storage. To look up invoice #5:
     *   s_invoices[5]  →  Invoice struct
     *
     * IMPORTANT: Solidity mappings do not have a "does this key exist?"
     * check built in. Accessing a missing key returns a zero-value struct.
     * That's why we track s_nextInvoiceId and revert if id >= s_nextInvoiceId.
     */
    mapping(uint256 => Invoice) private s_invoices;

    /**
     * @notice Maps a business address → array of their invoice IDs.
     *
     * WHY DO WE NEED THIS?
     * If a business wants to see "all my invoices", we can't iterate
     * over s_invoices (no way to list mapping keys). So we maintain
     * a separate list of IDs per business.
     *
     * Example: s_businessInvoices[alice] = [0, 3, 7, 12]
     * Then we can do: for each id → s_invoices[id]
     */
    mapping(address => uint256[]) private s_businessInvoices;

    /**
     * @notice Maps a buyer address → array of invoice IDs they owe.
     * Useful for the buyer dashboard to see what they need to repay.
     */
    mapping(address => uint256[]) private s_buyerInvoices;

    // ============================================================
    //  EVENTS
    // ============================================================

    /**
     * @notice Emitted when a new invoice is registered on-chain.
     * @param invoiceId Unique identifier of the invoice
     * @param business  Address of the business (borrower)
     * @param buyer     Address of the buyer (repayer)
     * @param amount    Face value of the invoice (6 decimals)
     * @param dueDate   Unix timestamp of payment due date
     *
     * WHY INDEXED?
     * `indexed` parameters are stored in the event's "topics" rather than
     * the data field. This makes them filterable. For example:
     *   "Show me all InvoiceCreated events where business = alice"
     * You can filter by up to 3 indexed parameters per event.
     * Non-indexed params are cheaper but not filterable.
     */
    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed business,
        address indexed buyer,
        uint256 amount,
        uint256 financingAmount,
        uint256 dueDate,
        bytes32 documentHash
    );

    /// @notice Emitted when a verifier approves an invoice
    event InvoiceVerified(uint256 indexed invoiceId, address indexed verifier);

    /// @notice Emitted when a business cancels their invoice
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed business);

    /// @notice Emitted when FinancingPool updates the invoice status
    /// Used in Level 3+ for FUNDED, REPAID, OVERDUE, DEFAULTED, CLOSED transitions
    event InvoiceStatusUpdated(
        uint256 indexed invoiceId,
        InvoiceStatus indexed previousStatus,
        InvoiceStatus indexed newStatus
    );

    // ============================================================
    //  ERRORS
    // ============================================================

    /**
     * WHY CUSTOM ERRORS?
     * Before Solidity 0.8.4, we used: require(condition, "string message")
     * The string is stored in bytecode and included in revert data — wastes gas.
     * Custom errors are identified by a 4-byte selector (like function signatures).
     * They are cheaper to deploy and cheaper to revert with.
     * They also support typed parameters for richer error information.
     *
     * NAMING CONVENTION: ContractName__ErrorName
     * The double underscore makes it obvious which contract threw the error.
     */

    /// @notice Thrown when invoice amount is zero
    error InvoiceRegistry__InvalidAmount();

    /// @notice Thrown when financingAmount is 0 or greater than amount
    error InvoiceRegistry__InvalidFinancingAmount();

    /// @notice Thrown when dueDate is in the past or equals current time
    error InvoiceRegistry__InvalidDueDate();

    /// @notice Thrown when buyer is zero address or same as the business
    error InvoiceRegistry__InvalidBuyer();

    /// @notice Thrown when accessing an invoice ID that doesn't exist
    error InvoiceRegistry__InvoiceNotFound(uint256 invoiceId);

    /// @notice Thrown when a non-owner tries to cancel/modify their invoice
    error InvoiceRegistry__NotInvoiceOwner();

    /**
     * @notice Thrown when a status transition is not allowed.
     * @param current  The current status of the invoice
     * @param required The status that was required for this operation
     *
     * WHY INCLUDE PARAMETERS IN ERRORS?
     * When a transaction reverts, the error is included in the tx receipt.
     * Your frontend can decode this and show the user exactly what went wrong:
     * "Invoice is in FUNDED state, but this action requires CREATED state"
     * Much better than a generic "Transaction failed" message.
     */
    error InvoiceRegistry__InvalidStatusTransition(
        InvoiceStatus current,
        InvoiceStatus required
    );

    // ============================================================
    //  CONSTRUCTOR
    // ============================================================

    /**
     * @param admin The address that becomes DEFAULT_ADMIN_ROLE.
     *              This address can grant/revoke VERIFIER_ROLE and
     *              FINANCING_CONTRACT_ROLE to other addresses.
     *
     * HOW ACCESSCONTROL CONSTRUCTOR WORKS:
     * AccessControl doesn't have its own constructor — we just call
     * _grantRole() to set up initial permissions. The admin gets both
     * DEFAULT_ADMIN_ROLE (role management) and VERIFIER_ROLE (can verify
     * invoices) so we can test everything from one address on day one.
     * In production, you'd separate these into different wallets.
     */
    constructor(address admin) {
        // Grant admin role — can assign/revoke all other roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        // Also make admin a verifier so we can test without a separate wallet
        _grantRole(VERIFIER_ROLE, admin);
    }

    // ============================================================
    //  EXTERNAL FUNCTIONS — BUSINESS ACTIONS
    // ============================================================

    /**
     * @notice Register a new invoice on-chain.
     * @param buyer           Wallet address of the buyer (who will repay)
     * @param amount          Face value of the invoice in MockUSDC units
     * @param financingAmount Amount investor will pay (must be ≤ amount)
     * @param dueDate         Unix timestamp — when buyer must repay
     * @param documentHash    keccak256 hash of the invoice document
     * @return invoiceId      Unique ID of the created invoice
     *
     * CALLER: Any wallet — represents a business submitting their invoice.
     * msg.sender automatically becomes the invoice's business address.
     *
     * CHECKS-EFFECTS-INTERACTIONS PATTERN (preview):
     * Notice how we structure this function:
     *   1. CHECK all inputs are valid (revert early if not)
     *   2. EFFECT — write to state (s_invoices, s_businessInvoices)
     *   3. INTERACT — emit event (events are not external calls, but the
     *      pattern still teaches us to put side effects last)
     *
     * We'll cover this pattern deeply in Level 5 (reentrancy).
     *
     * WHAT IS NOT VALIDATED HERE:
     * - We don't verify the document actually matches the hash (can't — off-chain)
     * - We don't verify the buyer is a real company (off-chain KYB)
     * - We don't verify the business is legitimate (off-chain KYC)
     * These are the limitations of on-chain verification.
     */
    function createInvoice(
        address buyer,
        uint256 amount,
        uint256 financingAmount,
        uint256 dueDate,
        bytes32 documentHash
    ) external returns (uint256 invoiceId) {
        // ---- CHECKS ----

        // Buyer cannot be the zero address (uninitialized address)
        // Buyer cannot be the same as business (can't finance yourself)
        if (buyer == address(0) || buyer == msg.sender) {
            revert InvoiceRegistry__InvalidBuyer();
        }

        // Invoice must have a non-zero face value
        if (amount == 0) revert InvoiceRegistry__InvalidAmount();

        // Financing amount must be positive and not exceed face value
        // financingAmount=0 makes no sense (why would investor pay nothing?)
        // financingAmount>amount makes no sense (investor would lose money immediately)
        if (financingAmount == 0 || financingAmount > amount) {
            revert InvoiceRegistry__InvalidFinancingAmount();
        }

        // Due date must be strictly in the future
        // block.timestamp is the Unix timestamp of the block being mined
        // Note: block.timestamp can be manipulated slightly by miners (~15s)
        // For due dates measured in days/weeks, this is not a concern
        if (dueDate <= block.timestamp)
            revert InvoiceRegistry__InvalidDueDate();

        // ---- EFFECTS ----

        // Assign this invoice the current counter value, then increment
        // Post-increment: invoiceId = s_nextInvoiceId, then s_nextInvoiceId += 1
        invoiceId = s_nextInvoiceId++;

        // Write the Invoice struct to storage
        // Every field stored here costs gas (SSTORE opcode)
        s_invoices[invoiceId] = Invoice({
            id: invoiceId,
            business: msg.sender, // whoever called this function
            buyer: buyer,
            amount: amount,
            financingAmount: financingAmount,
            issuedAt: block.timestamp, // current block timestamp
            dueDate: dueDate,
            documentHash: documentHash,
            status: InvoiceStatus.CREATED
        });

        // Track this invoice under the business's address
        s_businessInvoices[msg.sender].push(invoiceId);

        // Track this invoice under the buyer's address
        s_buyerInvoices[buyer].push(invoiceId);

        // ---- INTERACTIONS (Events) ----
        emit InvoiceCreated(
            invoiceId,
            msg.sender,
            buyer,
            amount,
            financingAmount,
            dueDate,
            documentHash
        );
    }

    /**
     * @notice Cancel an invoice that hasn't been verified yet.
     * @param invoiceId The ID of the invoice to cancel
     *
     * CALLER: The business that created the invoice (invoice.business).
     *
     * RULES:
     * - Only the original creator can cancel
     * - Only CREATED invoices can be cancelled
     * - Once VERIFIED, the invoice can't be recalled (investor might rely on it)
     *
     * This is a real-world rule: once a bank starts reviewing your invoice,
     * you can't just pull it. Same logic applies here.
     */
    function cancelInvoice(uint256 invoiceId) external {
        // Get a storage reference (we will modify the struct)
        Invoice storage invoice = _getInvoiceStorage(invoiceId);

        // Only the business that created it can cancel
        if (invoice.business != msg.sender) {
            revert InvoiceRegistry__NotInvoiceOwner();
        }

        // Can only cancel if it hasn't moved past CREATED
        if (invoice.status != InvoiceStatus.CREATED) {
            revert InvoiceRegistry__InvalidStatusTransition(
                invoice.status,
                InvoiceStatus.CREATED
            );
        }

        invoice.status = InvoiceStatus.CANCELLED;
        emit InvoiceCancelled(invoiceId, msg.sender);
    }

    // ============================================================
    //  EXTERNAL FUNCTIONS — VERIFIER ACTIONS
    // ============================================================

    /**
     * @notice Approve an invoice for financing.
     * @param invoiceId The ID of the invoice to verify
     *
     * CALLER: Must have VERIFIER_ROLE.
     *
     * onlyRole(VERIFIER_ROLE) is a modifier from OpenZeppelin AccessControl.
     * It expands to:
     *   if (!hasRole(VERIFIER_ROLE, msg.sender)) revert AccessControlUnauthorizedAccount(...)
     *
     * WHAT VERIFICATION MEANS HERE:
     * In the real world, verification means:
     *   - Confirm the invoice is genuine
     *   - Confirm the buyer relationship is real
     *   - Confirm the business is not double-pledging this invoice
     * In FinLedger, the verifier just calls this function.
     * The off-chain due diligence is simulated — we know this is a simplification.
     */
    function verifyInvoice(uint256 invoiceId) external onlyRole(VERIFIER_ROLE) {
        Invoice storage invoice = _getInvoiceStorage(invoiceId);

        // Can only verify a CREATED invoice
        if (invoice.status != InvoiceStatus.CREATED) {
            revert InvoiceRegistry__InvalidStatusTransition(
                invoice.status,
                InvoiceStatus.CREATED
            );
        }

        invoice.status = InvoiceStatus.VERIFIED;
        emit InvoiceVerified(invoiceId, msg.sender);
    }

    // ============================================================
    //  EXTERNAL FUNCTIONS — FINANCING CONTRACT ACTIONS
    // ============================================================

    /**
     * @notice Update invoice status — called by FinancingPool only.
     * @param invoiceId The invoice to update
     * @param newStatus The new status to set
     *
     * CALLER: Must have FINANCING_CONTRACT_ROLE.
     * This role will be granted to the FinancingPool address in Level 3.
     *
     * WHY THIS DESIGN?
     * FinancingPool needs to update invoice status when:
     *   VERIFIED → FUNDED   (when investor funds it)
     *   FUNDED   → REPAID   (when buyer repays)
     *   FUNDED   → OVERDUE  (when due date passes)
     *   OVERDUE  → DEFAULTED
     *   REPAID   → CLOSED
     *
     * Rather than duplicating status-transition logic, FinancingPool
     * calls this function and we validate here.
     *
     * NOTE: This is a simplified design for the learning version.
     * In production you would define strict allowed transitions for each
     * role rather than a generic "update status" function.
     */
    function updateInvoiceStatus(
        uint256 invoiceId,
        InvoiceStatus newStatus
    ) external onlyRole(FINANCING_CONTRACT_ROLE) {
        Invoice storage invoice = _getInvoiceStorage(invoiceId);
        InvoiceStatus previousStatus = invoice.status;
        invoice.status = newStatus;
        emit InvoiceStatusUpdated(invoiceId, previousStatus, newStatus);
    }

    // ============================================================
    //  EXTERNAL VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get the full Invoice struct for a given ID.
     * @param invoiceId The ID to look up
     * @return The Invoice struct (memory copy)
     *
     * WHY `memory` RETURN TYPE?
     * When returning a struct from a view function, you return a copy
     * (memory), not a storage reference. The caller gets all fields.
     * External callers (frontend, other contracts) call this to read invoice data.
     */
    function getInvoice(
        uint256 invoiceId
    ) external view returns (Invoice memory) {
        return _getInvoiceStorage(invoiceId);
    }

    /// @notice Get all invoice IDs created by a specific business
    function getBusinessInvoiceIds(
        address business
    ) external view returns (uint256[] memory) {
        return s_businessInvoices[business];
    }

    /// @notice Get all invoice IDs owed by a specific buyer
    function getBuyerInvoiceIds(
        address buyer
    ) external view returns (uint256[] memory) {
        return s_buyerInvoices[buyer];
    }

    /// @notice Returns total number of invoices ever created
    function getTotalInvoices() external view returns (uint256) {
        return s_nextInvoiceId;
    }

    // ============================================================
    //  INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Internal function to get a storage reference to an invoice.
     * @dev Reverts if the invoice ID has never been created.
     *
     * WHY INTERNAL?
     * Both verifyInvoice() and cancelInvoice() need to:
     *   1. Check the invoice exists
     *   2. Get a storage reference to modify it
     * Extracting this into _getInvoiceStorage() avoids duplication.
     *
     * WHY RETURN `storage`?
     * Returning a `storage` reference means the caller can modify
     * the invoice directly through this reference. Any writes go
     * directly to EVM storage — no need to write back.
     */
    function _getInvoiceStorage(
        uint256 invoiceId
    ) internal view returns (Invoice storage) {
        // If invoiceId >= s_nextInvoiceId, it was never created
        // Remember: mappings return zero-values for missing keys
        // Without this check, we'd silently modify a zero invoice
        if (invoiceId >= s_nextInvoiceId) {
            revert InvoiceRegistry__InvoiceNotFound(invoiceId);
        }
        return s_invoices[invoiceId];
    }
}
