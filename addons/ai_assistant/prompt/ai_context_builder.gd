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
