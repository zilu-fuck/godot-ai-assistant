@tool
extends RefCounted
class_name AIRulesLoader

const USER_RULES_PATH: String = "user://ai_assistant_rules.md"
const PROJECT_RULES_PATH: String = "res://AI_ASSISTANT.md"
const LOCAL_RULES_FILE: String = "AI_ASSISTANT.local.md"
const BUILTIN_RULES_PATH: String = "builtin://default"
const BUILTIN_RULES: String = """You are an AI coding assistant embedded in the Godot 4 editor.
- Prefer solutions that fit Godot 4.
- Use ```gdscript``` fenced blocks when returning code.
- When suggesting edits, explain the scope and likely impact.
- Avoid hardcoded paths when scene, resource, or node-driven approaches fit better.
- Stay focused on the current request and avoid adding unnecessary abstractions."""

func load_rules(current_script_path: String = "") -> Dictionary:
	var result: Dictionary = {
		"merged_text": "",
		"sources": [],
		"load_errors": [],
		"include_graph": {},
		"priority_order": [],
	}

	var visited: Dictionary = {}
	var merged_sections: Array = []
	var entries: Array = [
		{"kind": "builtin", "label": "builtin", "path": BUILTIN_RULES_PATH},
		{"kind": "file", "label": "user", "path": USER_RULES_PATH, "optional": true},
		{"kind": "file", "label": "project", "path": PROJECT_RULES_PATH, "optional": true},
	]

	for local_path in _collect_local_rule_paths(current_script_path):
		entries.append({"kind": "file", "label": "local", "path": local_path, "optional": true})

	for entry in entries:
		result["priority_order"].append(entry["path"])
		var section: String = ""
		if entry["kind"] == "builtin":
			result["sources"].append({
				"label": entry["label"],
				"path": entry["path"],
				"exists": true,
			})
			section = _expand_content(BUILTIN_RULES, BUILTIN_RULES_PATH, entry["label"], result, visited, [])
		else:
			section = _load_file_rules(entry["path"], entry["label"], bool(entry.get("optional", false)), result, visited, [])

		if not section.is_empty():
			merged_sections.append(section)

	result["merged_text"] = "\n\n".join(merged_sections).strip_edges()
	return result

func _load_file_rules(path: String, label: String, optional: bool, result: Dictionary, visited: Dictionary, stack: Array) -> String:
	if not FileAccess.file_exists(path):
		result["sources"].append({
			"label": label,
			"path": path,
			"exists": false,
		})
		if not optional:
			result["load_errors"].append("Missing rules file: %s" % path)
		return ""

	if visited.has(path):
		return ""
	visited[path] = true

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		result["sources"].append({
			"label": label,
			"path": path,
			"exists": true,
		})
		result["load_errors"].append("Failed to open rules file: %s" % path)
		return ""

	result["sources"].append({
		"label": label,
		"path": path,
		"exists": true,
	})

	return _expand_content(file.get_as_text(), path, label, result, visited, stack)

func _expand_content(content: String, source_path: String, label: String, result: Dictionary, visited: Dictionary, stack: Array) -> String:
	if stack.has(source_path):
		result["load_errors"].append("Circular @include detected: %s" % " -> ".join(stack + [source_path]))
		return ""

	var next_stack: Array = stack.duplicate()
	next_stack.append(source_path)

	var expanded_lines: Array = []
	var include_targets: Array = []
	for raw_line in content.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.begins_with("@include "):
			var include_path: String = line.substr(9).strip_edges()
			var resolved_path: String = _resolve_include_path(include_path, source_path)
			include_targets.append(resolved_path)
			var included_text: String = _load_included_rules(resolved_path, label, result, visited, next_stack)
			if not included_text.is_empty():
				expanded_lines.append(included_text)
		else:
			expanded_lines.append(raw_line)

	result["include_graph"][source_path] = include_targets
	return "\n".join(expanded_lines).strip_edges()

func _load_included_rules(path: String, label: String, result: Dictionary, visited: Dictionary, stack: Array) -> String:
	if stack.has(path):
		result["load_errors"].append("Circular @include detected: %s" % " -> ".join(stack + [path]))
		return ""

	if not FileAccess.file_exists(path):
		result["load_errors"].append("Missing included rules file: %s" % path)
		return ""

	if visited.has(path):
		return ""
	visited[path] = true

	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		result["load_errors"].append("Failed to open included rules file: %s" % path)
		return ""

	result["sources"].append({
		"label": "%s@include" % label,
		"path": path,
		"exists": true,
	})

	return _expand_content(file.get_as_text(), path, label, result, visited, stack)

func _resolve_include_path(include_path: String, source_path: String) -> String:
	if include_path.begins_with("res://") or include_path.begins_with("user://"):
		return include_path.simplify_path()

	var source_dir: String = source_path.get_base_dir()
	if source_dir.begins_with("res://") or source_dir.begins_with("user://"):
		return source_dir.path_join(include_path).simplify_path()

	return include_path

func _collect_local_rule_paths(current_script_path: String) -> Array:
	if current_script_path.is_empty():
		return []

	var collected: Array = []
	var current_dir: String = current_script_path.get_base_dir()

	while not current_dir.is_empty():
		var candidate: String = current_dir.path_join(LOCAL_RULES_FILE)
		if FileAccess.file_exists(candidate):
			collected.append(candidate)

		if current_dir == "res://" or current_dir.get_base_dir() == current_dir:
			break
		current_dir = current_dir.get_base_dir()

	collected.reverse()
	return collected
