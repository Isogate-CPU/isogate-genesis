# Contributing

Contributions that improve correctness, clarity, and test coverage are
welcome. Please keep this package focused on public source, local tests, and
non-submitting tooling.

## Development workflow

1. Read the relevant contract, test, and documentation before changing code.
2. Keep pull requests narrowly scoped and explain security-sensitive changes.
3. Add regression tests for changed behavior and failure paths.
4. Run the same safe checks used by CI:

   ```sh
   pnpm install
   pnpm run compile
   pnpm run typecheck
   pnpm run test
   pnpm run scripts:test
   ```

5. Review the final diff for credentials, private data, generated artifacts,
   logs, build output, and deployment state.

The test suite uses a local simulated network and synthetic dependency mocks.
It must not require a live RPC endpoint, wallet, or private key.

## Pull requests and commits

Use a concise title and describe what changed, why it is safe, and how it was
tested. Do not make unverified claims about audits, market performance,
decentralization, or production readiness. New dependencies require a clear
reason and a review of their licensing and security posture.

By participating, you agree to follow the Code of Conduct.
