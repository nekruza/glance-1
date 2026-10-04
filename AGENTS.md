# Repository Guidelines

## Project Structure & Module Organization

Glance is a Swift Package Manager macOS 14+ menu-bar application. Application code lives in `Sources/Glance/`, with features grouped into folders such as `Backend/`, `Capture/`, `Overlay/`, `Tasks/`, and `Settings/`. Keep shared app coordination and design tokens at the target root. XCTest suites belong in `Tests/GlanceTests/`. Build and signing helpers are in `Scripts/`; design notes, specifications, and implementation plans live in `docs/`. Generated output goes under `build/` or `.build/` and should not be committed.

## Build, Test, and Development Commands

- `swift build` — compile the debug executable with SwiftPM.
- `swift run Glance` — run the executable during quick development cycles.
- `swift test` — build and run all XCTest suites.
- `Scripts/build-app.sh` — create a release, signed `build/Glance.app` bundle.
- `Scripts/build-app.sh debug` — assemble the app from a faster debug build.
- `Scripts/dev-sign-setup.sh` — create the one-time local signing identity that preserves Screen Recording permission between builds.
- `open build/Glance.app` — launch the bundled app for permission-sensitive testing.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, one primary type per file, `UpperCamelCase` for types, and `lowerCamelCase` for methods and properties. Name files after their main type, for example `ScreenCaptureService.swift`. Keep UI work main-thread-safe and prefer small feature-local types over expanding app-level coordinators. No formatter or linter is configured; use Xcode formatting and keep `swift build` warning-free.

## Testing Guidelines

Tests use XCTest with `@testable import Glance`. Add focused test files named `<Subject>Tests.swift`, test classes named `<Subject>Tests`, and methods beginning with `test`, such as `testMapsTextDeltaToTokenEvent`. Run `swift test` before every pull request. Exercise screen capture, microphone, hotkeys, launch-at-login, and signing behavior manually in the bundled app because these rely on macOS permissions and frameworks.

## Commit & Pull Request Guidelines

Recent history mixes descriptive commits with prefixes such as `feat:`, `fix:`, and `docs:`. Prefer concise, imperative Conventional Commit-style subjects (`fix: retain backend selection`). Pull requests should explain user-visible behavior, list validation performed, link relevant specs or issues, and include screenshots or recordings for UI changes. Call out permission, privacy, signing, or transcript-storage changes explicitly. Never commit credentials, keychains, captured screens, transcripts, or local Claude/Codex session data.
