@tool
extends RefCounted
class_name AIRuntime

const DEFAULT_MAX_OUTPUT_TOKENS: int = 8192
const CONTEXT_WATCH_THRESHOLD: float = 0.6
const CONTEXT_COMPRESS_THRESHOLD: float = 0.8
const CONTEXT_LIMIT_THRESHOLD: float = 0.95
const STATE_IDLE: String = "idle"
const STATE_PREPARING: String = "preparing"
const STATE_STREAMING: String = "streaming"
const STATE_AWAITING_ACTION_CONFIRMATION: String = "awaiting_action_confirmation"
const STATE_COMPLETED: String = "completed"
const STATE_FAILED: String = "failed"
const STATE_STOPPED: String = "stopped"

var _net_client: AINetClient
var _max_history_length: int = 15

var _prompt_builder: AIPromptBuilder = AIPromptBuilder.new()
var _context_builder: AIContextBuilder = AIContextBuilder.new()
var _message_normalizer: AIMessageNormalizer = AIMessageNormalizer.new()
var _rules_loader: AIRulesLoader = AIRulesLoader.new()
var _memory_manager: AIMemoryManager = AIMemoryManager.new()
var _provider_adapter: AIProviderAdapter = AIProviderAdapter.new()
var _provider_profiles: AIProviderProfiles = AIProviderProfiles.new()
var _action_executor: AIActionExecutor
var _project_indexer: AIProjectIndexer

var last_request_preview: Dictionary = {}
var runtime_state: String = STATE_IDLE
var pending_action: Dictionary = {}
var last_response_actions: Array = []

func setup(net_client: AINetClient, max_history_length: int, action_executor: AIActionExecutor = null, project_indexer: AIProjectIndexer = null) -> void:
	_net_client = net_client
	_max_history_length = max_history_length
	_action_executor = action_executor
	_project_indexer = project_indexer

func start_chat_request(prompt: String, session: Dictionary, api_settings: Dictionary) -> Dictionary:
	_memory_manager.ensure_session_shape(session)
	last_response_actions.clear()

	var cleaned_prompt: String = prompt.strip_edges()
	if cleaned_prompt.is_empty():
		return {"ok": false, "reason": "empty_prompt", "message": "Enter a prompt before sending the request."}
	if String(api_settings.get("key", "")).is_empty():
		return {"ok": false, "reason": "missing_api_key", "message": "Add an API key in Settings before sending a request."}
	if _net_client == null:
		return {"ok": false, "reason": "missing_net_client", "message": "The network client is not initialized. Reload the plugin and try again."}
	if not session.has("history"):
		return {"ok": false, "reason": "missing_session", "message": "The current session is unavailable. Create or reopen a session and try again."}

	set_state(STATE_PREPARING)
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
		"provider_capabilities": _extract_provider_capabilities(profile),
		"rules": rules,
		"memory": session.get("memory", {}),
		"context": context,
		"request": request,
		"context_manifest": request.get("context_manifest", []),
		"dropped_context_items": request.get("dropped_context_items", []),
		"payload": provider_request["payload"],
		"usage": usage,
		"auto_compact": auto_compact,
	}

	var start_result: Dictionary = _net_client.start_stream(
		String(api_settings.get("url", "")),
		String(api_settings.get("key", "")),
		String(provider_request.get("body", ""))
	)
	if not bool(start_result.get("ok", false)):
		set_state(STATE_FAILED)
		last_request_preview["runtime_state"] = runtime_state
		last_request_preview["start_error"] = String(start_result.get("message", "Failed to start the model request."))
		return {
			"ok": false,
			"reason": "start_stream_failed",
			"message": String(start_result.get("message", "Failed to start the model request.")),
			"debug_label": _build_debug_label(last_request_preview),
			"preview_bbcode": build_request_preview_bbcode(last_request_preview),
			"request_preview": get_last_request_preview(),
		}

	begin_streaming()
	last_request_preview["runtime_state"] = runtime_state

	return {
		"ok": true,
		"debug_label": _build_debug_label(last_request_preview),
		"preview_bbcode": build_request_preview_bbcode(last_request_preview),
		"auto_compacted": bool(auto_compact.get("performed", false)),
		"memory_summary": String(auto_compact.get("summary_text", "")),
		"usage": usage,
		"request_preview": get_last_request_preview(),
	}
func get_script_context() -> Dictionary:
	return _context_builder.get_script_context()

func set_state(next_state: String) -> void:
	runtime_state = next_state

func get_state() -> String:
	return runtime_state

func is_busy() -> bool:
	return runtime_state == STATE_PREPARING or runtime_state == STATE_STREAMING

func begin_streaming() -> void:
	set_state(STATE_STREAMING)

func mark_stream_completed() -> void:
	set_state(STATE_COMPLETED)

func mark_stream_failed() -> void:
	set_state(STATE_FAILED)

func mark_stream_stopped() -> void:
	set_state(STATE_STOPPED)

func begin_manual_operation() -> void:
	set_state(STATE_PREPARING)

func finish_manual_operation() -> void:
	if pending_action.is_empty():
		set_state(STATE_IDLE)

func set_pending_action(action: Dictionary) -> void:
	pending_action = action.duplicate(true)
	set_state(STATE_AWAITING_ACTION_CONFIRMATION)

func get_pending_action() -> Dictionary:
	return pending_action.duplicate(true)

func clear_pending_action(next_state: String = STATE_IDLE) -> void:
	pending_action = {}
	set_state(next_state)

func begin_action_target_selection() -> void:
	set_state(STATE_AWAITING_ACTION_CONFIRMATION)

func begin_action_review(action: Dictionary) -> void:
	set_pending_action(action)

func cancel_action_review() -> void:
	clear_pending_action(STATE_IDLE)

func get_last_request_preview() -> Dictionary:
	return last_request_preview.duplicate(true)

func preview_chat_request(prompt: String, session: Dictionary, api_settings: Dictionary) -> Dictionary:
	_memory_manager.ensure_session_shape(session)

	if not session.has("history"):
		return {"ok": false, "reason": "missing_session", "message": "The current session is unavailable. Create or reopen a session and try again."}

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
		"provider_capabilities": _extract_provider_capabilities(profile),
		"runtime_state": runtime_state,
		"rules": rules,
		"memory": session.get("memory", {}),
		"context": context,
		"request": request,
		"context_manifest": request.get("context_manifest", []),
		"dropped_context_items": request.get("dropped_context_items", []),
		"payload": provider_request["payload"],
	}

	return {
		"ok": true,
		"usage": _build_usage_summary(preview),
		"debug_label": _build_debug_label(preview),
		"preview_bbcode": build_request_preview_bbcode(preview),
		"preview": preview,
	}
func compact_session(session: Dictionary, mode: String = "manual") -> Dictionary:
	_memory_manager.ensure_session_shape(session)
	var context: Dictionary = _context_builder.build_runtime_context(session.get("memory", {}))
	_memory_manager.register_context(session, context)
	return _memory_manager.compact_session(session, mode)

func record_assistant_response(session: Dictionary, content: String) -> void:
	_memory_manager.register_assistant_response(session, content)

func plan_assistant_response(content: String) -> Dictionary:
	var code_blocks: Array = _extract_code_blocks(content)
	var response_intent: String = _classify_response_intent(String(last_request_preview.get("prompt", "")), content, code_blocks)
	var actions: Array = []

	for block in code_blocks:
		if not (block is Dictionary):
			continue
		actions.append(_build_code_block_action(block, response_intent))

	last_response_actions = actions.duplicate(true)
	last_request_preview["response_intent"] = response_intent
	last_request_preview["response_actions"] = get_response_actions()

	return {
		"response_intent": response_intent,
		"code_block_actions": get_response_actions(),
	}

func get_response_actions() -> Array:
	return last_response_actions.duplicate(true)

func resolve_response_action(block_index: int) -> Dictionary:
	if block_index < 0 or block_index >= last_response_actions.size():
		return {
			"ok": false,
			"reason": "missing_code_block",
			"message": "The selected code block is no longer available.",
		}

	var action = last_response_actions[block_index]
	if not (action is Dictionary):
		return {
			"ok": false,
			"reason": "invalid_code_block",
			"message": "The selected code block metadata is invalid.",
		}

	if not bool(action.get("show_primary_action", false)):
		return {
			"ok": false,
			"reason": "apply_not_allowed",
			"message": String(action.get("reason", "This response is explanation-only, so Apply is unavailable.")),
		}

	var resolved_action: Dictionary = action.duplicate(true)
	resolved_action["ok"] = true
	return resolved_action

func prepare_response_action(block_index: int, session: Dictionary, editor_context: Dictionary) -> Dictionary:
	var resolved_action: Dictionary = resolve_response_action(block_index)
	if not bool(resolved_action.get("ok", false)):
		return resolved_action

	if _action_executor == null or _project_indexer == null:
		return {
			"ok": false,
			"reason": "missing_action_services",
			"message": "Action planning services are not configured.",
		}

	var target_code: String = str(resolved_action.get("content", "")).strip_edges()
	if target_code.is_empty():
		return {
			"ok": false,
			"reason": "missing_code",
			"message": "The selected code block does not contain any code to apply.",
		}

	var active_script_path: String = str(editor_context.get("active_script_path", "")).strip_edges()
	var target_resolution: Dictionary = _resolve_apply_target(session, active_script_path)
	if bool(target_resolution.get("has_unresolved_mention", false)):
		return {
			"ok": false,
			"reason": "unresolved_target_file",
			"message": str(target_resolution.get("reason", "The target file could not be resolved from the chat history.")),
		}

	var target_script_path: String = str(target_resolution.get("path", "")).strip_edges()
	var active_text: String = str(editor_context.get("active_text", ""))
	var plan: Dictionary = {}
	if not active_text.is_empty() and target_script_path == active_script_path:
		plan = _action_executor.plan_code_application_for_text(
			target_code,
			active_text,
			target_script_path,
			int(editor_context.get("caret_line", -1)),
			editor_context.get("selection_range", {}),
			active_script_path
		)
	else:
		var target_text: String = _read_text_file(target_script_path)
		if target_script_path.is_empty() or (target_text.is_empty() and not FileAccess.file_exists(target_script_path)):
			return {
				"ok": false,
				"reason": "missing_target_file",
				"message": "Failed to locate the target file for this Apply action.",
			}
		plan = _action_executor.plan_code_application_for_text(
			target_code,
			target_text,
			target_script_path,
			-1,
			{},
			active_script_path
		)

	if not bool(plan.get("ok", false)):
		return {
			"ok": false,
			"reason": str(plan.get("reason", "plan_failed")),
			"message": str(plan.get("message", "Failed to find an apply target.")),
		}

	var candidates: Array = []
	for candidate in plan.get("candidates", []):
		if not (candidate is Dictionary):
			continue
		candidates.append(_decorate_candidate(candidate, target_resolution))

	if candidates.is_empty():
		return {
			"ok": false,
			"reason": "missing_candidates",
			"message": "No suitable code block target was found for this Apply action.",
		}

	var info_message: String = ""
	if bool(target_resolution.get("used_explicit_mention", false)):
		info_message = str(target_resolution.get("reason", "Resolved an explicit file mention from the chat history."))

	if bool(plan.get("auto_apply", false)):
		var review_result: Dictionary = review_action_candidate(candidates[0])
		if not info_message.is_empty():
			review_result["info_message"] = info_message
		return review_result

	begin_action_target_selection()
	return {
		"ok": true,
		"disposition": "select_target",
		"candidates": candidates,
		"dialog": {
			"title": "Choose Apply Target",
			"confirm_text": "Review Change",
		},
		"info_message": info_message,
	}

func review_action_candidate(action: Dictionary) -> Dictionary:
	if action.is_empty():
		return {
			"ok": false,
			"reason": "missing_action",
			"message": "No action is available for review.",
		}

	var review_action: Dictionary = action.duplicate(true)
	var review_payload: Dictionary = {}
	if review_action.get("review_data", {}) is Dictionary:
		review_payload = review_action.get("review_data", {})
	elif _action_executor != null:
		review_payload = _action_executor.build_action_review_data(review_action)
	review_action["review_data"] = review_payload
	begin_action_review(review_action)
	return {
		"ok": true,
		"disposition": "review",
		"action": get_pending_action(),
		"review": review_payload,
	}

func mark_pending_action_secondary_confirmed() -> Dictionary:
	if pending_action.is_empty():
		return {}
	pending_action["secondary_confirmed"] = true
	return get_pending_action()

func execute_pending_action(editor_context: Dictionary) -> Dictionary:
	if _action_executor == null:
		return {
			"ok": false,
			"reason": "missing_action_executor",
			"error": "Action execution services are not configured.",
		}

	var action: Dictionary = get_pending_action()
	if action.is_empty():
		return {
			"ok": false,
			"reason": "missing_pending_action",
			"error": "No pending action is available.",
		}

	var confirmed_action: Dictionary = action.duplicate(true)
	confirmed_action["confirmed"] = true
	var target_script_path: String = str(confirmed_action.get("target_path", "")).strip_edges()
	var active_script_path: String = str(editor_context.get("active_script_path", "")).strip_edges()
	var code_edit: CodeEdit = editor_context.get("code_edit", null)
	var result: Dictionary = {}
	var gate: Dictionary = _action_executor.can_execute_action(confirmed_action, code_edit, true)
	if not bool(gate.get("ok", false)):
		return {
			"ok": false,
			"reason": str(gate.get("reason", "blocked")),
			"error": str(gate.get("message", "Action execution is blocked.")),
		}

	if not target_script_path.is_empty() and (code_edit == null or target_script_path != active_script_path):
		result = _execute_action_in_file(confirmed_action, target_script_path)
	else:
		result = _action_executor.execute_action(confirmed_action, code_edit)
	clear_pending_action(STATE_IDLE)
	return result

func build_request_preview_bbcode(preview: Dictionary) -> String:
	if preview.is_empty():
		return ""

	var usage: Dictionary = preview.get("usage", {})
	if usage.is_empty():
		usage = _build_usage_summary(preview)

	var profile: Dictionary = preview.get("profile", {})
	var rules: Dictionary = preview.get("rules", {})
	var capabilities: Dictionary = preview.get("provider_capabilities", {})
	var lines: Array = []
	lines.append("[b][color=#E5C07B]Request Preview[/color][/b]")
	lines.append("State: %s" % _localize_runtime_state(String(preview.get("runtime_state", runtime_state))))
	lines.append("Model: %s" % String(preview.get("model", profile.get("name", "unknown"))))
	lines.append("Provider: %s" % _localize_provider_label(String(profile.get("provider", "unknown"))))
	lines.append("Input: %s / %s tokens" % [
		_format_token_count(int(usage.get("estimated_input_tokens", 0))),
		_format_token_count(int(usage.get("input_budget_tokens", 0))),
	])
	lines.append("Context items: selected %d, dropped %d" % [
		int(usage.get("selected_context_count", 0)),
		int(usage.get("dropped_context_count", 0)),
	])
	lines.append("Messages: %d" % int(usage.get("message_count", 0)))
	lines.append("Auto compact: %s" % _bool_to_zh(bool(preview.get("auto_compact", {}).get("performed", false))))
	lines.append("Capabilities: system=%s, reasoning=%s, tools=%s" % [
		_bool_to_zh(bool(capabilities.get("supports_system_role", false))),
		_bool_to_zh(bool(capabilities.get("supports_reasoning_delta", false))),
		_bool_to_zh(bool(capabilities.get("supports_tool_calls", false))),
	])

	var sources: Array = usage.get("sources", [])
	if not sources.is_empty():
		lines.append("")
		lines.append("[b]Top Sources[/b]")
		for index in range(mini(4, sources.size())):
			var source: Dictionary = sources[index]
			lines.append("- %s: %s tokens" % [
				_localize_usage_source_name(String(source.get("name", "Unknown Source"))),
				_format_token_count(int(source.get("tokens", 0))),
			])

	var dropped_items: Array = preview.get("dropped_context_items", [])
	if not dropped_items.is_empty():
		lines.append("")
		lines.append("[b]Dropped Context[/b]")
		for index in range(mini(4, dropped_items.size())):
			var item: Dictionary = dropped_items[index]
			lines.append("- %s (%s)" % [
				String(item.get("title", item.get("kind", "Context"))),
				_localize_context_drop_reason(String(item.get("reason", "dropped"))),
			])

	var loaded_sources: Array = []
	for source in rules.get("sources", []):
		if source is Dictionary and bool(source.get("exists", false)):
			loaded_sources.append(_localize_rule_source(String(source.get("path", ""))))
	if not loaded_sources.is_empty():
		lines.append("")
		lines.append("[b]Rules[/b]")
		for index in range(mini(3, loaded_sources.size())):
			lines.append("- %s" % loaded_sources[index])

	return "\n".join(lines)

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
	lines.append("State: %s" % _localize_runtime_state(String(preview.get("runtime_state", runtime_state))))
	lines.append("Provider: %s" % _localize_provider_label(String(profile.get("provider", "unknown"))))
	if not loaded_sources.is_empty():
		lines.append("Rules: %s" % ", ".join(loaded_sources))
	else:
		lines.append("Rules: built-in defaults only")

	if not String(context.get("script_path", "")).is_empty():
		var context_label: String = "Current Script"
		if bool(context.get("is_selected", false)):
			context_label = "Selected Code"
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

	var selected_context_count: int = 0
	for entry in preview.get("context_manifest", []):
		if entry is Dictionary and bool(entry.get("selected", false)):
			selected_context_count += 1
	lines.append("Context items: selected %d / dropped %d" % [
		selected_context_count,
		preview.get("dropped_context_items", []).size(),
	])

	var load_errors: Array = rules.get("load_errors", [])
	if not load_errors.is_empty():
		lines.append("Rule errors: %s" % " | ".join(load_errors))

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
	var status_label: String = "Context is healthy"
	var should_compact: bool = false
	if estimated_input_tokens > input_budget_tokens:
		risk_level = "limit"
		status_label = "The request is over the input budget"
		should_compact = true
	elif usage_ratio >= CONTEXT_LIMIT_THRESHOLD:
		risk_level = "limit"
		status_label = "The request is close to the context limit"
		should_compact = true
	elif usage_ratio >= CONTEXT_COMPRESS_THRESHOLD:
		risk_level = "compress"
		status_label = "Compact the session before sending"
		should_compact = true
	elif usage_ratio >= CONTEXT_WATCH_THRESHOLD:
		risk_level = "watch"
		status_label = "Context usage is growing"

	var sources: Array = _build_usage_sources(rules, context, memory, request, profile, String(preview.get("prompt", "")))
	var selected_context_count: int = 0
	for entry in request.get("context_manifest", []):
		if entry is Dictionary and bool(entry.get("selected", false)):
			selected_context_count += 1

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
		"context_manifest_count": request.get("context_manifest", []).size(),
		"selected_context_count": selected_context_count,
		"dropped_context_count": request.get("dropped_context_items", []).size(),
	}

func _build_usage_sources(rules: Dictionary, context: Dictionary, memory: Dictionary, request: Dictionary, profile: Dictionary, prompt: String) -> Array:
	var sources: Array = []
	var rules_text: String = String(rules.get("merged_text", "")).strip_edges()
	_push_usage_source(sources, "Rules", rules_text)

	for item in request.get("selected_context_items", []):
		if not (item is Dictionary):
			continue
		_push_usage_source(
			sources,
			String(item.get("title", item.get("kind", "Context"))),
			String(item.get("rendered_text", item.get("text", ""))).strip_edges()
		)

	var history_text: String = ""
	for message in request.get("normalized_history", []):
		if not (message is Dictionary):
			continue
		if not history_text.is_empty():
			history_text += "\n\n"
		history_text += "[%s]\n%s" % [String(message.get("role", "user")), String(message.get("content", ""))]
	_push_usage_source(sources, "Chat History", history_text)
	_push_usage_source(sources, "Current Input", prompt.strip_edges())

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

func _localize_runtime_state(state: String) -> String:
	match state:
		STATE_IDLE:
			return "Idle"
		STATE_PREPARING:
			return "Preparing"
		STATE_STREAMING:
			return "Streaming"
		STATE_AWAITING_ACTION_CONFIRMATION:
			return "Awaiting Confirmation"
		STATE_COMPLETED:
			return "Completed"
		STATE_FAILED:
			return "Failed"
		STATE_STOPPED:
			return "Stopped"
		_:
			return state

func _localize_provider_label(provider: String) -> String:
	match provider:
		"openai_compatible":
			return "OpenAI Compatible"
		"deepseek_compatible":
			return "DeepSeek Compatible"
		_:
			return provider

func _bool_to_zh(value: bool) -> String:
	return "yes" if value else "no"

func _localize_usage_source_name(name: String) -> String:
	match name:
		"Session Memory":
			return "Session Memory"
		"Selected Code":
			return "Selected Code"
		"Current Script":
			return "Current Script"
		"Git Summary":
			return "Git Summary"
		"Project Map":
			return "Project Map"
		"Dynamic System Context":
			return "Dynamic System Context"
		_:
			return name

func _localize_context_drop_reason(reason: String) -> String:
	match reason:
		"budget_exhausted":
			return "Budget Exhausted"
		"too_large_for_budget":
			return "Too Large For Budget"
		"selected":
			return "Selected"
		"dropped":
			return "Dropped"
		_:
			return reason

func _localize_rule_source(path: String) -> String:
	if path == "builtin://default":
		return "Built-in Default Rule"
	return path

func _format_token_count(value: int) -> String:
	if value >= 1000:
		return "%.1fk" % (float(value) / 1000.0)
	return str(value)
func _extract_code_blocks(content: String) -> Array:
	var blocks: Array = []
	var in_code_block: bool = false
	var current_lang: String = ""
	var code_buffer: String = ""

	for line in content.split("\n"):
		var stripped: String = line.strip_edges()
		if stripped.begins_with("```"):
			if not in_code_block:
				in_code_block = true
				current_lang = stripped.substr(3).strip_edges().to_lower()
				code_buffer = ""
			else:
				var code_text: String = code_buffer.strip_edges()
				if not code_text.is_empty():
					blocks.append({
						"index": blocks.size(),
						"language": current_lang,
						"text": code_text,
					})
				in_code_block = false
				current_lang = ""
				code_buffer = ""
		elif in_code_block:
			code_buffer += line + "\n"

	if in_code_block:
		var trailing_code: String = code_buffer.strip_edges()
		if not trailing_code.is_empty():
			blocks.append({
				"index": blocks.size(),
				"language": current_lang,
				"text": trailing_code,
			})

	return blocks

func _classify_response_intent(prompt: String, content: String, code_blocks: Array) -> String:
	if code_blocks.is_empty():
		return "explain_only"

	var normalized_prompt: String = prompt.to_lower()
	var normalized_content: String = content.to_lower()
	var asks_for_change: bool = _contains_any(normalized_prompt, [
		"fix", "patch", "modify", "change", "update", "rewrite", "refactor",
		"implement", "add ", "replace", "insert", "write", "create", "edit",
	])
	var asks_for_explanation: bool = _contains_any(normalized_prompt, [
		"explain", "analysis", "analyze", "review", "why", "what", "how",
	])
	var content_offers_direct_change: bool = _contains_any(normalized_content, [
		"replace with", "updated code", "directly replace", "apply this",
		"complete code", "updated snippet", "replace the block",
	])

	if asks_for_change or content_offers_direct_change:
		return "modify_code"
	if asks_for_explanation:
		return "explain_only"
	return "explain_only"
func _build_code_block_action(block: Dictionary, response_intent: String) -> Dictionary:
	var code_text: String = String(block.get("text", "")).strip_edges()
	var language: String = String(block.get("language", "")).to_lower()
	var block_analysis: Dictionary = {}
	if _action_executor != null:
		block_analysis = _action_executor.inspect_generated_code(code_text, language)
	var applyable: bool = response_intent == "modify_code" and bool(block_analysis.get("is_applyable", false))
	var reason: String = "Review this AI-generated change before applying it."
	var action_type: String = AIActionExecutor.ACTION_EXPLAIN_ONLY
	var button_label: String = ""
	if applyable:
		action_type = str(block_analysis.get("default_action_type", AIActionExecutor.ACTION_REPLACE_SELECTION))
		button_label = str(block_analysis.get("default_button_label", "Apply"))
		reason = str(block_analysis.get("reason", reason))
	else:
		reason = "This response is explanation-only, so Apply stays hidden for this code block."
		if response_intent == "modify_code":
			reason = str(block_analysis.get("reason", "This code block does not look like a direct GDScript edit target."))

	return {
		"block_index": int(block.get("index", 0)),
		"action_type": action_type,
		"intent": response_intent,
		"show_primary_action": applyable,
		"button_label": button_label,
		"button_tooltip": reason,
		"reason": reason,
		"language": language,
		"content": code_text,
		"line_count": int(block_analysis.get("line_count", code_text.split("\n").size())),
		"risk_level": str(block_analysis.get("risk_level", "low")),
		"code_shape": str(block_analysis.get("code_shape", "snippet")),
	}

func _contains_any(text: String, patterns: Array) -> bool:
	for pattern in patterns:
		if text.contains(String(pattern)):
			return true
	return false

func _resolve_apply_target(session: Dictionary, active_script_path: String) -> Dictionary:
	if _project_indexer == null:
		return {
			"path": active_script_path,
			"mention": "",
			"reason": "",
			"used_explicit_mention": false,
			"has_unresolved_mention": false,
		}

	var recent_files: Array = []
	var memory: Dictionary = session.get("memory", {})
	if memory.get("recent_files", []) is Array:
		recent_files = memory.get("recent_files", [])
	var files: Array = _project_indexer.build_project_summary(recent_files).get("files", [])
	var mentions: Array = _project_indexer.extract_latest_file_mentions(session.get("history", []), "user")

	for mention_data in mentions:
		if not (mention_data is Dictionary):
			continue
		var mention: String = str(mention_data.get("mention", "")).strip_edges()
		var resolved: String = _project_indexer.match_project_file_path(mention, files)
		if not resolved.is_empty() and FileAccess.file_exists(resolved):
			return {
				"path": resolved,
				"mention": mention,
				"reason": "Resolved the latest user-mentioned file `%s` to `%s`." % [mention, resolved],
				"used_explicit_mention": true,
				"has_unresolved_mention": false,
			}

	if not mentions.is_empty():
		var unresolved_mention: String = str(mentions[0].get("mention", "")).strip_edges()
		return {
			"path": "",
			"mention": unresolved_mention,
			"reason": "The latest user-mentioned file `%s` could not be found in the project, so Apply is blocked instead of falling back to another file." % unresolved_mention,
			"used_explicit_mention": true,
			"has_unresolved_mention": true,
		}

	return {
		"path": active_script_path,
		"mention": "",
		"reason": "No explicit file mention was found, so the active editor stays the default apply target.",
		"used_explicit_mention": false,
		"has_unresolved_mention": false,
	}

func _decorate_candidate(candidate: Dictionary, target_resolution: Dictionary) -> Dictionary:
	var decorated: Dictionary = candidate.duplicate(true)
	var resolution_reason: String = str(target_resolution.get("reason", "")).strip_edges()
	var match_reason: String = str(decorated.get("match_reason", "")).strip_edges()
	if not resolution_reason.is_empty():
		if match_reason.is_empty():
			decorated["match_reason"] = resolution_reason
		else:
			decorated["match_reason"] = "%s %s" % [resolution_reason, match_reason]
	return _action_executor.prepare_candidate_for_ui(decorated) if _action_executor != null else decorated

func _read_text_file(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	return file.get_as_text()

func _execute_action_in_file(action: Dictionary, target_script_path: String) -> Dictionary:
	var original_text: String = _read_text_file(target_script_path)
	if target_script_path.is_empty() or (original_text.is_empty() and not FileAccess.file_exists(target_script_path)):
		return {
			"ok": false,
			"error": "Target file could not be opened: %s" % target_script_path,
		}

	var transformed: Dictionary = _action_executor.apply_action_to_text(action, original_text)
	if not bool(transformed.get("ok", false)):
		return {
			"ok": false,
			"error": str(transformed.get("message", "Failed to transform the target file.")),
		}

	var file: FileAccess = FileAccess.open(target_script_path, FileAccess.WRITE)
	if file == null:
		return {
			"ok": false,
			"error": "Target file could not be written: %s" % target_script_path,
		}
	file.store_string(str(transformed.get("text", original_text)))
	file.flush()

	return {
		"ok": true,
		"applied": true,
		"target_path": target_script_path,
		"log_entry": _action_executor.create_log_entry(action, true),
	}

func _extract_provider_capabilities(profile: Dictionary) -> Dictionary:
	return {
		"supports_system_role": bool(profile.get("supports_system_role", false)),
		"supports_reasoning_delta": bool(profile.get("supports_reasoning_delta", false)),
		"supports_streaming": bool(profile.get("supports_streaming", false)),
		"supports_tool_calls": bool(profile.get("supports_tool_calls", false)),
		"supports_cache_hints": bool(profile.get("supports_cache_hints", false)),
	}
