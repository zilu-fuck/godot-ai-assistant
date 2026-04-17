extends SceneTree

class FakeNetClient:
	extends AINetClient

	var start_calls: Array = []

	func start_request(url: String, key: String, body: String, options: Dictionary = {}) -> Dictionary:
		start_calls.append({
			"url": url,
			"key": key,
			"body": body,
			"options": options.duplicate(true),
		})
		return {"ok": true}

func _initialize() -> void:
	var failures: Array = []

	_run_network_validation(failures)
	_run_apply_undo_validation(failures)

	if failures.is_empty():
		print("v2.2 validation passed")
		quit(0)
		return

	for failure in failures:
		push_error(String(failure))
	quit(1)

func _run_network_validation(failures: Array) -> void:
	var fake_net := FakeNetClient.new()
	var runtime := AIRuntime.new()
	runtime.setup(fake_net, 15, AIActionExecutor.new(), null)

	runtime._begin_request("retry test")
	runtime._active_request = {
		"url": "https://example.invalid/chat/completions",
		"key": "token",
		"stream_request": {"body": "{}", "payload": {}},
		"fallback_request": {"body": "{\"stream\":false}", "payload": {"stream": false}},
		"retry_count": 0,
		"fallback_used": false,
		"allow_fallback": true,
	}
	var retry_result: Dictionary = runtime.handle_stream_failure("connect timeout", {
		"failure_kind": "connect_timeout",
		"response_code": 0,
		"partial_content": "",
	})
	_expect(str(retry_result.get("action", "")) == "restarted", "network retry should restart the request", failures)
	_expect(fake_net.start_calls.size() == 1, "network retry should trigger one new start_request call", failures)
	_expect(int(runtime.last_request_preview.get("network", {}).get("retry_count", -1)) == 1, "network retry should update retry_count in preview", failures)

	runtime._begin_request("fallback test")
	runtime._active_request = {
		"url": "https://example.invalid/chat/completions",
		"key": "token",
		"stream_request": {"body": "{}", "payload": {}},
		"fallback_request": {"body": "{\"stream\":false}", "payload": {"stream": false}},
		"retry_count": 1,
		"fallback_used": false,
		"allow_fallback": true,
	}
	var fallback_result: Dictionary = runtime.handle_stream_failure("stream interrupted", {
		"failure_kind": "response_interrupted",
		"response_code": 200,
		"partial_content": "",
	})
	_expect(str(fallback_result.get("action", "")) == "restarted", "fallback should restart the request in non-streaming mode", failures)
	_expect(fake_net.start_calls.size() == 2, "fallback should trigger a second start_request call", failures)
	if fake_net.start_calls.size() >= 2:
		_expect(not bool(fake_net.start_calls[1].get("options", {}).get("stream", true)), "fallback restart should disable streaming", failures)

	runtime._begin_request("partial keep test")
	runtime._active_request = {
		"url": "https://example.invalid/chat/completions",
		"key": "token",
		"stream_request": {"body": "{}", "payload": {}},
		"fallback_request": {"body": "{\"stream\":false}", "payload": {"stream": false}},
		"retry_count": 0,
		"fallback_used": false,
		"allow_fallback": true,
	}
	var partial_result: Dictionary = runtime.handle_stream_failure("stream interrupted", {
		"failure_kind": "stream_interrupted",
		"response_code": 200,
		"partial_content": "partial text",
	})
	_expect(str(partial_result.get("action", "")) == "finalize", "partial response should finalize instead of restarting", failures)
	_expect(bool(partial_result.get("keep_partial", false)), "partial response should be marked as kept", failures)
	_expect(bool(runtime.last_request_preview.get("network", {}).get("partial_response_kept", false)), "preview should record partial_response_kept", failures)
	fake_net.free()

func _run_apply_undo_validation(failures: Array) -> void:
	var runtime := AIRuntime.new()
	var fake_net := FakeNetClient.new()
	runtime.setup(fake_net, 15, AIActionExecutor.new(), null)

	var validation_dir: String = "user://v22_validation"
	var validation_file: String = "%s/runtime_target.gd" % validation_dir
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(validation_dir))
	var initial_text: String = "func value() -> int:\n\treturn 1\n"
	_write_text(validation_file, initial_text)

	var action: Dictionary = {
		"action_type": AIActionExecutor.ACTION_REPLACE_SELECTION,
		"execution_type": AIActionExecutor.EXEC_REPLACE_FILE,
		"content": "func value() -> int:\n\treturn 2\n",
		"target_path": validation_file,
		"requires_confirmation": true,
		"requires_secondary_confirmation": false,
		"confirmed": false,
		"secondary_confirmed": false,
		"risk_level": "high",
		"target_label": "runtime_target.gd",
	}
	runtime.set_pending_action(action)
	var apply_result: Dictionary = runtime.execute_pending_action({})
	_expect(bool(apply_result.get("ok", false)), "apply result should succeed for replace_file validation", failures)
	_expect(str(_read_text(validation_file)) == "func value() -> int:\n\treturn 2\n", "apply should update the target file", failures)
	_expect(not apply_result.get("rollback_entry", {}).is_empty(), "apply should return a rollback entry", failures)

	var session: Dictionary = {
		"history": [],
		"memory": {},
		"action_log": [],
		"rollback_log": [apply_result.get("rollback_entry", {})],
	}
	var undo_result: Dictionary = runtime.undo_last_ai_change(session, {})
	_expect(bool(undo_result.get("ok", false)), "undo should succeed when the target is unchanged", failures)
	_expect(str(_read_text(validation_file)) == initial_text, "undo should restore the previous file contents", failures)

	runtime.set_pending_action(action)
	var apply_result_again: Dictionary = runtime.execute_pending_action({})
	_expect(bool(apply_result_again.get("ok", false)), "second apply should also succeed", failures)
	_write_text(validation_file, "func value() -> int:\n\treturn 999\n")
	session["rollback_log"] = [apply_result_again.get("rollback_entry", {})]
	var conflict_result: Dictionary = runtime.undo_last_ai_change(session, {})
	_expect(not bool(conflict_result.get("ok", false)), "undo should fail when the target changed after apply", failures)
	_expect(str(conflict_result.get("reason", "")) == "rollback_conflict", "undo conflict should report rollback_conflict", failures)

	if FileAccess.file_exists(validation_file):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(validation_file))
	fake_net.free()

func _expect(condition: bool, message: String, failures: Array) -> void:
	if condition:
		print("PASS: %s" % message)
		return
	failures.append("FAIL: %s" % message)

func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()

func _write_text(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to write validation file: %s" % path)
		return
	file.store_string(text)
	file.flush()
