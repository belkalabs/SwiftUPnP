# Changelog

## Unreleased (fix/discovery-reliability)

- Accept USNs without `::`, such as Roku's `uuid:roku:ecp:<serial>`: Roku's own
  ECP answer was always dropped. `UPnPDevice.uuid` keeps its `uuid:` prefix;
  the new `bareUUID` has it without.
- Parse SSDP leniently: header names in any case, LF-only lines, padded
  values, no space after the colon, repeated headers (first value wins),
  missing CACHE-CONTROL/EXT/SERVER, `HTTP/1.0`, no reason phrase, Latin-1
  bytes, and unknown start lines judged by their headers.
- Continuous discovery: `startContinuousDiscovery(_:schedule:)` searches in a
  burst at 0, 1, 3 and 5 s, then every 15 s; `searchNow()` starts the burst
  over. `tvSearchTargets` lists the default search targets.
  `startDiscovery(_:requiredDefaultFiltration:)` keeps its 0/3/10 s schedule.
- Hear NOTIFY alive and byebye on a second socket bound to port 1900. A
  byebye for `upnp:rootdevice` removes the device under all of its types.
- One description load per device uuid and location, however many search
  targets it answers.
- A failed multicast join no longer stops searching. Problems are published
  through `discoveryStatus`, `discoveryIssues` and
  `DiscoveryDelegate.discoveryDidReportIssue(_:)` with a likely cause (no
  Wi-Fi, Local Network access off). Searches go out on `en0`. Stale sockets
  are reopened with a back-off.
- Device descriptions: 5 s timeout and one retry after a timeout, connection
  error, empty answer or 5xx. Missing names, specVersion or service URLs and
  broken icon lists no longer fail the whole description.

## 1.2.0 - 2026-10-30

- Update to katoemba/SwiftUPnP at `fcd298d`, including network recovery,
  repeated SSDP searches, device loading deduplication and subscription fixes.
- Preserve Belkalabs TV discovery for DIAL, Panasonic and Roku targets.
- Preserve SERVER metadata, raw XML diagnostics and discovery delegate APIs.
- Restore saved device descriptions with or without the SERVER field.
- Correct SOAP fault parsing for both plain and namespaced UPnP errors.
- Include both the deployed TV branch and the legacy repository history in main.
- Replace Swifter with the upstream native HTTP listener.

Validation: 42 SwiftPM tests passed, and RemoteControl built for iOS Simulator
with this package. The final history merges leave the tested implementation
unchanged. Real TV and Wi-Fi transition testing remains outstanding.
