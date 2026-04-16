@tool
extends Control

@onready var chat_scroll: ScrollContainer = $VBoxContainer/ChatScroll
@onready var message_list: VBoxContainer = $VBoxContainer/ChatScroll/MessageList
@onready var input_box: TextEdit = $VBoxContainer/InputPanel/VBoxContainer/TextEdit

@onready var session_selector: OptionButton = $VBoxContainer/HBoxContainer_top/SessionSelector
@onready var new_chat_button: Button = $VBoxContainer/HBoxContainer_top/NewChatButton
@onready var delete_chat_button: Button = $VBoxContainer/HBoxContainer_top/DeleteChatButton

@onready var clear_button: Button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/ClearButton
@onready var compress_button: Button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/CompressButton
@onready var settings_button: Button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/SettingsButton
@onready var context_ring: AIContextRing = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/ContextRing
@onready var model_selector: OptionButton = $VBoxContainer/InputPanel/VBoxContainer/Actions/ModelSelector
@onready var insert_button: Button = $VBoxContainer/InputPanel/VBoxContainer/Actions/InsertButton
@onready var stop_button: Button = $VBoxContainer/InputPanel/VBoxContainer/Actions/StopButton
@onready var debug_button: Button = $VBoxContainer/InputPanel/VBoxContainer/Actions/DebugButton
@onready var send_button: Button = $VBoxContainer/InputPanel/VBoxContainer/Actions/SendButton

@onready var settings_dialog: AcceptDialog = $SettingsDialog
@onready var api_url_input: LineEdit = $SettingsDialog/VBoxContainer/ApiUrlInput
@onready var api_key_input: LineEdit = $SettingsDialog/VBoxContainer/ApiKeyInput
@onready var model_input: LineEdit = $SettingsDialog/VBoxContainer/ModelInput

@onready var diff_dialog: AcceptDialog = $DiffDialog
@onready var diff_text: RichTextLabel = $DiffDialog/DiffText
@onready var target_dialog: AcceptDialog = get_node_or_null("TargetDialog")
@onready var target_list: ItemList = get_node_or_null("TargetDialog/VBoxContainer/TargetList")
@onready var target_preview: RichTextLabel = get_node_or_null("TargetDialog/VBoxContainer/TargetPreview")
var high_risk_dialog: ConfirmationDialog

const MAX_HISTORY_LENGTH: int = 15
const CONTEXT_COLOR_HEALTHY: Color = Color("56b6c2")
const CONTEXT_COLOR_WATCH: Color = Color("d19a66")
const CONTEXT_COLOR_LIMIT: Color = Color("e06c75")
const CONTEXT_COLOR_IDLE: Color = Color("5c6370")

var net_client: AINetClient = AINetClient.new()
var storage: AIStorage = AIStorage.new()
var renderer: AIChatRenderer = AIChatRenderer.new()
var runtime: AIRuntime = AIRuntime.new()
var provider_profiles: AIProviderProfiles = AIProviderProfiles.new()
var action_executor: AIActionExecutor = AIActionExecutor.new()
var project_indexer: AIProjectIndexer = AIProjectIndexer.new()
var model_profiles: Dictionary = {}

var current_api_url: String = ""
var current_api_key: String = ""
var current_model: String = ""
var all_sessions: Dictionary = {}
var current_session_id: String = ""
var is_compressing: bool = false

var stream_temp_node: RichTextLabel = null
var current_ai_content: String = ""
var current_ai_reasoning: String = ""
var runtime_debug_label: RichTextLabel
var pending_action_candidates: Array = []
var context_preview_hidden: bool = false
var last_runtime_debug_bbcode: String = ""
var suppress_target_dialog_cancel: bool = false
var suppress_diff_dialog_cancel: bool = false
var suppress_high_risk_dialog_cancel: bool = false

func _ready() -> void:
	add_child(net_client)
	add_child(storage)
	add_child(renderer)

	renderer.setup(chat_scroll, message_list)
	model_profiles = provider_profiles.get_profiles()
	runtime.setup(net_client, MAX_HISTORY_LENGTH, action_executor, project_indexer)

	net_client.chunk_received.connect(_on_chunk_received)
	net_client.stream_completed.connect(_on_stream_completed)
	net_client.stream_failed.connect(_on_stream_failed)
	renderer.response_action_requested.connect(_on_response_action_requested)
	_ensure_target_dialog_nodes()
	_ensure_high_risk_dialog()

	send_button.pressed.connect(_on_send_pressed)
	stop_button.pressed.connect(_on_stop_pressed)
	insert_button.visible = false
	settings_button.pressed.connect(_on_settings_button_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	compress_button.pressed.connect(_on_compress_pressed)
	input_box.text_changed.connect(_refresh_context_meter)
	new_chat_button.pressed.connect(_on_new_chat_pressed)
	session_selector.item_selected.connect(_on_session_selected)
	settings_dialog.confirmed.connect(_on_settings_dialog_confirmed)
	delete_chat_button.pressed.connect(_on_delete_chat_pressed)
	model_selector.item_selected.connect(_on_model_selected)
	debug_button.pressed.connect(_on_debug_pressed)
	diff_dialog.confirmed.connect(_on_diff_confirmed)
	diff_dialog.visibility_changed.connect(_on_diff_dialog_visibility_changed)
	if target_dialog != null:
		target_dialog.confirmed.connect(_on_target_dialog_confirmed)
		target_dialog.visibility_changed.connect(_on_target_dialog_visibility_changed)
	if target_list != null:
		target_list.item_selected.connect(_on_target_candidate_selected)
	if context_ring != null:
		context_ring.activated.connect(_on_context_ring_activated)
	if high_risk_dialog != null:
		high_risk_dialog.confirmed.connect(_on_high_risk_dialog_confirmed)
		high_risk_dialog.visibility_changed.connect(_on_high_risk_dialog_visibility_changed)

	stop_button.visible = false
	_setup_modern_ui()
	_setup_runtime_debug_label()
	_setup_review_dialogs()
	_sync_runtime_state_ui()

	var config: Dictionary = storage.load_config()
	current_api_url = String(config.get("url", "https://api.deepseek.com/chat/completions"))
	current_api_key = String(config.get("key", ""))
	current_model = String(config.get("model", "deepseek-chat"))
	_setup_model_selector()

	all_sessions = storage.load_all_sessions()
	if all_sessions.is_empty():
		_on_new_chat_pressed()
	else:
		_sync_session_ui()
		_load_session_to_ui(all_sessions.keys().back())

	_refresh_context_meter()

func _setup_modern_ui() -> void:
	var gui = EditorInterface.get_base_control()
	var all_icon_buttons: Dictionary = {
		new_chat_button: "Add",
		delete_chat_button: "Remove",
		clear_button: "Clear",
		compress_button: "Scissors",
		settings_button: "Tools",
		insert_button: "Edit",
		send_button: "Play",
		stop_button: "Stop",
		debug_button: "Debug",
	}

	for button in all_icon_buttons:
		button.icon = gui.get_theme_icon(all_icon_buttons[button], "EditorIcons")
		button.text = ""
		button.flat = true
		button.custom_minimum_size = Vector2(28, 28)
		_set_tooltip(button)

func _setup_runtime_debug_label() -> void:
	var container: VBoxContainer = $VBoxContainer/InputPanel/VBoxContainer
	var actions: HBoxContainer = $VBoxContainer/InputPanel/VBoxContainer/Actions

	runtime_debug_label = RichTextLabel.new()
	runtime_debug_label.bbcode_enabled = true
	runtime_debug_label.fit_content = true
	runtime_debug_label.selection_enabled = true
	runtime_debug_label.scroll_active = false
	runtime_debug_label.visible = false
	runtime_debug_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	container.add_child(runtime_debug_label)
	container.move_child(runtime_debug_label, actions.get_index())

func _setup_review_dialogs() -> void:
	var gui = EditorInterface.get_base_control()
	if gui.has_theme_font("source", "EditorFonts"):
		diff_text.add_theme_font_override("normal_font", gui.get_theme_font("source", "EditorFonts"))
		if target_preview != null:
			target_preview.add_theme_font_override("normal_font", gui.get_theme_font("source", "EditorFonts"))

	if target_preview != null:
		target_preview.fit_content = false
		target_preview.scroll_active = true
		target_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _ensure_high_risk_dialog() -> void:
	if high_risk_dialog != null:
		return

	high_risk_dialog = ConfirmationDialog.new()
	high_risk_dialog.name = "HighRiskDialog"
	high_risk_dialog.title = "Confirm High-Risk Change"
	high_risk_dialog.ok_button_text = "Apply Anyway"
	high_risk_dialog.dialog_text = "This change needs an additional confirmation."
	add_child(high_risk_dialog)

func _ensure_target_dialog_nodes() -> void:
	if target_dialog == null:
		target_dialog = AcceptDialog.new()
		target_dialog.name = "TargetDialog"
		target_dialog.title = "Choose Apply Target"
		target_dialog.size = Vector2i(760, 520)
		target_dialog.ok_button_text = "Review Diff"
		add_child(target_dialog)

	var container: VBoxContainer = null
	if target_dialog.has_node("VBoxContainer"):
		container = target_dialog.get_node("VBoxContainer")
	else:
		container = VBoxContainer.new()
		container.name = "VBoxContainer"
		container.offset_left = 8.0
		container.offset_top = 8.0
		container.offset_right = 752.0
		container.offset_bottom = 471.0
		container.add_theme_constant_override("separation", 8)
		target_dialog.add_child(container)

	if not container.has_node("TargetHint"):
		var target_hint: Label = Label.new()
		target_hint.name = "TargetHint"
		target_hint.text = "Choose the code block that should receive the AI change."
		container.add_child(target_hint)

	if target_list == null:
		if container.has_node("TargetList"):
			target_list = container.get_node("TargetList")
		else:
			target_list = ItemList.new()
			target_list.name = "TargetList"
			target_list.custom_minimum_size = Vector2(0, 180)
			target_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
			container.add_child(target_list)

	if target_preview == null:
		if container.has_node("TargetPreview"):
			target_preview = container.get_node("TargetPreview")
		else:
			target_preview = RichTextLabel.new()
			target_preview.name = "TargetPreview"
			target_preview.custom_minimum_size = Vector2(0, 220)
			target_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL
			target_preview.bbcode_enabled = true
			target_preview.selection_enabled = true
			container.add_child(target_preview)

func _set_tooltip(button: Button) -> void:
	if button == insert_button:
		button.tooltip_text = "Insert the latest generated code block"
	elif button == send_button:
		button.tooltip_text = "Send (Enter)"
	elif button == stop_button:
		button.tooltip_text = "Stop generation"
	elif button == clear_button:
		button.tooltip_text = "Clear the current session"
	elif button == compress_button:
		button.tooltip_text = "Compact session memory"
	elif button == settings_button:
		button.tooltip_text = "API settings"
	elif button == new_chat_button:
		button.tooltip_text = "Create a new chat"
	elif button == delete_chat_button:
		button.tooltip_text = "Delete this chat"
	elif button == debug_button:
		button.tooltip_text = "Analyze the copied error"

func _sync_runtime_state_ui() -> void:
	var busy: bool = runtime.is_busy()
	send_button.visible = not busy
	stop_button.visible = busy
	new_chat_button.disabled = busy
	clear_button.disabled = busy
	model_selector.disabled = busy
	debug_button.disabled = busy
	compress_button.disabled = busy
	delete_chat_button.disabled = busy
	session_selector.disabled = busy

func _update_runtime_debug_label(bbcode_text: String) -> void:
	if runtime_debug_label == null:
		return

	last_runtime_debug_bbcode = bbcode_text.strip_edges()
	var should_show: bool = not bbcode_text.strip_edges().is_empty()
	runtime_debug_label.visible = should_show and not context_preview_hidden
	_set_rich_text_bbcode(runtime_debug_label, bbcode_text)

func _refresh_context_meter() -> void:
	if context_ring == null:
		return

	if current_session_id.is_empty() or not all_sessions.has(current_session_id):
		_apply_context_preview({}, {})
		_update_runtime_debug_label("")
		return

	var preview: Dictionary = runtime.preview_chat_request(input_box.text, all_sessions[current_session_id], {
		"url": current_api_url,
		"model": current_model,
	})
	_apply_context_preview(preview.get("usage", {}), preview.get("preview", {}))
	_update_runtime_debug_label(String(preview.get("preview_bbcode", "")))

func _apply_context_usage(usage: Dictionary) -> void:
	if usage.is_empty():
		_apply_empty_context_ring("Open or create a session to inspect context usage.")
		return

	var raw_ratio: float = float(usage.get("ratio", 0.0))
	var risk_level: String = String(usage.get("risk_level", "healthy"))
	_update_context_ring_visuals(raw_ratio, risk_level, usage)
	context_ring.tooltip_text = _append_context_ring_hint(_build_context_tooltip(usage))

func _get_context_accent(risk_level: String) -> Color:
	match risk_level:
		"watch", "compress":
			return CONTEXT_COLOR_WATCH
		"limit":
			return CONTEXT_COLOR_LIMIT
		_:
			return CONTEXT_COLOR_HEALTHY

func _build_context_tooltip(usage: Dictionary) -> String:
	var lines: Array = []
	lines.append("Context Usage")
	lines.append("Status: %s" % String(usage.get("status_label", "Context is healthy")))
	lines.append("Estimated input: %s / %s tokens" % [
		_format_token_count(int(usage.get("estimated_input_tokens", 0))),
		_format_token_count(int(usage.get("input_budget_tokens", 0))),
	])
	lines.append("Reserved output: %s tokens" % _format_token_count(int(usage.get("estimated_output_tokens", 0))))
	lines.append("Context window: %s tokens" % _format_token_count(int(usage.get("context_window", 0))))
	lines.append("Characters: %d" % int(usage.get("char_count", 0)))
	if bool(usage.get("over_budget", false)):
		lines.append("Warning: the current request is over the input budget. Compact the session before sending.")

	var sources: Array = usage.get("sources", [])
	if not sources.is_empty():
		lines.append("")
		lines.append("Top Sources")
		var count: int = mini(4, sources.size())
		for index in range(count):
			var source: Dictionary = sources[index]
			lines.append("- %s: %s tokens, %d chars" % [
				String(source.get("name", "Unknown Source")),
				_format_token_count(int(source.get("tokens", 0))),
				int(source.get("chars", 0)),
			])

	return "\n".join(lines)

func _apply_context_preview(usage: Dictionary, preview: Dictionary) -> void:
	if usage.is_empty():
		_apply_empty_context_ring("No context preview is available yet.")
		return

	var raw_ratio: float = float(usage.get("ratio", 0.0))
	var risk_level: String = String(usage.get("risk_level", "healthy"))
	_update_context_ring_visuals(raw_ratio, risk_level, usage)
	context_ring.tooltip_text = _append_context_ring_hint(_build_context_preview_tooltip(usage, preview))

func _build_context_preview_tooltip(usage: Dictionary, preview: Dictionary) -> String:
	var lines: Array = []
	lines.append("Context Preview")
	lines.append("Status: %s" % String(usage.get("status_label", "Context is healthy")))
	lines.append("Estimated input: %s / %s tokens" % [
		_format_token_count(int(usage.get("estimated_input_tokens", 0))),
		_format_token_count(int(usage.get("input_budget_tokens", 0))),
	])
	lines.append("Reserved output: %s tokens" % _format_token_count(int(usage.get("estimated_output_tokens", 0))))
	lines.append("Context window: %s tokens" % _format_token_count(int(usage.get("context_window", 0))))
	lines.append("Characters: %d" % int(usage.get("char_count", 0)))
	lines.append("Selected context items: %d" % int(usage.get("selected_context_count", 0)))
	lines.append("Dropped context items: %d" % int(usage.get("dropped_context_count", 0)))
	if bool(usage.get("over_budget", false)):
		lines.append("Warning: this preview is already over budget.")

	var profile: Dictionary = preview.get("profile", {})
	var capabilities: Dictionary = preview.get("provider_capabilities", {})
	if not profile.is_empty():
		lines.append("")
		lines.append("Provider: %s" % _localize_provider_name(String(profile.get("name", profile.get("provider", "unknown")))) )
		lines.append("Capabilities: system=%s, reasoning=%s, tools=%s" % [
			"yes" if bool(capabilities.get("supports_system_role", false)) else "no",
			"yes" if bool(capabilities.get("supports_reasoning_delta", false)) else "no",
			"yes" if bool(capabilities.get("supports_tool_calls", false)) else "no",
		])

	var rules: Dictionary = preview.get("rules", {})
	var rule_sources: Array = []
	for source in rules.get("sources", []):
		if bool(source.get("exists", false)):
			rule_sources.append(_localize_rule_source(String(source.get("path", ""))))
	if not rule_sources.is_empty():
		lines.append("")
		lines.append("Rule Sources")
		for index in range(mini(3, rule_sources.size())):
			lines.append("- %s" % rule_sources[index])

	var sources: Array = usage.get("sources", [])
	if not sources.is_empty():
		lines.append("")
		lines.append("Top Sources")
		for index in range(mini(4, sources.size())):
			var source: Dictionary = sources[index]
			lines.append("- %s: %s tokens, %d chars" % [
				String(source.get("name", "Unknown Source")),
				_format_token_count(int(source.get("tokens", 0))),
				int(source.get("chars", 0)),
			])

	var dropped_items: Array = preview.get("dropped_context_items", [])
	if not dropped_items.is_empty():
		lines.append("")
		lines.append("Dropped Context")
		for index in range(mini(3, dropped_items.size())):
			var item: Dictionary = dropped_items[index]
			lines.append("- %s (%s)" % [
				String(item.get("title", item.get("kind", "Context"))),
				_localize_dropped_reason(String(item.get("reason", "dropped"))),
			])

	return "\n".join(lines)

func _update_context_ring_visuals(raw_ratio: float, risk_level: String, usage: Dictionary) -> void:
	var display_ratio: float = clampf(raw_ratio, 0.0, 1.0)
	context_ring.value = display_ratio
	context_ring.fill_color = _get_context_accent(risk_level)
	context_ring.risk_level = risk_level
	context_ring.display_text = _build_context_ring_display_text(raw_ratio, usage)

func _apply_empty_context_ring(message: String) -> void:
	context_ring.value = 0.0
	context_ring.fill_color = CONTEXT_COLOR_IDLE
	context_ring.risk_level = "idle"
	context_ring.display_text = "--"
	context_ring.tooltip_text = _append_context_ring_hint(message)

func _build_context_ring_display_text(raw_ratio: float, usage: Dictionary) -> String:
	if bool(usage.get("over_budget", false)):
		return "!"

	var percent: int = int(round(clampf(raw_ratio, 0.0, 1.0) * 100.0))
	if raw_ratio > 0.0 and percent == 0:
		return "<1"
	return str(percent)

func _append_context_ring_hint(base_text: String) -> String:
	var cleaned: String = base_text.strip_edges()
	if cleaned.is_empty():
		cleaned = "Context status"
	return "%s\n\nClick the ring to toggle the request preview." % cleaned

func _localize_provider_name(name: String) -> String:
	if name == "OpenAI Compatible Chat":
		return "OpenAI Compatible Chat"
	if name == "DeepSeek Chat (V3)":
		return "DeepSeek Chat (V3)"
	if name == "DeepSeek Reasoner (R1)":
		return "DeepSeek Reasoner (R1)"
	return name

func _localize_rule_source(path: String) -> String:
	if path == "builtin://default":
		return "Built-in Default Rule"
	return path

func _localize_dropped_reason(reason: String) -> String:
	match reason:
		"budget_exhausted":
			return "Budget Exhausted"
		"too_large_for_budget":
			return "Too Large For Budget"
		_:
			return reason

func _on_context_ring_activated() -> void:
	context_preview_hidden = not context_preview_hidden
	if runtime_debug_label == null:
		return
	runtime_debug_label.visible = not context_preview_hidden and not last_runtime_debug_bbcode.is_empty()

func _format_token_count(value: int) -> String:
	if value >= 1000:
		return "%.1fk" % (float(value) / 1000.0)
	return str(value)

func _on_send_pressed() -> void:
	if not all_sessions.has(current_session_id):
		return

	var prompt: String = input_box.text.strip_edges()
	var result: Dictionary = runtime.start_chat_request(prompt, all_sessions[current_session_id], {
		"url": current_api_url,
		"key": current_api_key,
		"model": current_model,
	})

	if not bool(result.get("ok", false)):
		var failure_message: String = str(result.get("message", "")).strip_edges()
		if not failure_message.is_empty():
			renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % failure_message)
		_update_runtime_debug_label(String(result.get("preview_bbcode", result.get("debug_label", ""))))
		_sync_runtime_state_ui()
		return

	renderer.render_message("user", prompt)
	input_box.text = ""
	_sync_runtime_state_ui()
	_refresh_context_meter()
	_update_runtime_debug_label(String(result.get("preview_bbcode", result.get("debug_label", ""))))
	if bool(result.get("auto_compacted", false)):
		var memory_tip = renderer.create_system_tip("[color=#7f848e][i]Older chat history was compacted into memory.[/i][/color]")
		message_list.add_child(memory_tip)

	current_ai_content = ""
	current_ai_reasoning = ""
	stream_temp_node = renderer.create_stream_node()

func _on_chunk_received(content_delta: String, reasoning_delta: String) -> void:
	if not reasoning_delta.is_empty():
		current_ai_reasoning += reasoning_delta
	if not content_delta.is_empty():
		current_ai_content += content_delta
	renderer.update_stream_node(stream_temp_node, current_ai_content, current_ai_reasoning)

func _on_stream_completed() -> void:
	runtime.mark_stream_completed()
	_finish_streaming(false)

func _on_stream_failed(error_message: String) -> void:
	if is_instance_valid(stream_temp_node):
		stream_temp_node.queue_free()

	runtime.mark_stream_failed()
	_sync_runtime_state_ui()

	var final_message: String = "[color=#E06C75]%s[/color]" % error_message
	if not current_ai_content.is_empty():
		final_message = current_ai_content + "\n\n[color=#E06C75][i](%s)[/i][/color]" % error_message

	current_ai_content = final_message
	current_ai_reasoning = ""
	_finish_streaming(true)

func _on_stop_pressed() -> void:
	net_client.stop_stream()
	runtime.mark_stream_stopped()
	if current_ai_content.is_empty():
		current_ai_content = "[color=#E06C75][i](Stopped manually)[/i][/color]"
	else:
		current_ai_content += "\n\n[color=#E06C75][i](Stopped manually)[/i][/color]"
	_finish_streaming(true)

func _finish_streaming(is_forced: bool) -> void:
	if is_instance_valid(stream_temp_node):
		stream_temp_node.queue_free()

	_sync_runtime_state_ui()

	if not current_ai_content.is_empty() or is_forced:
		var response_plan: Dictionary = runtime.plan_assistant_response(current_ai_content)
		all_sessions[current_session_id]["history"].append({
			"role": "assistant",
			"content": current_ai_content,
		})
		renderer.render_message("assistant", current_ai_content, current_ai_reasoning, response_plan)
		runtime.record_assistant_response(all_sessions[current_session_id], current_ai_content)
		all_sessions[current_session_id]["title"] = storage.get_updated_title(
			all_sessions[current_session_id]["history"],
			all_sessions[current_session_id]["title"]
		)
		_sync_session_ui()

	insert_button.disabled = renderer.last_generated_code == ""
	storage.save_sessions(all_sessions)
	_refresh_context_meter()

func _on_compress_pressed() -> void:
	if current_session_id == "" or all_sessions.is_empty() or is_compressing:
		return

	is_compressing = true
	runtime.begin_manual_operation()
	_sync_runtime_state_ui()

	var result: Dictionary = runtime.compact_session(all_sessions[current_session_id], "manual")

	is_compressing = false
	runtime.finish_manual_operation()
	_sync_runtime_state_ui()

	if not bool(result.get("performed", false)):
		var short_tip = renderer.create_system_tip("[color=#888888][i]This session is too short to compact.[/i][/color]")
		message_list.add_child(short_tip)
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(short_tip):
			short_tip.queue_free()
		return

	_load_session_to_ui(current_session_id)
	var summary_text: String = String(result.get("summary_text", ""))
	if summary_text.is_empty():
		summary_text = "Structured memory was created."
	var compact_tip = renderer.create_system_tip("[color=#E5C07B][i]Session compacted into structured memory:\n%s[/i][/color]" % summary_text)
	message_list.add_child(compact_tip)
	storage.save_sessions(all_sessions)
	_refresh_context_meter()

func get_smart_script_context() -> Dictionary:
	return runtime.get_script_context()

func _on_response_action_requested(block_index: int) -> void:
	if current_session_id.is_empty() or not all_sessions.has(current_session_id):
		return

	var result: Dictionary = runtime.prepare_response_action(
		block_index,
		all_sessions[current_session_id],
		_build_editor_context()
	)
	_present_action_result(result)

func _present_action_result(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % str(result.get("message", "This code block cannot be applied.")))
		return

	var info_message: String = str(result.get("info_message", "")).strip_edges()
	if not info_message.is_empty():
		renderer.render_message("assistant", "[color=#56B6C2][i]%s[/i][/color]" % info_message)

	match str(result.get("disposition", "")):
		"select_target":
			_show_target_candidates(result.get("candidates", []), result.get("dialog", {}))
		"review":
			_show_action_review(result.get("review", {}))
		_:
			renderer.render_message("assistant", "[color=#E06C75]The runtime returned an unknown action disposition.[/color]")

func _show_target_candidates(candidates: Array, dialog_data: Dictionary = {}) -> void:
	if target_dialog == null or target_list == null or target_preview == null:
		renderer.render_message("assistant", "[color=#E06C75]Target selection UI is unavailable. Please reload the plugin and try again.[/color]")
		return

	pending_action_candidates = candidates.duplicate(true)
	target_list.clear()
	target_dialog.title = str(dialog_data.get("title", "Choose Apply Target"))
	target_dialog.ok_button_text = str(dialog_data.get("confirm_text", "Review Change"))

	for candidate in pending_action_candidates:
		if not (candidate is Dictionary):
			continue
		target_list.add_item(str(candidate.get("selection_label", candidate.get("target_label", candidate.get("label", "Target")))))

	if target_list.get_item_count() > 0:
		target_list.select(0)
		_render_target_candidate_preview(0)

	_sync_runtime_state_ui()
	target_dialog.popup_centered_clamped(Vector2(760, 520))

func _on_target_candidate_selected(index: int) -> void:
	_render_target_candidate_preview(index)

func _render_target_candidate_preview(index: int) -> void:
	if index < 0 or index >= pending_action_candidates.size():
		_set_rich_text_bbcode(target_preview, "")
		return

	var action: Dictionary = pending_action_candidates[index]
	_set_rich_text_bbcode(target_preview, str(action.get("preview_bbcode", "")))

func _on_target_dialog_confirmed() -> void:
	var selected_items: PackedInt32Array = target_list.get_selected_items()
	var selected_index: int = 0
	if selected_items.size() > 0:
		selected_index = selected_items[0]

	if selected_index < 0 or selected_index >= pending_action_candidates.size():
		return

	var action: Dictionary = pending_action_candidates[selected_index]
	var review_result: Dictionary = runtime.review_action_candidate(action)
	suppress_target_dialog_cancel = true
	pending_action_candidates.clear()
	target_dialog.hide()
	_present_action_result(review_result)

func _show_action_review(review_data: Dictionary) -> void:
	diff_dialog.title = str(review_data.get("dialog_title", "Review Change"))
	diff_dialog.ok_button_text = str(review_data.get("confirm_text", "Apply Change"))
	diff_text.add_theme_constant_override("line_separation", 10)
	diff_text.add_theme_constant_override("outline_size", 0)
	_set_rich_text_bbcode(diff_text, str(review_data.get("bbcode", "")))
	diff_dialog.popup_centered_clamped(Vector2(900, 700))

func _on_diff_confirmed() -> void:
	var pending: Dictionary = runtime.get_pending_action()
	if pending.is_empty():
		return

	var review_data: Dictionary = pending.get("review_data", {})
	if bool(review_data.get("requires_secondary_confirmation", false)):
		suppress_diff_dialog_cancel = true
		_show_high_risk_dialog(review_data)
		return

	suppress_diff_dialog_cancel = true
	diff_dialog.hide()
	_run_pending_action()

func _on_diff_dialog_visibility_changed() -> void:
	if diff_dialog.visible:
		return
	if suppress_diff_dialog_cancel:
		suppress_diff_dialog_cancel = false
		return
	if runtime.get_pending_action().is_empty():
		return
	runtime.cancel_action_review()
	_sync_runtime_state_ui()

func _on_target_dialog_visibility_changed() -> void:
	if target_dialog.visible:
		return
	if suppress_target_dialog_cancel:
		suppress_target_dialog_cancel = false
		return
	pending_action_candidates.clear()
	if runtime.get_state() == AIRuntime.STATE_AWAITING_ACTION_CONFIRMATION and runtime.get_pending_action().is_empty():
		runtime.finish_manual_operation()
		_sync_runtime_state_ui()

func _run_pending_action() -> void:
	var result: Dictionary = runtime.execute_pending_action(_build_editor_context())
	_sync_runtime_state_ui()
	if not bool(result.get("ok", false)):
		renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % str(result.get("error", "Failed to apply code.")))
		return

	var target_path: String = str(result.get("target_path", "")).strip_edges()
	if not target_path.is_empty():
		_focus_target_resource(target_path)

	if all_sessions.has(current_session_id):
		if not all_sessions[current_session_id].has("action_log") or not (all_sessions[current_session_id]["action_log"] is Array):
			all_sessions[current_session_id]["action_log"] = []
		all_sessions[current_session_id]["action_log"].append(result.get("log_entry", {}))
		storage.save_sessions(all_sessions)

func _get_active_code_edit() -> CodeEdit:
	var script_editor = EditorInterface.get_script_editor()
	var current_editor = null
	if script_editor != null:
		current_editor = script_editor.get_current_editor()
	if current_editor and current_editor.get_base_editor() is CodeEdit:
		return current_editor.get_base_editor()
	return null

func _get_active_script_path() -> String:
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

func _build_editor_context() -> Dictionary:
	var context: Dictionary = {
		"code_edit": null,
		"active_script_path": _get_active_script_path(),
		"active_text": "",
		"caret_line": -1,
		"selection_range": {},
	}

	var code_edit: CodeEdit = _get_active_code_edit()
	if code_edit == null:
		return context

	context["code_edit"] = code_edit
	context["active_text"] = code_edit.text
	context["caret_line"] = code_edit.get_caret_line()
	if code_edit.has_selection():
		context["selection_range"] = {
			"original_text": code_edit.get_selected_text(),
			"start_line": code_edit.get_selection_from_line(),
			"end_line": code_edit.get_selection_to_line(),
			"start_column": code_edit.get_selection_from_column(),
			"end_column": code_edit.get_selection_to_column(),
		}
	return context

func _show_high_risk_dialog(review_data: Dictionary) -> void:
	if high_risk_dialog == null:
		renderer.render_message("assistant", "[color=#E06C75]High-risk confirmation UI is unavailable. Please reload the plugin and try again.[/color]")
		return

	high_risk_dialog.title = str(review_data.get("secondary_confirmation_title", "Confirm High-Risk Change"))
	high_risk_dialog.dialog_text = str(review_data.get("secondary_confirmation_message", "This change requires an additional confirmation."))
	high_risk_dialog.popup_centered()

func _on_high_risk_dialog_confirmed() -> void:
	suppress_high_risk_dialog_cancel = true
	runtime.mark_pending_action_secondary_confirmed()
	high_risk_dialog.hide()
	_run_pending_action()

func _on_high_risk_dialog_visibility_changed() -> void:
	if high_risk_dialog == null or high_risk_dialog.visible:
		return
	if suppress_high_risk_dialog_cancel:
		suppress_high_risk_dialog_cancel = false
		return
	if runtime.get_pending_action().is_empty():
		return
	runtime.cancel_action_review()
	_sync_runtime_state_ui()

func _focus_target_resource(target_script_path: String) -> void:
	if target_script_path.is_empty():
		return
	var resource: Resource = ResourceLoader.load(target_script_path)
	if resource != null:
		EditorInterface.edit_resource(resource)

func _on_settings_dialog_confirmed() -> void:
	current_api_url = api_url_input.text
	current_api_key = api_key_input.text
	current_model = model_input.text
	_setup_model_selector()
	storage.save_config(current_api_url, current_api_key, current_model)
	_refresh_context_meter()

func _load_session_to_ui(id: String) -> void:
	current_session_id = id
	renderer.clear_chat()
	for message in all_sessions[id]["history"]:
		renderer.render_message(message["role"], message["content"])
	_refresh_context_meter()

func _on_clear_pressed() -> void:
	if all_sessions.has(current_session_id):
		all_sessions[current_session_id]["history"].clear()
		_load_session_to_ui(current_session_id)
		_refresh_context_meter()

func _on_new_chat_pressed() -> void:
	current_session_id = str(Time.get_unix_time_from_system())
	all_sessions[current_session_id] = {
		"title": "New Chat " + Time.get_time_string_from_system().left(5),
		"history": [],
		"memory": {
			"core_goals": [],
			"decided_architecture": [],
			"open_questions": [],
			"bug_notes": [],
			"recent_files": [],
			"last_compacted_at": "",
			"last_compact_mode": "",
			"summary_text": "",
		},
		"action_log": [],
		"schema_version": 2,
	}
	_sync_session_ui()
	_load_session_to_ui(current_session_id)
	_refresh_context_meter()

func _on_delete_chat_pressed() -> void:
	all_sessions.erase(current_session_id)
	if not all_sessions.is_empty():
		current_session_id = String(all_sessions.keys().back())
	else:
		current_session_id = ""
	if current_session_id == "":
		_on_new_chat_pressed()
	else:
		_load_session_to_ui(current_session_id)

	_sync_session_ui()
	storage.save_sessions(all_sessions)
	_refresh_context_meter()

func _on_session_selected(index: int) -> void:
	var ids = all_sessions.keys()
	ids.reverse()
	current_session_id = ids[index]
	_load_session_to_ui(current_session_id)
	_refresh_context_meter()

func _sync_session_ui() -> void:
	session_selector.clear()
	var ids = all_sessions.keys()
	ids.reverse()
	for id in ids:
		session_selector.add_item(all_sessions[id]["title"])
	for index in ids.size():
		if ids[index] == current_session_id:
			session_selector.selected = index
			break

func _on_model_selected(index: int) -> void:
	current_model = model_selector.get_item_metadata(index)
	_refresh_context_meter()

func _setup_model_selector() -> void:
	model_selector.clear()
	model_profiles = provider_profiles.get_profiles()
	var keys: Array = provider_profiles.get_profile_keys()
	if not current_model.is_empty() and not model_profiles.has(current_model):
		model_profiles[current_model] = provider_profiles.resolve_profile(current_model, current_api_url)
	if not current_model.is_empty() and not keys.has(current_model):
		keys.append(current_model)

	for index in keys.size():
		var key = keys[index]
		model_selector.add_item(model_profiles[key]["name"], index)
		model_selector.set_item_metadata(index, key)
		if key == current_model:
			model_selector.select(index)

func _on_settings_button_pressed() -> void:
	api_url_input.text = current_api_url
	api_key_input.text = current_api_key
	model_input.text = current_model
	settings_dialog.popup_centered()

func _input(event) -> void:
	if input_box.has_focus() and event is InputEventKey and event.pressed and event.keycode == KEY_ENTER and not event.shift_pressed:
		_on_send_pressed()
		get_viewport().set_input_as_handled()

func _on_debug_pressed() -> void:
	var error_text: String = DisplayServer.clipboard_get().strip_edges()
	if error_text == "":
		renderer.render_message("assistant", "[color=#E5C07B]Clipboard is empty. Copy an error from the Godot console first, then try again.[/color]")
		return

	var prompt: String = "I hit the following error while running the game:\n```text\n%s\n```\n" % error_text
	var context_data: Dictionary = get_smart_script_context()
	if not String(context_data.get("text", "")).is_empty():
		prompt += "Related code snippet:\n```gdscript\n%s\n```\n" % String(context_data.get("text", ""))

	prompt += "Please analyze the root cause and suggest a fix."
	input_box.text = prompt
	_on_send_pressed()

func _set_rich_text_bbcode(label: RichTextLabel, bbcode_text: String) -> void:
	if label == null:
		return

	label.clear()
	if bbcode_text.is_empty():
		return
	label.append_text(bbcode_text)
