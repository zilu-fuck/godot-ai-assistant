@tool
extends RefCounted
class_name AIContextBuilder

var _project_indexer: AIProjectIndexer = AIProjectIndexer.new()
var _git_context: AIGitContext = AIGitContext.new()

const PRIORITY_SELECTION_TEXT: int = 110
const PRIORITY_SCRIPT_TEXT: int = 100
const PRIORITY_SESSION_MEMORY: int = 80
const PRIORITY_GIT_SUMMARY: int = 65
const PRIORITY_PROJECT_MAP: int = 55
const PRIORITY_DYNAMIC_SYSTEM_CONTEXT: int = 95
const PLUGIN_SCRIPT_PREFIX: String = "res://addons/ai_assistant/"

func build_runtime_context(memory: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	return _build_runtime_context_v22(memory, options)
	var script_context: Dictionary = get_script_context()
	var recent_files: Array = []
	if memory.has("recent_files") and memory["recent_files"] is Array:
		recent_files = memory["recent_files"]

	var project_summary: Dictionary = _project_indexer.build_project_summary(recent_files)
	var git_summary: Dictionary = _git_context.build_git_summary()
	var script_path: String = get_current_script_path()
	var scene_path: String = get_current_scene_path()
	var include_script_context: bool = bool(options.get("include_script_context", true))
	if _is_plugin_script(script_path):
		include_script_context = false

	var current_date: String = "%s %s" % [Time.get_date_string_from_system(), Time.get_time_string_from_system()]
	var context_items: Array = _build_context_items(
		script_context,
		memory,
		git_summary,
		project_summary,
		current_date,
		script_path,
		scene_path,
		include_script_context
	)

	return {
		"current_date": current_date,
		"script_path": script_path if include_script_context else "",
		"scene_path": scene_path,
		"is_selected": bool(script_context.get("is_selected", false)) if include_script_context else false,
		"script_text": String(script_context.get("text", "")) if include_script_context else "",
		"project_summary": project_summary,
		"project_map_text": String(project_summary.get("map_text", "")),
		"git_summary": git_summary,
		"git_text": String(git_summary.get("summary_text", "")),
		"context_items": context_items,
	}

func get_script_context() -> Dictionary:
	var script_editor = EditorInterface.get_script_editor()
	if script_editor == null:
		return {"text": "", "is_selected": false}

	var current_editor = script_editor.get_current_editor()
	if current_editor and current_editor.get_base_editor() is CodeEdit:
		var editor: CodeEdit = current_editor.get_base_editor()
		if editor.has_selection():
			return {"text": editor.get_selected_text(), "is_selected": true}
		return {"text": editor.text, "is_selected": false}

	return {"text": "", "is_selected": false}

func get_current_script_path() -> String:
	var script_editor = EditorInterface.get_script_editor()
	if script_editor == null:
		return ""

	if script_editor.has_method("get_current_script"):
		var current_script = script_editor.get_current_script()
		if current_script is Script:
			return current_script.resource_path

	var current_editor = script_editor.get_current_editor()
	if current_editor and current_editor.has_method("get_edited_resource"):
		var edited_resource = current_editor.get_edited_resource()
		if edited_resource is Resource:
			return edited_resource.resource_path

	return ""

func get_current_scene_path() -> String:
	var scene_root = EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ""
	return scene_root.scene_file_path

func _build_context_items(script_context: Dictionary, memory: Dictionary, git_summary: Dictionary, project_summary: Dictionary, current_date: String, script_path: String, scene_path: String, include_script_context: bool) -> Array:
	var items: Array = []
	var dynamic_lines: Array = []

	if not current_date.is_empty():
		dynamic_lines.append("当前时间：%s" % current_date)
	if not scene_path.is_empty():
		dynamic_lines.append("当前场景：%s" % scene_path)
	if include_script_context and not script_path.is_empty():
		dynamic_lines.append("当前脚本：%s" % script_path)

	_append_item(
		items,
		"dynamic_system_context",
		"runtime",
		PRIORITY_DYNAMIC_SYSTEM_CONTEXT,
		"\n".join(dynamic_lines),
		"system",
		"动态系统上下文"
	)

	if include_script_context:
		var script_text: String = String(script_context.get("text", ""))
		var is_selected: bool = bool(script_context.get("is_selected", false))
		_append_item(
			items,
			"selection_text" if is_selected else "script_text",
			script_path if not script_path.is_empty() else "active_script",
			PRIORITY_SELECTION_TEXT if is_selected else PRIORITY_SCRIPT_TEXT,
			script_text,
			"runtime",
			"选中代码" if is_selected else "当前脚本"
		)

	_append_item(
		items,
		"session_memory",
		"session_memory",
		PRIORITY_SESSION_MEMORY,
		String(memory.get("summary_text", "")),
		"runtime",
		"会话记忆"
	)

	_append_item(
		items,
		"git_summary",
		"git",
		PRIORITY_GIT_SUMMARY,
		String(git_summary.get("summary_text", "")),
		"system",
		"Git 摘要"
	)

	_append_item(
		items,
		"project_map",
		"project_index",
		PRIORITY_PROJECT_MAP,
		String(project_summary.get("map_text", "")),
		"system",
		"项目地图"
	)

	return items

func _append_item(items: Array, kind: String, source: String, priority: int, text: String, target: String, title: String) -> void:
	var cleaned: String = text.strip_edges()
	if cleaned.is_empty():
		return

	items.append({
		"kind": kind,
		"source": source,
		"priority": priority,
		"text": cleaned,
		"target": target,
		"title": title,
		"truncated": false,
	})

func _is_plugin_script(script_path: String) -> bool:
	return script_path.begins_with(PLUGIN_SCRIPT_PREFIX)

func _build_runtime_context_v22(memory: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	var script_context: Dictionary = get_script_context()
	var recent_files: Array = []
	if memory.has("recent_files") and memory["recent_files"] is Array:
		recent_files = memory["recent_files"]

	var project_summary: Dictionary = _project_indexer.build_project_summary(recent_files)
	var git_summary: Dictionary = _git_context.build_git_summary()
	var script_path: String = get_current_script_path()
	var scene_path: String = get_current_scene_path()
	var include_script_context: bool = bool(options.get("include_script_context", true))
	if _is_plugin_script(script_path):
		include_script_context = false

	var current_date: String = "%s %s" % [Time.get_date_string_from_system(), Time.get_time_string_from_system()]
	var context_items: Array = _build_context_items_v22(
		script_context,
		memory,
		git_summary,
		project_summary,
		current_date,
		script_path,
		scene_path,
		include_script_context,
		options
	)

	return {
		"current_date": current_date,
		"script_path": script_path if include_script_context else "",
		"scene_path": scene_path,
		"is_selected": bool(script_context.get("is_selected", false)) if include_script_context else false,
		"script_text": String(script_context.get("text", "")) if include_script_context else "",
		"project_summary": project_summary,
		"project_map_text": String(project_summary.get("map_text", "")),
		"git_summary": git_summary,
		"git_text": String(git_summary.get("summary_text", "")),
		"context_items": context_items,
	}

func _build_context_items_v22(script_context: Dictionary, memory: Dictionary, git_summary: Dictionary, project_summary: Dictionary, current_date: String, script_path: String, scene_path: String, include_script_context: bool, options: Dictionary = {}) -> Array:
	var items: Array = []
	var prompt: String = String(options.get("prompt", ""))
	var dynamic_lines: Array = []
	if not current_date.is_empty():
		dynamic_lines.append("Current time: %s" % current_date)
	if not scene_path.is_empty():
		dynamic_lines.append("Active scene: %s" % scene_path)
	if include_script_context and not script_path.is_empty():
		dynamic_lines.append("Active script: %s" % script_path)

	_append_item_v22(items, "dynamic_system_context", "runtime", PRIORITY_DYNAMIC_SYSTEM_CONTEXT, "\n".join(dynamic_lines), "system", "Dynamic System Context", ["runtime metadata"])

	if include_script_context:
		var script_text: String = String(script_context.get("text", ""))
		var is_selected: bool = bool(script_context.get("is_selected", false))
		var script_reasons: Array = _build_script_reasons_v22(prompt, script_path, script_text, is_selected)
		_append_item_v22(
			items,
			"selection_text" if is_selected else "script_text",
			script_path if not script_path.is_empty() else "active_script",
			(PRIORITY_SELECTION_TEXT if is_selected else PRIORITY_SCRIPT_TEXT) + _score_relevance_v22(script_reasons),
			script_text,
			"runtime",
			"Selected Code" if is_selected else "Current Script",
			script_reasons
		)

	var memory_reasons: Array = _build_memory_reasons_v22(prompt)
	_append_item_v22(items, "session_memory", "session_memory", PRIORITY_SESSION_MEMORY + _score_relevance_v22(memory_reasons), String(memory.get("summary_text", "")), "runtime", "Session Memory", memory_reasons)

	var git_reasons: Array = _build_git_reasons_v22(prompt)
	_append_item_v22(items, "git_summary", "git", PRIORITY_GIT_SUMMARY + _score_relevance_v22(git_reasons), String(git_summary.get("summary_text", "")), "system", "Git Summary", git_reasons)

	var map_reasons: Array = _build_project_map_reasons_v22(prompt, scene_path)
	_append_item_v22(items, "project_map", "project_index", PRIORITY_PROJECT_MAP + _score_relevance_v22(map_reasons), String(project_summary.get("map_text", "")), "system", "Project Map", map_reasons)

	return items

func _append_item_v22(items: Array, kind: String, source: String, priority: int, text: String, target: String, title: String, relevance_reasons: Array = []) -> void:
	var cleaned: String = text.strip_edges()
	if cleaned.is_empty():
		return
	items.append({
		"kind": kind,
		"source": source,
		"priority": priority,
		"text": cleaned,
		"target": target,
		"title": title,
		"truncated": false,
		"relevance_reasons": relevance_reasons.duplicate(),
	})

func _build_script_reasons_v22(prompt: String, script_path: String, script_text: String, is_selected: bool) -> Array:
	var reasons: Array = []
	var lowered_prompt: String = prompt.to_lower()
	if is_selected:
		reasons.append("active selection")
	if not script_path.is_empty():
		reasons.append("active script")
		var script_name: String = script_path.get_file().to_lower()
		var script_base: String = script_path.get_file().get_basename().to_lower()
		if lowered_prompt.contains(script_name) or (not script_base.is_empty() and lowered_prompt.contains(script_base)):
			reasons.append("prompt mentions active file")
		if lowered_prompt.contains(script_path.to_lower()):
			reasons.append("prompt mentions script path")

	for symbol_name in _extract_symbol_names_v22(script_text):
		if lowered_prompt.contains(String(symbol_name).to_lower()):
			reasons.append("prompt mentions symbol")
			break
	return reasons

func _build_git_reasons_v22(prompt: String) -> Array:
	var lowered_prompt: String = prompt.to_lower()
	var reasons: Array = []
	if _contains_any_v22(lowered_prompt, ["git", "commit", "branch", "diff", "merge", "rebase", "status"]):
		reasons.append("prompt is git-related")
	return reasons

func _build_project_map_reasons_v22(prompt: String, scene_path: String) -> Array:
	var lowered_prompt: String = prompt.to_lower()
	var reasons: Array = []
	if _contains_any_v22(lowered_prompt, ["project", "structure", "folder", "directory", "scene tree", "file map", "architecture"]):
		reasons.append("prompt asks about project structure")
	if not scene_path.is_empty() and (lowered_prompt.contains(scene_path.get_file().to_lower()) or lowered_prompt.contains("scene")):
		reasons.append("scene context is relevant")
	return reasons

func _build_memory_reasons_v22(prompt: String) -> Array:
	var lowered_prompt: String = prompt.to_lower()
	var reasons: Array = []
	if _contains_any_v22(lowered_prompt, ["previous", "before", "remember", "history", "last time"]):
		reasons.append("prompt references prior context")
	return reasons

func _score_relevance_v22(reasons: Array) -> int:
	var score: int = 0
	for reason in reasons:
		match String(reason):
			"active selection":
				score += 30
			"active script":
				score += 18
			"prompt mentions active file":
				score += 28
			"prompt mentions script path":
				score += 32
			"prompt mentions symbol":
				score += 24
			"prompt is git-related":
				score += 32
			"prompt asks about project structure":
				score += 20
			"scene context is relevant":
				score += 16
			"prompt references prior context":
				score += 12
	return score

func _extract_symbol_names_v22(script_text: String) -> Array:
	var names: Array = []
	for raw_line in script_text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("func "):
			var after_keyword: String = line.substr(5).strip_edges()
			var open_paren: int = after_keyword.find("(")
			if open_paren > 0:
				names.append(after_keyword.substr(0, open_paren).strip_edges())
		elif line.begins_with("class_name "):
			names.append(line.substr("class_name ".length()).strip_edges())
	return names

func _contains_any_v22(text: String, patterns: Array) -> bool:
	for pattern in patterns:
		if text.contains(String(pattern)):
			return true
	return false
