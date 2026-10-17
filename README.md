# UNLOCK (UNLK)

UNLOCK is a fixed-supply ERC-20. `src/UnlockToken.sol:UnlockToken` mints the entire
supply once in its constructor to `msg.sender`, the immediate deployer. Its
runtime exposes standard ERC-20 transfers and approvals, with no administrative
functions.

## Token and deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `UnlockToken` |
| Name | `UNLOCK` |
| Symbol | `UNLK` |
| Decimals | `18` |
| Supply | `1,000,000,000 UNLK` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Supply constant | `INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18` |
| Constructor arguments | None (`[]`) |
| Constructor transaction value | `0` |
| Initial recipient | Immediate deploying address (`msg.sender`) |
| Launch chain | Ethereum, chain ID `1` |
| Compiler | Solidity `0.8.26` |
| EVM target | Cancun |
| Optimizer | Enabled, `200` runs |
| Metadata bytecode hash | `none` |

Deploy the compiled creation bytecode directly, without a proxy, initializer, or
linked libraries. The artifact is `out/UnlockToken.sol/UnlockToken.json`. The
constructor requires no external contracts, settings, or funding.

In the IdentityMD launch, the factory is the immediate deployer and receives all
tokens. The external wallet calling the factory receives nothing from the token's
constructor. The token has no owner, so the factory receives no ongoing authority
over holders. The factory handles the launch allocation: 10% to the swarm
distributor, 80% to pool seeding, and 10% remainder under the supplied launch
economics. These transfers occur outside the constructor. Pool creation,
distribution, the launch manifest, and broadcasting belong to the network's
separate launch process; this project supplies the token artifact.

## Behavior and assumptions

- All transfers deliver the exact amount. There are no transfer taxes, burns,
  rebases, limits, exemptions, or recipient callbacks.
- There is no external mint or burn function, pause, blacklist, seizure,
  ownership, or upgrade mechanism. The total supply stays fixed permanently.
- Successful `transfer`, `approve`, and `transferFrom` calls return `true`.
  Invalid operations revert with OpenZeppelin ERC-20 custom errors.
- Transfers to the zero address and approvals for a zero spender revert. Zero
  value transfers between nonzero addresses succeed and emit `Transfer` events.
  Self-transfers preserve balances.
- Finite allowances decrease on `transferFrom`. An allowance of `uint256.max`
  is treated as unlimited and does not decrease. A failed delegated transfer
  reverts all balance and allowance changes. Even the deployer needs a holder's
  allowance to spend that holder's tokens.
- `approve` replaces the current allowance and emits `Approval`. This vendored
  implementation does not emit `Approval` when `transferFrom` spends allowance;
  integrations should query `allowance` for the current value.
- Users control their approvals and should grant only what they intend to spend.
  ERC-20 allowance replacement has the standard transaction-ordering risk:
  a spender may use the old allowance before a replacement is confirmed. Revoke
  to zero, confirm, then grant a new allowance when changing a live approval.
- The token cannot recover assets sent to its address or to an incompatible
  recipient. Sending UNLK to its own contract does not reduce total supply and
  makes those tokens inaccessible. Normal ETH sends revert; forcibly received
  ETH cannot be withdrawn.

## Build and checks

Foundry and the pinned Solidity compiler must be installed. All Solidity
dependencies are ordinary vendored files under `lib/`; no dependency download,
submodule initialization, RPC, environment secrets, filesystem cheatcodes, or
FFI is needed to build or run these tests. The test seed below is the verifier's
specified seed; the tests themselves do not read or set environment variables.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x4ebdeca90cdaa3024297efcc544d3005fe445c0dd7012457bdd9e26a5ab27c42 forge test
forge fmt --check
```

`test/UnlockToken.t.sol` covers metadata, the single mint event, CREATE2 factory
deployment, exact launch-style allocation and claims, transfer and approval
events, zero and self-transfers, finite and infinite allowances, failed operations
and atomic rollback, and rejected mint/burn/admin calls. Four fuzz tests cover
conservation and invalid balances/allowances (256 cases each).

`test/UnlockToken.invariant.t.sol` runs randomized sequences of transfers,
approvals, and delegated transfers among four actors. Both invariants check the
fixed supply and conservation of all balances, with 128 runs of depth 64 and
unexpected reverts treated as failures.

The local allocation fixture models exact token movement; it does not deploy a
Uniswap pool or establish pricing. The supplied protected tests depend on the
network's separate launch harness and resolved manifest. That end-to-end pool
check remains the verifier's responsibility.

## After launch

No owner settings or initialization calls are required. The launch operator is
responsible for deploying the reviewed artifact through the intended factory,
checking the mint and distribution events, checking token metadata and supply,
and publishing/verifying source and the resulting address. Token holders are
responsible for recipient addresses and spender approvals. There is no admin
account to maintain and no recovery or upgrade procedure.

The implementation makes no external calls and has no oracle, signatures,
randomness, or proxy. The supplied security reference was reviewed against that
scope. Local checks consist of compilation, unit/fuzz/invariant tests, and
formatting; Slither and Mythril were not run. These checks are not an independent
security audit. Independent review and the network's launch checks remain release
responsibilities.

## Vendored dependencies

- OpenZeppelin Contracts `v5.0.2`, commit
  `dbb6104ce834628e473d2173bbc9d47f81a9eec3`: the unchanged ERC-20 implementation and
  its four required imports, under the MIT license in
  `lib/openzeppelin-contracts/LICENSE`.
- forge-std `v1.9.7`, commit `77041d2ce690e692d6e03cc812b57d1ddaa4d505`:
  unchanged Solidity test sources, with upstream MIT and Apache-2.0 licenses in
  `lib/forge-std/`. This dependency is only used by tests.

`DEPENDENCIES.json` records repository URLs, exact revisions, and SHA-256 hashes
of every vendored file. Vendored files retain their upstream licenses and headers.
