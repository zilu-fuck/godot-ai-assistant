@tool
extends RefCounted
class_name AIProjectIndexer

const INCLUDED_EXTENSIONS: Array = [".gd", ".tscn", ".gdshader"]
const EXCLUDED_DIRS: Array = [".godot", ".import"]
const MAX_SUMMARY_FILES: int = 8

var _cache_summary: Dictionary = {}
var _cache_timestamp: int = 0

func build_project_summary(recent_files: Array = []) -> Dictionary:
	var now: int = Time.get_ticks_msec()
	if now - _cache_timestamp < 5000 and not _cache_summary.is_empty():
		return _merge_recent_files(_cache_summary.duplicate(true), recent_files)

	var files: Array = []
	_scan_dir("res://", files)

	var summary: Dictionary = {
		"total_files": files.size(),
		"files": files,
		"map_text": _build_map_text(files, recent_files),
	}

	_cache_summary = summary.duplicate(true)
	_cache_timestamp = now
	return _merge_recent_files(summary, recent_files)

func _scan_dir(path: String, files: Array) -> void:
	var dir: DirAccess = DirAccess.open(path)
	if dir == null:
		return

	dir.list_dir_begin()
	while true:
		var name: String = dir.get_next()
		if name == "":
			break
		if name == "." or name == "..":
			continue

		var child_path: String = path.path_join(name)
		if dir.current_is_dir():
			if EXCLUDED_DIRS.has(name):
				continue
			_scan_dir(child_path, files)
		else:
			for extension in INCLUDED_EXTENSIONS:
				if name.ends_with(extension):
					files.append(child_path)
					break
	dir.list_dir_end()

func _build_map_text(files: Array, recent_files: Array) -> String:
	var lines: Array = []
	lines.append("Indexed files: %d" % files.size())

	var script_files: Array = []
	var scene_files: Array = []
	var shader_files: Array = []
	for file_path in files:
		var path_str: String = str(file_path)
		if path_str.ends_with(".gd"):
			script_files.append(path_str)
		elif path_str.ends_with(".tscn"):
			scene_files.append(path_str)
		elif path_str.ends_with(".gdshader"):
			shader_files.append(path_str)

	lines.append("Scripts: %d, Scenes: %d, Shaders: %d" % [script_files.size(), scene_files.size(), shader_files.size()])

	var relevant_files: Array = _pick_relevant_files(files, recent_files)
	if not relevant_files.is_empty():
		lines.append("Relevant files:")
		for file_path in relevant_files:
			lines.append("- %s" % str(file_path))

	return "\n".join(lines)

func _pick_relevant_files(files: Array, recent_files: Array) -> Array:
	var picked: Array = []
	for file_path in recent_files:
		if files.has(file_path):
			picked.append(file_path)
			if picked.size() >= MAX_SUMMARY_FILES:
				return picked

	for file_path in files:
		if picked.has(file_path):
			continue
		picked.append(file_path)
		if picked.size() >= MAX_SUMMARY_FILES:
			return picked

	return picked

func _merge_recent_files(summary: Dictionary, recent_files: Array) -> Dictionary:
	summary["recent_files"] = recent_files.duplicate()
	return summary

func extract_file_mentions(content: String, role: String = "user") -> Array:
	var regex: RegEx = RegEx.new()
	var error_code: int = regex.compile("([A-Za-z0-9_./\\\\-]+\\.(?:gd|tscn|gdshader))")
	if error_code != OK:
		return []

	var mentions: Array = []
	var seen: Dictionary = {}
	for result in regex.search_all(content):
		var mention: String = result.get_string(1).replace("\\", "/")
		if seen.has(mention):
			continue
		seen[mention] = true
		mentions.append({
			"mention": mention,
			"role": role,
		})
	return mentions

func extract_latest_file_mentions(history: Array, preferred_role: String = "user") -> Array:
	for index in range(history.size() - 1, -1, -1):
		var message = history[index]
		if not (message is Dictionary):
			continue
		if str(message.get("role", "")).strip_edges() != preferred_role:
			continue

		var mentions: Array = extract_file_mentions(str(message.get("content", "")), preferred_role)
		if not mentions.is_empty():
			return mentions
	return []

func match_project_file_path(mention: String, files: Array) -> String:
	var normalized: String = mention.replace("\\", "/").strip_edges()
	if normalized.is_empty():
		return ""

	for file_path in files:
		var candidate: String = str(file_path)
		if candidate == normalized:
			return candidate
		if normalized.begins_with("res://") and candidate == normalized.simplify_path():
			return candidate
		if candidate.ends_with("/" + normalized):
			return candidate

	var basename: String = normalized.get_file()
	if basename.is_empty():
		return ""

	var matches: Array = []
	for file_path in files:
		var candidate: String = str(file_path)
		if candidate.get_file() == basename:
			matches.append(candidate)

	if matches.size() == 1:
		return matches[0]
	return ""

func resolve_project_path_hint(mention: String, preferred_dir: String = "res://") -> String:
	var normalized: String = mention.replace("\\", "/").strip_edges()
	if normalized.is_empty():
		return ""
	if normalized.begins_with("res://"):
		return normalized.simplify_path()

	if normalized.begins_with("./"):
		normalized = normalized.substr(2)
	while normalized.begins_with("/"):
		normalized = normalized.substr(1)
	if normalized.is_empty():
		return ""

	var base_dir: String = preferred_dir.strip_edges()
	if base_dir.is_empty():
		base_dir = "res://"

	if normalized.contains("/"):
		return ("res://" + normalized).simplify_path()
	return base_dir.path_join(normalized).simplify_path()
