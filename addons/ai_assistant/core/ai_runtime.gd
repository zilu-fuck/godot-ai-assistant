@tool
extends RefCounted
class_name AIRuntime

const DEFAULT_MAX_OUTPUT_TOKENS: int = 8192
const CONTEXT_WATCH_THRESHOLD: float = 0.6
const CONTEXT_COMPRESS_THRESHOLD: float = 0.8
const CONTEXT_LIMIT_THRESHOLD: float = 0.95

var _net_client: AINetClient
var _max_history_length: int = 15

var _prompt_builder: AIPromptBuilder = AIPromptBuilder.new()
var _context_builder: AIContextBuilder = AIContextBuilder.new()
var _message_normalizer: AIMessageNormalizer = AIMessageNormalizer.new()
var _rules_loader: AIRulesLoader = AIRulesLoader.new()
var _memory_manager: AIMemoryManager = AIMemoryManager.new()
var _provider_adapter: AIProviderAdapter = AIProviderAdapter.new()
var _provider_profiles: AIProviderProfiles = AIProviderProfiles.new()

var last_request_preview: Dictionary = {}

func setup(net_client: AINetClient, max_history_length: int) -> void:
	_net_client = net_client
	_max_history_length = max_history_length

func start_chat_request(prompt: String, session: Dictionary, api_settings: Dictionary) -> Dictionary:
	_memory_manager.ensure_session_shape(session)

	var cleaned_prompt: String = prompt.strip_edges()
	if cleaned_prompt.is_empty():
		return {"ok": false, "reason": "empty_prompt"}
	if String(api_settings.get("key", "")).is_empty():
		return {"ok": false, "reason": "missing_api_key"}
	if _net_client == null:
		return {"ok": false, "reason": "missing_net_client"}
	if not session.has("history"):
		return {"ok": false, "reason": "missing_session"}

	var model: String = String(api_settings.get("model", "deepseek-chat"))
	var profile: Dictionary = _provider_profiles.resolve_profile(model, String(api_settings.get("url", "")))
	var context: Dictionary = _context_builder.build_runtime_context(session.get("memory", {}))
	_memory_manager.register_context(session, context)
	var auto_compact: Dictionary = _memory_manager.maybe_auto_compact(session)
	var rules: Dictionary = _rules_loader.load_rules(String(context.get("script_path", "")))
	var request: Dictionary = _prompt_builder.build_request({
		"prompt": cleaned_prompt,
		"history": session.get("history", []),
		"model": model,
		"profile": profile,
		"rules": rules,
		"context": context,
		"memory": session.get("memory", {}),
		"max_history_length": _max_history_length,
	}, _message_normalizer)
	var provider_request: Dictionary = _provider_adapter.build_request({
		"model": model,
		"messages": request["messages"],
		"temperature": float(profile.get("temperature", 0.7)),
		"stream": true,
		"max_tokens": DEFAULT_MAX_OUTPUT_TOKENS,
		"profile": profile,
	})
	var usage: Dictionary = _build_usage_summary({
		"prompt": cleaned_prompt,
		"profile": profile,
		"rules": rules,
		"memory": session.get("memory", {}),
		"context": context,
		"request": request,
		"payload": provider_request["payload"],
	})

	session["history"].append({"role": "user", "content": cleaned_prompt})
	last_request_preview = {
		"prompt": cleaned_prompt,
		"model": model,
		"profile": profile,
		"rules": rules,
		"memory": session.get("memory", {}),
		"context": context,
		"request": request,
		"payload": provider_request["payload"],
		"usage": usage,
		"auto_compact": auto_compact,
	}

	_net_client.start_stream(
		String(api_settings.get("url", "")),
		String(api_settings.get("key", "")),
		String(provider_request.get("body", ""))
	)

	return {
		"ok": true,
		"debug_label": _build_debug_label(last_request_preview),
		"auto_compacted": bool(auto_compact.get("performed", false)),
		"memory_summary": String(auto_compact.get("summary_text", "")),
		"usage": usage,
	}

func get_script_context() -> Dictionary:
	return _context_builder.get_script_context()

func get_last_request_preview() -> Dictionary:
	return last_request_preview.duplicate(true)

func preview_chat_request(prompt: String, session: Dictionary, api_settings: Dictionary) -> Dictionary:
	_memory_manager.ensure_session_shape(session)

	if not session.has("history"):
		return {"ok": false, "reason": "missing_session"}

	var cleaned_prompt: String = prompt.strip_edges()
	var model: String = String(api_settings.get("model", "deepseek-chat"))
	var profile: Dictionary = _provider_profiles.resolve_profile(model, String(api_settings.get("url", "")))
	var context: Dictionary = _context_builder.build_runtime_context(session.get("memory", {}))
	var rules: Dictionary = _rules_loader.load_rules(String(context.get("script_path", "")))
	var request: Dictionary = _prompt_builder.build_request({
		"prompt": cleaned_prompt,
		"history": session.get("history", []),
		"model": model,
		"profile": profile,
		"rules": rules,
		"context": context,
		"memory": session.get("memory", {}),
		"max_history_length": _max_history_length,
	}, _message_normalizer)
	var provider_request: Dictionary = _provider_adapter.build_request({
		"model": model,
		"messages": request["messages"],
		"temperature": float(profile.get("temperature", 0.7)),
		"stream": true,
		"max_tokens": DEFAULT_MAX_OUTPUT_TOKENS,
		"profile": profile,
	})
	var preview: Dictionary = {
		"prompt": cleaned_prompt,
		"model": model,
		"profile": profile,
		"rules": rules,
		"memory": session.get("memory", {}),
		"context": context,
		"request": request,
		"payload": provider_request["payload"],
	}

	return {
		"ok": true,
		"usage": _build_usage_summary(preview),
		"debug_label": _build_debug_label(preview),
	}

func compact_session(session: Dictionary, mode: String = "manual") -> Dictionary:
	_memory_manager.ensure_session_shape(session)
	var context: Dictionary = _context_builder.build_runtime_context(session.get("memory", {}))
	_memory_manager.register_context(session, context)
	return _memory_manager.compact_session(session, mode)

func record_assistant_response(session: Dictionary, content: String) -> void:
	_memory_manager.register_assistant_response(session, content)

func _build_debug_label(preview: Dictionary) -> String:
	var rules: Dictionary = preview.get("rules", {})
	var context: Dictionary = preview.get("context", {})
	var payload: Dictionary = preview.get("payload", {})
	var profile: Dictionary = preview.get("profile", {})
	var loaded_sources: Array = []

	for source in rules.get("sources", []):
		if bool(source.get("exists", false)):
			loaded_sources.append(String(source.get("path", "")))

	var lines: Array = []
	lines.append("Provider: %s" % String(profile.get("provider", "unknown")))
	if not loaded_sources.is_empty():
		lines.append("Rules: %s" % ", ".join(loaded_sources))
	else:
		lines.append("Rules: builtin only")

	if not String(context.get("script_path", "")).is_empty():
		var context_label: String = "current script"
		if bool(context.get("is_selected", false)):
			context_label = "selected code"
		lines.append("Context: %s (%s)" % [String(context.get("script_path", "")), context_label])
	elif not String(context.get("scene_path", "")).is_empty():
		lines.append("Context: %s" % String(context.get("scene_path", "")))
	else:
		lines.append("Context: none")

	var message_count: int = 0
	var payload_messages = payload.get("messages", [])
	if payload_messages is Array:
		message_count = payload_messages.size()
	lines.append("Messages: %d" % message_count)

	var load_errors: Array = rules.get("load_errors", [])
	if not load_errors.is_empty():
		lines.append("Rules Error: %s" % " | ".join(load_errors))

	var memory: Dictionary = preview.get("memory", {})
	var compacted_at: String = String(memory.get("last_compacted_at", ""))
	if not compacted_at.is_empty():
		lines.append("Memory: compacted at %s" % compacted_at)

	return "[color=#7f848e][i]%s[/i][/color]" % "  |  ".join(lines)

func _build_usage_summary(preview: Dictionary) -> Dictionary:
	var payload: Dictionary = preview.get("payload", {})
	var profile: Dictionary = preview.get("profile", {})
	var rules: Dictionary = preview.get("rules", {})
	var context: Dictionary = preview.get("context", {})
	var memory: Dictionary = preview.get("memory", {})
	var request: Dictionary = preview.get("request", {})
	var messages: Array = payload.get("messages", [])
	var reserved_output_tokens: int = max(0, int(payload.get("max_tokens", int(profile.get("reserved_output_tokens", DEFAULT_MAX_OUTPUT_TOKENS)))))
	var context_window: int = max(1, int(profile.get("context_window", 65536)))
	var input_budget_tokens: int = max(1, context_window - reserved_output_tokens)

	var total_chars: int = 0
	var estimated_input_tokens: int = 0
	for message in messages:
		if not (message is Dictionary):
			continue

		var content: String = String(message.get("content", ""))
		total_chars += content.length()
		estimated_input_tokens += _estimate_message_tokens(message)

	estimated_input_tokens += 2

	var usage_ratio: float = float(estimated_input_tokens) / float(input_budget_tokens)
	var available_tokens: int = max(0, input_budget_tokens - estimated_input_tokens)
	var risk_level: String = "healthy"
	var status_label: String = "上下文健康"
	var should_compact: bool = false
	if estimated_input_tokens > input_budget_tokens:
		risk_level = "limit"
		status_label = "已超过输入预算"
		should_compact = true
	elif usage_ratio >= CONTEXT_LIMIT_THRESHOLD:
		risk_level = "limit"
		status_label = "接近上下文极限"
		should_compact = true
	elif usage_ratio >= CONTEXT_COMPRESS_THRESHOLD:
		risk_level = "compress"
		status_label = "建议立即压缩"
		should_compact = true
	elif usage_ratio >= CONTEXT_WATCH_THRESHOLD:
		risk_level = "watch"
		status_label = "上下文正在增长"

	var sources: Array = _build_usage_sources(rules, context, memory, request, profile, String(preview.get("prompt", "")))

	return {
		"estimated_input_tokens": estimated_input_tokens,
		"estimated_output_tokens": reserved_output_tokens,
		"context_window": context_window,
		"input_budget_tokens": input_budget_tokens,
		"available_tokens": available_tokens,
		"message_count": messages.size(),
		"char_count": total_chars,
		"ratio": usage_ratio,
		"risk_level": risk_level,
		"status_label": status_label,
		"should_compact": should_compact,
		"over_budget": estimated_input_tokens > input_budget_tokens,
		"sources": sources,
	}

func _build_usage_sources(rules: Dictionary, context: Dictionary, memory: Dictionary, request: Dictionary, profile: Dictionary, prompt: String) -> Array:
	var sources: Array = []
	var rules_text: String = String(rules.get("merged_text", "")).strip_edges()
	var dynamic_lines: Array = ["请求模式：%s" % String(profile.get("name", "聊天助手"))]
	if not String(context.get("current_date", "")).is_empty():
		dynamic_lines.append("当前时间：%s" % String(context.get("current_date", "")))
	if not String(context.get("scene_path", "")).is_empty():
		dynamic_lines.append("当前场景：%s" % String(context.get("scene_path", "")))
	if not String(context.get("script_path", "")).is_empty():
		dynamic_lines.append("当前脚本：%s" % String(context.get("script_path", "")))

	_push_usage_source(sources, "规则", rules_text)
	_push_usage_source(sources, "动态上下文", "\n".join(dynamic_lines))
	_push_usage_source(sources, "仓库快照", String(context.get("git_text", "")).strip_edges())
	_push_usage_source(sources, "项目地图", String(context.get("project_map_text", "")).strip_edges())

	var runtime_context_lines: Array = []
	var script_text: String = _message_normalizer.clamp_context_text(String(context.get("script_text", "")))
	if not script_text.is_empty():
		var title: String = "当前脚本"
		if bool(context.get("is_selected", false)):
			title = "选中代码"
		runtime_context_lines.append("%s\n```gdscript\n%s\n```" % [title, script_text])
	_push_usage_source(sources, "脚本上下文", "\n\n".join(runtime_context_lines))
	_push_usage_source(sources, "会话记忆", String(memory.get("summary_text", "")).strip_edges())

	var history_text: String = ""
	for message in request.get("normalized_history", []):
		if not (message is Dictionary):
			continue
		if not history_text.is_empty():
			history_text += "\n\n"
		history_text += "[%s]\n%s" % [String(message.get("role", "user")), String(message.get("content", ""))]
	_push_usage_source(sources, "聊天历史", history_text)
	_push_usage_source(sources, "当前输入", prompt.strip_edges())

	sources.sort_custom(_sort_usage_source_desc)
	return sources

func _push_usage_source(sources: Array, name: String, text: String) -> void:
	var cleaned: String = text.strip_edges()
	if cleaned.is_empty():
		return

	sources.append({
		"name": name,
		"chars": cleaned.length(),
		"tokens": _estimate_text_tokens(cleaned),
	})

func _estimate_message_tokens(message: Dictionary) -> int:
	return 4 + _estimate_text_tokens(String(message.get("content", "")))

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

func _sort_usage_source_desc(a: Dictionary, b: Dictionary) -> bool:
	return int(a.get("tokens", 0)) > int(b.get("tokens", 0))
