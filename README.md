# Godot AI Assistant v2.2

Godot AI Assistant is an in-editor AI coding assistant for Godot 4. It works inside the editor Dock and combines project context, rules, memory, and apply workflows so AI output can be reviewed before it changes files.

## v2.2 Highlights

- Runtime requests now move through explicit stages instead of a generic busy flag.
- Each request exposes a stable `request_id` and richer debug information.
- Network handling retries short failures once, can fall back from streaming to non-streaming, and keeps partial responses when possible.
- AI Apply now records rollback data so the latest AI change in the current session can be undone safely.
- Scene creation now participates in the same review and rollback flow, including companion scripts.
- Context selection now boosts relevance for the active file, selection, prompt-mentioned symbols or paths, recent edits, and Git-oriented prompts.

## Core Features

- Multi-session chat with local persistence
- Project-aware prompting with active script, selection, scene, project index, Git summary, rules, and session memory
- Structured prompt building with context budgeting and explainable context selection
- Provider profile and adapter layer for OpenAI-compatible endpoints
- Review-first apply flow with target resolution, diff preview, and high-risk confirmation
- Scene creation flow for `.tscn` content and companion scripts
- Undo entry point for the latest AI-generated change in the current session

## Project Layout

```text
addons/ai_assistant/
  ai_assistant.gd
  ai_chat_renderer.gd
  ai_context_ring.gd
  ai_dock.gd
  ai_dock.tscn
  ai_net_client.gd
  ai_storage.gd
  actions/
  core/
  memory/
  net/
  project/
  prompt/
```

`addons/ai_assistant` is the release payload. The rest of the repository exists to support development, validation, and project handoff.

## Quick Start

1. Open the project with Godot 4.
2. Enable the plugin in `Project Settings -> Plugins`.
3. Open the `AI助手` Dock.
4. Configure your API URL, API key, and model.
5. Send a request, review the generated plan or diff, and confirm before applying changes.

## Validation

Recommended release smoke checks:

```powershell
godot --headless --path E:\test --editor --quit-after 1
git diff --check
```

## Version

- Plugin version: `2.2`
- Plugin config: `addons/ai_assistant/plugin.cfg`
