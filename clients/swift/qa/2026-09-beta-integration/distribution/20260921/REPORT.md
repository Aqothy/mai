# Release archives after composer correction

Both platforms archived successfully from Swift source `267d18b` using the user-approved Xcode Product → Archive action. Xcode MCP reported successful archive logs without warnings. The JSON audits record exact archive paths, hashes, signing checks, entitlements and executable load commands.

The universal macOS archive supports Intel and Apple silicon and targets macOS 15.6. Its signature passes deep/strict verification; sandbox, network-client and user-selected read-only file entitlements are present, without `get-task-allow`. The arm64 iOS archive targets iOS 18.6 as explicitly requested; its signature also passes deep/strict verification. It is development-signed with `get-task-allow`, not an exported distribution artifact.

Both include the camera usage description and privacy manifest. The unmodified macOS archive passed the actual Codex chat, copy, import/fork and restart workflow, and ignored synthetic benchmark launch arguments. See `../../live-release-20260921/REPORT.md` for that runtime evidence. The iOS archive has not been run on a physical device. The older-runtime simulator test evidence is separate and does not substitute for that check.

No upload or distribution export was performed. Privacy API classification questions in `../PRIVACY.md`, distribution validation and physical-device QA remain open. The later backend-only reasoning fix does not alter these Swift binaries.
