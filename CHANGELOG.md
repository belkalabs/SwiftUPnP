# Changelog

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
