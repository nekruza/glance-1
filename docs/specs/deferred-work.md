# Deferred work

- 2026-07-07 (from spec-autonomy-v1 review): Review-queue rows call `approveReview(releaseBoundary: false)` — a code run's boundary artifact (git push / PR) can never be released from the queue, only from the task detail view's per-artifact "Approve & push". Conscious safe default; revisit if queue-level release is ever wanted.
