# Required-reason API audit

On 2026-09-13, the built Debug app had no `PrivacyInfo.xcprivacy`. The integration now declares the following uses in the app bundle:

| Category | Reason | Verified use |
| --- | --- | --- |
| User defaults | CA92.1 | App-owned draft preferences, draft persistence, project folders, read state and terminal settings use `UserDefaults.standard`. No shared app-group or foreign preference-domain access was found in app source. |
| System boot time | 35F9.1 | Statically linked GhosttyTerminal uses `ProcessInfo.systemUptime` for terminal rendering ticks and the elapsed duration of surface writes. These readings support in-app timing; the inspected code does not transmit raw uptime. |

The new manifest passes `plutil -lint` and is included verbatim by Xcode's synchronized app group in the iOS simulator product (`ios-privacy-build.json`). No Xcode project or generated file was edited. Both September 14 Release archives include the manifest and pass local code-signature verification; see `macos-archive.json` and `ios-archive.json`. App Store validation remains pending.

This is an accessed-API declaration, not a claim that the app collects no data. App Store privacy responses and third-party SDK manifest obligations are separate. No dependency checkout was modified; the pinned Ghostty package currently provides no separate privacy manifest. Inspect the archived executable and any embedded frameworks before closing the distribution gate.

Apple references checked on 2026-09-13: [required reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype), [manifest structure](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest). Xcode DocumentationSearch also confirmed API declaration and property-list structure.

The macOS archive also imports `fstat`/`fstatat` from static native code. Call-site candidates are saved in `file-api-callers.json`; symbolication only resolves a distant preceding native symbol, so it does not identify the real callers or justify an additional reason. SDK file-API usage and its privacy manifest remain an open distribution audit item. No reason was invented for these unresolved calls.
