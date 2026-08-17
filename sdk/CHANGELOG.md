# Changelog

## 0.4.0

- Add a resilient connection manager with fresh-admission retries, browser
  lifecycle recovery, identity persistence hooks, and reconnect-safe invoice
  streaming without automatic RPC replay.

## 0.3.0

- Accept v3 onion-service node addresses when the selected relay supports Tor.
- Suppress unnecessary BOLT 7 gossip after each Lightning initialization.
- Add `waitAnyInvoice()` and the resumable `paidInvoices()` async iterator.
- Add runtime CLN method and version capability helpers.
- Add stable SDK/RPC errors, relay request IDs, and `onConnectionStatus()`.
- Document RPC compatibility, cancellation, least-privilege runes, and errors.

## 0.2.0

- Add typed RPC controls, capability gates, paid-invoice notifications, and
  stable error codes.
- Add package metadata, repository links, and the MIT license.

## 0.1.0

- Initial browser SDK with end-to-end BOLT-8 and Commando RPC calls.
