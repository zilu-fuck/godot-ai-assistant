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
		return {"ok": false, "reason": "empty_prompt", "message": "请先输入内容，再发送请求。"}
	if String(api_settings.get("key", "")).is_empty():
		return {"ok": false, "reason": "missing_api_key", "message": "请先在设置里填写 API Key，再发送请求。"}
	if _net_client == null:
		return {"ok": false, "reason": "missing_net_client", "message": "网络客户端还没初始化，请重载插件后重试。"}
	if not session.has("history"):
		return {"ok": false, "reason": "missing_session", "message": "当前会话不可用，请新建或重新打开会话后重试。"}

	set_state(STATE_PREPARING)
	var model: String = String(api_settings.get("model", "deepseek-chat"))
	var profile: Dictionary = _provider_profiles.resolve_profile(model, String(api_settings.get("url", "")))
	var context: Dictionary = _context_builder.build_runtime_context(session.get("memory", {}), _build_context_options(cleaned_prompt))
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
		last_request_preview["start_error"] = String(start_result.get("message", "启动模型请求失败。"))
		return {
			"ok": false,
			"reason": "start_stream_failed",
			"message": String(start_result.get("message", "启动模型请求失败。")),
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
		return {"ok": false, "reason": "missing_session", "message": "当前会话不可用，请新建或重新打开会话后重试。"}

	var cleaned_prompt: String = prompt.strip_edges()
	var model: String = String(api_settings.get("model", "deepseek-chat"))
	var profile: Dictionary = _provider_profiles.resolve_profile(model, String(api_settings.get("url", "")))
	var context: Dictionary = _context_builder.build_runtime_context(session.get("memory", {}), _build_context_options(cleaned_prompt))
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
	return plan_assistant_response_for_prompt(String(last_request_preview.get("prompt", "")), content)

func plan_assistant_response_for_prompt(prompt: String, content: String) -> Dictionary:
	var code_blocks: Array = _extract_code_blocks(content)
	var response_intent: String = _classify_response_intent(prompt, content, code_blocks)
	var actions: Array = []

	for block in code_blocks:
		if not (block is Dictionary):
			continue
		actions.append(_build_code_block_action(block, response_intent))
	actions = _attach_scene_companion_metadata(actions)

	last_response_actions = actions.duplicate(true)
	last_request_preview["response_intent"] = response_intent
	last_request_preview["response_actions"] = get_response_actions()
	if not prompt.strip_edges().is_empty():
		last_request_preview["prompt"] = prompt

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
			"message": "选中的代码块已不可用。",
		}

	var action = last_response_actions[block_index]
	if not (action is Dictionary):
		return {
			"ok": false,
			"reason": "invalid_code_block",
			"message": "选中的代码块元数据无效。",
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
			"message": "动作规划服务尚未配置。",
		}

	var target_code: String = str(resolved_action.get("content", "")).strip_edges()
	if target_code.is_empty():
		return {
			"ok": false,
			"reason": "missing_code",
			"message": "选中的代码块里没有可应用的内容。",
		}

	if _is_scene_creation_action(resolved_action):
		return _prepare_scene_creation_action(resolved_action, session, editor_context)

	var active_script_path: String = str(editor_context.get("active_script_path", "")).strip_edges()
	var target_resolution: Dictionary = _resolve_apply_target(session, active_script_path)
	if bool(target_resolution.get("has_unresolved_mention", false)):
		return {
			"ok": false,
			"reason": "unresolved_target_file",
			"message": str(target_resolution.get("reason", "无法从聊天记录里解析目标文件。")),
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
			"message": "找不到这次应用对应的目标文件。",
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
			"message": str(plan.get("message", "找不到可应用的目标位置。")),
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
			"message": "没有找到适合这次应用的目标位置。",
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
			"title": "选择应用目标",
			"confirm_text": "查看变更",

		},
		"info_message": info_message,
	}

func review_action_candidate(action: Dictionary) -> Dictionary:
	if action.is_empty():
		return {
			"ok": false,
			"reason": "missing_action",
			"message": "当前没有可供审查的动作。",
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

func can_choose_pending_scene_target_path() -> bool:
	if pending_action.is_empty():
		return false
	return str(pending_action.get("execution_type", "")) == AIActionExecutor.EXEC_CREATE_SCENE_FILE

func choose_pending_scene_target_path(target_path: String, editor_context: Dictionary) -> Dictionary:
	if _action_executor == null:
		return {
			"ok": false,
			"reason": "missing_action_executor",
			"message": "动作执行服务尚未配置。",
		}

	var action: Dictionary = get_pending_action()
	if action.is_empty():
		return {
			"ok": false,
			"reason": "missing_pending_action",
			"message": "当前没有待调整路径的动作。",
		}
	if str(action.get("execution_type", "")) != AIActionExecutor.EXEC_CREATE_SCENE_FILE:
		return {
			"ok": false,
			"reason": "unsupported_action",
			"message": "只有创建场景动作支持手动选择保存位置。",
		}

	var normalized_target_path: String = target_path.strip_edges().replace("\\", "/")
	if normalized_target_path.is_empty():
		return {
			"ok": false,
			"reason": "missing_target_path",
			"message": "请选择一个场景保存路径。",
		}
	if not normalized_target_path.to_lower().ends_with(".tscn"):
		normalized_target_path += ".tscn"
	if not normalized_target_path.begins_with("res://"):
		var preferred_dir: String = _get_preferred_scene_directory(editor_context)
		if _project_indexer != null:
			normalized_target_path = _project_indexer.resolve_project_path_hint(normalized_target_path, preferred_dir)
		else:
			normalized_target_path = preferred_dir.path_join(normalized_target_path).simplify_path()
	if not normalized_target_path.begins_with("res://"):
		return {
			"ok": false,
			"reason": "invalid_target_path",
			"message": "场景保存路径必须位于项目资源目录中。",
		}

	var existing_text: String = _read_text_file(normalized_target_path)
	var plan: Dictionary = _action_executor.plan_scene_creation(
		str(action.get("content", "")),
		normalized_target_path,
		existing_text if FileAccess.file_exists(normalized_target_path) else "",
		str(editor_context.get("active_scene_path", "")).strip_edges()
	)
	if not bool(plan.get("ok", false)):
		return {
			"ok": false,
			"reason": str(plan.get("reason", "plan_failed")),
			"message": str(plan.get("message", "准备场景创建方案失败。")),
		}

	var replanned_action: Dictionary = plan.get("primary_candidate", {})
	if replanned_action.is_empty():
		var candidates: Array = plan.get("candidates", [])
		if not candidates.is_empty() and candidates[0] is Dictionary:
			replanned_action = candidates[0]
	if replanned_action.is_empty():
		return {
			"ok": false,
			"reason": "missing_candidate",
			"message": "无法为这个保存路径生成场景创建方案。",
		}

	replanned_action = _decorate_scene_candidate_with_companion(
		replanned_action,
		str(action.get("companion_script_content", "")).strip_edges(),
		_derive_scene_companion_script_path(normalized_target_path, str(action.get("companion_script_content", "")).strip_edges())
	)
	replanned_action = replanned_action.duplicate(true)
	replanned_action["confirmed"] = false
	replanned_action["secondary_confirmed"] = false

	var selection_reason: String = "用户手动选择了这个场景保存路径。"
	var match_reason: String = str(replanned_action.get("match_reason", "")).strip_edges()
	if match_reason.is_empty():
		replanned_action["match_reason"] = selection_reason
	else:
		replanned_action["match_reason"] = "%s %s" % [selection_reason, match_reason]

	var review_result: Dictionary = review_action_candidate(replanned_action)
	review_result["info_message"] = "场景将保存到 `%s`。" % normalized_target_path
	return review_result

func _prepare_scene_creation_action(resolved_action: Dictionary, session: Dictionary, editor_context: Dictionary) -> Dictionary:
	var target_scene: String = str(resolved_action.get("content", "")).strip_edges()
	if target_scene.is_empty():
		return {
			"ok": false,
			"reason": "missing_scene_content",
			"message": "选中的代码块里没有可创建场景的内容。",
		}

	var target_resolution: Dictionary = _resolve_scene_creation_target(session, editor_context, resolved_action)
	if bool(target_resolution.get("has_unresolved_mention", false)):
		return {
			"ok": false,
			"reason": "unresolved_scene_path",
			"message": str(target_resolution.get("reason", "无法从聊天记录里解析目标场景路径。")),
		}

	var target_path: String = str(target_resolution.get("path", "")).strip_edges()
	if target_path.is_empty():
		return {
			"ok": false,
			"reason": "missing_scene_path",
			"message": "运行时无法判断应该把场景创建到哪里。",
		}

	var companion_script_content: String = str(resolved_action.get("companion_script_content", "")).strip_edges()
	var companion_script_target_path: String = _derive_scene_companion_script_path(target_path, companion_script_content)
	var existing_text: String = _read_text_file(target_path)
	var plan: Dictionary = _action_executor.plan_scene_creation(
		target_scene,
		target_path,
		existing_text if FileAccess.file_exists(target_path) else "",
		str(editor_context.get("active_scene_path", "")).strip_edges()
	)
	if not bool(plan.get("ok", false)):
		return {
			"ok": false,
			"reason": str(plan.get("reason", "plan_failed")),
			"message": str(plan.get("message", "准备场景创建方案失败。")),
		}

	var candidates: Array = []
	for candidate in plan.get("candidates", []):
		if not (candidate is Dictionary):
			continue
		var decorated_candidate: Dictionary = _decorate_candidate(candidate, target_resolution)
		decorated_candidate = _decorate_scene_candidate_with_companion(decorated_candidate, companion_script_content, companion_script_target_path)
		candidates.append(decorated_candidate)
	if candidates.is_empty():
		return {
			"ok": false,
			"reason": "missing_candidates",
			"message": "当前回复没有可用的场景创建候选目标。",
		}

	var info_message: String = ""
	if bool(target_resolution.get("used_explicit_mention", false)):
		info_message = str(target_resolution.get("reason", "Resolved a scene path from the latest user message."))

	var review_result: Dictionary = review_action_candidate(candidates[0])
	if not info_message.is_empty():
		review_result["info_message"] = info_message
	return review_result

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
			"error": "动作执行服务尚未配置。",
		}

	var action: Dictionary = get_pending_action()
	if action.is_empty():
		return {
			"ok": false,
			"reason": "missing_pending_action",
			"error": "当前没有待执行的动作。",
		}

	var confirmed_action: Dictionary = action.duplicate(true)
	confirmed_action["confirmed"] = true
	var target_script_path: String = str(confirmed_action.get("target_path", "")).strip_edges()
	var active_script_path: String = str(editor_context.get("active_script_path", "")).strip_edges()
	var execution_type: String = str(confirmed_action.get("execution_type", ""))
	var code_edit: CodeEdit = editor_context.get("code_edit", null)
	var result: Dictionary = {}
	var gate: Dictionary = _action_executor.can_execute_action(confirmed_action, code_edit, true)
	if not bool(gate.get("ok", false)):
		return {
			"ok": false,
			"reason": str(gate.get("reason", "blocked")),
			"error": str(gate.get("message", "动作执行被阻止。")),
		}

	if execution_type == AIActionExecutor.EXEC_CREATE_SCENE_FILE:
		result = _execute_scene_creation_action(confirmed_action, target_script_path)
	elif not target_script_path.is_empty() and (code_edit == null or target_script_path != active_script_path):
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
	lines.append("[b][color=#E5C07B]请求预览[/color][/b]")
	lines.append("状态：%s" % _localize_runtime_state(String(preview.get("runtime_state", runtime_state))))
	lines.append("模型：%s" % String(preview.get("model", profile.get("name", "unknown"))))
	lines.append("提供方：%s" % _localize_provider_label(String(profile.get("provider", "unknown"))))
	lines.append("输入：%s / %s tokens" % [
		_format_token_count(int(usage.get("estimated_input_tokens", 0))),
		_format_token_count(int(usage.get("input_budget_tokens", 0))),
	])
	lines.append("上下文项：已选 %d，丢弃 %d" % [
		int(usage.get("selected_context_count", 0)),
		int(usage.get("dropped_context_count", 0)),
	])
	lines.append("消息数：%d" % int(usage.get("message_count", 0)))
	lines.append("自动压缩：%s" % _bool_to_zh(bool(preview.get("auto_compact", {}).get("performed", false))))
	lines.append("能力：system=%s，reasoning=%s，tools=%s" % [
		_bool_to_zh(bool(capabilities.get("supports_system_role", false))),
		_bool_to_zh(bool(capabilities.get("supports_reasoning_delta", false))),
		_bool_to_zh(bool(capabilities.get("supports_tool_calls", false))),
	])

	var sources: Array = usage.get("sources", [])
	if not sources.is_empty():
		lines.append("")
		lines.append("[b]主要来源[/b]")
		for index in range(mini(4, sources.size())):
			var source: Dictionary = sources[index]
			lines.append("- %s：%s tokens" % [
				_localize_usage_source_name(String(source.get("name", "未知来源"))),
				_format_token_count(int(source.get("tokens", 0))),
			])

	var dropped_items: Array = preview.get("dropped_context_items", [])
	if not dropped_items.is_empty():
		lines.append("")
		lines.append("[b]已丢弃上下文[/b]")
		for index in range(mini(4, dropped_items.size())):
			var item: Dictionary = dropped_items[index]
			lines.append("- %s（%s）" % [
				String(item.get("title", item.get("kind", "上下文"))),
				_localize_context_drop_reason(String(item.get("reason", "dropped"))),
			])

	var loaded_sources: Array = []
	for source in rules.get("sources", []):
		if source is Dictionary and bool(source.get("exists", false)):
			loaded_sources.append(_localize_rule_source(String(source.get("path", ""))))
	if not loaded_sources.is_empty():
		lines.append("")
		lines.append("[b]规则[/b]")
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
	lines.append("状态：%s" % _localize_runtime_state(String(preview.get("runtime_state", runtime_state))))
	lines.append("提供方：%s" % _localize_provider_label(String(profile.get("provider", "unknown"))))
	if not loaded_sources.is_empty():
		lines.append("规则：%s" % ", ".join(loaded_sources))
	else:
		lines.append("规则：仅内置默认规则")

	if not String(context.get("script_path", "")).is_empty():
		var context_label: String = "当前脚本"
		if bool(context.get("is_selected", false)):
			context_label = "选中代码"
		lines.append("上下文：%s（%s）" % [String(context.get("script_path", "")), context_label])
	elif not String(context.get("scene_path", "")).is_empty():
		lines.append("上下文：%s" % String(context.get("scene_path", "")))
	else:
		lines.append("上下文：无")

	var message_count: int = 0
	var payload_messages = payload.get("messages", [])
	if payload_messages is Array:
		message_count = payload_messages.size()
	lines.append("消息数：%d" % message_count)

	var selected_context_count: int = 0
	for entry in preview.get("context_manifest", []):
		if entry is Dictionary and bool(entry.get("selected", false)):
			selected_context_count += 1
	lines.append("上下文项：已选 %d / 丢弃 %d" % [
		selected_context_count,
		preview.get("dropped_context_items", []).size(),
	])

	var load_errors: Array = rules.get("load_errors", [])
	if not load_errors.is_empty():
		lines.append("规则错误：%s" % " | ".join(load_errors))

	var memory: Dictionary = preview.get("memory", {})
	var compacted_at: String = String(memory.get("last_compacted_at", ""))
	if not compacted_at.is_empty():
		lines.append("记忆：最近压缩于 %s" % compacted_at)

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
	var status_label: String = "上下文状态正常"
	var should_compact: bool = false
	if estimated_input_tokens > input_budget_tokens:
		risk_level = "limit"
		status_label = "请求已超过输入预算"
		should_compact = true
	elif usage_ratio >= CONTEXT_LIMIT_THRESHOLD:
		risk_level = "limit"
		status_label = "请求已接近上下文上限"
		should_compact = true
	elif usage_ratio >= CONTEXT_COMPRESS_THRESHOLD:
		risk_level = "compress"
		status_label = "建议先压缩会话再发送"
		should_compact = true
	elif usage_ratio >= CONTEXT_WATCH_THRESHOLD:
		risk_level = "watch"
		status_label = "上下文占用正在增长"

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
			return "空闲"
		STATE_PREPARING:
			return "准备中"
		STATE_STREAMING:
			return "生成中"
		STATE_AWAITING_ACTION_CONFIRMATION:
			return "等待确认"
		STATE_COMPLETED:
			return "已完成"
		STATE_FAILED:
			return "失败"
		STATE_STOPPED:
			return "已停止"
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
	return "是" if value else "否"

func _localize_usage_source_name(name: String) -> String:
	match name:
		"Session Memory":
			return "会话记忆"
		"Selected Code":
			return "选中代码"
		"Current Script":
			return "当前脚本"
		"Git Summary":
			return "Git 摘要"
		"Project Map":
			return "项目地图"
		"Dynamic System Context":
			return "动态系统上下文"
		_:
			return name

func _localize_context_drop_reason(reason: String) -> String:
	match reason:
		"budget_exhausted":
			return "预算已耗尽"
		"too_large_for_budget":
			return "内容过大，超出预算"
		"selected":
			return "已选中"
		"dropped":
			return "已丢弃"
		_:
			return reason

func _localize_rule_source(path: String) -> String:
	if path == "builtin://default":
		return "内置默认规则"
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

func _build_context_options(prompt: String) -> Dictionary:
	var cleaned_prompt: String = prompt.strip_edges()
	return {
		"include_script_context": not _prompt_requests_scene_creation(cleaned_prompt),
	}

func _prompt_requests_scene_creation(prompt: String) -> bool:
	var normalized_prompt: String = prompt.to_lower()
	return _contains_any(normalized_prompt, [
		"create scene", "new scene", "scene file", ".tscn", "build scene",
		"登录场景", "创建场景", "新建场景", "场景文件", "界面场景", "ui场景"
	]) or (_contains_any(normalized_prompt, ["scene", "场景"]) and _contains_any(normalized_prompt, ["create", "new", "build", "make", "创建", "新建", "生成", "做一个", "做个"]))

func _classify_response_intent(prompt: String, content: String, code_blocks: Array) -> String:
	if code_blocks.is_empty():
		return "explain_only"

	var normalized_prompt: String = prompt.to_lower()
	var normalized_content: String = content.to_lower()
	var has_scene_block: bool = _response_has_scene_block(code_blocks)
	var asks_for_scene_creation: bool = _contains_any(normalized_prompt, [
		"create scene", "new scene", "scene file", ".tscn", "build scene",
		"创建场景", "新建场景", "做一个场景", "做个场景", "生成场景", "登录场景", "界面场景", "ui场景",
	]) or (_contains_any(normalized_prompt, ["scene", "场景"]) and _contains_any(normalized_prompt, ["create", "new", "build", "make", "创建", "新建", "做一个", "做个", "生成"]))
	var asks_for_change: bool = _contains_any(normalized_prompt, [
		"fix", "patch", "modify", "change", "update", "rewrite", "refactor",
		"implement", "add ", "replace", "insert", "write", "create", "edit",
		"修复", "补丁", "修改", "改动", "更新", "重写", "重构", "实现", "添加", "替换", "插入", "编写", "编辑",
	])
	var asks_for_explanation: bool = _contains_any(normalized_prompt, [
		"explain", "analysis", "analyze", "review", "why", "what", "how",
		"解释", "分析", "评审", "为什么", "是什么", "怎么",
	])
	var content_offers_direct_change: bool = _contains_any(normalized_content, [
		"replace with", "updated code", "directly replace", "apply this",
		"complete code", "updated snippet", "replace the block",
		"替换为", "更新后的代码", "直接替换", "应用这个", "完整代码", "更新后的片段", "替换这个代码块",
	])
	var content_offers_scene_creation: bool = _contains_any(normalized_content, [
		"scene file", ".tscn", "[gd_scene", "create scene",
		"场景文件", "创建场景", "[gd_scene",
	])

	if has_scene_block and (asks_for_scene_creation or content_offers_scene_creation):
		return "create_scene"
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
		block_analysis = _action_executor.inspect_generated_block(code_text, language)
	var content_kind: String = str(block_analysis.get("content_kind", "code_edit"))
	var applyable: bool = false
	if content_kind == "scene_file":
		applyable = response_intent == "create_scene" and bool(block_analysis.get("is_applyable", false))
	else:
		applyable = response_intent == "modify_code" and bool(block_analysis.get("is_applyable", false))
	var reason: String = "Review this AI-generated change before applying it."
	var action_type: String = AIActionExecutor.ACTION_EXPLAIN_ONLY
	var button_label: String = ""
	if applyable:
		action_type = str(block_analysis.get("default_action_type", AIActionExecutor.ACTION_REPLACE_SELECTION))
		button_label = str(block_analysis.get("default_button_label", "Apply"))
		reason = str(block_analysis.get("reason", reason))
	else:
		reason = "This response is explanation-only, so Apply stays hidden for this code block."
		if response_intent in ["modify_code", "create_scene"]:
			reason = str(block_analysis.get("reason", "这个代码块看起来不像一个可直接应用的修改目标。"))

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
		"content_kind": content_kind,
		"scene_root_name": str(block_analysis.get("scene_root_name", "")),
	}

func _attach_scene_companion_metadata(actions: Array) -> Array:
	var linked_actions: Array = actions.duplicate(true)
	var scene_indexes: Array = []
	var script_indexes: Array = []

	for index in range(linked_actions.size()):
		var action = linked_actions[index]
		if not (action is Dictionary):
			continue
		if str(action.get("content_kind", "")) == "scene_file":
			scene_indexes.append(index)
			continue
		var language: String = str(action.get("language", "")).to_lower()
		if language in ["gd", "gdscript"] and not str(action.get("content", "")).strip_edges().is_empty():
			script_indexes.append(index)

	if scene_indexes.size() != 1:
		return linked_actions

	var scene_index: int = int(scene_indexes[0])
	var script_index: int = _choose_scene_companion_script_index(linked_actions, script_indexes)
	if script_index < 0:
		return linked_actions
	var scene_action: Dictionary = linked_actions[scene_index]
	var script_action: Dictionary = linked_actions[script_index]
	var companion_script_content: String = str(script_action.get("content", "")).strip_edges()
	if companion_script_content.is_empty():
		return linked_actions

	scene_action["companion_script_content"] = companion_script_content
	scene_action["has_companion_script"] = true
	scene_action["risk_level"] = "high"
	scene_action["button_label"] = "预览"
	scene_action["button_tooltip"] = "这条回复同时包含场景和配套脚本，运行时会先预览并进行高风险确认。"
	scene_action["reason"] = "这条回复同时包含场景和配套脚本，运行时会一起创建两个文件并自动绑定根节点脚本。"
	linked_actions[scene_index] = scene_action
	return linked_actions

func _choose_scene_companion_script_index(actions: Array, script_indexes: Array) -> int:
	if script_indexes.is_empty():
		return -1
	if script_indexes.size() == 1:
		return int(script_indexes[0])

	var best_index: int = -1
	var best_score: int = -1
	for index_value in script_indexes:
		var index: int = int(index_value)
		if index < 0 or index >= actions.size():
			continue
		var action = actions[index]
		if not (action is Dictionary):
			continue
		var content: String = str(action.get("content", "")).strip_edges()
		if content.is_empty():
			continue

		var score: int = 0
		if content.begins_with("extends ") or content.contains("\nextends "):
			score += 3
		if content.begins_with("class_name ") or content.contains("\nclass_name "):
			score += 2
		if content.contains("\nfunc ") or content.begins_with("func "):
			score += 1
		if content.split("\n").size() >= 8:
			score += 1

		if score > best_score:
			best_score = score
			best_index = index

	if best_score <= 0:
		return -1
	return best_index

func _response_has_scene_block(code_blocks: Array) -> bool:
	for block in code_blocks:
		if not (block is Dictionary):
			continue
		var language: String = str(block.get("language", "")).to_lower()
		var text: String = str(block.get("text", "")).strip_edges()
		if _action_executor != null:
			var analysis: Dictionary = _action_executor.inspect_generated_block(text, language)
			if str(analysis.get("content_kind", "")) == "scene_file":
				return true
		elif text.begins_with("[gd_scene"):
			return true
	return false

func _is_scene_creation_action(action: Dictionary) -> bool:
	return str(action.get("action_type", "")) == AIActionExecutor.ACTION_CREATE_SCENE or str(action.get("content_kind", "")) == "scene_file"

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
				"reason": "已将用户最近提到的文件 `%s` 解析为 `%s`。" % [mention, resolved],
				"used_explicit_mention": true,
				"has_unresolved_mention": false,
			}

	if not mentions.is_empty():
		var unresolved_mention: String = str(mentions[0].get("mention", "")).strip_edges()
		return {
			"path": "",
			"mention": unresolved_mention,
			"reason": "用户最近提到的文件 `%s` 在项目里找不到，因此阻止 Apply，而不是回退到别的文件。" % unresolved_mention,
			"used_explicit_mention": true,
			"has_unresolved_mention": true,
		}

	return {
		"path": active_script_path,
		"mention": "",
		"reason": "没有找到明确的文件提及，因此默认使用当前活动编辑器。",
		"used_explicit_mention": false,
		"has_unresolved_mention": false,
	}

func _resolve_scene_creation_target(session: Dictionary, editor_context: Dictionary, action: Dictionary) -> Dictionary:
	var preferred_dir: String = _get_preferred_scene_directory(editor_context)
	var recent_files: Array = []
	var memory: Dictionary = session.get("memory", {})
	if memory.get("recent_files", []) is Array:
		recent_files = memory.get("recent_files", [])

	var files: Array = []
	if _project_indexer != null:
		files = _project_indexer.build_project_summary(recent_files).get("files", [])

	var mentions: Array = []
	if _project_indexer != null:
		mentions = _project_indexer.extract_latest_file_mentions(session.get("history", []), "user")

	for mention_data in mentions:
		if not (mention_data is Dictionary):
			continue
		var mention: String = str(mention_data.get("mention", "")).strip_edges()
		if not mention.to_lower().ends_with(".tscn"):
			continue

		var resolved_existing: String = ""
		if _project_indexer != null:
			resolved_existing = _project_indexer.match_project_file_path(mention, files)
		if not resolved_existing.is_empty():
			return {
				"path": resolved_existing,
				"mention": mention,
				"reason": "已将用户最近提到的场景 `%s` 解析为 `%s`。" % [mention, resolved_existing],
				"used_explicit_mention": true,
				"has_unresolved_mention": false,
			}

		var hinted_path: String = mention
		if _project_indexer != null:
			hinted_path = _project_indexer.resolve_project_path_hint(mention, preferred_dir)
		if not hinted_path.is_empty():
			return {
				"path": hinted_path,
				"mention": mention,
				"reason": "用户最近提到的场景 `%s` 还不存在，因此运行时会在 `%s` 创建它。" % [mention, hinted_path],
				"used_explicit_mention": true,
				"has_unresolved_mention": false,
			}

		return {
			"path": "",
			"mention": mention,
			"reason": "用户最近提到的场景 `%s` 无法解析为有效项目路径。" % mention,
			"used_explicit_mention": true,
			"has_unresolved_mention": true,
		}

	var suggested_path: String = _suggest_scene_creation_path(action, preferred_dir)
	return {
		"path": suggested_path,
		"mention": "",
		"reason": "没有找到明确的场景路径，因此运行时根据当前编辑器上下文推荐了一个新路径。",
		"used_explicit_mention": false,
		"has_unresolved_mention": suggested_path.is_empty(),
	}

func _get_preferred_scene_directory(editor_context: Dictionary) -> String:
	var active_scene_path: String = str(editor_context.get("active_scene_path", "")).strip_edges()
	if not active_scene_path.is_empty():
		return active_scene_path.get_base_dir()

	var preview_context: Dictionary = last_request_preview.get("context", {})
	var preview_scene_path: String = str(preview_context.get("scene_path", "")).strip_edges()
	if not preview_scene_path.is_empty():
		return preview_scene_path.get_base_dir()

	var active_script_path: String = str(editor_context.get("active_script_path", "")).strip_edges()
	if not active_script_path.is_empty():
		return active_script_path.get_base_dir()
	return "res://"

func _suggest_scene_creation_path(action: Dictionary, preferred_dir: String) -> String:
	var base_dir: String = preferred_dir.strip_edges()
	if base_dir.is_empty():
		base_dir = "res://"

	var root_name: String = str(action.get("scene_root_name", "")).strip_edges()
	if root_name.is_empty() and _action_executor != null:
		root_name = _action_executor.extract_scene_root_name(str(action.get("content", "")))
	if root_name.is_empty():
		root_name = "GeneratedScene"

	var safe_name: String = root_name.strip_edges().replace(" ", "")
	if safe_name.is_empty():
		safe_name = "GeneratedScene"
	return base_dir.path_join("%s.tscn" % safe_name).simplify_path()

func _derive_scene_companion_script_path(scene_path: String, companion_script_content: String = "") -> String:
	if scene_path.strip_edges().is_empty() or companion_script_content.strip_edges().is_empty():
		return ""
	return "%s.gd" % scene_path.get_basename()

func _decorate_scene_candidate_with_companion(candidate: Dictionary, companion_script_content: String, companion_script_target_path: String) -> Dictionary:
	var decorated: Dictionary = candidate.duplicate(true)
	if companion_script_content.strip_edges().is_empty() or companion_script_target_path.strip_edges().is_empty():
		return decorated

	decorated["companion_script_content"] = companion_script_content
	decorated["companion_script_target_path"] = companion_script_target_path
	decorated["risk_level"] = "high"
	decorated["requires_secondary_confirmation"] = true

	var companion_reason: String = "运行时会同时创建配套脚本 `%s`，并把它挂到场景根节点。" % companion_script_target_path
	var match_reason: String = str(decorated.get("match_reason", "")).strip_edges()
	if match_reason.is_empty():
		decorated["match_reason"] = companion_reason
	else:
		decorated["match_reason"] = "%s %s" % [match_reason, companion_reason]

	return _action_executor.prepare_candidate_for_ui(decorated) if _action_executor != null else decorated

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

func _write_text_file(path: String, text: String) -> Dictionary:
	if path.is_empty():
		return {
			"ok": false,
			"error": "缺少目标文件路径。",
		}

	var directory_path: String = path.get_base_dir()
	if not directory_path.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory_path))

	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {
			"ok": false,
			"error": "无法写入目标文件：%s" % path,
		}
	file.store_string(text)
	file.flush()
	return {
		"ok": true,
	}

func _execute_scene_creation_action(action: Dictionary, target_scene_path: String) -> Dictionary:
	var final_action: Dictionary = action.duplicate(true)
	var final_scene_text: String = str(final_action.get("content", ""))
	var companion_script_content: String = str(final_action.get("companion_script_content", "")).strip_edges()
	var companion_script_target_path: String = str(final_action.get("companion_script_target_path", "")).strip_edges()

	if not companion_script_content.is_empty():
		if companion_script_target_path.is_empty():
			companion_script_target_path = _derive_scene_companion_script_path(target_scene_path, companion_script_content)
		if companion_script_target_path.is_empty():
			return {
				"ok": false,
				"error": "无法为配套脚本生成保存路径。",
			}

		var script_write_result: Dictionary = _write_text_file(companion_script_target_path, companion_script_content)
		if not bool(script_write_result.get("ok", false)):
			return script_write_result

		final_scene_text = _inject_scene_companion_script(final_scene_text, companion_script_target_path)
		final_action["companion_script_target_path"] = companion_script_target_path
		final_action["content"] = final_scene_text

	var scene_write_result: Dictionary = _write_text_file(target_scene_path, final_scene_text)
	if not bool(scene_write_result.get("ok", false)):
		return scene_write_result

	return {
		"ok": true,
		"applied": true,
		"target_path": target_scene_path,
		"log_entry": _action_executor.create_log_entry(final_action, true),
	}

func _inject_scene_companion_script(scene_text: String, companion_script_target_path: String) -> String:
	var cleaned_scene: String = scene_text.strip_edges()
	if cleaned_scene.is_empty() or companion_script_target_path.strip_edges().is_empty():
		return cleaned_scene

	var lines: Array = cleaned_scene.split("\n")
	if lines.is_empty():
		return cleaned_scene

	lines[0] = _increment_scene_load_steps(str(lines[0]))
	var script_resource_id: String = "1_runtime_script"
	var ext_resource_line: String = "[ext_resource type=\"Script\" path=\"%s\" id=\"%s\"]" % [
		companion_script_target_path,
		script_resource_id,
	]

	var rebuilt_lines: Array = [lines[0], "", ext_resource_line]
	if lines.size() > 1:
		rebuilt_lines.append("")
		rebuilt_lines.append_array(lines.slice(1))

	for index in range(rebuilt_lines.size()):
		if str(rebuilt_lines[index]).strip_edges().begins_with("[node "):
			rebuilt_lines.insert(index + 1, "script = ExtResource(\"%s\")" % script_resource_id)
			break

	return "\n".join(rebuilt_lines).strip_edges() + "\n"

func _increment_scene_load_steps(header_line: String) -> String:
	var regex: RegEx = RegEx.new()
	if regex.compile("load_steps=(\\d+)") != OK:
		return header_line

	var match: RegExMatch = regex.search(header_line)
	if match == null:
		if header_line.ends_with("]"):
			return "%s load_steps=2]" % header_line.substr(0, header_line.length() - 1)
		return header_line

	var current_value: int = int(match.get_string(1))
	return header_line.replace("load_steps=%s" % match.get_string(1), "load_steps=%d" % maxi(2, current_value + 1))

func _execute_action_in_file(action: Dictionary, target_script_path: String) -> Dictionary:
	var original_text: String = _read_text_file(target_script_path)
	var execution_type: String = str(action.get("execution_type", ""))
	var allow_missing_file: bool = execution_type == AIActionExecutor.EXEC_CREATE_SCENE_FILE
	if target_script_path.is_empty() or ((original_text.is_empty() and not FileAccess.file_exists(target_script_path)) and not allow_missing_file):
		return {
			"ok": false,
			"error": "无法打开目标文件：%s" % target_script_path,
		}

	var transformed: Dictionary = _action_executor.apply_action_to_text(action, original_text)
	if not bool(transformed.get("ok", false)):
		return {
			"ok": false,
			"error": str(transformed.get("message", "转换目标文件失败。")),
		}

	var file: FileAccess = FileAccess.open(target_script_path, FileAccess.WRITE)
	if file == null:
		return {
			"ok": false,
			"error": "无法写入目标文件：%s" % target_script_path,
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
