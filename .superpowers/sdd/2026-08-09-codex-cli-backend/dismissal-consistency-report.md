# Dismissal consistency correction

Date: 2026-08-11

## Status

Completed and committed: overlay dismissal now clears the visible ask transcript
and per-turn UI state before the next invocation creates its fresh backend.

## Change

- `AppCoordinator.endSession()` now clears the overlay transcript, input,
  attachment/working state, suggestions, and capture label. It also drops the
  pending capture label.
- The active backend shutdown behavior remains unchanged.
- Provider-switch reset behavior is unchanged, and no task-system or persisted
  history behavior was modified.
- The coordinator accepts an injected overlay in tests, keeping the production
  overlay private while exercising the real dismissal path.

## Regression coverage

`AskBackendLifecycleTests.testCoordinatorDismissalClearsVisibleTranscriptAndShutsDownItsActiveBackend`
seeds old turns, draft input, and suggestions; after `endSession()` it asserts
all are empty and confirms the backend is shut down.

The test was run before the implementation change and failed on all three UI
state assertions, then passed after the correction.

## Verification

- `swift test --filter AskBackendLifecycleTests/testCoordinatorDismissalClearsVisibleTranscriptAndShutsDownItsActiveBackend` — passed.
- `swift test` — passed: 17 tests, 0 failures.
- `Scripts/build-app.sh` — passed and assembled `build/Glance.app`.

## Concern

The release build completed with pre-existing Swift 6 concurrency warnings in
`TaskRunner.swift` and `MeetingTranscriber.swift`; this correction does not
modify those files.
