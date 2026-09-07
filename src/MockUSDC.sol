// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDC
 * @notice A test ERC-20 token that simulates USDC for local development.
 *
 * KEY DESIGN DECISIONS:
 * - Uses 6 decimals (real USDC uses 6, not 18). This is important because
 *   we will write $10,000 as 10_000_000_000 (10,000 * 10^6).
 * - Owner can mint freely — simulates getting test tokens on a faucet.
 * - No burn, no permit, no other complexity. This is purely a test tool.
 *
 * WHY DO WE NEED THIS?
 * We cannot use real USDC on a local Anvil chain. We need our own token
 * that we can freely mint to test wallets during development.
 *
 * WHY NOT USE 18 DECIMALS LIKE ETH?
 * USDC intentionally uses 6 decimals. Since we are simulating USDC,
 * we match that behavior so the numbers feel real. If we forget this
 * when writing amounts in tests, it will cause confusion.
 *
 * WHAT THIS IS NOT:
 * This is not a real stablecoin. It has no peg mechanism, no reserves,
 * no collateral. It is a learning tool only.
 */
contract MockUSDC is ERC20, Ownable {
    // ============================================================
    //  ERRORS
    // ============================================================

    /// @notice Thrown when mint is called with a zero amount
    error MockUSDC__ZeroMintAmount();

    // ============================================================
    //  EVENTS
    // ============================================================

    /// @notice Emitted when tokens are minted to an address
    event TokensMinted(address indexed to, uint256 amount);

    // ============================================================
    //  CONSTRUCTOR
    // ============================================================

    /**
     * @param initialOwner The address that will own this contract.
     *                     Owner is the only one who can mint tokens.
     *
     * WHY OWNABLE?
     * We don't want just anyone to mint unlimited tokens in a test,
     * even on a local chain. The owner represents a "faucet admin".
     * OpenZeppelin's Ownable gives us a ready-made owner pattern
     * with a transferOwnership function included.
     */
    constructor(
        address initialOwner
    ) ERC20("Mock USDC", "mUSDC") Ownable(initialOwner) {}

    // ============================================================
    //  EXTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Mint tokens to any address. Only callable by owner.
     * @param to     Recipient address
     * @param amount Amount in smallest units (remember: 6 decimals)
     *               To mint $100: pass 100_000_000 (100 * 10^6)
     *
     * WHY A CUSTOM ERROR INSTEAD OF require(amount > 0, "...")?
     * Custom errors are cheaper on gas because they don't store
     * a string in the transaction revert data. This is a good habit
     * to build from the start, even if gas is cheap on local chain.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        if (amount == 0) revert MockUSDC__ZeroMintAmount();
        _mint(to, amount);
        emit TokensMinted(to, amount);
    }

    // ============================================================
    //  PUBLIC VIEW OVERRIDES
    // ============================================================

    /**
     * @notice Returns 6 decimals — matching real USDC.
     *
     * WHY OVERRIDE?
     * ERC20 defaults to 18 decimals. We override to 6 to match USDC.
     * This affects how UIs display balances but NOT how the EVM
     * stores numbers. The EVM always stores raw integers — decimals
     * are just a convention for display.
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }
}
