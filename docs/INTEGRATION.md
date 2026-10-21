# Integrating with Letsprint.ink

For trading terminals, bots, aggregators, wallets and indexers that want to list and trade Letsprint coins on Ink.

Everything here is permissionless. No API key, no allow-list, no fee for integrators. Fees and creator tax are enforced by the contracts on every trade, whichever app sends it.

- Chain: **Ink mainnet**, chain ID `57073`
- ABIs: [`abi/LaunchpadFactory.json`](../abi/LaunchpadFactory.json), [`abi/BondingCurve.json`](../abi/BondingCurve.json), [`abi/LaunchRouter.json`](../abi/LaunchRouter.json). These cover the functions and events integrators need. Full ABIs are on the verified contracts on the [Ink explorer](https://explorer.inkonchain.com).
- Addresses: [`deployments/ink-mainnet.json`](../deployments/ink-mainnet.json)

| | Address |
| --- | --- |
| LaunchpadFactory | `0xd88C543Ddae849091F2160bba5881230c30E1634` |
| LaunchRouter | `0x6874D1e52D4E58865da08D99362f490fF6a01fd8` |
| PrintHook (Uniswap v4 hook) | `0xe1e2E5Bd7043322fd8aB7484ca01Dbb9ef83a0cC` |
| Uniswap v4 PoolManager | `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32` |
| WETH | `0x4200000000000000000000000000000000000006` |
| USDC | `0x2D270e6886d130D724215A266106e6832161EAEd` |

## 1. The life of a coin

1. **Launch.** `LaunchpadFactory.createToken` deploys an ERC-20 (fixed 1B supply, 18 decimals, EIP-2612 permit) and its own `BondingCurve`. The factory emits `TokenCreated`.
2. **Curve trading.** People buy and sell against that coin's curve (a constant-product curve with virtual reserves). 800M tokens are for sale on the curve; 200M are kept for the pool.
3. **Graduation.** The buy that sells out the curve also creates and seeds a Uniswap v4 pool in the same transaction. The curve emits `CurveCompleted` and `TokenGraduated`. The liquidity is owned by nobody and can never be withdrawn.
4. **Pool trading.** From then on the coin trades only in its Uniswap v4 pool. The `PrintHook` charges the same fee and creator tax on every swap.

Every coin has one pair asset (`quote`): WETH for ETH pairs, USDC for USDC pairs. Stock pairs (an ERC-4626 vault wrapping an xStock) are built in but not switched on yet.

## 2. Finding coins

Listen for `TokenCreated` on the factory:

```solidity
event TokenCreated(
    address indexed token,
    address indexed curve,
    address indexed creator,
    bytes32 poolId,            // the Uniswap v4 pool the coin will graduate into
    address hook,              // PrintHook
    address quote,             // WETH or USDC
    uint256 graduationAmount,  // pair asset the curve raises before graduating (5 ETH, or 12,800 USDC)
    uint256 creatorTaxBps,     // 0 to 1,000 (10%); can only ever go down
    TokenMetadata metadata     // name, symbol, metadataURI, metadataHash, twitter, telegram, website
);
```

The factory was deployed at block **58987826**, so there is nothing to backfill before it.

To check whether an address is a Letsprint coin or curve: `factory.curveOf(token)` returns its curve (zero if not ours), and `factory.isCurve(curve)` returns true for genuine curves. Only trust curves the factory confirms.

**Metadata.** `metadataURI` points to a JSON file (`name`, `symbol`, `description`, `image`, optional `banner`, socials). `metadataHash` is the keccak256 of the exact file bytes: hash what you download and ignore the file if it doesn't match.

`TeamWalletsDeclared(token, wallets)` lists wallets the creator declared as team at launch. They are exempt from the launch tax, and it's good practice to label them.

## 3. Trading on the curve

### Quotes

```solidity
function quoteBuy(uint256 quoteInGross, address recipient) external view
    returns (uint256 tokensOut, uint256 fee, uint256 creatorTax, uint256 snipeTax, uint256 refund, bool completes);
function quoteBuyExactTokens(uint256 tokensOut, address recipient) external view returns (uint256 grossQuote);
function quoteSell(uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee, uint256 creatorTax);
```

These are exact. They return what the trade would do right now, including the launch tax for that recipient. `refund` is the part of a buy that isn't needed because it sells out the curve. `completes` is true when this buy graduates the coin.

### Buying and selling

**ETH pairs, through the LaunchRouter** (wraps and unwraps ETH for you, holds nothing, and only accepts curves the factory confirms):

```solidity
router.buyWithETH{value: ethIn}(curve, minTokensOut, recipient, deadline, ref);
router.sellForETH(curve, tokensIn, minEthOut, recipient, deadline, ref);              // approve the router first
router.sellForETHWithPermit(curve, tokensIn, minEthOut, recipient, deadline, ref,
                            permitDeadline, v, r, s);                                  // or sign a permit
```

**USDC pairs:** buy through `router.buyWithToken` (approve the router for USDC once, or use `buyWithTokenPermit`). Sell directly on the curve with `curve.sell` or `curve.sellWithPermit`; it pays USDC straight to the recipient.

**Direct curve calls** also work for WETH pairs: `curve.buy(quoteIn, minTokensOut, recipient, deadline, ref)` after approving the curve for WETH.

- `deadline` is a unix timestamp. Trades after it revert with `Expired()`.
- `ref` is an optional `bytes32` tag that emits a `Referral` event. Nothing is paid for it today. Pass `bytes32(0)` if unused. Integrators are welcome to tag their volume with a stable value.
- Slippage: set `minTokensOut` / `minQuoteOut` from a fresh quote. Trades that miss it revert with `SlippageExceeded()`.
- Permits use the token's EIP-712 domain: `name` = the token's on-chain `name()`, `version` = `"1"`, `chainId` = 57073, `verifyingContract` = the token.

### Fees, creator tax and the launch tax

- **Fee: 1%** of every buy and sell (`FEE_BPS = 100`). 70% goes to the creator (and any wallets they share with), 30% to the treasury. Paid inside the trade.
- **Creator tax:** an optional extra 0 to 10% (`creatorTaxBps()`), paid entirely to the creator. It can only be lowered (`CreatorTaxLowered` event), never raised.
- **Launch tax:** for the first `SNIPE_WINDOW` (5 seconds) after `launchedAt()`, buys pay an extra tax that starts at 98% and falls to a quarter every second. `snipeTaxBps(recipient)` returns the current rate. The creator and declared team wallets are exempt. Snipers pay; people who wait 5 seconds don't.

All three are applied by the contracts, so nothing extra is needed on your side beyond showing them.

### Gas for the graduating buy

The buy that completes the curve also creates and seeds the Uniswap pool, so it needs much more gas than a normal trade. If the remaining gas is below `MIN_GRADUATION_GAS` (600,000) at that point, the buy reverts with `InsufficientGasToGraduate()` rather than leaving the coin half-graduated.

When `quoteBuy(...).completes` is true, use a gas limit of at least **1,500,000**. On an Ink fork, a graduating buy through the router used about 530,000 gas, and `eth_estimateGas` returned about 840,000.

A buy made from inside a Uniswap v4 unlock (some aggregator routes) can't create the pool itself. In that case the curve emits `GraduationDeferred(token)` and anyone can finish with `curve.graduate()`.

### Reading curve state

`virtualQuoteReserve()`, `virtualTokenReserve()`, `realQuoteReserve()`, `realTokenReserve()`, `complete()`, `graduated()`, `graduationAmount()`, `creator()`, `token()` and `quote()` are all public.

Spot price (pair asset per token) = `virtualQuoteReserve / virtualTokenReserve`, adjusted for decimals. Bonding progress = `realQuoteReserve / graduationAmount`.

Every curve trade emits:

```solidity
event CurveSwapped(
    address indexed token, address indexed trader, address indexed recipient, bool isBuy,
    uint256 quoteAmount, uint256 tokenAmount, uint256 fee, uint256 creatorTax, uint256 snipeTax,
    uint256 virtualQuote, uint256 virtualToken, uint256 realQuote   // reserves right after the trade
);
```

For trades sent through the LaunchRouter, `trader` is the router. For buys, use `recipient` as the buyer. For sells, the seller is the address that sent the coins to the router (the ERC-20 `Transfer` into the router in the same transaction).

## 4. After graduation: the Uniswap v4 pool

Each coin has exactly one pool, announced in advance as `poolId` in `TokenCreated`:

| PoolKey field | Value |
| --- | --- |
| `currency0`, `currency1` | the coin and its pair asset (WETH or USDC), sorted by address |
| `fee` | `0` (the hook charges the fee instead) |
| `tickSpacing` | `200` |
| `hooks` | PrintHook `0xe1e2E5Bd7043322fd8aB7484ca01Dbb9ef83a0cC` |

Route swaps through the Uniswap v4 PoolManager or Universal Router as for any v4 pool with a hook. PrintHook takes the 1% fee and the creator tax on every swap and pays the creator immediately. Quote with Uniswap's v4 quoter so the hook's fee is included.

**Use the official pool.** Like any ERC-20, a Letsprint coin can be put in other pools by anyone, without this hook. Those pools aren't Letsprint pools: they don't pay the creator and their liquidity isn't locked. The real pool is the one whose ID matches `poolId` in `TokenCreated` (and `curve.poolId()`), with the PrintHook as its hook.

## 5. Displaying coins well

- Show the **creator tax** next to the price. It's part of the cost of every trade.
- During the first 5 seconds, show that the **launch tax** is active.
- Show **bonding progress** (`realQuoteReserve / graduationAmount`) and a "graduated" state once `graduated()` is true.
- Link to the coin page: `https://letsprint.ink/t/<token address>`

## Questions

Open an issue in this repo, or reach us on [X @LetsPrintInk](https://x.com/LetsPrintInk) or [Discord](https://discord.gg/dZzN3CZc6m). Security reports go through [SECURITY.md](../SECURITY.md), not public issues.
