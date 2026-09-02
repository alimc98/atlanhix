# TROUBLESHOOTING

## Import fails with "Could not recognize this configuration format"

The sniffer supports share-link lists, Base64, Clash YAML, sing-box/Xray JSON
and `.conf`. If your payload is an SSR link (`ssr://`) or a provider-specific
format, it is reported as unsupported rather than silently dropped.

## "Engine not installed"

The selected node's engine binary was not found. Install per `BUILD.md`
(cores directory or Settings → Cores). The UI will never pretend a node works
without its engine.

## Connection fails — read the layered result

Diagnostics probe in order DNS → TCP → TLS → HTTP-through-proxy. The failing
layer is the likely problem:

| Failing layer | Typical cause |
|---|---|
| DNS | hostname wrong, or your resolver is blocking it |
| TCP | server down, wrong port, ISP reset |
| TLS | SNI mismatch, expired cert, Reality params wrong, wrong system clock |
| Proxy | protocol/auth mismatch, server rejected handshake |

## Node "works" but HTTP probe fails

Some servers pass TLS but block your fingerprint or path. Try the
fragmentation toggle (Xray nodes only) or a different uTLS fingerprint in the
node editor.

## TUN requires elevation (Windows/Linux)

TUN needs admin/cap_net_admin. NEXUS elevates **only the core process**, never
the app. On Linux prefer `setcap` (see BUILD.md) to avoid repeated prompts.

## Subscription shows no traffic info

Not all providers send `subscription-userinfo`. When absent, NEXUS shows "—"
instead of fabricating numbers.

## Logs are empty

Set Settings → Advanced → Log level to Debug; Privacy Mode hides debug/info.
