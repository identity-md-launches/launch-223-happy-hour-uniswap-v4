# Happy Hour

A Uniswap v4 launch: the **HAPPY** token and the **Happy Hour** hook. Every swap on the native-ETH
pool pays a 1% fee on its ETH side, burned to the dead address, except during one free hour each
UTC day. The free hour moves every day on a fixed public schedule that nobody can change.

## Contracts

| Contract | Path | Purpose |
| --- | --- | --- |
| `HappyHourToken` | `src/HappyHourToken.sol` | ERC-20 "Happy Hour" / "HAPPY", 18 decimals. |
| `HappyHourHook` | `src/HappyHourHook.sol` | The v4 hook: schedule, 1% ETH-side burn. |
| `HookFlags` | `src/HookFlags.sol` | Permission-bit constants and address helpers. |
| `HookMiner` | `src/HookMiner.sol` | CREATE2 salt mining for the flagged address. |
| `Deploy` | `script/Deploy.s.sol` | Operator-only hook deployment. |

ABIs are exported at `docs/abi/HappyHourHook.json` and `docs/abi/HappyHourToken.json`.

### Token rules

- Zero-argument constructor mints exactly `1e27` minor units (one billion HAPPY) to `msg.sender`,
  which is the launch factory. That is the only mint that ever happens.
- No owner, mint, burn, pause, proxy, fee-on-transfer, or transfer hook. It is OpenZeppelin `ERC20`
  v5.7.0 and nothing else.

### Hook rules

- Constructor takes only the `IPoolManager` address. It reverts with `ZeroPoolManager` on the zero
  address and with `Hooks.HookAddressNotValid` if the deploy address does not carry exactly the
  declared permission bits. There is no owner, admin, setter, pause, sweep, or upgrade path, and the
  runtime code contains no `DELEGATECALL`, `CALLCODE`, or `SELFDESTRUCT`.
- Permissions: `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. Flag
  mask **0xCC** (204). `beforeInitialize` is not used; the launch factory opens the pool.
- On any pool whose `currency0` is not native ETH the hook does nothing: no fee, no take, no event.
- Schedule (all from `block.timestamp`, no oracle, no admin input):
  - `day = block.timestamp / 86400`
  - free hour starts at UTC hour `(day * 7) % 24` and lasts exactly 3600 seconds
  - the hour sequence therefore cycles every 24 days: 0, 7, 14, 21, 4, 11, 18, 1, 8, 15, 22, 5,
    12, 19, 2, 9, 16, 23, 6, 13, 20, 3, 10, 17, then 0 again.
- Outside the free hour every swap pays exactly 1% (rounded down) of its ETH side, taken from the
  PoolManager to `0x000000000000000000000000000000000000dEaD` inside the same swap, and emits
  `FeeBurned(PoolId indexed poolId, uint256 amount)`. Amounts below 100 wei round to a zero fee and
  emit nothing.
- Inside the free hour there is no fee at all; the swap is byte-for-byte what a hookless pool does.
- The hook holds no ETH, no tokens, and no ERC-6909 claims between calls.

### What "1% of the ETH side" means per swap shape

The fee is always 1% of the ETH amount a hookless pool would move for the same swap parameters.

| Shape | ETH is | Where charged | User sees |
| --- | --- | --- | --- |
| Buy, exact input (`zeroForOne`, `amountSpecified < 0`) | specified | `beforeSwap` | Pays exactly the ETH specified; 1% of it is burned before the pool swaps the other 99%. |
| Buy, exact output (`zeroForOne`, `amountSpecified > 0`) | unspecified | `afterSwap` | Receives exactly the tokens specified; pays the pool's ETH cost plus 1%. |
| Sell, exact input (`!zeroForOne`, `amountSpecified < 0`) | unspecified | `afterSwap` | Pays exactly the tokens specified; receives the pool's ETH output minus 1%. |
| Sell, exact output (`!zeroForOne`, `amountSpecified > 0`) | specified | `beforeSwap` | Receives exactly the ETH specified; the pool produces 1% more, which is burned. |

### Views

| Function | Returns |
| --- | --- |
| `isHappyHour()` | `true` during today's free hour. |
| `happyHourStart(uint256 day)` | Unix timestamp at which day `day`'s free hour starts. |
| `nextHappyHour()` | Start of the next free hour that has not started yet (during a free hour this is tomorrow's). |
| `currentFeeBps()` | `100` outside the free hour, `0` inside. |
| `getHookPermissions()` | The `Hooks.Permissions` struct the address must encode. |
| `poolManager()` | The PoolManager the hook serves. |

## Build and test (offline)

Everything needed is vendored under `lib/` as plain files: forge-std 1.16.2, v4-core 1.0.2 (with the
single solmate `Owned` file `ProtocolFees` imports and the `CurrencySettler` test utility the v4-core
routers import), and the five OpenZeppelin 5.7.0 files behind `ERC20`. There are no submodules and
no remote dependencies.

```sh
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

Toolchain: solc 0.8.26 (pinned; v4-core's `PoolManager` requires it exactly), `evm_version = cancun`
(v4 needs transient storage), optimizer on at 200 runs, `via_ir = false`, `ffi = false`,
`fs_permissions = []`, `offline = true`.

### Tests

`test/HappyHourHook.t.sol` runs the hook against a real `PoolManager` with an ETH/HAPPY pool and an
identical hookless reference pool seeded with the same liquidity:

- all four swap shapes outside the free hour: exactly 1% of the reference pool's ETH leg reaches
  the dead address, the `FeeBurned` event carries that amount, and the non-fee legs match the
  reference exactly;
- all four shapes inside the free hour: deltas identical to the reference pool, nothing burned, no
  event;
- boundaries: one second before the start, the first second, the last second, one second after
  the end; a day whose hour is 0 and a day whose hour is 23 (which runs to the day boundary);
- schedule for 72 consecutive days, the wrap from hour 23 (day 17) to hour 6 and from hour 17
  (day 23) back to hour 0 (day 24), `nextHappyHour` before, at, during and after a free hour;
- an ERC-20/ERC-20 pool with the hook attached behaves exactly like its hookless twin;
- the hook's ETH, token, and claim balances are zero after every swap;
- fuzz: shape x size x timestamp (fee is 1% of the reference leg or 0 by the formula), the
  schedule over 10 million days, and exactly 3600 free seconds in every day;
- constructor: zero PoolManager (at a flagged and an unflagged address), missing bits, extra bits,
  a plain CREATE address; callbacks refuse any caller other than the PoolManager.

`test/HappyHourToken.t.sol` covers metadata, the single mint, no admin surface, exact transfers,
allowance failures, supply conservation under fuzz, and the opcode scan.
`test/Deploy.t.sol` calls the script's `configure` and `deploy` directly with a test PoolManager.

Tests never call `vm.setEnv`.

## Deployment (operator only)

The token is deployed by the launch factory: its constructor mints the supply to `msg.sender`, and
the factory must be that sender. This repository does not deploy the token.

The hook is deployed at a CREATE2 address whose low 14 bits equal 0xCC. `script/Deploy.s.sol`
reads exactly one environment variable, `EXPECTED_CHAIN_ID`, and no keys:

| `EXPECTED_CHAIN_ID` | Behaviour |
| --- | --- |
| `11155111` | Sepolia. Uses the canonical Uniswap v4 PoolManager `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543`. Reverts unless `block.chainid` agrees. |
| `31337` | Local anvil. Creates a scaffold PoolManager before the broadcast section (simulation only). |
| `0` | Offline check: no chain assertion, configures for the simulated chain (31337 under `--offline`). |

Anything else reverts with `UnsupportedChain` or `ChainMismatch` before any deployment. The
broadcast section contains exactly one deployment, the hook. The salt is mined for the canonical
CREATE2 proxy `0x4e59b44847b379578588920cA78FbF26c0B4956C`, which `forge script` routes salted
creates through; the script reverts with `AddressMismatch` if the deployed address is not the one
mined. The network's own deployer signs and broadcasts; this repository holds no keys, and the
command it runs is:

```sh
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy --rpc-url <sepolia> --broadcast
```

Launch target: Sepolia (11155111) unless the manifest says otherwise. The manifest must declare
hook flags `204` (0xCC), token decimals `18`, and constructor argument = the PoolManager address.

## Assumptions and operational responsibilities

- **The pool is `ETH / HAPPY`** with `currency0 = address(0)`. Native ETH always sorts first, so
  the hook's "currency0 is native" check is the same as "this is an ETH pool". Fee tier and tick
  spacing are the factory's choice; the hook does not read them.
- **The fee is taken from the PoolManager's ETH balance during the swap**, before the trader
  settles. On a live network the PoolManager holds ETH from every native pool, so this is always
  covered. On a fresh local manager with a pool seeded only on the token side, the very first buy
  would revert with insufficient balance until the manager holds at least 1% of that buy in ETH;
  seeding the launch pool with some ETH-side liquidity removes the case entirely.
- **Rounding**: the fee is `amount / 100` rounded down. Swaps whose ETH leg is under 100 wei pay
  nothing and emit nothing.
- **Exact-output sells that partially fill** (price limit reached): the fee is 1% of the ETH the
  trader asked for, computed before the pool runs, and the trader receives the pool's actual output
  minus that fee. Routers that set tight price limits on exact-output sells should account for it.
- **Fee-on-transfer or rebasing tokens** are not supported as `currency1`; HAPPY is neither.
- **The schedule is UTC and immutable.** Day boundaries and the 7-hour daily shift are computed
  from `block.timestamp`; validators can nudge timestamps by a few seconds, which moves the free
  hour's edges by the same few seconds. That is inherent to the specification and is not a
  security concern because nothing of value is decided by the exact second.
- **No fees accrue to anyone.** The dead address cannot spend, so the 1% is destroyed. LP fees of
  the pool itself (the `fee` field of the key) are unaffected and still go to LPs.
- **No monitoring hooks, no upgrade path.** If the hook must change, a new hook and a new pool are
  required.
