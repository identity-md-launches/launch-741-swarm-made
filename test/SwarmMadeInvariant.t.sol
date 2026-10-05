// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmMade} from "../src/SwarmMade.sol";

/// @notice Drives the token with random call sequences from many accounts and keeps a reference
///         model of what every balance and allowance must be according to ERC-20, independently of
///         the token's own storage. The invariants compare the two after every call.
/// @dev Every function is total: inputs are bounded, never discarded, and an attempt that must fail
///      is made with `vm.expectRevert` so that a call which wrongly succeeds reverts the handler.
///      The invariant runs set `fail-on-revert`, so a handler revert is a failure, not a skipped call.
contract SwarmMadeHandler is Test {
    struct Grant {
        address owner;
        address spender;
    }

    SwarmMade public immutable token;

    /// @dev Accounts that may send, approve and spend.
    address[] internal _actors;
    /// @dev Every account whose balance is tracked: the actors plus the token contract itself, which
    ///      can receive tokens but has no way to send them.
    address[] internal _holders;
    mapping(address => bool) internal _isHolder;

    /// @dev The reference model. Seeded from what the test sent, updated from what was requested.
    mapping(address => uint256) public modelBalance;
    mapping(address => mapping(address => uint256)) public modelAllowance;

    /// @dev Every (owner, spender) pair an approval was ever made for.
    Grant[] internal _grants;
    mapping(address => mapping(address => bool)) public isGrant;

    /// @dev Selectors of privileged functions a token might hide. None may exist here.
    bytes4[] internal _privileged;

    uint256 public transfersOk;
    uint256 public transferFromsOk;
    uint256 public approvalsOk;
    uint256 public newHolders;
    uint256 public rejections;
    uint256 public sentToTokenContract;

    constructor(SwarmMade token_, address[] memory actors_, uint256[] memory balances_) {
        require(actors_.length == balances_.length, "length mismatch");
        token = token_;
        _isHolder[address(token_)] = true;
        _holders.push(address(token_));
        for (uint256 i = 0; i < actors_.length; i++) {
            _addActor(actors_[i]);
            modelBalance[actors_[i]] = balances_[i];
        }

        string[30] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burn(address,uint256)",
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
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "seize(address)",
            "setFee(uint256)",
            "rescueTokens(address,address,uint256)",
            "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            _privileged.push(bytes4(keccak256(bytes(signatures[i]))));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    /// @notice A funded account sends any part of its balance to a tracked account or to the token.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _fundedActor(fromSeed);
        address to = _holders[toSeed % _holders.length];
        _transfer(from, to, bound(amount, 0, modelBalance[from]));
    }

    /// @notice A funded account sends its entire balance, the edge of the balance check.
    function transferWholeBalance(uint256 fromSeed, uint256 toSeed) external {
        address from = _fundedActor(fromSeed);
        address to = _holders[toSeed % _holders.length];
        _transfer(from, to, modelBalance[from]);
    }

    /// @notice A funded account sends to an arbitrary address the suite has never seen, which then
    ///         becomes an actor in its own right. The zero address must be refused.
    function transferToAnyAddress(uint256 fromSeed, address to, uint256 amount) external {
        address from = _fundedActor(fromSeed);
        amount = bound(amount, 0, modelBalance[from]);
        if (to == address(0)) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(from);
            token.transfer(to, amount);
            rejections++;
            return;
        }
        if (!_isHolder[to]) {
            _addActor(to);
            newHolders++;
        }
        _transfer(from, to, amount);
    }

    /// @notice Any account, funded or not, tries to send more than it holds.
    function transferMoreThanBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actors[fromSeed % _actors.length];
        address to = _holders[toSeed % _holders.length];
        uint256 held = modelBalance[from];
        amount = bound(amount, held + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount));
        vm.prank(from);
        token.transfer(to, amount);
        rejections++;
    }

    // ---------------------------------------------------------------------------------------------
    // Approvals
    // ---------------------------------------------------------------------------------------------

    /// @notice Any account approves any tracked account (itself and the token included) for any value.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        _approve(_actors[ownerSeed % _actors.length], _holders[spenderSeed % _holders.length], amount);
    }

    /// @notice The infinite approval, which must never be decremented by a spend.
    function approveMax(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actors[ownerSeed % _actors.length], _holders[spenderSeed % _holders.length], type(uint256).max);
    }

    /// @notice Approving the zero address must be refused, whatever the value.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actors[ownerSeed % _actors.length];
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
        rejections++;
    }

    // ---------------------------------------------------------------------------------------------
    // Allowance spends
    // ---------------------------------------------------------------------------------------------

    /// @notice A spender pulls up to what it was granted and the owner holds. When no grant is
    ///         spendable the pull is for zero, which needs neither allowance nor balance.
    function transferFrom(uint256 grantSeed, uint256 toSeed, uint256 amount) external {
        address to = _holders[toSeed % _holders.length];
        (bool found, Grant memory grant) = _spendableGrant(grantSeed);
        if (!found) {
            grant = Grant(_actors[grantSeed % _actors.length], _actors[toSeed % _actors.length]);
        }
        uint256 allowed = modelAllowance[grant.owner][grant.spender];
        uint256 held = modelBalance[grant.owner];
        amount = bound(amount, 0, allowed < held ? allowed : held);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(grant.spender);
        assertTrue(token.transferFrom(grant.owner, to, amount), "transferFrom returned false");

        if (allowed != type(uint256).max) modelAllowance[grant.owner][grant.spender] = allowed - amount;
        modelBalance[grant.owner] -= amount;
        modelBalance[to] += amount;
        if (to == address(token) && grant.owner != to) sentToTokenContract += amount;

        assertEq(token.balanceOf(grant.owner), modelBalance[grant.owner], "owner balance after transferFrom");
        assertEq(token.balanceOf(to), modelBalance[to], "receiver balance after transferFrom");
        assertEq(
            token.allowance(grant.owner, grant.spender),
            modelAllowance[grant.owner][grant.spender],
            "allowance after transferFrom"
        );
        assertEq(token.totalSupply(), supplyBefore, "transferFrom changed the supply");
        transferFromsOk++;
    }

    /// @notice A spender tries to pull more than its (finite) allowance from any account.
    function transferFromMoreThanAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount)
        external
    {
        address owner = _actors[ownerSeed % _actors.length];
        address spender = _actors[spenderSeed % _actors.length];
        address to = _holders[toSeed % _holders.length];
        uint256 allowed = modelAllowance[owner][spender];
        if (allowed == type(uint256).max) {
            // An infinite allowance cannot be exceeded; the balance is the only limit left.
            uint256 held = modelBalance[owner];
            amount = bound(amount, held + 1, type(uint256).max);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount));
        } else {
            amount = bound(amount, allowed + 1, type(uint256).max);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        }
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        rejections++;
    }

    /// @notice A spender with enough allowance tries to pull more than the owner holds. The spend
    ///         must fail and the allowance must come back whole (the model is left untouched).
    function transferFromMoreThanBalance(uint256 grantSeed, uint256 toSeed, uint256 amount) external {
        uint256 count = _grants.length;
        for (uint256 i = 0; i < count; i++) {
            Grant memory grant = _grants[(grantSeed % count + i) % count];
            uint256 allowed = modelAllowance[grant.owner][grant.spender];
            uint256 held = modelBalance[grant.owner];
            if (allowed <= held) continue;
            amount = bound(amount, held + 1, allowed);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, grant.owner, held, amount)
            );
            vm.prank(grant.spender);
            token.transferFrom(grant.owner, _holders[toSeed % _holders.length], amount);
            rejections++;
            return;
        }
    }

    /// @notice A spender tries to pull to the zero address, within its allowance.
    function transferFromToZeroAddress(uint256 grantSeed, uint256 amount) external {
        if (_grants.length == 0) return;
        Grant memory grant = _grants[grantSeed % _grants.length];
        amount = bound(amount, 0, modelAllowance[grant.owner][grant.spender]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(grant.spender);
        token.transferFrom(grant.owner, address(0), amount);
        rejections++;
    }

    // ---------------------------------------------------------------------------------------------
    // Everything that must not exist
    // ---------------------------------------------------------------------------------------------

    /// @notice Any account calls a privileged function a token might hide, aimed at another account.
    function callPrivileged(uint256 callerSeed, uint256 selectorSeed, uint256 victimSeed, uint256 amount) external {
        address caller = _actors[callerSeed % _actors.length];
        address victim = _holders[victimSeed % _holders.length];
        bytes4 selector = _privileged[selectorSeed % _privileged.length];
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, abi.encode(victim, amount, victim, amount)));
        assertFalse(ok, "a privileged function exists");
        rejections++;
    }

    /// @notice Any account sends arbitrary calldata. Anything outside the ERC-20 surface must fail;
    ///         the three mutators are left to the handlers above so the model stays exact.
    function callArbitrary(uint256 callerSeed, bytes4 selector, bytes calldata payload) external {
        if (
            selector == token.transfer.selector || selector == token.approve.selector
                || selector == token.transferFrom.selector
        ) return;
        address caller = _actors[callerSeed % _actors.length];
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodePacked(selector, payload));
        if (!_isView(selector)) {
            assertFalse(ok, "an undeclared function exists");
            rejections++;
        }
    }

    /// @notice Any account tries to pay the token, with or without calldata. Nothing is payable.
    function sendEther(uint256 callerSeed, uint256 value, bool viaTransfer) external {
        address caller = _actors[callerSeed % _actors.length];
        value = bound(value, 1, 100 ether);
        vm.deal(caller, value);
        bytes memory data = viaTransfer ? abi.encodeCall(token.transfer, (caller, 0)) : bytes("");
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(data);
        assertFalse(ok, "the token accepted ether");
        rejections++;
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------

    function holderCount() external view returns (uint256) {
        return _holders.length;
    }

    function holderAt(uint256 index) external view returns (address) {
        return _holders[index];
    }

    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 index) external view returns (address) {
        return _actors[index];
    }

    function grantCount() external view returns (uint256) {
        return _grants.length;
    }

    function grantAt(uint256 index) external view returns (address owner, address spender) {
        Grant memory grant = _grants[index];
        return (grant.owner, grant.spender);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");

        modelBalance[from] -= amount;
        modelBalance[to] += amount;
        if (to == address(token)) sentToTokenContract += amount;

        assertEq(token.balanceOf(from), modelBalance[from], "sender balance after transfer");
        assertEq(token.balanceOf(to), modelBalance[to], "receiver balance after transfer");
        assertEq(token.totalSupply(), supplyBefore, "transfer changed the supply");
        transfersOk++;
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        modelAllowance[owner][spender] = amount;
        if (!isGrant[owner][spender]) {
            isGrant[owner][spender] = true;
            _grants.push(Grant(owner, spender));
        }
        assertEq(token.allowance(owner, spender), amount, "allowance after approve");
        approvalsOk++;
    }

    function _addActor(address account) internal {
        require(!_isHolder[account], "duplicate actor");
        _isHolder[account] = true;
        _actors.push(account);
        _holders.push(account);
    }

    /// @dev The first actor at or after the seeded position that holds something, so that most
    ///      transfers move a real amount. Falls back to the seeded actor when nobody is funded.
    function _fundedActor(uint256 seed) internal view returns (address) {
        uint256 count = _actors.length;
        for (uint256 i = 0; i < count; i++) {
            address candidate = _actors[(seed % count + i) % count];
            if (modelBalance[candidate] != 0) return candidate;
        }
        return _actors[seed % count];
    }

    /// @dev The first grant at or after the seeded position with both allowance and balance behind it,
    ///      whose spender is able to act (the token contract can be approved but can never spend).
    function _spendableGrant(uint256 seed) internal view returns (bool, Grant memory grant) {
        uint256 count = _grants.length;
        for (uint256 i = 0; i < count; i++) {
            grant = _grants[(seed % count + i) % count];
            if (
                grant.spender != address(token) && modelAllowance[grant.owner][grant.spender] != 0
                    && modelBalance[grant.owner] != 0
            ) return (true, grant);
        }
        return (false, grant);
    }

    function _isView(bytes4 selector) internal view returns (bool) {
        return selector == token.name.selector || selector == token.symbol.selector
            || selector == token.decimals.selector || selector == token.totalSupply.selector
            || selector == token.balanceOf.selector || selector == token.allowance.selector
            || selector == token.TOKEN_NAME.selector || selector == token.TOKEN_SYMBOL.selector
            || selector == token.TOTAL_SUPPLY.selector;
    }
}

/// @notice Invariants of Swarm Made over random call sequences, starting from the state the launch
///         leaves behind: 10% with the distributor, 88% with the pool manager, 2% with the
///         requester's address, nothing with the factory.
/// @dev Run counts are set inline because foundry.toml is not this suite's to change. `fail-on-revert`
///      is on so that an assertion inside the handler fails the run instead of being discarded.
contract SwarmMadeInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address internal constant REMAINDER_TO = 0x1846927b920FA2D41766ED4F88F1d10e640F1590;

    SwarmMade internal token;
    SwarmMadeHandler internal handler;
    bytes32 internal codehashAtLaunch;

    address internal factory = makeAddr("factory");
    address internal distributor = makeAddr("distributor");
    address internal poolManager = makeAddr("poolManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        vm.prank(factory);
        token = new SwarmMade();

        address[] memory actors = new address[](7);
        uint256[] memory balances = new uint256[](7);
        (actors[0], balances[0]) = (factory, 0);
        (actors[1], balances[1]) = (distributor, (SUPPLY * 1_000) / 10_000);
        (actors[2], balances[2]) = (poolManager, (SUPPLY * 8_800) / 10_000);
        (actors[3], balances[3]) = (REMAINDER_TO, SUPPLY - balances[1] - balances[2]);
        (actors[4], balances[4]) = (alice, 0);
        (actors[5], balances[5]) = (bob, 0);
        (actors[6], balances[6]) = (carol, 0);

        vm.startPrank(factory);
        for (uint256 i = 1; i <= 3; i++) {
            token.transfer(actors[i], balances[i]);
        }
        vm.stopPrank();

        handler = new SwarmMadeHandler(token, actors, balances);
        codehashAtLaunch = address(token).codehash;

        bytes4[] memory selectors = new bytes4[](14);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferWholeBalance.selector;
        selectors[2] = handler.transferToAnyAddress.selector;
        selectors[3] = handler.transferMoreThanBalance.selector;
        selectors[4] = handler.approve.selector;
        selectors[5] = handler.approveMax.selector;
        selectors[6] = handler.approveZeroSpender.selector;
        selectors[7] = handler.transferFrom.selector;
        selectors[8] = handler.transferFromMoreThanAllowance.selector;
        selectors[9] = handler.transferFromMoreThanBalance.selector;
        selectors[10] = handler.transferFromToZeroAddress.selector;
        selectors[11] = handler.callPrivileged.selector;
        selectors[12] = handler.callArbitrary.selector;
        selectors[13] = handler.sendEther.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ---------------------------------------------------------------------------------------------
    // Invariants
    // ---------------------------------------------------------------------------------------------

    /// @notice The supply is fixed: no sequence of calls from anyone mints or burns a single unit.
    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY, "the supply constant changed");
    }

    /// @notice Conservation: the balances of every account that ever held or was offered tokens add
    ///         up to the supply exactly. Nothing leaks, nothing appears, nothing is skimmed.
    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToTheSupply() public view {
        uint256 sum;
        uint256 count = handler.holderCount();
        for (uint256 i = 0; i < count; i++) {
            sum += token.balanceOf(handler.holderAt(i));
        }
        assertEq(sum, SUPPLY, "tracked balances do not add up to the supply");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// @notice Every balance is exactly what the requested transfers say it should be: no fee, no
    ///         rounding, no hand moving a holder's balance other than the holder or its spender.
    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyBalanceMatchesTheModel() public view {
        uint256 count = handler.holderCount();
        for (uint256 i = 0; i < count; i++) {
            address holder = handler.holderAt(i);
            assertEq(token.balanceOf(holder), handler.modelBalance(holder), "a balance drifted from the model");
        }
    }

    /// @notice Every allowance is exactly what its owner last set, less what its spender spent.
    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyAllowanceMatchesTheModel() public view {
        uint256 grants = handler.grantCount();
        for (uint256 i = 0; i < grants; i++) {
            (address owner, address spender) = handler.grantAt(i);
            assertEq(
                token.allowance(owner, spender),
                handler.modelAllowance(owner, spender),
                "an allowance drifted from the model"
            );
        }
    }

    /// @notice At the end of every sequence: no account holds an allowance its owner never granted,
    ///         in every pairing of the seven launch accounts and the token itself.
    function afterInvariant() public view {
        _assertNoUngrantedAllowances();
    }

    function _assertNoUngrantedAllowances() internal view {
        for (uint256 i = 0; i < 8; i++) {
            address owner = handler.holderAt(i);
            for (uint256 j = 0; j < 8; j++) {
                address spender = handler.holderAt(j);
                if (!handler.isGrant(owner, spender)) {
                    assertEq(token.allowance(owner, spender), 0, "an allowance exists that nobody granted");
                }
            }
        }
    }

    /// @notice Tokens sent to the token contract stay there: it has no function that could move
    ///         them and nobody, the deployer included, has a privileged way to take them.
    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_tokenContractBalanceOnlyGrowsByWhatWasSentToIt() public view {
        assertEq(token.balanceOf(address(token)), handler.sentToTokenContract(), "the token contract's own balance");
    }

    /// @notice The contract never holds ether, its code never changes and its metadata is constant.
    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_noEtherNoCodeChangeNoMetadataChange() public view {
        assertEq(address(token).balance, 0, "the token holds ether");
        assertEq(address(token).codehash, codehashAtLaunch, "the token's code changed");
        assertEq(token.name(), "Swarm Made");
        assertEq(token.symbol(), "MADE");
        assertEq(token.decimals(), 18);
    }

    // ---------------------------------------------------------------------------------------------
    // The harness itself
    // ---------------------------------------------------------------------------------------------

    /// @dev The launch split the campaign starts from is the one the brief describes.
    function test_campaignStartsFromTheLaunchState() public view {
        assertEq(token.balanceOf(factory), 0);
        assertEq(token.balanceOf(distributor), 100_000_000e18);
        assertEq(token.balanceOf(poolManager), 880_000_000e18);
        assertEq(token.balanceOf(REMAINDER_TO), 20_000_000e18);
        assertEq(handler.holderCount(), 8);
        assertEq(handler.holderAt(0), address(token));
        assertEq(handler.actorCount(), 7);
        invariant_totalSupplyNeverChanges();
        invariant_balancesSumToTheSupply();
        invariant_everyBalanceMatchesTheModel();
        invariant_everyAllowanceMatchesTheModel();
        _assertNoUngrantedAllowances();
        invariant_tokenContractBalanceOnlyGrowsByWhatWasSentToIt();
        invariant_noEtherNoCodeChangeNoMetadataChange();
    }

    /// @dev Walks every handler function down the branch it is meant to reach, with fixed inputs, so
    ///      that a campaign cannot pass merely because its handlers never did anything.
    function test_everyHandlerPathIsReachable() public {
        // Actor indices: 0 factory, 1 distributor, 2 poolManager, 3 remainderTo, 4 alice, 5 bob, 6 carol.
        // Holder indices: 0 token, then the actors shifted by one.
        handler.transfer(1, 5, 40e18); // distributor -> alice
        assertEq(token.balanceOf(alice), 40e18);
        handler.transfer(4, 0, 1e18); // alice -> the token contract
        assertEq(token.balanceOf(address(token)), 1e18);
        assertEq(handler.sentToTokenContract(), 1e18);
        handler.transfer(0, 5, 0); // the unfunded factory is skipped: distributor -> alice, zero
        handler.transferWholeBalance(4, 6); // alice -> bob, everything
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 39e18);
        assertEq(handler.transfersOk(), 4);

        address stranger = makeAddr("stranger");
        handler.transferToAnyAddress(5, stranger, 9e18); // bob -> stranger
        assertEq(token.balanceOf(stranger), 9e18);
        assertEq(handler.newHolders(), 1);
        assertEq(handler.holderCount(), 9);
        handler.transferToAnyAddress(5, address(0), 1e18);
        assertEq(handler.rejections(), 1);
        handler.transferMoreThanBalance(4, 5, 0); // alice holds nothing and tries to send 1
        handler.transferMoreThanBalance(5, 5, type(uint256).max);
        assertEq(handler.rejections(), 3);

        handler.approve(5, 7, 20e18); // bob approves carol
        assertEq(token.allowance(bob, carol), 20e18);
        handler.approveMax(2, 5); // poolManager approves alice without limit
        handler.approve(5, 0, 5e18); // bob approves the token contract, which can never spend
        handler.approveZeroSpender(5, 1);
        assertEq(handler.approvalsOk(), 3);
        assertEq(handler.grantCount(), 3);
        assertEq(handler.rejections(), 4);

        handler.transferFrom(0, 5, 15e18); // carol pulls from bob to alice
        assertEq(token.balanceOf(alice), 15e18);
        assertEq(token.allowance(bob, carol), 5e18);
        handler.transferFrom(1, 6, 1e18); // alice pulls from poolManager to bob
        assertEq(token.allowance(poolManager, alice), type(uint256).max);
        handler.transferFrom(2, 0, 1e18); // the token's grant is skipped: carol pulls from bob again
        assertEq(token.allowance(bob, carol), 4e18);
        assertEq(handler.transferFromsOk(), 3);

        handler.transferFromMoreThanAllowance(5, 6, 4, 0); // carol over bob: 4e18 + 1
        handler.transferFromMoreThanAllowance(2, 4, 4, 0); // alice over poolManager: infinite, so the balance refuses
        handler.transferFromMoreThanAllowance(0, 1, 4, 0); // no grant at all
        assertEq(handler.rejections(), 7);

        handler.approve(5, 7, 1_000e18); // bob approves carol for more than he holds
        handler.transferFromMoreThanBalance(0, 4, 0);
        assertEq(token.allowance(bob, carol), 1_000e18, "a failed spend consumed allowance");
        handler.transferFromToZeroAddress(0, 1e18);
        assertEq(handler.rejections(), 9);

        handler.callPrivileged(0, 0, 5, 1e18); // the factory tries mint(alice, 1e18)
        handler.callPrivileged(4, 6, 6, 1e18); // alice tries burnFrom(bob, 1e18)
        handler.callArbitrary(4, 0xdeadbeef, hex"01");
        handler.callArbitrary(4, token.balanceOf.selector, abi.encode(alice)); // a view: allowed, counts nothing
        handler.callArbitrary(4, token.transfer.selector, abi.encode(alice, 1)); // left to the modelled handler
        handler.sendEther(4, 1 ether, false);
        handler.sendEther(4, 1 ether, true);
        assertEq(handler.rejections(), 14);

        invariant_totalSupplyNeverChanges();
        invariant_balancesSumToTheSupply();
        invariant_everyBalanceMatchesTheModel();
        invariant_everyAllowanceMatchesTheModel();
        _assertNoUngrantedAllowances();
        invariant_tokenContractBalanceOnlyGrowsByWhatWasSentToIt();
        invariant_noEtherNoCodeChangeNoMetadataChange();
    }
}
