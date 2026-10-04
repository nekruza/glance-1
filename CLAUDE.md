# CLAUDE.md

See `AGENTS.md` for structure, build/test commands, and style.

## Troubleshooting

### "Screenshot couldn't be attached" / Screen Recording enabled but still denied

**Cause:** macOS stores the Screen Recording grant with the signing certificate's hash. After the signing identity changes (new `Glance Dev` cert or keychain), the saved grant no longer matches the build. The toggle shows ON, but `tccd` rejects it. Re-toggling does not help.

**Confirm:**
```bash
/usr/bin/log show --last 5m --predicate 'process == "tccd" AND eventMessage CONTAINS[c] "com.h57q3wq0c.glance"' --style compact | grep "Failed to match"
codesign -d -r- build/Glance.app   # cert hash of the current build
```
A `Failed to match existing code requirement` entry listing a different `certificate leaf` hash than the current build confirms it.

**Fix:**
```bash
tccutil reset ScreenCapture com.h57q3wq0c.glance
pkill -x Glance; open build/Glance.app
```
Then trigger a screenshot, enable Glance in System Settings → Screen Recording, and accept the prompt. If macOS's "Quit & Reopen" doesn't relaunch the app (common for menu-bar apps), run `open build/Glance.app` manually.

Avoid recurrence: always sign with the same identity (`Scripts/dev-sign-setup.sh`; `build-app.sh` selects the cert by fingerprint because duplicate `Glance Dev` names exist).

### `swift build` / `swift run` crash with `dyld: Symbol not found ... BuildServerProtocol`

**Cause:** Broken Command Line Tools install. `/Library/Developer/CommandLineTools/usr/bin/swift-package` and its `pm/*.framework` come from mismatched versions. Xcode.app is also broken on this machine (`libxcodebuildLoader` / `_XPCTypeBool`), so it cannot be used as a fallback.

**Fix:** update or reinstall the CLT:
```bash
sudo softwareupdate --install "Command Line Tools for Xcode 27.0-27.0"
# or: sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
```
The compiler itself (`swiftc`) still works, so the existing `build/Glance.app` runs fine. The issue only blocks rebuilding.

**Workaround without SwiftPM:** the CLT `swiftc` (6.3.3) rejects the default 27.0 SDK, so pass the 26.5 one.
```bash
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
swiftc -typecheck -swift-version 5 -sdk $SDK -target arm64-apple-macos14.0 $(find Sources -name "*.swift")   # fast check
swiftc -O -wmo -swift-version 5 -sdk $SDK -target arm64-apple-macos14.0 -framework Carbon -framework ScreenCaptureKit \
  -framework ServiceManagement -module-name Glance -o /tmp/Glance-new $(find Sources -name "*.swift")
```
To ship it: copy `build/Glance.app`, replace `Contents/MacOS/Glance`, re-sign with the `Glance Dev` cert hash (same steps as `build-app.sh`), verify, then swap it in. Keep the same cert so the Screen Recording grant survives. Note: stale Swift 5.10 `PackageDescription` `.private.swiftinterface` files in the CLT were previously renamed to `.bak5.10`. Revert that if the CLT is reinstalled and builds behave oddly.
