// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmMade} from "../src/SwarmMade.sol";

/// @notice Deploys with CREATE2 through a low-level call so that a failed deployment returns the
///         zero address instead of reverting the test.
contract RawCreate2 {
    function deploy(bytes32 salt, uint256 value) external payable returns (address deployed) {
        bytes memory code = type(SwarmMade).creationCode;
        assembly ("memory-safe") {
            deployed := create2(value, add(code, 32), mload(code), salt)
        }
    }
}

/// @notice The inputs the implementation did not pick: the zero address as owner, the token as a
///         receiver, calls with dirty or short calldata, the same call twice, callers who are nobody.
///         Also the shape of the contract: what it writes, what it returns, which opcodes and which
///         selectors it contains, so that "no fees, no rules, no owner" is checked against the
///         bytecode and not only against the functions the author chose to expose.
contract SwarmMadeAdversarialTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant BALANCES_SLOT = 0;
    uint256 internal constant ALLOWANCES_SLOT = 1;

    SwarmMade internal token;
    address internal deployer = address(this);
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public {
        token = new SwarmMade();
    }

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    function test_constructorEmitsExactlyOneEvent() public {
        vm.recordLogs();
        SwarmMade fresh = new SwarmMade();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "the constructor emitted more than the mint");
        assertEq(logs[0].emitter, address(fresh));
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_constructorRefusesEther() public {
        RawCreate2 raw = new RawCreate2();
        vm.deal(address(raw), 1 ether);
        address deployed = raw.deploy(bytes32(uint256(1)), 1);
        assertEq(deployed, address(0), "a non-payable constructor accepted ether");
        // Without value the same salt works, and the deployer, not the test, gets the supply.
        deployed = raw.deploy(bytes32(uint256(1)), 0);
        assertTrue(deployed != address(0));
        assertEq(SwarmMade(deployed).balanceOf(address(raw)), SUPPLY);
    }

    /// @dev "Minted once": the same launch number cannot be replayed to mint a second supply.
    function test_sameSaltCannotDeployTwice() public {
        RawCreate2 raw = new RawCreate2();
        address first = raw.deploy(bytes32(uint256(9)), 0);
        address second = raw.deploy(bytes32(uint256(9)), 0);
        assertTrue(first != address(0));
        assertEq(second, address(0), "a second deployment at the same address succeeded");
        assertEq(SwarmMade(first).totalSupply(), SUPPLY);
        assertEq(SwarmMade(first).balanceOf(address(raw)), SUPPLY);
    }

    function test_deploymentsAreIndependent() public {
        vm.prank(alice, alice);
        SwarmMade other = new SwarmMade();
        assertEq(other.balanceOf(alice), SUPPLY);
        assertEq(other.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), 0);
        token.transfer(bob, 1e18);
        assertEq(other.balanceOf(bob), 0);
        assertEq(other.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // What a call writes and returns
    // ---------------------------------------------------------------------------------------------

    function _balanceSlot(address account) internal pure returns (bytes32) {
        return keccak256(abi.encode(account, BALANCES_SLOT));
    }

    function _allowanceSlot(address owner, address spender) internal pure returns (bytes32) {
        return keccak256(abi.encode(spender, keccak256(abi.encode(owner, ALLOWANCES_SLOT))));
    }

    /// @dev No hidden bookkeeping: a transfer touches the two balances and nothing else, so there is
    ///      no fee accumulator, no last-transfer timestamp, no per-account counter, no reflection index.
    function test_transferWritesOnlyTheTwoBalances() public {
        vm.record();
        token.transfer(alice, 1e18);
        (, bytes32[] memory writes) = vm.accesses(address(token));
        assertEq(writes.length, 2, "a transfer wrote more than two slots");
        assertEq(writes[0], _balanceSlot(deployer));
        assertEq(writes[1], _balanceSlot(alice));
        assertEq(uint256(vm.load(address(token), _balanceSlot(alice))), 1e18);
    }

    function test_approveWritesOnlyTheAllowance() public {
        vm.record();
        token.approve(alice, 5e18);
        (, bytes32[] memory writes) = vm.accesses(address(token));
        assertEq(writes.length, 1, "an approval wrote more than one slot");
        assertEq(writes[0], _allowanceSlot(deployer, alice));
        assertEq(uint256(vm.load(address(token), _allowanceSlot(deployer, alice))), 5e18);
    }

    function test_transferFromWritesTheAllowanceAndTheTwoBalances() public {
        token.approve(alice, 5e18);
        vm.record();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 2e18);
        (, bytes32[] memory writes) = vm.accesses(address(token));
        assertEq(writes.length, 3, "a transferFrom wrote more than three slots");
        assertEq(writes[0], _allowanceSlot(deployer, alice));
        assertEq(writes[1], _balanceSlot(deployer));
        assertEq(writes[2], _balanceSlot(bob));
    }

    function test_infiniteAllowanceSpendWritesNoAllowance() public {
        token.approve(alice, type(uint256).max);
        vm.record();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 2e18);
        (, bytes32[] memory writes) = vm.accesses(address(token));
        assertEq(writes.length, 2);
    }

    function test_viewsWriteNothing() public {
        vm.record();
        token.name();
        token.symbol();
        token.decimals();
        token.totalSupply();
        token.balanceOf(alice);
        token.allowance(alice, bob);
        (, bytes32[] memory writes) = vm.accesses(address(token));
        assertEq(writes.length, 0);
    }

    /// @dev Integrators (the factory's IToken, v4's currency library) check the returned word, so it
    ///      must be exactly one word holding exactly `true`.
    function test_mutatorsReturnExactlyOneTrueWord() public {
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(token.transfer, (alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);

        (ok, ret) = address(token).call(abi.encodeCall(token.approve, (alice, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);

        vm.prank(alice);
        (ok, ret) = address(token).call(abi.encodeCall(token.transferFrom, (deployer, bob, 1)));
        assertTrue(ok);
        assertEq(ret.length, 32);
        assertEq(abi.decode(ret, (uint256)), 1);
    }

    function test_viewsAnswerUnderStaticcallAndMutatorsDoNot() public view {
        (bool ok, bytes memory ret) = address(token).staticcall(abi.encodeCall(token.balanceOf, (deployer)));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), SUPPLY);
        (ok,) = address(token).staticcall(abi.encodeCall(token.transfer, (alice, 1)));
        assertFalse(ok, "transfer succeeded in a static context");
        (ok,) = address(token).staticcall(abi.encodeCall(token.approve, (alice, 1)));
        assertFalse(ok, "approve succeeded in a static context");
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Malformed calldata
    // ---------------------------------------------------------------------------------------------

    function test_dirtyAddressBitsAreRejected() public {
        bytes memory data = abi.encodeCall(token.transfer, (alice, 1));
        data[4] = 0xFF; // high byte of the address word, which must be zero
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "an address with dirty upper bits was accepted");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_shortCalldataIsRejected() public {
        bytes memory data = abi.encodeCall(token.transfer, (alice, 1));
        bytes memory short = new bytes(36);
        for (uint256 i = 0; i < 36; i++) {
            short[i] = data[i];
        }
        (bool ok,) = address(token).call(short);
        assertFalse(ok, "truncated calldata was accepted");
        (ok,) = address(token).call(abi.encodePacked(token.transfer.selector));
        assertFalse(ok, "a bare selector was accepted");
        assertEq(token.balanceOf(alice), 0);
    }

    function test_extraCalldataIsIgnored() public {
        (bool ok,) = address(token).call(abi.encodePacked(abi.encodeCall(token.transfer, (alice, 7)), hex"deadbeef"));
        assertTrue(ok);
        assertEq(token.balanceOf(alice), 7);
    }

    function test_emptyCalldataIsRejected() public {
        (bool ok,) = address(token).call("");
        assertFalse(ok, "there is a fallback or receive function");
        (ok,) = address(token).call(hex"00");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    function test_zeroValueTransferEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(deployer, alice, 0);
        token.transfer(alice, 0);
    }

    function test_selfTransferEmits() public {
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(deployer, deployer, 3e18);
        token.transfer(deployer, 3e18);
    }

    function test_transferFromEmitsOnlyTransfer() public {
        token.approve(alice, 5e18);
        vm.recordLogs();
        vm.prank(alice);
        token.transferFrom(deployer, bob, 2e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom emitted more than Transfer");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(deployer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(bob))));
        assertEq(abi.decode(logs[0].data, (uint256)), 2e18);
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths the happy-path tests do not reach
    // ---------------------------------------------------------------------------------------------

    function test_transferFromTheZeroAddressReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1));
        token.transferFrom(address(0), alice, 1);
        // Even for zero, where no allowance is needed: the zero address can never be an approver.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function test_ownerCannotPullFromItselfWithoutSelfApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
        token.approve(deployer, 1);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, deployer), 0);
        assertEq(token.balanceOf(alice), 1);
    }

    function test_zeroValueTransferFromNeedsNoAllowance() public {
        vm.prank(bob);
        assertTrue(token.transferFrom(deployer, alice, 0));
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_selfTransferAboveBalanceReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
        token.transfer(deployer, SUPPLY + 1);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferOfMaxUintReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(alice, type(uint256).max);
    }

    /// @dev The allowance is spent before the balance is checked; a balance failure must undo the spend.
    function test_failedSpendLeavesTheAllowanceWhole() public {
        token.transfer(alice, 5e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 5e18, 8e18));
        token.transferFrom(alice, carol, 8e18);
        assertEq(token.allowance(alice, bob), 10e18, "a reverted spend consumed allowance");
        assertEq(token.balanceOf(alice), 5e18);
        assertEq(token.balanceOf(carol), 0);
    }

    /// @dev When several checks fail at once the order is: allowance, then receiver, then balance.
    function test_errorPrecedence() public {
        token.transfer(alice, 1e18);
        // No allowance, zero receiver, insufficient balance: the allowance is reported.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 2e18));
        token.transferFrom(alice, address(0), 2e18);
        // Allowance fine, zero receiver, insufficient balance: the receiver is reported.
        vm.prank(alice);
        token.approve(bob, 2e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(alice, address(0), 2e18);
        assertEq(token.allowance(alice, bob), 2e18);
    }

    function test_allowanceOfMaxMinusOneIsNotInfinite() public {
        token.approve(alice, type(uint256).max - 1);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, alice), type(uint256).max - 2);
    }

    function test_allowanceDoesNotFollowTheTokens() public {
        token.transfer(alice, 10e18);
        vm.prank(alice);
        token.approve(bob, 10e18);
        vm.prank(alice);
        token.transfer(carol, 10e18);
        // Bob was approved by alice, who now holds nothing; carol never approved anyone.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(carol, bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
        assertEq(token.allowance(alice, bob), 10e18, "the allowance over alice survives her balance");
        assertEq(token.allowance(carol, bob), 0);
    }

    function test_approveNeedsNoBalanceAndMayExceedSupply() public {
        vm.prank(alice);
        assertTrue(token.approve(bob, SUPPLY * 2));
        assertEq(token.allowance(alice, bob), SUPPLY * 2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_approveSelfAndTokenAsSpender() public {
        assertTrue(token.approve(deployer, 1));
        assertTrue(token.approve(address(token), 1));
        assertEq(token.allowance(deployer, address(token)), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No hooks, no outside dependencies, no rules
    // ---------------------------------------------------------------------------------------------

    /// @dev A recipient that reverts on any call still receives tokens, because the token never calls
    ///      it: there is no receiver hook that a malicious or broken recipient could use to block flows.
    function test_transferToARevertingContractSucceedsWithoutCallingIt() public {
        address bomb = makeAddr("bomb");
        vm.etch(bomb, hex"fe"); // INVALID: anything that calls it fails
        vm.expectCall(bomb, "", 0);
        assertTrue(token.transfer(bomb, 1e18));
        assertEq(token.balanceOf(bomb), 1e18);
        token.approve(bomb, 1e18);
        assertEq(token.allowance(deployer, bomb), 1e18);
    }

    function test_tokensSentToTheTokenContractCannotBeMovedByAnyone() public {
        token.transfer(address(token), 1e18);
        assertEq(token.balanceOf(address(token)), 1e18);
        address[3] memory callers = [deployer, alice, address(token)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, callers[i], 0, 1));
            token.transferFrom(address(token), callers[i], 1);
        }
        assertEq(token.balanceOf(address(token)), 1e18);
    }

    /// @dev "No transfer rules" in the bytecode: nothing in the runtime calls out, creates, reads the
    ///      block, the origin, the gas price or another account's code or balance. A transfer's
    ///      outcome can therefore depend on nothing but balances, allowances and the arguments.
    function test_runtimeHasNoCallsAndReadsNoEnvironment() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF0, "CREATE");
            assertTrue(op != 0xF1, "CALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF5, "CREATE2");
            assertTrue(op != 0xFA, "STATICCALL");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
            assertTrue(op != 0x31, "BALANCE");
            assertTrue(op != 0x32, "ORIGIN");
            assertTrue(op != 0x3A, "GASPRICE");
            assertTrue(op != 0x3B, "EXTCODESIZE");
            assertTrue(op != 0x3C, "EXTCODECOPY");
            assertTrue(op != 0x3F, "EXTCODEHASH");
            assertTrue(op != 0x40, "BLOCKHASH");
            assertTrue(op != 0x41, "COINBASE");
            assertTrue(op != 0x42, "TIMESTAMP");
            assertTrue(op != 0x43, "NUMBER");
            assertTrue(op != 0x44, "PREVRANDAO");
            assertTrue(op != 0x45, "GASLIMIT");
            assertTrue(op != 0x46, "CHAINID");
            assertTrue(op != 0x47, "SELFBALANCE");
            assertTrue(op != 0x48, "BASEFEE");
            assertTrue(op != 0x49, "BLOBHASH");
            assertTrue(op != 0x4A, "BLOBBASEFEE");
            assertTrue(op != 0x5C, "TLOAD");
            assertTrue(op != 0x5D, "TSTORE");
        }
    }

    /// @dev The external surface is exactly ERC-20 plus the three public constants. Every selector
    ///      the dispatcher can compare against is a PUSH immediate, so every immediate of up to four
    ///      bytes is tried: the twelve declared ones must answer and every other one must fail.
    function test_externalSurfaceIsExactlyErc20PlusThreeConstants() public {
        bytes4[12] memory declared = [
            token.name.selector,
            token.symbol.selector,
            token.decimals.selector,
            token.totalSupply.selector,
            token.balanceOf.selector,
            token.transfer.selector,
            token.allowance.selector,
            token.approve.selector,
            token.transferFrom.selector,
            token.TOKEN_NAME.selector,
            token.TOKEN_SYMBOL.selector,
            token.TOTAL_SUPPLY.selector
        ];
        bool[12] memory seen;

        bytes memory runtime = address(token).code;
        bytes memory args = abi.encode(alice, uint256(1), uint256(1), uint256(1));
        uint256 undeclaredTried;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op < 0x60 || op > 0x7F) continue;
            uint256 width = op - 0x5F;
            if (width <= 4 && i + width < runtime.length) {
                uint256 value;
                for (uint256 b = 1; b <= width; b++) {
                    value = (value << 8) | uint8(runtime[i + b]);
                }
                bytes4 candidate = bytes4(uint32(value));
                bool isDeclared;
                for (uint256 d = 0; d < declared.length; d++) {
                    if (candidate == declared[d]) {
                        isDeclared = true;
                        seen[d] = true;
                    }
                }
                if (!isDeclared) {
                    undeclaredTried++;
                    _assertNoFunction(candidate, args);
                }
            }
            i += width;
        }
        for (uint256 d = 0; d < declared.length; d++) {
            assertTrue(seen[d], "a declared selector was not found in the runtime");
        }
        assertGt(undeclaredTried, 0);
        _assertNoFunction(bytes4(0), args); // the one selector PUSH0 could encode
    }

    function _assertNoFunction(bytes4 selector, bytes memory args) internal {
        uint256 supplyBefore = token.totalSupply();
        uint256 heldBefore = token.balanceOf(deployer);
        address[2] memory callers = [deployer, alice];
        for (uint256 c = 0; c < callers.length; c++) {
            vm.prank(callers[c]);
            (bool ok, bytes memory ret) = address(token).call(abi.encodePacked(selector, args));
            assertFalse(ok, vm.toString(selector));
            assertEq(ret.length, 0, "an undeclared selector returned data");
        }
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(token.balanceOf(deployer), heldBefore);
    }

    // ---------------------------------------------------------------------------------------------
    // Properties
    // ---------------------------------------------------------------------------------------------

    /// @dev One oracle for every transferFrom outcome: predicted from the three inputs alone, then
    ///      compared with what happened, including that a failure changes nothing.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromOutcomeMatchesTheSpec(uint256 held, uint256 allowed, uint256 amount, bool toZero)
        public
    {
        held = bound(held, 0, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(bob, allowed);
        address to = toZero ? address(0) : carol;

        bytes memory expectedError;
        if (allowed != type(uint256).max && allowed < amount) {
            expectedError =
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, allowed, amount);
        } else if (toZero) {
            expectedError = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        } else if (held < amount) {
            expectedError = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount);
        }

        vm.prank(bob);
        if (expectedError.length != 0) {
            vm.expectRevert(expectedError);
            token.transferFrom(alice, to, amount);
            assertEq(token.balanceOf(alice), held);
            assertEq(token.balanceOf(carol), 0);
            assertEq(token.allowance(alice, bob), allowed);
        } else {
            assertTrue(token.transferFrom(alice, to, amount));
            assertEq(token.balanceOf(alice), held - amount);
            assertEq(token.balanceOf(carol), amount);
            assertEq(token.allowance(alice, bob), allowed == type(uint256).max ? allowed : allowed - amount);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Transfers are additive: two transfers move exactly what one would. No per-call fee, no
    ///      rounding, nothing lost to dust at any split point including 0 and the whole amount.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitTransferEqualsSingleTransfer(uint256 amount, uint256 cut) public {
        amount = bound(amount, 0, SUPPLY);
        cut = bound(cut, 0, amount);
        token.transfer(alice, cut);
        token.transfer(alice, amount - cut);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_roundTripRestoresBothBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfTransferChangesNothingOrReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        token.transfer(alice, held);
        vm.prank(alice);
        if (amount > held) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount));
        }
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Any receiver but zero, the token itself and precompiles included, gets exactly the amount.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferToAnyAddressIsExact(address to, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        if (to == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(to, amount);
            assertEq(token.balanceOf(deployer), SUPPLY);
            return;
        }
        uint256 expectedTo = to == deployer ? SUPPLY : amount;
        uint256 expectedFrom = to == deployer ? SUPPLY : SUPPLY - amount;
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), expectedTo);
        assertEq(token.balanceOf(deployer), expectedFrom);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Nobody without an allowance moves a holder's tokens, whoever they are.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_strangerCannotPull(address stranger, uint256 amount) public {
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, amount));
        token.transferFrom(deployer, stranger, amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    /// @dev Approvals never move tokens, whatever the owner, spender or value.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveNeverMovesTokens(address owner, address spender, uint256 amount) public {
        vm.prank(owner);
        if (owner == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        } else if (spender == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        }
        token.approve(spender, amount);
        if (owner != address(0) && spender != address(0)) assertEq(token.allowance(owner, spender), amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(owner), owner == deployer ? SUPPLY : 0);
        assertEq(token.balanceOf(spender), spender == deployer ? SUPPLY : 0);
    }

    /// @dev Nothing is payable: any calldata with any value fails and the token keeps no ether.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_valueIsAlwaysRejected(bytes calldata data, uint96 value) public {
        value = uint96(bound(value, 1, type(uint96).max));
        vm.deal(alice, value);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: value}(data);
        assertFalse(ok);
        assertEq(address(token).balance, 0);
        assertEq(alice.balance, value);
    }

    /// @dev Arbitrary calldata that is not one of the three mutators changes no balance.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unknownCalldataChangesNothing(address caller, bytes calldata data) public {
        token.transfer(alice, 1e18);
        if (data.length >= 4) {
            bytes4 selector = bytes4(data[:4]);
            if (
                selector == token.transfer.selector || selector == token.approve.selector
                    || selector == token.transferFrom.selector
            ) return;
        }
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        ok;
        assertEq(token.balanceOf(alice), 1e18);
        assertEq(token.balanceOf(deployer), SUPPLY - 1e18);
        assertEq(token.balanceOf(caller), caller == alice ? 1e18 : caller == deployer ? SUPPLY - 1e18 : 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
