# Belkalabs SwiftUPnP fork

Upstream: https://github.com/katoemba/SwiftUPnP

Baseline: `fcd298d753bfd9b59ffb45df684694edea2f23bd` (2026-10-18).

This fork incorporates that upstream version and preserves the TV discovery
interfaces used by Belkalabs remote apps.

## Retained behavior

- `startDiscovery(_:requiredDefaultFiltration:)` accepts service URNs and
  vendor targets such as DIAL, Panasonic NetworkControl and `roku:ecp`.
  Strict filtering remains opt-in.
- SSDP responses retain the `SERVER` header. Missing headers use an empty
  string, including device departure notifications.
- `UPnPDevice.rootXML` retains the raw device description for diagnostics.
- Saved descriptions preserve `server`; descriptions from upstream versions
  without that field remain readable.
- `setDiscoveryDelegate(_:)` and `DiscoveryDelegate.sockedDidClose(_:)`
  remain available. The callback reports unexpected socket closures.
- Active SSDP searches keep an ephemeral local port, the `en0` multicast
  interface, a five-second response window and no User-Agent header.
  Passive multicast announcements on port 1900 are not guaranteed by this
  active-search configuration.
- Socket recovery, network monitoring and discovery callbacks share the main
  queue, following the new upstream lifecycle.
- CocoaAsyncSocket remains pinned to the previously deployed revision.

The upstream subscription recovery, native HTTP listener and device-loading
deduplication are included. The SOAP error parser's escaped interpolation is
corrected, with regression tests covering normal and namespaced UPnP faults.

## Verification

`swift test` passes 42 tests, including local HTTP listener/subscription tests
and TV discovery, saved-description and SOAP regression cases.

Real televisions and Wi-Fi transitions still require device testing.

## Migration history

- `legacy/main-before-upstream-sync` preserves the old standalone repository's
  main branch at `7d7a416eb20b3eab7dce3b61e4a8090af3b08039`.
- `tv-connection-reliability-v2` preserves the deployed package at
  `e8ca6eabf6e246d42edc30ccee15d5ea9d74c976`.
- The old repository is retained as an archive so repository-level history and
  settings are not discarded during migration to GitHub's fork network.
