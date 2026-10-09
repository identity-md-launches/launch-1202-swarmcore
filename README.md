# SwarmCore (CORE)

A fixed-supply ERC-20 for the SwarmCore custom token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `SwarmCoreToken` (`src/SwarmCoreToken.sol`) |
| `name()` | `SwarmCore` |
| `symbol()` | `CORE` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18), fixed |
| Constructor arguments | none |
| Minted to | `msg.sender` (the deployer; at launch, the launch factory), once, in the constructor |

## Behaviour

`SwarmCoreToken` is OpenZeppelin's ERC-20 (v5.4.0) and nothing else:

- The whole supply is minted once in the constructor. No function can mint more, so the supply can
  never grow.
- There is no owner, admin, minter, pause, blacklist, freeze, burn, transfer fee or transfer limit.
  Transfers and `transferFrom` move exactly the amount requested; only a holder (or a spender the
  holder approved) can move a holder's balance.
- Standard ERC-20 failure cases revert with OpenZeppelin's ERC-6093 custom errors: insufficient
  balance, insufficient allowance, transfer to the zero address, approval of the zero address.
- The contract has no `receive`/`fallback` and rejects ETH.
- The runtime code contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`, and no external library
  calls (nothing to link).

## Layout

```
src/SwarmCoreToken.sol            the token (the only contract this launch deploys from this repo)
script/DeploySwarmCore.s.sol      reviewable manual deployment; deploy() is tested directly
test/SwarmCoreToken.t.sol         ERC-20 success / failure / fuzz tests, no-privilege checks
test/SwarmCoreLaunch.t.sol        the launch flow against a real Uniswap v4 PoolManager
src/LaunchLiquidity.sol           launch-harness support (see below), not deployed
src/PoolInitializationGuard.sol   launch-harness support, not deployed
src/HookFlags.sol                 launch-harness support, not deployed
lib/                              vendored dependencies (ordinary files, no submodules)
```

`LaunchLiquidity`, `PoolInitializationGuard` and `HookFlags` exist so that the launch floor test
(which imports them from `src/`) and `test/SwarmCoreLaunch.t.sol` can seed a pool and open it behind
a beforeInitialize guard exactly as the factory does. They are not part of the token and are not
launch contracts; the factory brings its own. `LaunchLiquidity` and `HookFlags` contain only
internal functions.

Vendored dependencies (copied as plain files, upstream `.git`, tests and tooling removed):

| Path | Source | Commit |
| --- | --- | --- |
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts v5.4.0 (`contracts/` only) | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` |
| `lib/forge-std` | foundry-rs/forge-std v1.9.7 | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| `lib/v4-core` | Uniswap/v4-core (`src/` and licenses only), tests only | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` |
| `lib/solmate` | transmissions11/solmate (`src/` only), needed by v4-core | `89365b880c4f3c786bdd453d4b8e8fe410344a69` |

The token itself only depends on OpenZeppelin. v4-core (BUSL-1.1 for `PoolManager`) and solmate are
used by tests only.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"` (v4-core uses transient storage),
the optimizer at 200 runs, `via_ir = true` (needed to compile v4-core's `PoolManager` for the tests)
and `bytecode_hash = "none"`. No ffi, no filesystem permissions, no environment reads in tests.

The tests cover:

- metadata, supply and the single mint to the deployer (including the deploy script);
- transfer, approve and transferFrom success paths, with fuzzed conservation of supply and exact
  allowance accounting;
- failure paths: insufficient balance, insufficient or missing allowance, zero receiver, zero
  spender, ETH sent to the token, and calls to common mint / owner / pause / blacklist / burn / seize
  selectors (all revert, supply and balances unchanged);
- the launch flow: the factory stand-in deploys the token and holds the whole supply, sends 10% to a
  distributor which passes it on whole, opens a 1.25% / tick-spacing-60 pool against an IMD stand-in
  behind the initialization guard (strangers are refused), seeds 88% of the supply single-sided at
  the 2,500 IMD opening cap, forwards the rest to the requester, and an ordinary trader buys and
  sells back — with IMD sorting both below and above the token and at IMD's real address;
- seed failure when the factory no longer holds the funds.

The launch floor test (`Token.protected.t.sol`) was also run locally against this token's creation
code with this launch's terms (IMD pair, fee 12500, spacing 60, 88% pool share) and passed 8/8.

## Launch parameters

These come from the launch and are recorded here for review; the manifest step writes `launch.json`
(this repository deliberately has none).

- Chain: Ethereum mainnet, chain id 1.
- Token: `SwarmCoreToken`, name `SwarmCore`, symbol `CORE`, decimals 18, total supply
  `1000000000000000000000000000`, constructor arguments: none.
- Application contracts: none.
- Pool: paired with IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals), fee `12500`,
  tick spacing `60`, initialPrice `79228162514264337593543950336` (provenance only; the deployer
  derives the opening price).
- Economics: `{"poolBps":8800,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0x6bf192ebef135e0f645e99d59d9bf44e7711606c"}`.
  10% goes to the swarm's MerkleDistributor (by the factory), 88% seeds the pool, 2% goes to
  `0x6bf192ebef135e0f645e99d59d9bf44e7711606c`.

## Assumptions

- "Minted once to the deployer" means `msg.sender` of the constructor. In the launch that is the
  launch factory, which distributes the supply as above; in a manual deployment with
  `script/DeploySwarmCore.s.sol` it is the broadcasting account.
- The token needs no exemptions: it charges no fee and burns nothing on transfer, so every launch
  flow (factory → distributor → claimants, factory → PoolManager, trades) moves exactly what it says.
  For that reason it takes none of the optional `$factory` / `$poolManager` / `$launchNumber`
  arguments.
- No burn function was requested, so none exists; the supply is constant.

## Operational responsibilities

- There is nothing to configure after launch and no privileged role to hold: the token has no owner
  and no setters. **After launch:** no settings.
- Deployment, explorer verification (`forge verify-contract`) and any announcement of the token
  address belong to the network's deployer and launch policy; this work did not deploy, broadcast or
  use any key.
- Trading, liquidity management and the distributor's claims are handled by Uniswap v4 and the launch
  infrastructure, not by this contract.

## Security notes

The token is a minimal OpenZeppelin ERC-20 with a constructor mint and no privileged functions,
which removes the usual centralisation risks (mint, pause, blacklist, upgrade). The common ERC-20
approve front-running caveat applies as for any ERC-20; use `approve(spender, 0)` before changing
a non-zero allowance if that matters to you. Passing tests is not a security audit; no static
analysers (Slither, Mythril) were run for this work.
