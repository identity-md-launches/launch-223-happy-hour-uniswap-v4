# Review: Happy Hour hook and token

Independent read of `src/`, `script/`, and `test/` after implementation, against the task's
acceptance criteria and the v4 hook security checklist. Tests passing are not an audit; a separate
adversarial review by another contributor is still required before this handles other people's
funds.

## Scope

- `src/HappyHourToken.sol`, `src/HappyHourHook.sol`, `src/HookFlags.sol`, `src/HookMiner.sol`
- `script/Deploy.s.sol`
- `test/*.t.sol`, `test/utils/HappyHourFixture.sol`, `test/mocks/MockERC20.sol`
- `foundry.toml`, `remappings.txt`, vendored `lib/`

## What was re-run

| Command | Result |
| --- | --- |
| `forge build --offline` | OK, no errors. `PoolManager` runtime 19,725 B, hook 3,793 B, token 1,753 B. |
| `forge test --offline` | 56 passed, 0 failed (41 hook, 8 token, 7 deploy; 256 fuzz runs each). |
| `forge fmt --check` | OK. |
| `EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline` | OK, hook simulated at an address ending in `...c0cc`. |
| `EXPECTED_CHAIN_ID=11155111 forge script ... --offline` | Reverts `ChainMismatch(11155111, 31337)` as intended. |
| Protected floor suite (`Hook.protected.t.sol`, `Token.protected.t.sol`) run from `test/scratch/` with the real creation code, flags 204, decimals 18 | 9 passed, 0 failed. |

## Findings

### F1. Fee take depends on the PoolManager's ETH balance at callback time (informational, documented)

`_burn` calls `poolManager.take(currency0, DEAD, fee)` inside `beforeSwap` / `afterSwap`, which is
before the trader settles. If the manager holds less than `fee` in ETH at that moment the swap
reverts. On Sepolia and mainnet the manager holds ETH from every native pool, so this cannot
happen in practice; it can on a fresh local manager with a token-only pool.
**Disposition**: accepted and documented in README. The alternative, minting ERC-6909 ETH claims to
the dead address, would not put ETH at the dead address as the specification requires.

### F2. Exact-output sell fee is computed on the requested amount, not the filled amount (informational, documented)

When ETH is the specified output, the fee has to be decided in `beforeSwap`, before the pool runs.
If the pool cannot fill the whole request (price limit hit) the fee is still 1% of the request.
The trader receives the pool's actual output minus that fee. With the limits routers normally use
for exact-output swaps this does not occur; where it does, the shortfall is bounded by 1% of the
request. **Disposition**: accepted and documented.

### F3. Fee rounds down and dust swaps pay nothing (informational)

`fee = amount / 100`. Below 100 wei on the ETH leg no fee is taken and no event is emitted, so
"every charged swap emits `FeeBurned`" holds while "every swap is charged" does not for dust. There
is no economic path to exploit this: splitting a swap into sub-100-wei pieces costs orders of
magnitude more gas than the fee saved. **Disposition**: accepted, covered by
`test_feeRoundsDown_andSkipsDust`.

### F4. `nextHappyHour()` during a free hour returns tomorrow's start (design note)

The specification says "the start of the next free hour". Inside the free hour the current one has
already started, so the function points at the next day. `isHappyHour()` is the signal for "we are
in one now". **Disposition**: documented in NatSpec and README, tested.

### F5. Hook returns a positive specified delta on exact-output sells, so the pool moves 1% more ETH than requested (design note)

This is the only way to charge the fee on the specified ETH leg without changing what the trader
receives. The extra 1% comes from the pool's ETH reserves and is burned; the trader pays the
tokens for the gross amount, which is what a hookless pool would charge for `ethOut + fee`.
`test_sellExactOut_charges1pctOfEthOut` pins this exactly. **Disposition**: intended.

## Checklist

| # | Check | Status |
| --- | --- | --- |
| 1 | Callbacks verify `msg.sender == poolManager` | Yes, `onlyPoolManager` on both; protected floor test confirms refusal. |
| 2 | Router allow-listing | Not needed; the hook never trusts `sender`. |
| 3 | Unbounded loops | None in the hook. `HookMiner` loops are bounded and never deployed. |
| 4 | Reentrancy | The only external call is `poolManager.take` to an address with no code. Hook has no mutable state. |
| 5 | Delta accounting sums to zero | Take debits the hook by `fee`; returned delta credits `fee`; tests assert zero ETH, token and claim balances after every swap. |
| 6 | Fee-on-transfer tokens | HAPPY is plain ERC-20; documented as unsupported for other `currency1`. |
| 7 | Hardcoded addresses | Only the dead address (specified) and, in the script, the Sepolia PoolManager and CREATE2 proxy. |
| 8 | Slippage respected | The pool's own price limit still applies; the hook only adjusts amounts by 1%. |
| 9 | Sensitive data on chain | None. |
| 10 | Upgrade mechanisms | None. No DELEGATECALL/CALLCODE/SELFDESTRUCT in either runtime (scanned in tests). |
| 11 | `beforeSwapReturnDelta` justified | Yes: it is the only way to charge the specified ETH leg. The delta is always `+fee` in the specified slot, never the full amount, so a NoOp is impossible; `HookDeltaExceedsSwapAmount` in v4-core also bounds it. |
| 12 | Fuzz testing | Shape x amount x timestamp, schedule, free-seconds-per-day, token transfers. |
| 13 | Invariant testing | Not added; the hook is stateless and every test asserts the zero-balance invariant directly. |

## Risk score (from the security foundations reference)

Permissions: beforeSwap (HIGH) + afterSwap (MEDIUM) + beforeSwapReturnDelta (CRITICAL) +
afterSwapReturnDelta (HIGH). External calls: one, to the PoolManager. State: none mutable. Upgrade:
none. Token handling: native ETH plus one plain ERC-20. The permission set is what a fee hook
needs and nothing more; the risk is concentrated in the two return-delta bits, which the tests pin
to exactly 1% in every shape. A professional review of `beforeSwap`/`afterSwap` is still
recommended before mainnet.

## Unresolved deployment choices

- Which chain (Sepolia assumed), and the pool's fee tier and tick spacing (factory's choice).
- Whether the launch pool is seeded with ETH-side liquidity (recommended, see F1).
- The manifest must carry flags `204`, decimals `18`, and the PoolManager address as the single
  constructor argument.
