# Swarm Made (MADE)

A plain, fixed-supply community token for launch through IdentityMD's `ProjectFactory.launchCustom`.

| Item | Value |
|------|-------|
| Name | Swarm Made |
| Symbol | MADE |
| Decimals | 18 |
| Total supply | 1,000,000,000 MADE = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor (the factory), once, in the constructor |
| Constructor arguments | none |
| Owner / minter / pauser | none |
| Fees, burns, transfer rules | none |
| Upgradeable | no |

## Layout

```
src/SwarmMade.sol              the token (OpenZeppelin v5 ERC20, constructor mints the supply)
script/DeploySwarmMade.s.sol   launch parameters as constants + a deploy() function tests call directly
test/SwarmMade.t.sol           behaviour, failure and launch-flow tests
test/DeploySwarmMade.t.sol     deploy function and launch-parameter tests
lib/forge-std                  vendored test framework (v1.9.7, commit 77041d2c), ordinary files
lib/openzeppelin-contracts     vendored ERC20 slice of OpenZeppelin Contracts v5.1.0 (commit 69c8def5)
docs/DEPLOYMENT.md             deployment parameters, assumptions and operational responsibilities
foundry.toml                   solc 0.8.26, bytecode_hash = "none", cbor_metadata = false, no ffi, no fs access
```

Both dependencies are copied in as plain files (no git submodules) so the project builds offline.
Only the five OpenZeppelin files the token needs are vendored: `ERC20.sol`, `IERC20.sol`,
`IERC20Metadata.sol`, `Context.sol` and `draft-IERC6093.sol`, plus the licence.

## Build and test

```
forge build
forge test
forge fmt --check
```

Tests read no environment variables, do not depend on the caller address, and pass in any order and
in parallel. Fuzz tests use the default 256 runs.

## What the token does

`SwarmMade` is OpenZeppelin's `ERC20` with a constructor that mints `TOTAL_SUPPLY` to `msg.sender`.
Nothing else is added. Consequences:

- The supply can never grow. There is no `mint`, no minter role, no owner and no fallback function.
- The supply can never be moved by anyone but the holder, or a spender the holder approved. There is
  no `pause`, `blacklist`, `freeze`, `seize`, `burnFrom` or similar.
- Every transfer moves exactly the amount requested. The factory, the MerkleDistributor, the Uniswap
  v4 PoolManager and any later trader are treated identically, so the launch flows arrive whole. No
  exemption list is needed and the constructor takes no launch addresses.
- Transfers to the zero address revert. Transfers that exceed the balance or allowance revert with
  the ERC-6093 custom errors. Zero-value transfers and transfers to self succeed.
- The contract has no `receive` or `fallback`, so ETH sent to it is rejected.
- The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` (checked by a test).

## Launch economics

Copied from the job, in the manifest's terms. See `docs/DEPLOYMENT.md` for the derivation and the
operational notes.

| Field | Value |
|-------|-------|
| `economics.poolBps` | `8800` (88% of the whole supply seeds the single-sided pool) |
| `economics.initialMarketCapWei` | `2500000000000000000000` (2,500 IMD, 18-decimal minor units) |
| `economics.remainderTo` | `0x1846927b920FA2D41766ED4F88F1d10e640F1590` |
| Swarm share (by construction, not in the manifest) | 10% = 100,000,000 MADE |
| Pool seed | 880,000,000 MADE |
| Remainder forwarded to `remainderTo` | 20,000,000 MADE |

## Security notes

The eth-security checklist was walked for this contract. Items that apply to a token with no
privileged functions, no external calls, no oracle, no swaps, no proxy and no signatures:

- Access control: there are no privileged functions to guard. Verified by `test_noPrivilegedFunctionsExist`.
- Reentrancy: the token makes no external calls.
- Decimals: 18, stated once as a constant and asserted in tests against `decimals()`.
- Events: `Transfer` and `Approval` are emitted by the inherited implementation; the constructor's
  mint emits a `Transfer` from the zero address.
- Input validation: zero-address sender, receiver and spender revert, as inherited.
- Infinite approvals: the token does not grant any; a holder who approves `type(uint256).max` keeps
  that allowance undecremented, which is standard ERC-20 behaviour and is tested.
- Automated analysis: only Foundry's compiler and test runner were available in this task. Slither,
  Mythril and long fuzz campaigns did not run and remain an open item for the independent reviewer.

Passing tests are not an audit. An independent adversarial review is required before this launch is
admitted, as the launch policy already provides.
