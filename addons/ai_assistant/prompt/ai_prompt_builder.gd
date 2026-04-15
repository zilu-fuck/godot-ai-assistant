@tool
extends RefCounted
class_name AIPromptBuilder

func build_request(input: Dictionary, normalizer: AIMessageNormalizer) -> Dictionary:
	var model: String = String(input.get("model", "deepseek-chat"))
	var profile: Dictionary = input.get("profile", {})
	var rules: Dictionary = input.get("rules", {})
	var context: Dictionary = input.get("context", {})
	var memory: Dictionary = input.get("memory", {})
	var prompt: String = String(input.get("prompt", "")).strip_edges()
	var history: Array = input.get("history", [])
	var max_history_length: int = int(input.get("max_history_length", 15))

	var normalized_history: Array = normalizer.normalize_history(history, max_history_length)
	var system_sections: Array = _build_system_sections(profile, rules, context)
	var runtime_context: String = _build_runtime_context(context, memory, normalizer)

	var messages: Array = []
	if bool(profile.get("use_system_role", true)):
		if not system_sections.is_empty():
			messages.append({"role": "system", "content": "\n\n".join(system_sections)})
	else:
		if not system_sections.is_empty():
			messages.append({
				"role": "user",
				"content": "[System Instructions]\n" + "\n\n".join(system_sections),
			})

	if not runtime_context.is_empty():
		messages.append({"role": "user", "content": runtime_context})

	for message in normalized_history:
		messages.append(message.duplicate())

	if not prompt.is_empty():
		messages.append({"role": "user", "content": prompt})

	return {
		"model": model,
		"messages": messages,
		"system_sections": system_sections,
		"runtime_context": runtime_context,
		"normalized_history": normalized_history,
	}

func _build_system_sections(profile: Dictionary, rules: Dictionary, context: Dictionary) -> Array:
	var sections: Array = []
	var rules_text: String = String(rules.get("merged_text", "")).strip_edges()
	if not rules_text.is_empty():
		sections.append(rules_text)

	var dynamic_lines: Array = []
	dynamic_lines.append("Request mode: %s" % String(profile.get("name", "chat assistant")))
	if not String(context.get("current_date", "")).is_empty():
		dynamic_lines.append("Current time: %s" % String(context.get("current_date", "")))
	if not String(context.get("scene_path", "")).is_empty():
		dynamic_lines.append("Current scene: %s" % String(context.get("scene_path", "")))
	if not String(context.get("script_path", "")).is_empty():
		dynamic_lines.append("Current script: %s" % String(context.get("script_path", "")))

	if not dynamic_lines.is_empty():
		sections.append("\n".join(dynamic_lines))

	var system_context_lines: Array = []
	var git_text: String = String(context.get("git_text", "")).strip_edges()
	if not git_text.is_empty():
		system_context_lines.append(git_text)
	var project_map_text: String = String(context.get("project_map_text", "")).strip_edges()
	if not project_map_text.is_empty():
		system_context_lines.append(project_map_text)
	if not system_context_lines.is_empty():
		sections.append("\n\n".join(system_context_lines))

	return sections

func _build_runtime_context(context: Dictionary, memory: Dictionary, normalizer: AIMessageNormalizer) -> String:
	var sections: Array = []

	var script_text: String = normalizer.clamp_context_text(String(context.get("script_text", "")))
	if not script_text.is_empty():
		var title: String = "Current script"
		if bool(context.get("is_selected", false)):
			title = "Selected code"
		sections.append("[Runtime Context]\n%s\n```gdscript\n%s\n```" % [title, script_text])

	var memory_text: String = String(memory.get("summary_text", "")).strip_edges()
	if not memory_text.is_empty():
		sections.append("[Session Memory]\n%s" % memory_text)

	return "\n\n".join(sections).strip_edges()
