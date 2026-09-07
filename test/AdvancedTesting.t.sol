// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {InvoiceRegistry} from "../src/InvoiceRegistry.sol";
import {FinancingPool} from "../src/FinancingPool.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// ============================================================
//  1. MALICIOUS CONTRACT (For Reentrancy Simulation)
// ============================================================

/**
 * @notice A fake token that pretends to be ERC-20, but executes a Reentrancy Attack.
 * When `FinancingPool` calls `transferFrom` on this token, it will trigger the attack
 * and try to call `fundInvoice` AGAIN before the first transaction finishes.
 */
contract MaliciousToken is ERC20 {
    FinancingPool public pool;
    uint256 public attackInvoiceId;
    bool private isAttacking;

    constructor() ERC20("Malicious", "MAL") {
        _mint(msg.sender, 1_000_000 * 10 ** 6);
    }

    function setupAttack(FinancingPool _pool, uint256 _id) external {
        pool = _pool;
        attackInvoiceId = _id;
    }

    // Override the standard ERC20 transferFrom to inject our attack
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        // 1. Do the normal transfer
        super.transferFrom(from, to, value);

        // 2. THE ATTACK: If the FinancingPool is the one calling us, strike back!
        if (msg.sender == address(pool) && !isAttacking) {
            isAttacking = true;
            console.log("ATTACKER: Attempting to re-enter fundInvoice()...");

            // This is where the hacker tries to drain funds by calling fundInvoice twice
            // in the exact same transaction.
            pool.fundInvoice(attackInvoiceId);

            isAttacking = false;
        }
        return true;
    }
}

// ============================================================
//  2. ADVANCED TEST SUITE
// ============================================================

contract AdvancedTestingTest is Test {
    MockUSDC public usdc;
    InvoiceRegistry public registry;
    FinancingPool public pool;

    address public admin = makeAddr("admin");
    address public business = makeAddr("business");
    address public buyer = makeAddr("buyer");
    address public investor = makeAddr("investor");
    bytes32 constant DOC_HASH = keccak256("doc");

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockUSDC(admin);
        registry = new InvoiceRegistry(admin);
        pool = new FinancingPool(admin, address(registry), address(usdc));

        registry.grantRole(registry.VERIFIER_ROLE(), admin);
        registry.grantRole(registry.FINANCING_CONTRACT_ROLE(), address(pool));

        usdc.mint(investor, 1_000_000 * 10 ** 6);
        vm.stopPrank();

        // ---------------------------------------------------------
        // TARGET SETUP FOR INVARIANT TESTING
        // Tells the fuzzer: "Throw random calls at this contract!"
        // ---------------------------------------------------------
        targetContract(address(pool));
    }

    // ============================================================
    //  A. FUZZ TESTING (Stateless)
    // ============================================================

    /**
     * @notice Foundry will run this function 256 times with random numbers.
     * We don't hardcode $10,000. We test ALL possible valid and invalid numbers.
     */
    function testFuzz_createInvoice_amounts(
        uint256 amount,
        uint256 financingAmount
    ) public {
        // Bound random numbers to a realistic range (1 to 100M USDC)
        amount = bound(amount, 1, 100_000_000 * 10 ** 6);

        // If the fuzzer generates an invalid financing amount, we EXPECT a revert.
        if (financingAmount == 0 || financingAmount > amount) {
            vm.expectRevert();
        }

        vm.prank(business);
        registry.createInvoice(
            buyer,
            amount,
            financingAmount,
            block.timestamp + 30 days,
            DOC_HASH
        );
    }

    // ============================================================
    //  B. REENTRANCY SECURITY TEST
    // ============================================================

    /**
     * @notice Prove that our nonReentrant guard actually blocks hackers.
     */
    function test_security_reentrancy_isBlocked() public {
        // 1. Setup a corrupted FinancingPool that uses our MaliciousToken instead of USDC
        vm.startPrank(admin);
        MaliciousToken evilToken = new MaliciousToken();
        FinancingPool corruptedPool = new FinancingPool(
            admin,
            address(registry),
            address(evilToken)
        );
        registry.grantRole(
            registry.FINANCING_CONTRACT_ROLE(),
            address(corruptedPool)
        );
        vm.stopPrank();

        // 2. Create and verify a real invoice
        vm.prank(business);
        uint256 id = registry.createInvoice(
            buyer,
            10_000 * 10 ** 6,
            9_500 * 10 ** 6,
            block.timestamp + 30 days,
            DOC_HASH
        );
        vm.prank(admin);
        registry.verifyInvoice(id);

        // 3. Setup the attacker
        address hacker = makeAddr("hacker");
        vm.prank(admin);
        evilToken.transfer(hacker, 100_000 * 10 ** 6);

        vm.startPrank(hacker);
        evilToken.approve(address(corruptedPool), 100_000 * 10 ** 6);
        evilToken.setupAttack(corruptedPool, id);

        // 4. TRIGGER THE ATTACK
        // The hacker calls fundInvoice. Deep inside that function, evilToken.transferFrom
        // fires, which calls back into fundInvoice!

        // OpenZeppelin v5 ReentrancyGuard custom error selector
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        corruptedPool.fundInvoice(id);

        vm.stopPrank();
        console.log(
            "SUCCESS: Reentrancy attack was blocked by ReentrancyGuard!"
        );
    }

    // ============================================================
    //  C. INVARIANT TESTING (Stateful Fuzzing)
    // ============================================================

    /**
     * @notice This invariant must ALWAYS be true, no matter what functions the
     * fuzzer calls, in whatever order, with whatever inputs.
     *
     * THE TRUTH: "The FinancingPool acts strictly as a router. It should NEVER
     * hold any USDC itself at the end of a transaction."
     */
    function invariant_poolShouldNeverHoldTokens() public {
        uint256 poolBalance = usdc.balanceOf(address(pool));
        assertEq(poolBalance, 0, "CRITICAL BUG: Funds got stuck in the pool!");
    }
}
