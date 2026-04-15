@tool
extends RefCounted
class_name AIGitContext

const MAX_STATUS_LINES: int = 8
const CACHE_TTL_MS: int = 5000

var _cache_summary: Dictionary = {}
var _cache_timestamp: int = 0

func build_git_summary() -> Dictionary:
	var now: int = Time.get_ticks_msec()
	if now - _cache_timestamp < CACHE_TTL_MS and not _cache_summary.is_empty():
		return _cache_summary.duplicate(true)

	var project_path: String = ProjectSettings.globalize_path("res://")
	var branch_output: Array = []
	var branch_exit: int = OS.execute("git", ["-C", project_path, "rev-parse", "--abbrev-ref", "HEAD"], branch_output, true)
	if branch_exit != OK:
		_cache_summary = {
			"available": false,
			"summary_text": "",
		}
		_cache_timestamp = now
		return _cache_summary.duplicate(true)

	var status_output: Array = []
	OS.execute("git", ["-C", project_path, "status", "--short"], status_output, true)

	var branch: String = ""
	if not branch_output.is_empty():
		branch = String(branch_output[0]).strip_edges()

	var changed_lines: Array = []
	for line in status_output:
		var line_text: String = String(line).strip_edges()
		if line_text.is_empty():
			continue
		changed_lines.append(line_text)
		if changed_lines.size() >= MAX_STATUS_LINES:
			break

	var summary_lines: Array = []
	if not branch.is_empty():
		summary_lines.append("Git branch: %s" % branch)
	if changed_lines.is_empty():
		summary_lines.append("Working tree: clean")
	else:
		summary_lines.append("Working tree changes:")
		for line in changed_lines:
			summary_lines.append("- %s" % line)

	_cache_summary = {
		"available": true,
		"branch": branch,
		"changes": changed_lines,
		"summary_text": "\n".join(summary_lines).strip_edges(),
	}
	_cache_timestamp = now
	return _cache_summary.duplicate(true)
