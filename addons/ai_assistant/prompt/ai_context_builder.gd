@tool
extends RefCounted
class_name AIContextBuilder

var _project_indexer: AIProjectIndexer = AIProjectIndexer.new()
var _git_context: AIGitContext = AIGitContext.new()

func build_runtime_context(memory: Dictionary = {}) -> Dictionary:
	var script_context: Dictionary = get_script_context()
	var recent_files: Array = []
	if memory.has("recent_files") and memory["recent_files"] is Array:
		recent_files = memory["recent_files"]

	var project_summary: Dictionary = _project_indexer.build_project_summary(recent_files)
	var git_summary: Dictionary = _git_context.build_git_summary()

	return {
		"current_date": "%s %s" % [Time.get_date_string_from_system(), Time.get_time_string_from_system()],
		"script_path": get_current_script_path(),
		"scene_path": get_current_scene_path(),
		"is_selected": script_context.get("is_selected", false),
		"script_text": script_context.get("text", ""),
		"project_summary": project_summary,
		"project_map_text": String(project_summary.get("map_text", "")),
		"git_summary": git_summary,
		"git_text": String(git_summary.get("summary_text", "")),
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
