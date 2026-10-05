# Swarm Made (MADE): deployment parameters, assumptions and responsibilities

## 1. What gets deployed

One contract, `src/SwarmMade.sol:SwarmMade`, with an empty constructor argument list. The factory
deploys it through CREATE2 with the launch number as salt; the constructor mints the whole supply to
the factory. No application contracts accompany this token (`contracts: []`).

The manifest for this launch (written by the separate manifest step, not by this task) should state:

```
kind:             custom_token
token.contract:   SwarmMade
token.name:       Swarm Made
token.symbol:     MADE
token.decimals:   18
token.constructorArgs: []
token.totalSupply: 1000000000000000000000000000      (1e27 minor units)
contracts:        []
pool.pairedCurrency: the chain's IMD token address (from network.json; the opening cap is quoted in IMD)
economics.poolBps:              8800
economics.initialMarketCapWei:  2500000000000000000000   (2,500 IMD at 18 decimals)
economics.remainderTo:          0x1846927b920FA2D41766ED4F88F1d10e640F1590
```

The same numbers are compiled into `script/DeploySwarmMade.s.sol` as constants and asserted by
`test/DeploySwarmMade.t.sol`, so a manifest that disagrees with the code is caught by reading either.

## 2. Supply split at launch

| Recipient | Share | Amount (MADE) | Minor units |
|-----------|-------|---------------|-------------|
| MerkleDistributor (swarm: 2% contributors + 8% paired seats) | 10% | 100,000,000 | 1e26 |
| Uniswap v4 pool, single-sided seed | 88% | 880,000,000 | 8.8e26 |
| `remainderTo` = `0x1846927b920FA2D41766ED4F88F1d10e640F1590` | 2% | 20,000,000 | 2e25 |

The swarm share is fixed by the factory and is not a manifest field. The requester's 90% is split by
`poolBps`; `remainderTo` receives what is left after the seed. All three flows are exact because the
token has no fee or hook; `test_launchFlowsMoveExactAmounts` rehearses them.

## 3. Opening price

`initialMarketCapWei` is 2,500 IMD expressed in IMD's minor units (assumed 18 decimals; see the
assumptions below). The deployer derives the opening price as

```
price (IMD per MADE) = initialMarketCapWei / totalSupply = 2.5e21 / 1e27 = 2.5e-6 IMD per MADE
```

and converts it to the pool's `sqrtPriceX96` with the currency ordering determined by the deployed
token address relative to the IMD address. The pool fee, tick spacing, tick range and liquidity amount
are chosen by the deployer and recorded in the manifest as provenance; this task does not fix them.

## 4. Build reproducibility

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `optimizer = true`,
`optimizer_runs = 200`, `bytecode_hash = "none"` and `cbor_metadata = false`. The launch compares
deployed bytes without a metadata hash, so these settings must not be changed between the attested
build and the verifier's build. `ffi` is off and `fs_permissions` is empty.

Dependencies are vendored as ordinary files:

- `lib/forge-std` from foundry-rs/forge-std tag `v1.9.7` (commit `77041d2ce690e692d6e03cc812b57d1ddaa4d505`), `src/` and licences only.
- `lib/openzeppelin-contracts` from OpenZeppelin/openzeppelin-contracts tag `v5.1.0` (commit `69c8def5f222ff96f2b5beff05dfba996368aa79`), the five files the ERC20 needs plus `LICENSE`.

## 5. Assumptions

1. **IMD has 18 decimals.** `initialMarketCapWei = 2500 * 1e18` relies on this. If the chain's IMD
   token uses another precision the manifest value must be rescaled before admission.
2. **The paired currency is IMD, not ETH.** The brief quotes the cap in IMD. `pool.pairedCurrency`
   must therefore be the IMD address from `network.json`, which this task did not have and did not
   invent.
3. **`remainderTo` is correct and controlled by the requester.** `0x1846927b920FA2D41766ED4F88F1d10e640F1590`
   is copied verbatim from the job. It is an externally supplied address; nothing on-chain can recover
   tokens sent to it if it is wrong. Confirm it with the requester before admission.
4. **No exemptions are needed.** Because transfers are untaxed, the token does not take `$factory`,
   `$poolManager` or `$launchNumber` as constructor arguments. If a future variant adds a fee, that
   decision must be revisited.
5. **The factory is the only minter, once.** The token trusts whoever calls its constructor. In
   production that is the factory under the launch policy; in a rehearsal it is the broadcaster.

## 6. Operational responsibilities

| Responsibility | Owner | Notes |
|----------------|-------|-------|
| Deploying through `launchCustom` and seeding the pool | Network deployer | This task authorises no transactions and holds no keys. |
| Writing `launch.json` with the fields in section 1 | Manifest step | Admission refuses a copy that differs from the job. |
| Choosing pool fee, tick spacing, range, liquidity | Network deployer | Recorded in the manifest as provenance. |
| Verifying source on the block explorer | Network deployer | `forge verify-contract <addr> src/SwarmMade.sol:SwarmMade --compiler-version 0.8.26` with no constructor args. |
| Independent adversarial review before release | Independent contributor | Required by the launch policy; tests passing is not an audit. |
| Running Slither / Mythril / extended fuzzing | Independent reviewer | Not available in this task's toolset; listed as open. |
| Custody of the 2% remainder | Holder of `remainderTo` | No on-chain controls exist after transfer. |
| Nothing ongoing on the token itself | nobody | There is no admin role, key, or upgrade path to rotate, secure or hand to a multisig. |

## 7. Rehearsing locally

```
anvil
forge script script/DeploySwarmMade.s.sol:DeploySwarmMade --rpc-url http://127.0.0.1:8545 \
    --private-key <anvil test key> --broadcast
```

The broadcaster receives the whole supply, which mirrors what the factory receives in production.
This is for inspection only; the production deployment goes through the factory.

## 8. What was checked here

- `forge build` with solc 0.8.26: clean.
- `forge test`: 36 tests pass (31 token, 5 deploy/config), including three fuzz tests at 256 runs.
- `forge fmt --check`: clean.
- The protected floor test (`CustomTokenProtectedTest`) was read and each of its checks is covered by
  an equivalent local test: supply and decimals, exact swarm and claim flows, no supply growth under
  the listed admin selectors, no privileged hand over a holder, no `DELEGATECALL`/`CALLCODE`/
  `SELFDESTRUCT` in the runtime. The floor's live pool seed and swap against a real v4 PoolManager
  could not be run in this task because its harness and `v4-core` are not part of this repository;
  the token has no transfer logic that could distinguish the PoolManager from any other address.
