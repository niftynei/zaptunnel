# Public beta checklist

Use this matrix before calling a relay build ready for public beta. Automated
rows belong in `nix flake check`; manual rows exercise browser, network, and
operational behavior that a hermetic build cannot prove.

## Automated release gate

| Area | Required result | Coverage |
|---|---|---|
| Relay unit suite | Pass | Admission limits, draining, address policy, BOLT 8, SOCKS5, metrics, and diagnostics |
| SDK and website suite | Pass | Package build, public APIs, stable errors, docs UI, and mobile CSS assertions |
| Clearnet end to end | Pass | Browser SDK → relay WebSocket → real regtest CLN → `getinfo` |
| Tor end to end | Pass | Browser SDK → relay → isolated SOCKS5 onion gateway → real regtest CLN → `getinfo` |
| NixOS module | Evaluate and build | Service, ACME, Tor, Prometheus, Grafana, Alertmanager, firewall, and secret wiring |
| Prometheus rules | Pass `promtool check rules` | Syntax and rule loading for every shipped alert |
| Source hygiene | Clean | No uncommitted release artifacts or credentials |

Run the complete gate from the repository root:

```console
make check
```

## Manual browser and node matrix

Record the date, SDK version, relay revision, CLN version, result, and request
ID for every attempt. Never paste a rune into the results.

| Scenario | Chrome desktop | Firefox desktop | Safari desktop | iOS Safari |
|---|---:|---:|---:|---:|
| Public clearnet node, `getinfo` | Pending | Pending | Pending | Pending |
| Public v3 onion node, `getinfo` | Pending | Pending | Pending | Pending |
| Invalid node ID reports a stable code | Pending | Pending | Pending | Pending |
| Wrong address/node pair reports `endpoint_unverified` plus request ID | Pending | Pending | Pending | Pending |
| Read-only rune rejects a mutating RPC | Pending | Pending | Pending | Pending |
| Three concurrent sessions succeed; fourth returns `connection_limit` | Pending | Pending | Pending | Pending |
| `paidInvoices()` resumes from a saved `pay_index` | Pending | Pending | Pending | Pending |
| Disconnect/reconnect status reaches the application | Pending | Pending | Pending | Pending |
| iOS background/foreground reconnect | N/A | N/A | N/A | Pending |

Test at least:

- the oldest CLN release the project intends to support;
- the current CLN release;
- a node with Commando unavailable, to verify the failure is understandable;
- clearnet-only, onion-only, and dual-address nodes;
- Wi-Fi and cellular on iOS.

## Operational acceptance

- `https://relay.zapptunnel.com/healthz` remains a liveness check and
  `/readyz` returns `503` while draining.
- Grafana shows relay traffic, failures, capacity, Tor, and firing alerts.
- Every shipped alert has been deliberately triggered once in staging and can
  be found with `make alert-logs`.
- A planned shutdown rejects new admissions, allows active sessions up to the
  drain deadline, and does not page as a crash.
- A request ID copied from an SDK error finds the corresponding verification or
  session log without exposing a rune or RPC payload.
- DNS, ACME renewal, disk use, backup/recovery notes, and the abuse-response
  owner have been checked.

## Beta feedback record

For each tester, collect only what helps reproduce failures:

```text
date/time (with timezone):
SDK version:
browser and OS:
CLN version:
clearnet or onion:
stable error code:
request ID:
expected / observed:
```

Node IDs, IP addresses, onion names, and timing are sensitive metadata. Keep
feedback private by default and never request a rune, private key, or complete
RPC payload.
