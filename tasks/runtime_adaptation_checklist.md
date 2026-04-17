# Runtime Adaptation Checklist

Use this checklist after changing `AIRuntime`, Apply planning, action execution, or the Dock review flow.

Reference scripts:

- `res://test/v22_validation.gd`
- `res://test/ui_validation.gd`
- `E:\test\test\run_v22_validations.ps1`

## Request and Context

- [ ] Runtime state machine: send one request and confirm the preview/debug label steps through request states instead of a generic busy flag.
- [ ] Request ID visibility: confirm the preview/debug block shows a stable `request_id` for the active request.
- [ ] Long conversation budget: send or preview a prompt in a session with enough history to exercise the context meter.
- [ ] Preview integrity: confirm the request preview still shows context usage, dropped items, and provider/rules info.
- [ ] Relevance ranking: mention the active file name, a symbol name, and a Git term in separate prompts and confirm the selected context list shifts accordingly.
- [ ] Context explainability: confirm selected and dropped context entries show why they were prioritized or dropped.

## Response Rendering

- [ ] Explanation-only reply with a code block: no `Apply` or `Preview` button is shown.
- [ ] Suggestion reply with a focused function replacement: the code block shows `Apply`.
- [ ] Suggestion reply with a full-file or obviously large replacement: the code block shows `Preview`.

## Target Resolution

- [ ] Single-function replacement in the active script resolves to the matching function instead of the whole file.
- [ ] Whole-script code block resolves to a whole-file plan and is marked high risk.
- [ ] Latest user-mentioned file path wins over the active editor when the file exists.
- [ ] Missing user-mentioned file blocks Apply instead of falling back to a random file.

## Review and Risk

- [ ] Candidate list reason text matches the final review reason for the selected target.
- [ ] Normal-risk change reaches one review dialog before execution.
- [ ] High-risk change requires a second confirmation after the review dialog.
- [ ] High-risk review clearly signals that the change is high risk.

## Execution

- [ ] Active-file function replacement writes to the open editor correctly.
- [ ] Cross-file apply writes to the resolved file and re-focuses that resource.
- [ ] Large replacement and whole-file replacement are logged with high-risk metadata.
- [ ] Every successful AI apply stores a rollback entry with before/after text.
- [ ] Undo last AI change restores the latest session-local AI edit when the target is unchanged.
- [ ] Undo conflict handling blocks rollback when the target file was modified after the AI apply.

## Scene Creation

- [ ] Scene-creation reply with a valid `.tscn` block shows `Create Scene` or `Preview`, not `Apply`.
- [ ] Explicit user-mentioned `.tscn` path is reused for scene creation, even when the file does not exist yet.
- [ ] Scene creation without an explicit path falls back to a sensible suggested path near the active scene or script.
- [ ] Creating a brand-new `.tscn` writes the file and opens that scene in the editor.
- [ ] Replacing an existing `.tscn` is marked high risk and requires a second confirmation.
- [ ] Scene creation with a companion script stores rollback data for both the scene and the generated script.

## Network Recovery

- [ ] Connection failure before the first token retries once automatically.
- [ ] First-byte timeout retries once automatically.
- [ ] Streaming failure before any content can fall back to a non-streaming response when the provider profile allows it.
- [ ] Streaming failure after partial content keeps the partial response and reports that clearly in the preview/debug panel.
- [ ] Retry/fallback metadata appears in the request preview/debug output.

## Regression Notes

- [ ] `ai_dock.gd` only orchestrates UI state, dialogs, and callbacks for Apply.
- [ ] `AIRuntime` returns structured action/candidate/review data instead of asking the Dock to infer policy.
- [ ] `AIActionExecutor` still handles both editor-backed execution and file-text transformation safely.
- [ ] `AINetClient` categorizes failures well enough for runtime retry/fallback policy to stay out of the Dock.
