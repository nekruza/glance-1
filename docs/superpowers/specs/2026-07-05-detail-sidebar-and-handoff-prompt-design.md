# Task Detail Sidebar + AI Handoff Prompt — Design

Date: 2026-07-05 · Status: approved by user

## Goal

1. Opening a task keeps the rest of the list visible in a left sidebar; clicking a sidebar row switches the detail in place.
2. Code tasks get a **Create prompt** button that AI-generates a self-contained prompt the user can paste into another AI assistant.

## 1. Sidebar

- `TaskBoardView`: when `session.selectedTask != nil`, render `HStack { TaskSidebar; Divider; TaskDetailView }` instead of full-width detail.
- Sidebar content = `session.visibleTasks()` — current tab's list, same sort and search filter the user was browsing.
- Row: priority badge + title (2-line max) + status badge. Selected row highlighted with accent-soft background. Click sets `session.selectedTaskId`.
- Fixed width ~230pt, scrollable. Header shows tab name + count.
- "Back to Board" button in the detail header unchanged. Window `minWidth` 760 → 900.

## 2. Create prompt (code tasks)

- Button in `TaskDetailView` header, visible only when `taskKind == .code`. Spinner while generating.
- `TaskAI.handoffPrompt(for:)` — one-shot `claude -p` (default model) returning raw markdown (new `runText` plumbing beside `runJSON`). Inputs: title, description, repo name + path, labels, agent skills.
- Result persisted as `TaskItem.handoffPrompt: String?` (optional → old JSON decodes fine).
- New "Prompt for your AI" section under Description: rendered markdown, **Copy** (clipboard, "Copied" flash), **Edit** inline (TextEditor + Save), **Regenerate**.

## Error handling

- AI call fails → busy flag clears, no prompt saved; section stays absent (same degrade-to-no-change convention as enrichment).
- Sidebar list empty (edge: tab without lists) → sidebar just shows header; detail still works.

## Testing

- `swift build` clean; manual run: open task from Board → sidebar shows same list, switching works; code task → Create prompt → section appears, Copy puts text on clipboard.
