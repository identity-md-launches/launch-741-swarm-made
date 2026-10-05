// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmMade} from "../src/SwarmMade.sol";

/// @notice Stands in for the ProjectFactory: deploys the token so that it, not the test, is
///         `msg.sender` in the constructor, and can forward tokens on command.
contract FactoryStandIn {
    function deployWithCreate2(bytes32 salt) external returns (SwarmMade) {
        return new SwarmMade{salt: salt}();
    }

    function send(SwarmMade token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract SwarmMadeTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;

    SwarmMade internal token;
    address internal deployer = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new SwarmMade();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Swarm Made");
        assertEq(token.symbol(), "MADE");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Swarm Made");
        assertEq(token.TOKEN_SYMBOL(), "MADE");
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), address(this), SUPPLY);
        new SwarmMade();
    }

    /// @dev The factory deploys through CREATE2 and must end up holding everything.
    function test_create2DeploymentMintsToTheFactoryNotTheOrigin() public {
        FactoryStandIn factory = new FactoryStandIn();
        SwarmMade t = factory.deployWithCreate2(bytes32(uint256(42)));
        assertEq(t.totalSupply(), SUPPLY);
        assertEq(t.balanceOf(address(factory)), SUPPLY);
        assertEq(t.balanceOf(address(this)), 0);
        assertEq(t.balanceOf(tx.origin), 0);
    }

    function test_create2AddressIsDeterministic() public {
        FactoryStandIn factory = new FactoryStandIn();
        bytes32 salt = bytes32(uint256(7));
        address predicted = vm.computeCreate2Address(salt, keccak256(type(SwarmMade).creationCode), address(factory));
        SwarmMade t = factory.deployWithCreate2(salt);
        assertEq(address(t), predicted);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 1_234e18;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
        vm.prank(bob); // bob holds nothing and may still send zero
        assertTrue(token.transfer(alice, 0));
    }

    function test_transferToSelfIsNoOp() public {
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferChainPreservesSupply() public {
        token.transfer(alice, 300e18);
        vm.prank(alice);
        token.transfer(bob, 200e18);
        vm.prank(bob);
        token.transfer(carol, 50e18);
        assertEq(token.balanceOf(alice), 100e18);
        assertEq(token.balanceOf(bob), 150e18);
        assertEq(token.balanceOf(carol), 50e18);
        assertEq(token.balanceOf(deployer) + 300e18, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesBalances(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        token.transfer(alice, 10e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 10e18, 10e18 + 1));
        token.transfer(bob, 10e18 + 1);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        token.transfer(alice, 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 held, uint256 attempt) public {
        held = bound(held, 0, SUPPLY - 1);
        attempt = bound(attempt, held + 1, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, attempt));
        token.transfer(bob, attempt);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, alice, 77e18);
        assertTrue(token.approve(alice, 77e18));
        assertEq(token.allowance(deployer, alice), 77e18);
    }

    function test_approveOverwritesPreviousAllowance() public {
        token.approve(alice, 10e18);
        token.approve(alice, 3e18);
        assertEq(token.allowance(deployer, alice), 3e18);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowanceExactly() public {
        token.approve(alice, 100e18);
        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 60e18));
        assertEq(token.balanceOf(bob), 60e18);
        assertEq(token.allowance(deployer, alice), 40e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 60e18);
    }

    function test_transferFromWithMaxAllowanceDoesNotDecrement() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        token.approve(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 5e18, 5e18 + 1));
        token.transferFrom(deployer, bob, 5e18 + 1);
    }

    function test_transferFromRevertsWhenOwnerBalanceTooLow() public {
        token.transfer(alice, 1e18);
        vm.prank(alice);
        token.approve(bob, 2e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        token.transferFrom(alice, carol, 2e18);
    }

    function test_transferFromRevertsToZeroAddress() public {
        token.approve(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1e18);
    }

    function testFuzz_transferFromNeverExceedsAllowance(uint256 allowed, uint256 spent) public {
        allowed = bound(allowed, 0, SUPPLY);
        spent = bound(spent, 0, SUPPLY);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (spent > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, allowed, spent)
            );
            token.transferFrom(deployer, bob, spent);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spent));
            assertEq(token.balanceOf(bob), spent);
            assertEq(token.allowance(deployer, alice), allowed - spent);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // No owner powers, no minting, no transfer rules
    // ---------------------------------------------------------------------------------------------

    /// @dev Every privileged selector a token might plausibly expose must be absent: the call fails
    ///      (there is no fallback) and neither the supply nor any balance changes, whoever calls.
    function test_noPrivilegedFunctionsExist() public {
        token.transfer(alice, 1_000e18);
        uint256 aliceBefore = token.balanceOf(alice);
        address attacker = makeAddr("attacker");
        string[24] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "setOwner(address)",
            "transferOwnership(address)",
            "renounceOwnership()",
            "upgradeTo(address)",
            "upgradeToAndCall(address,bytes)",
            "initialize(address)",
            "pause()",
            "unpause()",
            "setMinter(address)",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "setFee(uint256)",
            "setTaxRate(uint256)",
            "excludeFromFee(address)",
            "setTransfersEnabled(bool)",
            "seize(address)"
        ];
        address[3] memory callers = [attacker, deployer, address(token)];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, type(uint128).max);
            for (uint256 c = 0; c < callers.length; c++) {
                vm.prank(callers[c]);
                (bool ok,) = address(token).call(data);
                assertFalse(ok, signatures[i]);
            }
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(alice), aliceBefore, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
        // Alice is unaffected and can still move her tokens.
        vm.prank(alice);
        assertTrue(token.transfer(bob, aliceBefore));
        assertEq(token.balanceOf(bob), aliceBefore);
    }

    function test_deployerHasNoSpecialPowerOverHolders() public {
        token.transfer(alice, 500e18);
        // No allowance was granted, so even the deployer cannot pull from a holder.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 500e18);
    }

    function test_rejectsEther() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        vm.prank(alice);
        (ok,) = address(token).call{value: 1 ether}(abi.encodeWithSelector(IERC20.transfer.selector, bob, 0));
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F); // skip PUSH data
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flow, as the factory performs it
    // ---------------------------------------------------------------------------------------------

    /// @dev 10% to the distributor, 88% to the pool, the rest to the requester's address, every
    ///      hop arriving whole, and a later claim arriving whole too.
    function test_launchFlowsMoveExactAmounts() public {
        FactoryStandIn factory = new FactoryStandIn();
        SwarmMade t = factory.deployWithCreate2(bytes32(uint256(1)));
        address distributor = makeAddr("distributor");
        address poolManager = makeAddr("poolManager");
        address remainderTo = 0x1846927b920FA2D41766ED4F88F1d10e640F1590;
        address claimant = makeAddr("claimant");

        uint256 swarm = (SUPPLY * 1_000) / 10_000;
        uint256 pool = (SUPPLY * 8_800) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        assertEq(remainder, (SUPPLY * 200) / 10_000, "remainder is 2%");

        assertTrue(factory.send(t, distributor, swarm));
        assertTrue(factory.send(t, poolManager, pool));
        assertTrue(factory.send(t, remainderTo, remainder));

        assertEq(t.balanceOf(distributor), swarm, "swarm share short");
        assertEq(t.balanceOf(poolManager), pool, "pool seed short");
        assertEq(t.balanceOf(remainderTo), remainder, "remainder short");
        assertEq(t.balanceOf(address(factory)), 0, "factory kept something");

        vm.prank(distributor);
        assertTrue(t.transfer(claimant, swarm));
        assertEq(t.balanceOf(claimant), swarm, "claim short");
        assertEq(t.balanceOf(distributor), 0);

        // A trader buys from and sells back into the pool manager, whole both ways.
        address trader = makeAddr("trader");
        vm.prank(poolManager);
        assertTrue(t.transfer(trader, 1e18));
        assertEq(t.balanceOf(trader), 1e18);
        vm.prank(trader);
        assertTrue(t.transfer(poolManager, 1e18));
        assertEq(t.balanceOf(trader), 0);
        assertEq(t.balanceOf(poolManager), pool);

        assertEq(t.totalSupply(), SUPPLY, "launch changed the supply");
    }
}
