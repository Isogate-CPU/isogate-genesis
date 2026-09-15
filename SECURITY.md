# Security policy

## Scope

This repository contains public smart-contract source and local tests. The
contracts are unaudited, and the synthetic test doubles are not production
implementations. A passing local test is not a security guarantee.

## Reporting a vulnerability

Please do not disclose suspected vulnerabilities in a public issue. Send a
clear report to [support@isogate.tech](mailto:support@isogate.tech), including:

- the affected contract, function, and source revision;
- a minimal reproduction or test case;
- the impact and conditions required to reproduce it; and
- relevant compiler, dependency, or transaction details that are safe to
  share.

Do not send private keys, credentials, personal data, or other sensitive
operational information. We will acknowledge reports as practical and
coordinate remediation and disclosure with the reporter.

## Responsible use

Independently review source, dependencies, compiler output, deployed bytecode,
constructor arguments, and administrative permissions before any use. Never
send funds or approve a contract solely because an address appears in this
repository.
