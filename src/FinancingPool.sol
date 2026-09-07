// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {InvoiceRegistry} from "./InvoiceRegistry.sol";

/**
 * @title FinancingPool
 * @notice Handles the funding and repayment of invoices.
 *
 * WHAT THIS CONTRACT DOES:
 * - Investors fund verified invoices by transferring MockUSDC
 * - Buyers repay funded invoices, routing funds to the investor
 * - Marks invoices as overdue or defaulted when applicable
 *
 * HOW IT CONNECTS TO InvoiceRegistry:
 * FinancingPool calls InvoiceRegistry to:
 *   1. Read invoice state (getInvoice)
 *   2. Update invoice status (updateInvoiceStatus)
 * For (2), FinancingPool must have FINANCING_CONTRACT_ROLE in InvoiceRegistry.
 * This role must be granted after deployment by the admin:
 *   registry.grantRole(FINANCING_CONTRACT_ROLE, address(financingPool))
 *
 * WHAT msg.sender IS HERE vs IN InvoiceRegistry:
 * When a user calls fundInvoice() on FinancingPool:
 *   - Inside fundInvoice:  msg.sender = the investor's wallet
 *   - Inside updateInvoiceStatus (called from FinancingPool):
 *     msg.sender = address(FinancingPool) — NOT the investor!
 * This is why FINANCING_CONTRACT_ROLE is granted to the FinancingPool ADDRESS,
 * not to any human wallet.
 *
 * CEI PATTERN:
 * Every function that moves funds follows Checks-Effects-Interactions:
 *   1. CHECK  — validate conditions, revert if invalid
 *   2. EFFECT — write state to this contract's storage
 *   3. INTERACT — make external calls (registry, token)
 *
 * REENTRANCY GUARD:
 * nonReentrant is added to all money-moving functions as a safety net.
 * The full reentrancy deep-dive happens in Level 5.
 */
contract FinancingPool is Ownable, ReentrancyGuard {
    // ============================================================
    //  LIBRARIES
    // ============================================================

    /**
     * WHY SafeERC20?
     * Some ERC-20 tokens don't return a bool from transfer/transferFrom
     * (USDT on mainnet is a famous example). If we ignore the return value,
     * a failed transfer might go undetected. SafeERC20 wraps every call
     * and reverts if the transfer fails or returns false.
     * MockUSDC follows the standard correctly, but the habit matters.
     */
    using SafeERC20 for IERC20;

    // ============================================================
    //  IMMUTABLE STATE (bytecode, not storage — cheap to read)
    // ============================================================

    /**
     * @notice Reference to the InvoiceRegistry contract.
     *
     * WHY IMMUTABLE?
     * These addresses never change after deployment. Storing them as
     * immutable means reads are compiled into the bytecode — zero gas
     * for SLOAD. It also provides a security guarantee: once deployed,
     * the registry and stablecoin addresses can never be swapped out.
     *
     * i_ prefix = immutable variable.
     */
    InvoiceRegistry private immutable i_invoiceRegistry;
    IERC20 private immutable i_stablecoin;

    // ============================================================
    //  STORAGE STATE
    // ============================================================

    /**
     * @notice Maps invoiceId → the investor who funded it.
     *
     * address(0) means the invoice has not been funded yet.
     * We use this to:
     *   1. Prevent double-funding (if != address(0), already funded)
     *   2. Know where to send repayment (when buyer repays)
     *
     * WHY NOT STORE THIS IN InvoiceRegistry?
     * Separation of concerns. InvoiceRegistry manages invoice lifecycle
     * (created, verified, funded states). FinancingPool manages financial
     * relationships (who funded, how much). Each contract does one thing.
     */
    mapping(uint256 => address) private s_invoiceInvestor;

    // ============================================================
    //  EVENTS
    // ============================================================

    /**
     * @notice Emitted when an investor funds an invoice.
     * Investors and businesses listen to this event to update their dashboards.
     */
    event InvoiceFunded(
        uint256 indexed invoiceId,
        address indexed investor,
        address indexed business,
        uint256 financingAmount
    );

    /**
     * @notice Emitted when a buyer repays an invoice.
     * Investors listen to this to confirm they've been repaid.
     */
    event RepaymentReceived(
        uint256 indexed invoiceId,
        address indexed buyer,
        address indexed investor,
        uint256 repaymentAmount
    );

    /// @notice Emitted when an invoice is marked overdue
    event InvoiceMarkedOverdue(uint256 indexed invoiceId);

    /// @notice Emitted when an invoice is marked defaulted
    event InvoiceMarkedDefaulted(uint256 indexed invoiceId);

    // ============================================================
    //  ERRORS
    // ============================================================

    /**
     * @notice Thrown when trying to fund an invoice that isn't VERIFIED.
     * @param invoiceId   The invoice that was attempted
     * @param actualStatus The actual current status
     */
    error FinancingPool__InvoiceNotVerified(
        uint256 invoiceId,
        InvoiceRegistry.InvoiceStatus actualStatus
    );

    /// @notice Thrown when trying to fund an invoice that already has an investor
    error FinancingPool__InvoiceAlreadyFunded(uint256 invoiceId);

    /// @notice Thrown when the business tries to fund their own invoice
    error FinancingPool__BusinessCannotFundOwnInvoice();

    /// @notice Thrown when the buyer tries to act as investor on their own invoice
    error FinancingPool__BuyerCannotBeInvestor();

    /**
     * @notice Thrown when an action requires FUNDED status but invoice isn't funded.
     * Used by repayInvoice() and markOverdue().
     */
    error FinancingPool__InvoiceNotFunded(
        uint256 invoiceId,
        InvoiceRegistry.InvoiceStatus actualStatus
    );

    /// @notice Thrown when someone other than the buyer tries to repay
    error FinancingPool__OnlyBuyerCanRepay(
        address caller,
        address expectedBuyer
    );

    /// @notice Thrown when markOverdue is called before the due date
    error FinancingPool__DueDateNotPassed(uint256 dueDate, uint256 currentTime);

    /// @notice Thrown when markDefaulted is called on a non-OVERDUE invoice
    error FinancingPool__InvoiceNotOverdue(
        uint256 invoiceId,
        InvoiceRegistry.InvoiceStatus actualStatus
    );

    /// @notice Defensive check — investor should always be set when FUNDED
    error FinancingPool__NoInvestorRecorded(uint256 invoiceId);

    // ============================================================
    //  CONSTRUCTOR
    // ============================================================

    /**
     * @param owner           Admin wallet — can mark invoices defaulted
     * @param invoiceRegistry Address of the deployed InvoiceRegistry
     * @param stablecoin      Address of the MockUSDC token
     *
     * DEPLOYMENT ORDER:
     * 1. Deploy MockUSDC
     * 2. Deploy InvoiceRegistry
     * 3. Deploy FinancingPool (pass registry + usdc addresses)
     * 4. Call registry.grantRole(FINANCING_CONTRACT_ROLE, address(financingPool))
     * Step 4 is critical — without it, FinancingPool cannot update invoice status.
     */
    constructor(
        address owner,
        address invoiceRegistry,
        address stablecoin
    ) Ownable(owner) {
        i_invoiceRegistry = InvoiceRegistry(invoiceRegistry);
        i_stablecoin = IERC20(stablecoin);
    }

    // ============================================================
    //  EXTERNAL FUNCTIONS — INVESTOR ACTIONS
    // ============================================================

    /**
     * @notice Fund a verified invoice.
     * @param invoiceId The invoice to fund
     *
     * CALLER: An investor with sufficient MockUSDC allowance.
     *
     * PRE-CONDITION (investor must do this first):
     *   token.approve(address(financingPool), invoice.financingAmount)
     *
     * WHAT HAPPENS STEP BY STEP:
     * 1. Read invoice from InvoiceRegistry (external read call)
     * 2. Validate: VERIFIED status, not already funded, caller is not business or buyer
     * 3. Record investor in local storage (EFFECT — before any external write)
     * 4. Update invoice status to FUNDED in registry (INTERACTION 1)
     * 5. Pull financingAmount from investor, send to business (INTERACTION 2)
     * 6. Emit event
     *
     * THE APPROVE → TRANSFERFROM FLOW:
     * The investor does NOT call token.transfer() themselves.
     * Instead:
     *   Investor → approve(financingPool, financingAmount)  ← investor's tx
     *   Investor → fundInvoice(id)                          ← investor's tx
     *     └─→ FinancingPool → token.safeTransferFrom(investor, business, amount)
     *
     * This two-step pattern lets FinancingPool pull funds on the investor's behalf,
     * but ONLY up to the approved amount. The investor stays in control.
     *
     * DOUBLE-FUNDING PREVENTION:
     * We check s_invoiceInvestor[invoiceId] != address(0) before recording.
     * And we write the investor BEFORE the external calls (CEI).
     * Even if a reentrancy attack tried to call fundInvoice again,
     * the investor is already recorded → second call reverts with AlreadyFunded.
     */
    function fundInvoice(uint256 invoiceId) external nonReentrant {
        // Read invoice data — external call, but view-only (no state change)
        InvoiceRegistry.Invoice memory invoice = i_invoiceRegistry.getInvoice(
            invoiceId
        );

        // ---- CHECKS ----

        // Prevent double-funding: address(0) means nobody has funded it yet
        if (s_invoiceInvestor[invoiceId] != address(0)) {
            revert FinancingPool__InvoiceAlreadyFunded(invoiceId);
        }

        // Only VERIFIED invoices are eligible for financing
        if (invoice.status != InvoiceRegistry.InvoiceStatus.VERIFIED) {
            revert FinancingPool__InvoiceNotVerified(invoiceId, invoice.status);
        }

        // Business cannot fund their own invoice (conflict of interest)
        if (msg.sender == invoice.business) {
            revert FinancingPool__BusinessCannotFundOwnInvoice();
        }

        // Buyer cannot be the investor on their own invoice
        // (they'd be paying themselves — economically meaningless and exploitable)
        if (msg.sender == invoice.buyer) {
            revert FinancingPool__BuyerCannotBeInvestor();
        }

        // ---- EFFECTS ----

        // Record the investor BEFORE making any external calls.
        // This is the CEI pattern. If we did this AFTER the token transfer,
        // a malicious token contract could reenter fundInvoice and pass
        // the "already funded" check (since investor not yet recorded).
        s_invoiceInvestor[invoiceId] = msg.sender;

        // ---- INTERACTIONS ----

        // Tell InvoiceRegistry that this invoice is now funded
        // msg.sender inside updateInvoiceStatus will be address(this) — FinancingPool
        // That's why FinancingPool needs FINANCING_CONTRACT_ROLE
        i_invoiceRegistry.updateInvoiceStatus(
            invoiceId,
            InvoiceRegistry.InvoiceStatus.FUNDED
        );

        // Pull financing amount from investor's wallet, send directly to business
        // SafeERC20 ensures this reverts if transfer fails for any reason
        // The investor must have approved this contract before calling fundInvoice
        i_stablecoin.safeTransferFrom(
            msg.sender,
            invoice.business,
            invoice.financingAmount
        );

        emit InvoiceFunded(
            invoiceId,
            msg.sender,
            invoice.business,
            invoice.financingAmount
        );
    }

    // ============================================================
    //  EXTERNAL FUNCTIONS — BUYER ACTIONS
    // ============================================================

    /**
     * @notice Repay a funded invoice.
     * @param invoiceId The invoice to repay
     *
     * CALLER: Must be the buyer recorded in InvoiceRegistry.
     *
     * PRE-CONDITION (buyer must do this first):
     *   token.approve(address(financingPool), invoice.amount)  ← full face value
     *
     * WHAT HAPPENS:
     * 1. Read invoice state + investor address
     * 2. Validate: FUNDED status, caller is buyer, investor is recorded
     * 3. Update status to REPAID
     * 4. Transfer full invoice amount from buyer to investor
     * 5. Update status to CLOSED
     * 6. Emit event
     *
     * WHY TWO STATUS UPDATES?
     * REPAID and CLOSED are logically different:
     *   REPAID  = buyer has paid
     *   CLOSED  = all settlement is complete, nothing further can happen
     * In a more complex system, there might be actions between REPAID and CLOSED
     * (e.g., fee collection, reserve release). We keep both for clarity.
     *
     * REAL-WORLD NOTE:
     * In production, the buyer would NOT call this directly on the blockchain.
     * They'd repay via bank transfer. A Chainlink oracle or trusted backend
     * would then confirm the payment on-chain, triggering the token transfer.
     * We simulate this in Level 8 (Chainlink). For now, the buyer holds
     * MockUSDC and repays directly.
     */
    function repayInvoice(uint256 invoiceId) external nonReentrant {
        InvoiceRegistry.Invoice memory invoice = i_invoiceRegistry.getInvoice(
            invoiceId
        );
        address investor = s_invoiceInvestor[invoiceId];

        // ---- CHECKS ----

        if (invoice.status != InvoiceRegistry.InvoiceStatus.FUNDED) {
            revert FinancingPool__InvoiceNotFunded(invoiceId, invoice.status);
        }

        // Only the registered buyer can repay
        // This prevents a random third party from repaying on behalf of the buyer
        // (in production this would be relaxed — anyone could repay, but let's keep it simple)
        if (msg.sender != invoice.buyer) {
            revert FinancingPool__OnlyBuyerCanRepay(msg.sender, invoice.buyer);
        }

        // Defensive: investor should always be set when status is FUNDED
        // In theory impossible to reach this state without an investor,
        // but defensive programming catches bugs in future code changes
        if (investor == address(0)) {
            revert FinancingPool__NoInvestorRecorded(invoiceId);
        }

        // ---- EFFECTS ----
        // No local storage changes needed for repayment.
        // s_invoiceInvestor stays set — useful for historical record keeping.

        // ---- INTERACTIONS ----

        // First update status (before token transfer — CEI)
        i_invoiceRegistry.updateInvoiceStatus(
            invoiceId,
            InvoiceRegistry.InvoiceStatus.REPAID
        );

        // Transfer FULL invoice amount from buyer to investor
        // Note: financingAmount went to business. amount comes back to investor.
        // Difference (amount - financingAmount) is the investor's return.
        i_stablecoin.safeTransferFrom(msg.sender, investor, invoice.amount);

        // Close the invoice — terminal state, no further transitions possible
        i_invoiceRegistry.updateInvoiceStatus(
            invoiceId,
            InvoiceRegistry.InvoiceStatus.CLOSED
        );

        emit RepaymentReceived(invoiceId, msg.sender, investor, invoice.amount);
    }

    // ============================================================
    //  EXTERNAL FUNCTIONS — DEFAULT HANDLING
    // ============================================================

    /**
     * @notice Mark a funded invoice as overdue.
     * @param invoiceId The invoice to mark overdue
     *
     * CALLER: Anyone — this is permissionless.
     *
     * WHY PERMISSIONLESS?
     * Overdue status is a fact based on public data:
     *   invoice.status == FUNDED  AND  block.timestamp > invoice.dueDate
     * Anyone can observe and assert this. No special role needed.
     * This is also useful for Chainlink Automation (Level 8) — an automated
     * keeper can call this without a specific privileged role.
     *
     * WHAT THIS DOES NOT DO:
     * It does NOT recover the investor's money. It just records the state.
     * Legal recovery of funds from a defaulted buyer is an off-chain problem.
     * Blockchain records what happened; it cannot compel real-world payment.
     */
    function markOverdue(uint256 invoiceId) external {
        InvoiceRegistry.Invoice memory invoice = i_invoiceRegistry.getInvoice(
            invoiceId
        );

        // Can only mark overdue if it's currently FUNDED
        if (invoice.status != InvoiceRegistry.InvoiceStatus.FUNDED) {
            revert FinancingPool__InvoiceNotFunded(invoiceId, invoice.status);
        }

        // Due date must have passed
        if (block.timestamp <= invoice.dueDate) {
            revert FinancingPool__DueDateNotPassed(
                invoice.dueDate,
                block.timestamp
            );
        }

        i_invoiceRegistry.updateInvoiceStatus(
            invoiceId,
            InvoiceRegistry.InvoiceStatus.OVERDUE
        );
        emit InvoiceMarkedOverdue(invoiceId);
    }

    /**
     * @notice Mark an overdue invoice as defaulted.
     * @param invoiceId The invoice to mark defaulted
     *
     * CALLER: Only the owner (admin).
     *
     * WHY RESTRICTED?
     * Default has legal and reputational consequences. We don't want anyone
     * marking an invoice defaulted — only an admin who has confirmed that
     * all recovery options have been exhausted.
     *
     * NOTE: In a production system there would be a grace period after OVERDUE
     * before DEFAULTED can be set. We simplify this here.
     */
    function markDefaulted(uint256 invoiceId) external onlyOwner {
        InvoiceRegistry.Invoice memory invoice = i_invoiceRegistry.getInvoice(
            invoiceId
        );

        if (invoice.status != InvoiceRegistry.InvoiceStatus.OVERDUE) {
            revert FinancingPool__InvoiceNotOverdue(invoiceId, invoice.status);
        }

        i_invoiceRegistry.updateInvoiceStatus(
            invoiceId,
            InvoiceRegistry.InvoiceStatus.DEFAULTED
        );
        emit InvoiceMarkedDefaulted(invoiceId);
    }

    // ============================================================
    //  EXTERNAL VIEW FUNCTIONS
    // ============================================================

    /// @notice Get the investor address for a given invoice
    /// @return address(0) if invoice is not yet funded
    function getInvoiceInvestor(
        uint256 invoiceId
    ) external view returns (address) {
        return s_invoiceInvestor[invoiceId];
    }

    /// @notice Get the InvoiceRegistry contract address
    function getInvoiceRegistry() external view returns (address) {
        return address(i_invoiceRegistry);
    }

    /// @notice Get the stablecoin contract address
    function getStablecoin() external view returns (address) {
        return address(i_stablecoin);
    }
}
