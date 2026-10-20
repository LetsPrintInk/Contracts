# Security policy

## Reporting a vulnerability

Email **hello@letsprint.ink** with the subject "Security". Include:

- the contract and function affected
- a description of the issue and its impact
- steps to reproduce, ideally a Foundry test

Please do not open a public GitHub issue, post on social media or exploit the issue on mainnet. We will
acknowledge your report within 48 hours and keep you updated until it is resolved. We are happy to credit
researchers who report responsibly.

## Scope

All contracts in `src/` as deployed on Ink mainnet (see [deployments/ink-mainnet.json](deployments/ink-mainnet.json)),
including every BondingCurve and TokenTemplate created by the LaunchpadFactory.

Out of scope: the website front end, third-party contracts (Uniswap v4, WETH, USDC, xStocks), and issues
already listed as known and accepted in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#independent-review-13-october-2026).

## Status

No external audit yet. The contracts were reviewed independently, fuzz, invariant and fork tested, and
checked with three static analysers. The full results are in [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md).
