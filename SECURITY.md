# SECURITY

## Threat model & posture

NEXUS handles credentials (proxy passwords, UUIDs, WireGuard private keys,
WARP tokens, subscription URLs with embedded tokens) on devices that may be
shared, seized, or compromised. The design minimizes what is persisted and
what is observable.

## Secrets handling (§41)

* All secret material is written to the OS secure store through `SecureVault`:
  Android Keystore (encryptedSharedPreferences), Windows DPAPI, Linux Secret
  Service. The database stores only `@vault:<key>` references (see
  `lib/data/profile_codec.dart`).
* Vault values are joined into generated engine configs **at launch time
  only**; configs are written to temp files with restrictive permissions and
  deleted on engine stop.
* First-run fallback: if the platform vault is unavailable, an in-memory vault
  is used and Settings surfaces a warning; secrets are then only in process
  memory, never on disk.

## Logging (§42)

* `lib/core/logger.dart` redacts UUIDs, passwords, keys, subscription URLs
  and base64 credentials **before** a line enters the buffer — components
  cannot leak secrets by logging carelessly.
* Privacy Mode (§85) suppresses debug/info lines entirely.

## Network behavior (§84)

* No telemetry, no analytics, no crash uploads, no configuration sync.
* The only outbound contacts are: your proxies/engines, your subscription
  URLs, Cloudflare's WARP API (only when you press Generate), and public IP /
  latency probe endpoints you configure.
* Generated configs pin the Clash API and all inbounds to `127.0.0.1` with a
  generated secret.

## Reporting

Report vulnerabilities privately to the maintainers; do not open public
issues for exploitable findings. Include reproduction steps and affected
commit.
