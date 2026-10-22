# Letsprint.ink deployment (Ink mainnet, chain 57073)

Status: contracts frozen for launch. No external audit yet; that comes later. In its place: an
independent review by separate reviewers who had to prove each issue with an attack test (every confirmed
issue is fixed, see "Independent review"), fuzz and invariant tests, end-to-end tests on a fork of Ink,
three static analysers, and a full deployment rehearsal (`script/rehearse.sh`). Publish the source and
these results, and run a bug bounty from day one.

## Addresses

| What | Address | Source |
| --- | --- | --- |
| Uniswap v4 PoolManager | `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32` | Uniswap v4 deployments list |
| WETH | `0x4200000000000000000000000000000000000006` | OP Stack predeploy |
| USDC (native, Circle) | `0x2D270e6886d130D724215A266106e6832161EAEd` | Circle's USDC contract addresses |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` | OP Stack preinstall; deploys the hook |
| Safe v1.4.1 (factory, L2 singleton) | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`, `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` | Checked on chain: both have code on Ink |
| Explorer | https://explorer.inkonchain.com (Blockscout, verify at `/api/`, no key needed) | |

Ink Sepolia has no Uniswap v4 deployment, so a coin cannot graduate there. See "Staging" below.

## Launch settings

| Setting | Value | Why |
| --- | --- | --- |
| ETH graduation target (R) | `5 ether` | Starts near a $4,000 market cap and graduates near $64,000 at ETH = $2,566, in line with pump.fun's USDC pairs and the top of InkyPump's 1 to 5 ETH range |
| USDC graduation target (R) | `12_800e6` | Starts at exactly $4,000 and graduates at $64,000, whatever ETH does |
| Deploy fee | `0.0005 ether` | Anti-spam |

These were the settings at deployment. On 24 October 2026 the Safe lowered the graduation targets through the timelock to 3 ETH and 7,680 USDC (`setQuoteAsset`), for coins launched from then on.
| Spotlight prices | `[0.1, 0.2, 0.5, 1] ether` | 1h, 3h, 9h, 24h |

Curve shape for any R: starting market cap 0.3125 x R, graduation market cap 5 x R, price rises 16x.
The buy that sells out a curve gets only the tokens left, pays only for those, and is refunded the rest,
the same rule pump.fun uses. That buy graduates the coin into a full-range Uniswap v4 position that no one
can ever remove, in the same transaction: a final buy sent without enough gas for that reverts instead,
so a wallet's normal gas estimate always covers graduation.

## Build

solc 0.8.26, via IR, EVM cancun, optimizer 200 runs. OpenZeppelin Contracts 5.6.1, Uniswap v4-core 1.0.2,
v4-periphery 1.0.3 (`npm install`; forge-std ships inside v4-core).

| Contract | Runtime size (limit 24,576) | Initcode (limit 49,152) |
| --- | --- | --- |
| CurveDeployer | 19,129 | 29,941 |
| BondingCurve | 14,251 | 17,747 |
| LaunchpadFactory | 11,713 | 43,600 |
| TokenDeployer | 10,636 | 10,681 |
| PrintHook | 7,218 | 7,910 |
| StockVaultDeployer | 6,537 | 6,563 |
| TokenTemplate | 6,188 | 9,820 |
| LaunchRouter | 5,822 | 6,129 |
| StockVault | 3,935 | 5,257 |
| LaunchpadRegistry | 2,549 | 2,767 |

The factory's constructor creates a CurveDeployer, which creates a TokenDeployer, so all three are bound
together at deployment. Only the factory can use the CurveDeployer, and the TokenDeployer only works
while the CurveDeployer is building a curve, so every token it creates is a real launch.

## Tests

All pass on the frozen code (13 October 2026).

`test/Invariants.t.sol` runs the whole system on a local chain with a real Uniswap v4 PoolManager.
Invariants: 1,000 runs of 100 random buys, sells, burns, time jumps and graduation attempts from five
wallets on an ETH curve with a 2% creator tax (100,000 calls, 0 reverts). After every call:

- the curve holds at least its reserves plus every payout it is holding for someone
- k = x * y never drops, so every rounding favours the curve
- real reserves move in lockstep with the virtual ones
- until graduation the curve holds every unsold token plus the 200M reserved for the pool
- if every holder sold everything at once, the curve could pay them all
- after graduation the pool has liquidity and the curve owns that position for good

Fuzz tests, 1,000 random inputs each: a buy and an immediate sell never make money (ETH and 6-decimal
USDC); the quote functions predict buys and sells exactly, refunds included; however the curve got
there, the buy that sells it out raises exactly R and pays only for the tokens left; the launch tax
fades to zero by second 5, always leaves a buyer at least 1%, and never applies to the creator.

`test/Fork.t.sol` deploys everything against the real PoolManager, WETH and USDC on a fork of Ink and
passes all 5 tests: the full ETH lifecycle (launch, launch tax, trades matching quotes, creator paid
inside each trade, burn, graduation inside the final buy with its refund, all four pool swap shapes
paying the hook fee, claims, creator controls, rescue limits, Spotlight), a final buy that reverts
without the gas to graduate and graduates with it, a USDC pair with a Circle-blocked fee wallet (trading
never stops; its share is held to claim), a stock pair round trip through the vault, and the access locks.

`test/Hook.t.sol` (from the hook reviewer, 16 tests): fee exactness fuzzed over all four swap shapes, both
token orderings and all three pair assets; the hook's balance in the PoolManager is zero after every swap;
partial fills revert; trading continues with any mix of blocked recipients, treasury and hook; only the
curve can create its pool; third-party liquidity pays the full fee; rescue cannot touch held payouts; the
Uniswap V4Quoter matches real swaps. `test/Regressions.t.sol` (8 tests) pins every other fix below.

Gas: launch with a first buy 5.0M, curve buy 227k, curve sell 228k, final buy with graduation 511k to
704k, pool buy through the hook 264k, the whole deployment about 16M across 10 transactions. Ink's block gas limit is 30M and gas costs about 0.001 gwei.

```bash
forge test --no-match-path test/Fork.t.sol    # invariants, fuzz, hook and regression tests
forge test --match-path test/Fork.t.sol --fork-url https://rpc-gel.inkonchain.com -vv
FOUNDRY_INVARIANT_RUNS=1000 forge test --match-contract CurveInvariants   # the 100,000-call run
```

## Static analysis

Slither (60 results, 17 detectors), Aderyn (2 high, 12 low) and forge lint (69 warnings) were run on the
final code. Fixed after the first pass:

- PrintHook converts its fee charge to int128 with SafeCast instead of a bare cast
- PrintHook and LaunchRouter reject zero addresses in their constructors
- BondingCurve marks the curve complete, and accrues the treasury's share, before any transfer
- LaunchpadFactory's WETH interface was renamed so no two files define the same name

Everything left is intended or a false positive:

| Finding | Where | Why it stays |
| --- | --- | --- |
| Reentrancy (state written after a call) | curve trades, graduation, claims, hook payouts | Every entry point is `nonReentrant`, and the only calls go to WETH, USDC, the coin itself, factory-made vaults and the PoolManager |
| Contract locks Ether | LaunchRouter, LaunchpadFactory | Both only accept ETH from WETH while unwrapping; the factory's owner can rescue anything stray |
| Unchecked low-level call, unused return | `BondingCurve._pay` | A failed payout is credited to `owed` so a blocked wallet can never stop trading |
| Strict equality | supply check at launch, zero-amount guards | Intended guards |
| Missing zero check | `TokenTemplate` constructor, `setHook` | The token's curve is always its deployer; `setHook` requires code at the address |
| Timestamp comparisons | deadlines, the 5-second launch tax, Spotlight | A few seconds of drift changes nothing material |
| Typecasts | sign-checked int128 to uint256, `uint16(BPS)`, `uint64(block.timestamp)` | Each is guarded or cannot overflow |
| Centralization | factory and registry owner | The owner is a timelock run by the team Safe and can only change settings for future launches |
| Style and gas notes | naming, assembly, loops, pragma, PUSH0 | Informational; Ink supports PUSH0 |

## Independent review (13 October 2026)

Three reviewers who had not seen the code being written each took one part (curve and token; Uniswap
hook; factory, router and stock vaults), and every issue had to be proven with a Foundry attack test. A
fourth checked real xStocks on Ink, and a fifth re-checked the fixes. No one found a way to steal funds.
Confirmed issues, all fixed:

| Severity | Issue | Fix |
| --- | --- | --- |
| Medium | Hook: a swap that named the pair-asset amount was charged the full fee even if it only partly filled at its price limit; a creator could sandwich price-limited traders | Such a swap must fill in full or it reverts (`PartialFill`) |
| Medium | Hook: if Circle blocked the hook and any fee recipient, every swap in that USDC pool reverted (holders trapped) | Failed payouts are held as PoolManager claims, with no token transfer; claimed later through the hook |
| Medium | Curve: a final buy sent with a normal wallet gas estimate left the coin complete but not graduated (no trading) until someone called `graduate()` | The final buy graduates or reverts; deferral only for buys made from inside a PoolManager unlock |
| Medium (High after the first fix) | Stock vaults: dust sent to a new vault could re-price its shares and break every launch on that stock | Fixed rate while a vault is empty, and every new vault is seeded with one whole xStock locked behind dead shares |
| Low | Graduation reward (off by default) could always be captured by whoever filled the curve | Removed |
| Low | The treasury received the deploy fee before the creator's first buy | Fee is sent last |
| Low | Router sells to address 0 burned the proceeds | Rejected |
| Low | Stock-pair targets had no bounds | 1e15 to 1e33 shares |
| Low | The owner could renounce ownership, killing pause and rescue for good | Renouncing reverts (factory and registry) |
| Info | Treasury not in the launch terms; hook did not pin tick spacing; vault symbol clashed with Backed's `w` wrappers; script did not insist on a Safe | Treasury in the terms hash; tick spacing 200 enforced; `lp` prefix; `SAFE` must be a deployed contract on chain 57073 |

Known and accepted: anyone can open other pools for a coin without this hook (no fee there), as on any
launchpad; Circle or Backed blocking a curve, the PoolManager or a vault freezes that pair, which the site
must disclose; a buy that unexpectedly becomes the final buy because someone else bought first reverts if
it was sent with little gas (no funds lost).

## Deploy

You need: Foundry and Node; the team Safe on Ink (it receives fees and runs the timelock); and a fresh
deployer wallet with about 0.01 ETH on Ink, ideally a hardware wallet. After the handover the deployer
has no power left.

1. Rehearse. `npm install && ./script/rehearse.sh` forks Ink mainnet locally, deploys, launches and
   trades a coin, buys out its curve so it graduates, and plays the Safe's side of the ownership handover.
   It must end with "Rehearsal passed."
2. Dry run against Ink (nothing is sent):
   ```bash
   export RPC=https://rpc-gel.inkonchain.com
   export POOL_MANAGER=0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32
   export USDC=0x2D270e6886d130D724215A266106e6832161EAEd
   export TREASURY=<team Safe> SAFE=<team Safe> DEPLOYER=<deployer address>
   export TIMELOCK_DELAY=0   # beta: the Safe can act at once, e.g. to pause new launches. See step 6.
   # SAFE must already be deployed on Ink: the script refuses an empty address on chain 57073.
   forge script script/Deploy.s.sol --rpc-url $RPC --sender $DEPLOYER
   ```
3. Deploy and verify (with a Ledger, use `--ledger` instead of `--account`):
   ```bash
   cast wallet import deployer --interactive   # once: stores the key encrypted
   forge script script/Deploy.s.sol --rpc-url $RPC --sender $DEPLOYER --account deployer --broadcast \
     --verify --verifier blockscout --verifier-url https://explorer.inkonchain.com/api/
   ```
   The factory creates the CurveDeployer and TokenDeployer itself; verify those two by hand:
   ```bash
   forge verify-contract <address> src/Deployers.sol:CurveDeployer --chain 57073 \
     --verifier blockscout --verifier-url https://explorer.inkonchain.com/api/
   forge verify-contract <address> src/Deployers.sol:TokenDeployer --chain 57073 \
     --verifier blockscout --verifier-url https://explorer.inkonchain.com/api/
   ```
   After the first launch, check its BondingCurve and TokenTemplate show as verified on the explorer.
   If later launches do not, have the keeper submit each new pair for verification.
4. Hand over ownership. The deploy leaves the timelock as pending owner of the factory and the registry.
   In the Safe app, open the Transaction Builder, enter the TimelockController's address, and call
   `scheduleBatch` with targets `[factory, registry]`, values `[0, 0]`, payloads
   `[0x79ba5097, 0x79ba5097]` (that is `acceptOwnership()`), predecessor and salt
   `0x0000000000000000000000000000000000000000000000000000000000000000`, and delay equal to
   `TIMELOCK_DELAY`. When the delay has passed (with 0, add it to the same batch), call `executeBatch`
   with the same values minus the delay. `owner()` on both then returns the timelock. Do this
   straight after deploying: until it runs, the deployer wallet still has the owner's powers.
5. Smoke test: `FACTORY=<factory> ROUTER=<router> forge script script/Smoke.s.sol --rpc-url $RPC
   --sender $DEPLOYER --account deployer --broadcast` launches a coin called "Letsprint Smoke Test",
   buys, and sells half back. Hide that coin in the indexer.
6. When the beta is stable, the Safe schedules `updateDelay(172800)` on the timelock itself. From then
   on every settings change waits 48 hours, visibly on chain.
7. Stock pairs, after legal sign-off (see "Stock pairs"): through the timelock, `approve(factory, 1e18)`
   on the xStock (the timelock must hold one whole xStock per new pair: it seeds the vault and stays
   locked), then `factory.addStockPair(xStock, R)`.

Every owner action (pause launches, fees, pairs, treasury) goes through the timelock: the Safe schedules
it, waits the delay, and executes it. The owner can never touch trading on existing curves, mint, or
move user funds.

## Staging

Ink Sepolia has no Uniswap v4, so the realistic full test is a separate staging deployment on Ink
mainnet with a small target: `GRAD_ETH=500000000000000000` (0.5 ETH, the minimum), `SAFE` unset so the
deployer stays owner, and a staging copy of the site pointed at it. Run the whole lifecycle with real
wallets, including a graduation and trades on Uniswap afterwards, then call `setLaunchesPaused(true)`.
Buying out a staging curve takes about 0.51 ETH. Selling those tokens back into the new pool recovers
most of it; about 0.1 ETH stays in the pool for good.

## Stock pairs

xStocks are live on Ink (18 decimals, upgradeable proxies run by Backed, with pause and sanctions
screening; dividends and splits change balances through a multiplier, which the vault absorbs as a
share-price change). Check each address on the explorer before adding it:

| Stock | xStock on Ink | R for about $12,800 (price on 13 Oct 2026) |
| --- | --- | --- |
| TSLAx | `0x8ad3c73f833d3f9a523ab01476625f269aeb7cf0` | `34_107e18` shares ($375.28) |
| AAPLx | `0x9d275685dc284c8eb1c79f6aba7a63dc75ec890a` | `38_017e18` ($336.69) |
| NVDAx | `0xc845b2894dbddd03858fd2d643b4ef725fe0849d` | `56_875e18` ($225.05) |
| SPYx | `0x90a2a4c76b5d8c0bc892a69ea28aa775a8f2dd48` | `16_467e18` ($777.31) |
| QQQx | `0xa753a7395cae905cd615da0b82a53e0560f250af` | `17_235e18` ($742.65) |

R is in vault shares: the number of whole stocks x 10^21 (so 34.107 TSLAx is `34_107e18`). Dollar figures move with the stock price.
Before going live with stock pairs: legal sign-off (xStocks may not be offered to US persons, and Kraken
also excludes the UK, Canada and Australia), geoblocking on the site, and a decision on screening: our
vault shares can be passed between wallets without Backed's sanctions checks. The site should stop
stock wrapping for about 15 minutes either side of a scheduled multiplier change.

## Front end and keeper

The final buy of a curve graduates in the same transaction, and a normal wallet gas estimate covers it
(the rehearsal used the wallet estimate: 511k gas). A buy near the end of a curve can turn into the final
buy if someone else buys first; send buys while the curve is above about 95% with a gas limit of at
least 900,000 so they don't revert for lack of gas. A small keeper should sweep the treasury's share
with `claimFor(treasury)` across curves and the hook, and call `graduate()` on any curve left complete
by a buy made from inside a Uniswap unlock (rare).

Test keys: the well-known Foundry addresses (makeAddr("alice"), "bob", "owner") carry EIP-7702 sweeper
delegations on Ink mainnet and forward any ETH sent to them. Never fund them; the tests use fresh labels.

## Disclosures for the site

- The contracts have not had an external audit. Link the source and this file from the Security page.
- USDC and xStocks are issued by third parties that can pause transfers or block addresses. If Circle
  blocked a curve or the PoolManager, that pair would stop trading; if Backed paused an xStock or blocked
  its vault, nobody could unwrap back to the stock. A blocked fee recipient never stops trading: its
  share is held for it to claim.
- xStock pairs are not available to US persons (and, through Kraken, not in the UK, Canada or
  Australia).
