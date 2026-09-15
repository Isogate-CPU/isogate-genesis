# Isogate Genesis contracts

Standalone public Solidity source and synthetic tests for the Isogate Genesis
contract system. This package contains no deployment keys, live launch
wrappers, funded-wallet material, fork state, generated build output, or
production operational state.

## Included

- `contracts/genesis/`: identity registry, fixed-supply token, factory,
  coordinator, hook, fee vault, and position lock.
- `contracts/`: isolated escrow, provider bond, receipt registry, and shared
  primitives.
- `test/genesis/genesis.ts`: local tests against synthetic dependency mocks.
- `scripts/`: non-submitting public verification helpers and their tests.
- `docs/deployments/`: a sanitized public v2 address manifest.

The contracts are unaudited. Local tests are not evidence that a deployment is
safe or suitable for production. Independently review code, dependencies,
compiler output, on-chain bytecode, permissions, and operational controls.

## Requirements

- Node.js 20 or newer
- pnpm 10 or newer

## Checks

```sh
pnpm install
pnpm run check
```

`compile` and `test` use only the local simulated network. No script in this
export submits a transaction or requires a private key. The optional
`prepare-verification` helper only writes explorer-ready local inputs when all
values are explicitly provided; it does not submit verification.

## Deployment information

See [`docs/deployments/robinhood-4663-v2.json`](docs/deployments/robinhood-4663-v2.json)
and [`docs/source-match-evidence.md`](docs/source-match-evidence.md). These are
public records supplied for independent checking, not an endorsement or an
independent audit.
