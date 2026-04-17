@tool
extends RefCounted
class_name AIMemoryManager

const SESSION_SCHEMA_VERSION: int = 3
const AUTO_COMPACT_MESSAGE_THRESHOLD: int = 12
const KEEP_RECENT_MESSAGES: int = 6
const MAX_ITEM_LENGTH: int = 180
const MAX_LIST_ITEMS: int = 5

func ensure_session_shape(session: Dictionary) -> void:
	if not session.has("history") or not (session["history"] is Array):
		session["history"] = []

	session["schema_version"] = SESSION_SCHEMA_VERSION

	if not session.has("memory") or not (session["memory"] is Dictionary):
		session["memory"] = _default_memory()
	else:
		var memory: Dictionary = session["memory"]
		var defaults: Dictionary = _default_memory()
		for key in defaults.keys():
			if not memory.has(key):
				memory[key] = defaults[key]

	if not session.has("action_log") or not (session["action_log"] is Array):
		session["action_log"] = []
	if not session.has("rollback_log") or not (session["rollback_log"] is Array):
		session["rollback_log"] = []

func register_context(session: Dictionary, runtime_context: Dictionary) -> void:
	ensure_session_shape(session)
	var memory: Dictionary = session["memory"]
	var script_path: String = String(runtime_context.get("script_path", ""))
	if script_path.is_empty():
		return

	_push_unique(memory["recent_files"], script_path)

func register_assistant_response(session: Dictionary, content: String) -> void:
	ensure_session_shape(session)
	var memory: Dictionary = session["memory"]
	var compact_content: String = content.strip_edges()
	if compact_content.is_empty():
		return

	if _looks_like_bug_note(compact_content):
		_push_unique(memory["bug_notes"], compact_content.left(MAX_ITEM_LENGTH))

func maybe_auto_compact(session: Dictionary) -> Dictionary:
	ensure_session_shape(session)
	var history: Array = session["history"]
	if history.size() < AUTO_COMPACT_MESSAGE_THRESHOLD:
		return {"performed": false}

	return compact_session(session, "auto")

func compact_session(session: Dictionary, mode: String = "manual") -> Dictionary:
	ensure_session_shape(session)

	var history: Array = session["history"]
	if history.size() <= KEEP_RECENT_MESSAGES:
		return {
			"ok": true,
			"performed": false,
			"reason": "too_short",
			"summary_text": export_memory_text(session["memory"]),
		}

	var split_index: int = max(0, history.size() - KEEP_RECENT_MESSAGES)
	var older_history: Array = history.slice(0, split_index)
	var recent_history: Array = history.slice(split_index)
	var memory: Dictionary = session["memory"]

	_merge_history_into_memory(memory, older_history)
	memory["last_compacted_at"] = "%s %s" % [Time.get_date_string_from_system(), Time.get_time_string_from_system()]
	memory["last_compact_mode"] = mode
	memory["summary_text"] = export_memory_text(memory)

	session["history"] = recent_history

	return {
		"ok": true,
		"performed": true,
		"memory": memory,
		"summary_text": memory["summary_text"],
	}

func export_memory_text(memory: Dictionary) -> String:
	var sections: Array = []
	_append_section(sections, "Core Goals", memory.get("core_goals", []))
	_append_section(sections, "Decisions", memory.get("decided_architecture", []))
	_append_section(sections, "Open Questions", memory.get("open_questions", []))
	_append_section(sections, "Bug Notes", memory.get("bug_notes", []))
	_append_section(sections, "Recent Files", memory.get("recent_files", []))

	var compacted_at: String = String(memory.get("last_compacted_at", ""))
	if not compacted_at.is_empty():
		sections.append("Last compacted: %s" % compacted_at)

	return "\n".join(sections).strip_edges()

func _default_memory() -> Dictionary:
	return {
		"core_goals": [],
		"decided_architecture": [],
		"open_questions": [],
		"bug_notes": [],
		"recent_files": [],
		"last_compacted_at": "",
		"last_compact_mode": "",
		"summary_text": "",
	}

func _merge_history_into_memory(memory: Dictionary, history: Array) -> void:
	for message in history:
		if not (message is Dictionary):
			continue

		var role: String = String(message.get("role", ""))
		var content: String = String(message.get("content", "")).strip_edges()
		if content.is_empty():
			continue

		var trimmed: String = content.left(MAX_ITEM_LENGTH)
		if role == "user":
			_push_unique(memory["core_goals"], trimmed)
			if _looks_like_question(content):
				_push_unique(memory["open_questions"], trimmed)
			if _looks_like_bug_note(content):
				_push_unique(memory["bug_notes"], trimmed)
		elif role == "assistant":
			if _looks_like_bug_note(content):
				_push_unique(memory["bug_notes"], trimmed)
			else:
				_push_unique(memory["decided_architecture"], trimmed)

	_trim_list(memory["core_goals"])
	_trim_list(memory["decided_architecture"])
	_trim_list(memory["open_questions"])
	_trim_list(memory["bug_notes"])
	_trim_list(memory["recent_files"])

func _looks_like_question(content: String) -> bool:
	return content.contains("?") or content.contains("how") or content.contains("what") or content.contains("why")

func _looks_like_bug_note(content: String) -> bool:
	var lowered: String = content.to_lower()
	return lowered.contains("error") or lowered.contains("failed") or lowered.contains("exception") or lowered.contains("warning")

func _append_section(sections: Array, title: String, items: Array) -> void:
	if items.is_empty():
		return

	var lines: Array = [title + ":"]
	for item in items:
		lines.append("- %s" % String(item))
	sections.append("\n".join(lines))

func _push_unique(target: Array, value: String) -> void:
	var cleaned: String = value.strip_edges()
	if cleaned.is_empty():
		return
	if target.has(cleaned):
		target.erase(cleaned)
	target.append(cleaned)

func _trim_list(target: Array) -> void:
	while target.size() > MAX_LIST_ITEMS:
		target.pop_front()
