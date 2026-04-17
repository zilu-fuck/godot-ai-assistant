# Reads and writes local config and sessions.
@tool
extends Node
class_name AIStorage

const CONFIG_PATH = "user://ai_assistant_config.cfg"
const SESSIONS_PATH = "user://ai_sessions.json"
const SESSION_SCHEMA_VERSION = 2

func load_config() -> Dictionary:
	var config: ConfigFile = ConfigFile.new()
	var data: Dictionary = {
		"url": "https://api.deepseek.com/chat/completions",
		"key": "",
		"model": "deepseek-chat",
		"profiles": {},
	}

	if config.load(CONFIG_PATH) == OK:
		data.url = config.get_value("API", "url", data.url)
		data.key = config.get_value("API", "key", "")
		data.model = config.get_value("API", "model", data.model)
		var raw_profiles = config.get_value("API", "profiles_json", "")
		if raw_profiles is String and not String(raw_profiles).strip_edges().is_empty():
			var parsed_profiles = JSON.parse_string(String(raw_profiles))
			if parsed_profiles is Dictionary:
				data.profiles = _normalize_profiles(parsed_profiles)
		elif raw_profiles is Dictionary:
			data.profiles = _normalize_profiles(raw_profiles)

	if data.profiles.is_empty() and not String(data.model).is_empty():
		data.profiles[String(data.model)] = {
			"url": String(data.url),
			"key": String(data.key),
		}

	var selected_model: String = String(data.model)
	if data.profiles.has(selected_model):
		var selected_profile: Dictionary = data.profiles[selected_model]
		data.url = String(selected_profile.get("url", data.url))
		data.key = String(selected_profile.get("key", data.key))
	return data

func save_config(url: String, key: String, model: String, profiles: Dictionary = {}) -> void:
	var config: ConfigFile = ConfigFile.new()
	var normalized_profiles: Dictionary = _normalize_profiles(profiles)
	if not String(model).is_empty():
		normalized_profiles[String(model)] = {
			"url": String(url),
			"key": String(key),
		}
	config.set_value("API", "url", url)
	config.set_value("API", "key", key)
	config.set_value("API", "model", model)
	config.set_value("API", "profiles_json", JSON.stringify(normalized_profiles))
	config.save(CONFIG_PATH)

func load_all_sessions() -> Dictionary:
	if FileAccess.file_exists(SESSIONS_PATH):
		var file: FileAccess = FileAccess.open(SESSIONS_PATH, FileAccess.READ)
		var json = JSON.parse_string(file.get_as_text())
		if json is Dictionary:
			return _normalize_sessions(json)
	return {}

func save_sessions(all_sessions: Dictionary) -> void:
	var file: FileAccess = FileAccess.open(SESSIONS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_normalize_sessions(all_sessions)))

func get_updated_title(history: Array, current_title: String) -> String:
	if history.size() > 0 and current_title.begins_with("New Chat"):
		var first_msg: String = String(history[0]["content"])
		return first_msg.left(12).strip_edges() + "..."
	return current_title

func _normalize_sessions(all_sessions: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}

	for session_id in all_sessions.keys():
		var raw_session = all_sessions[session_id]
		if not (raw_session is Dictionary):
			continue

		var session: Dictionary = raw_session.duplicate(true)
		if not session.has("title"):
			session["title"] = "New Chat"
		if not session.has("history") or not (session["history"] is Array):
			session["history"] = []
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
		session["schema_version"] = SESSION_SCHEMA_VERSION
		normalized[session_id] = session

	return normalized

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

func _normalize_profiles(raw_profiles: Dictionary) -> Dictionary:
	var normalized: Dictionary = {}
	for raw_model in raw_profiles.keys():
		var model: String = String(raw_model).strip_edges()
		if model.is_empty():
			continue
		var profile: Variant = raw_profiles[raw_model]
		if not (profile is Dictionary):
			continue
		normalized[model] = {
			"url": String(profile.get("url", "")).strip_edges(),
			"key": String(profile.get("key", "")).strip_edges(),
		}
	return normalized
