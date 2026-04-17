extends SceneTree

func _initialize() -> void:
	await process_frame
	await process_frame

	var failures: Array = []
	var dock: Control = _find_ai_dock(EditorInterface.get_base_control())
	_expect(dock != null, "AI Dock should exist in editor mode", failures)
	if dock != null:
		_validate_undo_button(dock, failures)

	if failures.is_empty():
		print("ui validation passed")
		quit(0)
		return

	for failure in failures:
		push_error(String(failure))
	quit(1)

func _validate_undo_button(dock: Control, failures: Array) -> void:
	var undo_button: Button = dock.undo_button
	_expect(undo_button != null, "Undo button should be created dynamically", failures)
	if undo_button == null:
		return

	_expect(undo_button.tooltip_text == "撤销上次 AI 改动", "Undo button tooltip should match the intended action", failures)
	_expect(undo_button.disabled, "Undo button should start disabled when there is no rollback entry", failures)

	dock.all_sessions = {
		"session-a": {
			"title": "Session A",
			"history": [],
			"memory": {},
			"action_log": [],
			"rollback_log": [],
			"schema_version": 3,
		}
	}
	dock.current_session_id = "session-a"
	dock._sync_runtime_state_ui()
	_expect(undo_button.disabled, "Undo button should remain disabled when rollback_log is empty", failures)

	var session: Dictionary = dock.all_sessions["session-a"]
	session["rollback_log"] = [{
		"rolled_back": false,
		"targets": [],
	}]
	dock.all_sessions["session-a"] = session
	dock.runtime.set_state(AIRuntime.STATE_IDLE)
	dock._sync_runtime_state_ui()
	_expect(not undo_button.disabled, "Undo button should enable when an undoable rollback entry exists", failures)

	dock.runtime.set_state(AIRuntime.STATE_STREAMING)
	dock._sync_runtime_state_ui()
	_expect(undo_button.disabled, "Undo button should disable while runtime is busy", failures)

	dock.runtime.set_state(AIRuntime.STATE_IDLE)
	dock._sync_runtime_state_ui()
	_expect(not undo_button.disabled, "Undo button should re-enable after runtime returns idle", failures)

func _find_ai_dock(root: Node) -> Control:
	if root == null:
		return null
	if root is Control:
		var script: Script = root.get_script()
		if script != null and script.resource_path == "res://addons/ai_assistant/ai_dock.gd":
			return root
	for child in root.get_children():
		var found: Control = _find_ai_dock(child)
		if found != null:
			return found
	return null

func _expect(condition: bool, message: String, failures: Array) -> void:
	if condition:
		print("PASS: %s" % message)
		return
	failures.append("FAIL: %s" % message)
