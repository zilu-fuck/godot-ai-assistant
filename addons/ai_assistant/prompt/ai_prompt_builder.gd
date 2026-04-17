@tool
extends RefCounted
class_name AIPromptBuilder

const DEFAULT_CONTEXT_WINDOW: int = 65536
const DEFAULT_RESERVED_OUTPUT_TOKENS: int = 8192
const CONTEXT_SELECTION_OVERHEAD_TOKENS: int = 32
const MIN_ITEM_TOKENS: int = 32
const MIN_HIGH_PRIORITY_ITEM_TOKENS: int = 192
const PER_KIND_BUDGET: Dictionary = {
	"selection_text": 0.45,
	"script_text": 0.45,
	"session_memory": 0.20,
	"git_summary": 0.15,
	"project_map": 0.15,
	"dynamic_system_context": 0.08,
}

func build_request(input: Dictionary, normalizer: AIMessageNormalizer) -> Dictionary:
	var model: String = String(input.get("model", "deepseek-chat"))
	var profile: Dictionary = input.get("profile", {})
	var rules: Dictionary = input.get("rules", {})
	var context: Dictionary = input.get("context", {})
	var prompt: String = String(input.get("prompt", "")).strip_edges()
	var history: Array = input.get("history", [])
	var max_history_length: int = int(input.get("max_history_length", 15))

	var normalized_history: Array = normalizer.normalize_history(history, max_history_length)
	var context_items: Array = context.get("context_items", [])
	var budget_plan: Dictionary = _build_budget_plan(profile, rules, normalized_history, prompt)
	var selected_context: Dictionary = _select_context_items(context_items, budget_plan, normalizer)
	var system_sections: Array = _build_system_sections(profile, rules, selected_context.get("system_items", []))
	var runtime_context: String = _build_runtime_context(selected_context.get("runtime_items", []))

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
		"context_budget": selected_context.get("budget", budget_plan),
		"context_manifest": selected_context.get("manifest", []),
		"selected_context_items": selected_context.get("selected_items", []),
		"dropped_context_items": selected_context.get("dropped_items", []),
	}

func _build_system_sections(profile: Dictionary, rules: Dictionary, system_items: Array) -> Array:
	var sections: Array = []
	var rules_text: String = String(rules.get("merged_text", "")).strip_edges()
	if not rules_text.is_empty():
		sections.append(rules_text)

	sections.append("Request mode: %s" % String(profile.get("name", "chat assistant")))

	for item in system_items:
		var rendered_text: String = String(item.get("rendered_text", "")).strip_edges()
		if not rendered_text.is_empty():
			sections.append(rendered_text)

	return sections

func _build_runtime_context(runtime_items: Array) -> String:
	var sections: Array = []
	for item in runtime_items:
		var rendered_text: String = String(item.get("rendered_text", "")).strip_edges()
		if not rendered_text.is_empty():
			sections.append(rendered_text)

	return "\n\n".join(sections).strip_edges()

func _build_budget_plan(profile: Dictionary, rules: Dictionary, normalized_history: Array, prompt: String) -> Dictionary:
	var context_window: int = max(1, int(profile.get("context_window", DEFAULT_CONTEXT_WINDOW)))
	var reserved_output_tokens: int = max(0, int(profile.get("reserved_output_tokens", DEFAULT_RESERVED_OUTPUT_TOKENS)))
	var input_budget_tokens: int = max(1, context_window - reserved_output_tokens)
	var fixed_tokens: int = _estimate_text_tokens(String(rules.get("merged_text", "")))
	fixed_tokens += _estimate_text_tokens(prompt)

	for message in normalized_history:
		if not (message is Dictionary):
			continue
		fixed_tokens += 4 + _estimate_text_tokens(String(message.get("content", "")))

	fixed_tokens += CONTEXT_SELECTION_OVERHEAD_TOKENS
	var available_context_tokens: int = max(0, input_budget_tokens - fixed_tokens)
	var per_kind_budget_tokens: Dictionary = {}

	for kind in PER_KIND_BUDGET.keys():
		per_kind_budget_tokens[kind] = int(floor(float(available_context_tokens) * float(PER_KIND_BUDGET[kind])))

	return {
		"context_window": context_window,
		"reserved_output_tokens": reserved_output_tokens,
		"input_budget_tokens": input_budget_tokens,
		"fixed_tokens": fixed_tokens,
		"available_context_tokens": available_context_tokens,
		"per_kind_budget_tokens": per_kind_budget_tokens,
	}

func _select_context_items(context_items: Array, budget_plan: Dictionary, normalizer: AIMessageNormalizer) -> Dictionary:
	var sorted_items: Array = []
	for raw_item in context_items:
		if raw_item is Dictionary:
			sorted_items.append(raw_item.duplicate(true))

	sorted_items.sort_custom(_sort_context_items)

	var remaining_total: int = int(budget_plan.get("available_context_tokens", 0))
	var per_kind_remaining: Dictionary = budget_plan.get("per_kind_budget_tokens", {}).duplicate(true)
	var selected_items: Array = []
	var dropped_items: Array = []
	var manifest: Array = []
	var system_items: Array = []
	var runtime_items: Array = []

	for item in sorted_items:
		var rendered_text: String = _render_item_text(item)
		var kind: String = String(item.get("kind", "context"))
		var kind_remaining: int = int(per_kind_remaining.get(kind, remaining_total))
		var minimum_budget: int = MIN_HIGH_PRIORITY_ITEM_TOKENS if int(item.get("priority", 0)) >= 90 else MIN_ITEM_TOKENS
		var allowed_tokens: int = min(remaining_total, max(kind_remaining, minimum_budget))

		if remaining_total <= 0 or allowed_tokens <= 0:
			dropped_items.append(_build_manifest_entry(item, false, false, 0, "budget_exhausted"))
			manifest.append(dropped_items.back())
			continue

		var selection: Dictionary = _fit_item_to_budget(item, allowed_tokens, normalizer)
		var selected_text: String = String(selection.get("text", "")).strip_edges()
		if selected_text.is_empty():
			dropped_items.append(_build_manifest_entry(item, false, false, 0, "too_large_for_budget"))
			manifest.append(dropped_items.back())
			continue

		var selected_tokens: int = _estimate_text_tokens(selected_text)
		var selected_item: Dictionary = item.duplicate(true)
		selected_item["rendered_text"] = selected_text
		selected_item["estimated_tokens"] = selected_tokens
		selected_item["truncated"] = bool(selection.get("truncated", false))

		selected_items.append(selected_item)
		if String(selected_item.get("target", "runtime")) == "system":
			system_items.append(selected_item)
		else:
			runtime_items.append(selected_item)

		var entry: Dictionary = _build_manifest_entry(selected_item, true, bool(selection.get("truncated", false)), selected_tokens, "selected")
		manifest.append(entry)
		remaining_total = max(0, remaining_total - selected_tokens)
		per_kind_remaining[kind] = max(0, kind_remaining - selected_tokens)

	for dropped in dropped_items:
		if not manifest.has(dropped):
			manifest.append(dropped)

	return {
		"budget": {
			"context_window": int(budget_plan.get("context_window", 0)),
			"reserved_output_tokens": int(budget_plan.get("reserved_output_tokens", 0)),
			"input_budget_tokens": int(budget_plan.get("input_budget_tokens", 0)),
			"fixed_tokens": int(budget_plan.get("fixed_tokens", 0)),
			"available_context_tokens": int(budget_plan.get("available_context_tokens", 0)),
			"remaining_context_tokens": remaining_total,
			"per_kind_budget_tokens": budget_plan.get("per_kind_budget_tokens", {}).duplicate(true),
		},
		"selected_items": selected_items,
		"dropped_items": dropped_items,
		"manifest": manifest,
		"system_items": system_items,
		"runtime_items": runtime_items,
	}

func _fit_item_to_budget(item: Dictionary, allowed_tokens: int, normalizer: AIMessageNormalizer) -> Dictionary:
	var full_text: String = _render_item_text(item)
	var full_tokens: int = _estimate_text_tokens(full_text)
	if full_tokens <= allowed_tokens:
		return {
			"text": full_text,
			"truncated": false,
		}

	var source_text: String = String(item.get("text", "")).strip_edges()
	if source_text.is_empty() or allowed_tokens < MIN_ITEM_TOKENS:
		return {"text": "", "truncated": true}

	var overhead_text: String = _render_item_text({
		"kind": item.get("kind", ""),
		"title": item.get("title", ""),
		"text": "",
	})
	var overhead_tokens: int = _estimate_text_tokens(overhead_text)
	var target_tokens: int = max(8, allowed_tokens - overhead_tokens)
	var target_chars: int = max(48, target_tokens * 4)
	var truncated_text: String = source_text
	var rendered_text: String = full_text

	while target_chars >= 48:
		truncated_text = normalizer.clamp_context_text(source_text, target_chars)
		rendered_text = _render_item_text({
			"kind": item.get("kind", ""),
			"title": item.get("title", ""),
			"text": truncated_text,
		})
		if _estimate_text_tokens(rendered_text) <= allowed_tokens:
			return {
				"text": rendered_text,
				"truncated": true,
			}
		target_chars = int(floor(float(target_chars) * 0.7))

	return {"text": "", "truncated": true}

func _render_item_text(item: Dictionary) -> String:
	var kind: String = String(item.get("kind", "context"))
	var title: String = String(item.get("title", "Context"))
	var text: String = String(item.get("text", "")).strip_edges()
	if text.is_empty():
		return ""

	match kind:
		"selection_text", "script_text":
			return "[Runtime Context]\n%s\n```gdscript\n%s\n```" % [title, text]
		"session_memory":
			return "[Session Memory]\n%s" % text
		"git_summary":
			return "[Git Summary]\n%s" % text
		"project_map":
			return "[Project Map]\n%s" % text
		"dynamic_system_context":
			return "[Dynamic System Context]\n%s" % text
		_:
			return "[%s]\n%s" % [title, text]

func _build_manifest_entry(item: Dictionary, selected: bool, truncated: bool, estimated_tokens: int, reason: String) -> Dictionary:
	var text: String = String(item.get("rendered_text", item.get("text", ""))).strip_edges()
	return {
		"kind": String(item.get("kind", "context")),
		"source": String(item.get("source", "")),
		"target": String(item.get("target", "runtime")),
		"title": String(item.get("title", "")),
		"priority": int(item.get("priority", 0)),
		"selected": selected,
		"truncated": truncated,
		"estimated_tokens": estimated_tokens,
		"chars": text.length(),
		"reason": reason,
		"relevance_reasons": item.get("relevance_reasons", []),
	}

func _estimate_text_tokens(text: String) -> int:
	var cleaned: String = text.strip_edges()
	if cleaned.is_empty():
		return 0

	var ascii_letters: int = 0
	var digits: int = 0
	var whitespace: int = 0
	var punctuation: int = 0
	var non_ascii: int = 0

	for index in range(cleaned.length()):
		var code: int = cleaned.unicode_at(index)
		if code <= 0x7F:
			if _is_ascii_letter(code):
				ascii_letters += 1
			elif _is_ascii_digit(code):
				digits += 1
			elif _is_ascii_whitespace(code):
				whitespace += 1
			else:
				punctuation += 1
		else:
			non_ascii += 1

	var estimate: float = 0.0
	estimate += float(ascii_letters) / 4.0
	estimate += float(digits) / 3.0
	estimate += float(punctuation) / 2.0
	estimate += float(whitespace) / 8.0
	estimate += float(non_ascii) * 0.9

	return max(1, int(ceil(estimate)))

func _is_ascii_letter(code: int) -> bool:
	return (code >= 65 and code <= 90) or (code >= 97 and code <= 122)

func _is_ascii_digit(code: int) -> bool:
	return code >= 48 and code <= 57

func _is_ascii_whitespace(code: int) -> bool:
	return code == 9 or code == 10 or code == 13 or code == 32

func _sort_context_items(a: Dictionary, b: Dictionary) -> bool:
	var priority_a: int = int(a.get("priority", 0))
	var priority_b: int = int(b.get("priority", 0))
	if priority_a == priority_b:
		return String(a.get("kind", "")) < String(b.get("kind", ""))
	return priority_a > priority_b
