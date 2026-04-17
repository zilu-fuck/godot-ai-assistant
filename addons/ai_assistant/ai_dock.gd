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
var undo_button: Button

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
var scene_save_dialog: FileDialog
var review_pick_path_button: Button

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
var saved_model_configs: Dictionary = {}

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
var context_preview_hidden: bool = true
var last_runtime_debug_bbcode: String = ""
var suppress_target_dialog_cancel: bool = false
var suppress_diff_dialog_cancel: bool = false
var suppress_high_risk_dialog_cancel: bool = false
var restore_review_after_scene_save_dialog: bool = false
var pending_diff_secondary_confirmation: bool = false

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
	_ensure_scene_save_dialog()
	_ensure_undo_button()

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
	saved_model_configs = _normalize_saved_model_configs(config.get("profiles", {}))
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
	if undo_button != null:
		all_icon_buttons[undo_button] = "Undo"

	for button in all_icon_buttons:
		button.icon = gui.get_theme_icon(all_icon_buttons[button], "EditorIcons")
		button.text = ""
		button.flat = true
		button.custom_minimum_size = Vector2(28, 28)
		_set_tooltip(button)

func _ensure_undo_button() -> void:
	if undo_button != null:
		return

	var actions: HBoxContainer = $VBoxContainer/InputPanel/VBoxContainer/Actions
	undo_button = Button.new()
	undo_button.name = "UndoButton"
	undo_button.flat = true
	undo_button.visible = true
	undo_button.disabled = true
	actions.add_child(undo_button)
	actions.move_child(undo_button, max(0, send_button.get_index()))
	undo_button.pressed.connect(_on_undo_pressed)

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
	diff_dialog.dialog_hide_on_ok = false
	if gui.has_theme_font("source", "EditorFonts"):
		diff_text.add_theme_font_override("normal_font", gui.get_theme_font("source", "EditorFonts"))
		if target_preview != null:
			target_preview.add_theme_font_override("normal_font", gui.get_theme_font("source", "EditorFonts"))

	if target_preview != null:
		target_preview.fit_content = false
		target_preview.scroll_active = true
		target_preview.size_flags_vertical = Control.SIZE_EXPAND_FILL

	if review_pick_path_button == null and diff_dialog.has_method("add_button"):
		review_pick_path_button = diff_dialog.add_button("选择保存位置", true)
		review_pick_path_button.pressed.connect(_on_review_pick_path_pressed)
		review_pick_path_button.visible = false

func _ensure_high_risk_dialog() -> void:
	if high_risk_dialog != null:
		return

	high_risk_dialog = ConfirmationDialog.new()
	high_risk_dialog.name = "HighRiskDialog"
	high_risk_dialog.dialog_hide_on_ok = false
	high_risk_dialog.title = "确认高风险改动"
	high_risk_dialog.ok_button_text = "仍然应用"
	high_risk_dialog.dialog_text = "这个改动需要额外确认。"
	add_child(high_risk_dialog)

func _ensure_scene_save_dialog() -> void:
	if scene_save_dialog != null:
		return

	scene_save_dialog = FileDialog.new()
	scene_save_dialog.name = "SceneSaveDialog"
	scene_save_dialog.access = FileDialog.ACCESS_RESOURCES
	scene_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	scene_save_dialog.title = "选择场景保存位置"
	scene_save_dialog.add_filter("*.tscn", "Godot 场景")
	scene_save_dialog.file_selected.connect(_on_scene_save_path_selected)
	scene_save_dialog.visibility_changed.connect(_on_scene_save_dialog_visibility_changed)
	add_child(scene_save_dialog)

func _ensure_target_dialog_nodes() -> void:
	if target_dialog == null:
		target_dialog = AcceptDialog.new()
		target_dialog.name = "TargetDialog"
		target_dialog.title = "选择应用目标"
		target_dialog.size = Vector2i(760, 520)
		target_dialog.ok_button_text = "查看变更"
		add_child(target_dialog)
	target_dialog.dialog_hide_on_ok = false

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
		target_hint.text = "请选择要接收这次 AI 改动的目标。"
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
		button.tooltip_text = "插入最近一次生成的代码块"
	elif button == send_button:
		button.tooltip_text = "发送（Enter）"
	elif button == stop_button:
		button.tooltip_text = "停止生成"
	elif button == clear_button:
		button.tooltip_text = "清空当前会话"
	elif button == compress_button:
		button.tooltip_text = "压缩会话记忆"
	elif button == settings_button:
		button.tooltip_text = "API 设置"
	elif button == new_chat_button:
		button.tooltip_text = "新建会话"
	elif button == delete_chat_button:
		button.tooltip_text = "删除当前会话"
	elif button == debug_button:
		button.tooltip_text = "分析已复制的报错"
	elif button == undo_button:
		button.tooltip_text = "撤销上次 AI 改动"

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
	if undo_button != null:
		undo_button.disabled = busy or not _has_undoable_change()

func _has_undoable_change() -> bool:
	if current_session_id.is_empty() or not all_sessions.has(current_session_id):
		return false
	var session: Dictionary = all_sessions[current_session_id]
	if not session.has("rollback_log") or not (session["rollback_log"] is Array):
		return false
	for index in range(session["rollback_log"].size() - 1, -1, -1):
		var entry: Variant = session["rollback_log"][index]
		if entry is Dictionary and not bool(entry.get("rolled_back", false)):
			return true
	return false

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
		_apply_empty_context_ring("请先打开或创建一个会话，再查看上下文占用。")
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
	lines.append("上下文占用")
	lines.append("状态：%s" % String(usage.get("status_label", "上下文状态正常")))
	lines.append("预计输入：%s / %s tokens" % [
		_format_token_count(int(usage.get("estimated_input_tokens", 0))),
		_format_token_count(int(usage.get("input_budget_tokens", 0))),
	])
	lines.append("预留输出：%s tokens" % _format_token_count(int(usage.get("estimated_output_tokens", 0))))
	lines.append("上下文窗口：%s tokens" % _format_token_count(int(usage.get("context_window", 0))))
	lines.append("字符数：%d" % int(usage.get("char_count", 0)))
	if bool(usage.get("over_budget", false)):
		lines.append("警告：当前请求已经超过输入预算，请先压缩会话再发送。")

	var sources: Array = usage.get("sources", [])
	if not sources.is_empty():
		lines.append("")
		lines.append("主要来源")
		var count: int = mini(4, sources.size())
		for index in range(count):
			var source: Dictionary = sources[index]
			lines.append("- %s：%s tokens，%d chars" % [
				String(source.get("name", "未知来源")),
				_format_token_count(int(source.get("tokens", 0))),
				int(source.get("chars", 0)),
			])

	return "\n".join(lines)

func _apply_context_preview(usage: Dictionary, preview: Dictionary) -> void:
	if usage.is_empty():
		_apply_empty_context_ring("当前还没有可用的上下文预览。")
		return

	var raw_ratio: float = float(usage.get("ratio", 0.0))
	var risk_level: String = String(usage.get("risk_level", "healthy"))
	_update_context_ring_visuals(raw_ratio, risk_level, usage)
	context_ring.tooltip_text = _append_context_ring_hint(_build_context_preview_tooltip(usage, preview))

func _build_context_preview_tooltip(usage: Dictionary, preview: Dictionary) -> String:
	var lines: Array = []
	lines.append("上下文预览")
	lines.append("状态：%s" % String(usage.get("status_label", "上下文状态正常")))
	lines.append("预计输入：%s / %s tokens" % [
		_format_token_count(int(usage.get("estimated_input_tokens", 0))),
		_format_token_count(int(usage.get("input_budget_tokens", 0))),
	])
	lines.append("预留输出：%s tokens" % _format_token_count(int(usage.get("estimated_output_tokens", 0))))
	lines.append("上下文窗口：%s tokens" % _format_token_count(int(usage.get("context_window", 0))))
	lines.append("字符数：%d" % int(usage.get("char_count", 0)))
	lines.append("已选上下文项：%d" % int(usage.get("selected_context_count", 0)))
	lines.append("已丢弃上下文项：%d" % int(usage.get("dropped_context_count", 0)))
	if bool(usage.get("over_budget", false)):
		lines.append("警告：这个预览已经超出预算。")

	var profile: Dictionary = preview.get("profile", {})
	var capabilities: Dictionary = preview.get("provider_capabilities", {})
	if not profile.is_empty():
		lines.append("")
		lines.append("提供方：%s" % _localize_provider_name(String(profile.get("name", profile.get("provider", "unknown")))) )
		lines.append("能力：system=%s，reasoning=%s，tools=%s" % [
			"是" if bool(capabilities.get("supports_system_role", false)) else "否",
			"是" if bool(capabilities.get("supports_reasoning_delta", false)) else "否",
			"是" if bool(capabilities.get("supports_tool_calls", false)) else "否",
		])

	var rules: Dictionary = preview.get("rules", {})
	var rule_sources: Array = []
	for source in rules.get("sources", []):
		if bool(source.get("exists", false)):
			rule_sources.append(_localize_rule_source(String(source.get("path", ""))))
	if not rule_sources.is_empty():
		lines.append("")
		lines.append("规则来源")
		for index in range(mini(3, rule_sources.size())):
			lines.append("- %s" % rule_sources[index])

	var sources: Array = usage.get("sources", [])
	if not sources.is_empty():
		lines.append("")
		lines.append("主要来源")
		for index in range(mini(4, sources.size())):
			var source: Dictionary = sources[index]
			lines.append("- %s：%s tokens，%d chars" % [
				String(source.get("name", "未知来源")),
				_format_token_count(int(source.get("tokens", 0))),
				int(source.get("chars", 0)),
			])

	var dropped_items: Array = preview.get("dropped_context_items", [])
	if not dropped_items.is_empty():
		lines.append("")
		lines.append("已丢弃上下文")
		for index in range(mini(3, dropped_items.size())):
			var item: Dictionary = dropped_items[index]
			lines.append("- %s（%s）" % [
				String(item.get("title", item.get("kind", "上下文"))),
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
		cleaned = "上下文状态"
	return "%s\n\n点击圆环可切换请求预览。" % cleaned

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
		return "内置默认规则"
	return path

func _localize_dropped_reason(reason: String) -> String:
	match reason:
		"budget_exhausted":
			return "预算已耗尽"
		"too_large_for_budget":
			return "内容过大，超出预算"
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
	runtime.handle_stream_delta(content_delta, reasoning_delta)
	if not reasoning_delta.is_empty():
		current_ai_reasoning += reasoning_delta
	if not content_delta.is_empty():
		current_ai_content += content_delta
	renderer.update_stream_node(stream_temp_node, current_ai_content, current_ai_reasoning)

func _on_stream_completed(response_info: Dictionary = {}) -> void:
	runtime.handle_stream_completed(response_info)
	_finish_streaming(false)

func _on_stream_failed(error_message: String, failure_info: Dictionary = {}) -> void:
	var recovery: Dictionary = runtime.handle_stream_failure(error_message, failure_info)
	_update_runtime_debug_label(String(recovery.get("preview_bbcode", "")))
	if str(recovery.get("action", "")) == "restarted":
		var retry_message: String = str(recovery.get("message", "")).strip_edges()
		if not retry_message.is_empty():
			var retry_tip = renderer.create_system_tip("[color=#7f848e][i]%s[/i][/color]" % retry_message)
			message_list.add_child(retry_tip)
		_sync_runtime_state_ui()
		return

	if is_instance_valid(stream_temp_node):
		stream_temp_node.queue_free()

	_sync_runtime_state_ui()

	var final_message: String = "[color=#E06C75]%s[/color]" % error_message
	if not current_ai_content.is_empty():
		final_message = current_ai_content + "\n\n[color=#E06C75][i](%s)[/i][/color]" % error_message
	var recovery_message: String = str(recovery.get("message", "")).strip_edges()
	if not recovery_message.is_empty():
		final_message += "\n\n[color=#E5C07B][i](%s)[/i][/color]" % recovery_message

	current_ai_content = final_message
	current_ai_reasoning = ""
	_finish_streaming(true)

func _on_stop_pressed() -> void:
	net_client.stop_stream()
	runtime.mark_stream_stopped()
	if current_ai_content.is_empty():
		current_ai_content = "[color=#E06C75][i]（已手动停止）[/i][/color]"
	else:
		current_ai_content += "\n\n[color=#E06C75][i]（已手动停止）[/i][/color]"
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

func _on_undo_pressed() -> void:
	if current_session_id.is_empty() or not all_sessions.has(current_session_id):
		return

	runtime.begin_manual_operation()
	_sync_runtime_state_ui()
	var result: Dictionary = runtime.undo_last_ai_change(all_sessions[current_session_id], _build_editor_context())
	runtime.finish_manual_operation()
	_sync_runtime_state_ui()

	if not bool(result.get("ok", false)):
		renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % str(result.get("message", "Undo failed.")))
		return

	var target_paths: Array = result.get("target_paths", [])
	if not target_paths.is_empty():
		var primary_path: String = str(target_paths[0]).strip_edges()
		if not primary_path.is_empty() and FileAccess.file_exists(primary_path):
			_focus_target_resource(primary_path)

	storage.save_sessions(all_sessions)
	renderer.render_message("assistant", "[color=#56B6C2][i]Reverted the latest AI change for this session.[/i][/color]")

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
		var short_tip = renderer.create_system_tip("[color=#888888][i]当前会话太短，暂时不需要压缩。[/i][/color]")
		message_list.add_child(short_tip)
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(short_tip):
			short_tip.queue_free()
		return

	_load_session_to_ui(current_session_id)
	var summary_text: String = String(result.get("summary_text", ""))
	if summary_text.is_empty():
		summary_text = "已生成结构化记忆。"
	var compact_tip = renderer.create_system_tip("[color=#E5C07B][i]会话已压缩为结构化记忆：\n%s[/i][/color]" % summary_text)
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
		renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % str(result.get("message", "这个代码块暂时无法应用。")))
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
			renderer.render_message("assistant", "[color=#E06C75]运行时返回了未知的动作结果。[/color]")

func _show_target_candidates(candidates: Array, dialog_data: Dictionary = {}) -> void:
	if target_dialog == null or target_list == null or target_preview == null:
		renderer.render_message("assistant", "[color=#E06C75]目标选择界面不可用，请重载插件后重试。[/color]")
		return

	pending_action_candidates = candidates.duplicate(true)
	target_list.clear()
	target_dialog.title = str(dialog_data.get("title", "选择应用目标"))
	target_dialog.ok_button_text = str(dialog_data.get("confirm_text", "查看变更"))

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
	pending_diff_secondary_confirmation = false
	diff_dialog.title = str(review_data.get("dialog_title", "查看变更"))
	diff_dialog.ok_button_text = str(review_data.get("confirm_text", "应用改动"))
	diff_text.add_theme_constant_override("line_separation", 10)
	diff_text.add_theme_constant_override("outline_size", 0)
	_set_rich_text_bbcode(diff_text, str(review_data.get("bbcode", "")))
	if review_pick_path_button != null:
		review_pick_path_button.visible = runtime.can_choose_pending_scene_target_path()
	diff_dialog.popup_centered_clamped(Vector2(900, 700))

func _on_review_pick_path_pressed() -> void:
	if scene_save_dialog == null or not runtime.can_choose_pending_scene_target_path():
		return

	var pending_action: Dictionary = runtime.get_pending_action()
	var target_path: String = str(pending_action.get("target_path", "res://GeneratedScene.tscn")).strip_edges()
	if target_path.is_empty():
		target_path = "res://GeneratedScene.tscn"

	scene_save_dialog.current_dir = target_path.get_base_dir()
	scene_save_dialog.current_file = target_path.get_file()
	restore_review_after_scene_save_dialog = true
	suppress_diff_dialog_cancel = true
	diff_dialog.hide()
	call_deferred("_popup_scene_save_dialog")

func _popup_scene_save_dialog() -> void:
	if scene_save_dialog == null:
		return
	scene_save_dialog.popup_centered_ratio(0.7)

func _on_scene_save_path_selected(path: String) -> void:
	restore_review_after_scene_save_dialog = false
	var result: Dictionary = runtime.choose_pending_scene_target_path(path, _build_editor_context())
	if not bool(result.get("ok", false)):
		renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % str(result.get("message", "选择场景保存路径失败。")))
		call_deferred("_restore_pending_action_review")
		return

	var info_message: String = str(result.get("info_message", "")).strip_edges()
	if not info_message.is_empty():
		renderer.render_message("assistant", "[color=#56B6C2][i]%s 请在接下来的预览窗口中继续确认，场景才会真正保存。[/i][/color]" % info_message)
	call_deferred("_show_action_review", result.get("review", {}))

func _on_scene_save_dialog_visibility_changed() -> void:
	if scene_save_dialog == null or scene_save_dialog.visible:
		return
	if not restore_review_after_scene_save_dialog:
		return
	restore_review_after_scene_save_dialog = false
	call_deferred("_restore_pending_action_review")

func _restore_pending_action_review() -> void:
	var pending_action: Dictionary = runtime.get_pending_action()
	if pending_action.is_empty():
		return
	var review_data: Dictionary = pending_action.get("review_data", {})
	if review_data.is_empty():
		return
	_show_action_review(review_data)

func _show_inline_secondary_confirmation(review_data: Dictionary) -> void:
	diff_dialog.title = str(review_data.get("secondary_confirmation_title", "确认高风险改动"))
	diff_dialog.ok_button_text = "仍然应用"
	var message: String = str(review_data.get("secondary_confirmation_message", "这个改动需要额外确认。")).strip_edges()
	var bbcode: String = "[color=#E5C07B][b]%s[/b][/color]" % message
	var pending_action: Dictionary = runtime.get_pending_action()
	var companion_script_target_path: String = str(pending_action.get("companion_script_target_path", "")).strip_edges()
	if not companion_script_target_path.is_empty():
		bbcode += "\n\n配套脚本：%s" % companion_script_target_path
	bbcode += "\n\n[color=#7f848e]再次点击“仍然应用”后，才会真正执行这次改动。[/color]"
	_set_rich_text_bbcode(diff_text, bbcode)
	if review_pick_path_button != null:
		review_pick_path_button.visible = false

func _on_diff_confirmed() -> void:
	var pending: Dictionary = runtime.get_pending_action()
	if pending.is_empty():
		return

	var review_data: Dictionary = pending.get("review_data", {})
	if bool(review_data.get("requires_secondary_confirmation", false)):
		suppress_diff_dialog_cancel = true
		diff_dialog.hide()
		call_deferred("_show_high_risk_dialog", review_data)
		return

	suppress_diff_dialog_cancel = true
	diff_dialog.hide()
	_run_pending_action()

func _on_diff_dialog_visibility_changed() -> void:
	if diff_dialog.visible:
		return
	pending_diff_secondary_confirmation = false
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
	var pending_action: Dictionary = runtime.get_pending_action()
	if str(pending_action.get("execution_type", "")) == AIActionExecutor.EXEC_CREATE_SCENE_FILE:
		var scene_validation: Dictionary = _validate_scene_creation_content(str(pending_action.get("content", "")))
		if not bool(scene_validation.get("ok", false)):
			runtime.cancel_action_review()
			_sync_runtime_state_ui()
			renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % str(scene_validation.get("message", "场景校验失败，已阻止保存。")))
			return

	var result: Dictionary = runtime.execute_pending_action(_build_editor_context())
	_sync_runtime_state_ui()
	if not bool(result.get("ok", false)):
		renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % str(result.get("error", "应用代码失败。")))
		return

	var target_path: String = str(result.get("target_path", "")).strip_edges()
	if not target_path.is_empty():
		_focus_target_resource(target_path)

	if all_sessions.has(current_session_id):
		if not all_sessions[current_session_id].has("action_log") or not (all_sessions[current_session_id]["action_log"] is Array):
			all_sessions[current_session_id]["action_log"] = []
		all_sessions[current_session_id]["action_log"].append(result.get("log_entry", {}))
		if not all_sessions[current_session_id].has("rollback_log") or not (all_sessions[current_session_id]["rollback_log"] is Array):
			all_sessions[current_session_id]["rollback_log"] = []
		var rollback_entry: Dictionary = result.get("rollback_entry", {})
		if not rollback_entry.is_empty():
			all_sessions[current_session_id]["rollback_log"].append(rollback_entry)
		storage.save_sessions(all_sessions)

func _validate_scene_creation_content(scene_text: String) -> Dictionary:
	var base_validation: Dictionary = action_executor.validate_scene_text(scene_text)
	if not bool(base_validation.get("ok", false)):
		return base_validation

	for raw_line in scene_text.split("\n"):
		var line: String = str(raw_line).strip_edges()
		if line.begins_with("[ext_resource "):
			return {
				"ok": false,
				"reason": "external_resources_not_allowed",
				"message": "当前场景创建默认只接受纯 .tscn。请不要返回 ext_resource；如果需要脚本，请单独提供一个 gdscript 代码块。",
			}
		if line.find("res://addons/ai_assistant/") >= 0 and line.find(".gd") >= 0:
			return {
				"ok": false,
				"reason": "plugin_script_reference",
				"message": "场景结果错误地引用了 AI 助手插件脚本。请新开一个会话后再生成纯业务场景。",
			}
		if line.find("uid=\"") >= 0 and line.find("path=\"") < 0:
			return {
				"ok": false,
				"reason": "uid_only_ext_resource",
				"message": "场景里有只写 UID、没有 path 的外部资源引用。请让模型返回纯 .tscn，或给出真实资源路径。",
			}

	return {
		"ok": true,
	}

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

func _get_active_scene_path() -> String:
	var scene_root = EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ""
	return str(scene_root.scene_file_path)

func _build_editor_context() -> Dictionary:
	var context: Dictionary = {
		"code_edit": null,
		"active_script_path": _get_active_script_path(),
		"active_scene_path": _get_active_scene_path(),
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
		renderer.render_message("assistant", "[color=#E06C75]高风险确认界面不可用，请重载插件后重试。[/color]")
		return

	high_risk_dialog.title = str(review_data.get("secondary_confirmation_title", "确认高风险改动"))
	high_risk_dialog.dialog_text = str(review_data.get("secondary_confirmation_message", "这个改动需要额外确认。"))
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
	if target_script_path.to_lower().ends_with(".tscn") and EditorInterface.has_method("open_scene_from_path"):
		var scene_resource: Resource = ResourceLoader.load(target_script_path)
		if scene_resource is PackedScene:
			EditorInterface.open_scene_from_path(target_script_path)
		else:
			renderer.render_message("assistant", "[color=#E06C75]场景文件已写入，但 Godot 当前无法加载它，所以没有自动打开：%s[/color]" % target_script_path)
		return
	var resource: Resource = ResourceLoader.load(target_script_path)
	if resource != null:
		EditorInterface.edit_resource(resource)

func _on_settings_dialog_confirmed() -> void:
	current_api_url = api_url_input.text.strip_edges()
	current_api_key = api_key_input.text.strip_edges()
	current_model = model_input.text.strip_edges()
	if not current_model.is_empty():
		saved_model_configs[current_model] = {
			"url": current_api_url,
			"key": current_api_key,
		}
	_setup_model_selector()
	storage.save_config(current_api_url, current_api_key, current_model, saved_model_configs)
	_refresh_context_meter()

func _load_session_to_ui(id: String) -> void:
	current_session_id = id
	renderer.clear_chat()
	var last_user_prompt: String = ""
	for message in all_sessions[id]["history"]:
		var role: String = str(message.get("role", ""))
		var content: String = str(message.get("content", ""))
		if role == "assistant":
			var response_plan: Dictionary = runtime.plan_assistant_response_for_prompt(last_user_prompt, content)
			renderer.render_message(role, content, "", response_plan)
		else:
			renderer.render_message(role, content)
			if role == "user":
				last_user_prompt = content
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
		"rollback_log": [],
		"schema_version": 3,
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
	var saved_profile: Dictionary = _get_saved_model_config(current_model)
	if not saved_profile.is_empty():
		current_api_url = String(saved_profile.get("url", current_api_url))
		current_api_key = String(saved_profile.get("key", current_api_key))
	else:
		var resolved_profile: Dictionary = provider_profiles.resolve_profile(current_model, current_api_url)
		current_api_url = String(resolved_profile.get("default_url", current_api_url))
	storage.save_config(current_api_url, current_api_key, current_model, saved_model_configs)
	_refresh_context_meter()

func _setup_model_selector() -> void:
	model_selector.clear()
	model_profiles = provider_profiles.get_profiles()
	var keys: Array = provider_profiles.get_profile_keys()
	for saved_key in saved_model_configs.keys():
		var model_key: String = String(saved_key)
		var saved_profile: Dictionary = _get_saved_model_config(model_key)
		model_profiles[model_key] = provider_profiles.resolve_profile(model_key, String(saved_profile.get("url", "")))
		if not keys.has(model_key):
			keys.append(model_key)
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

func _normalize_saved_model_configs(raw_profiles: Variant) -> Dictionary:
	if not (raw_profiles is Dictionary):
		return {}

	var normalized: Dictionary = {}
	for raw_model in raw_profiles.keys():
		var model: String = String(raw_model).strip_edges()
		if model.is_empty():
			continue
		var raw_profile: Variant = raw_profiles[raw_model]
		if not (raw_profile is Dictionary):
			continue
		normalized[model] = {
			"url": String(raw_profile.get("url", "")).strip_edges(),
			"key": String(raw_profile.get("key", "")).strip_edges(),
		}
	return normalized

func _get_saved_model_config(model: String) -> Dictionary:
	if model.is_empty():
		return {}
	if not saved_model_configs.has(model):
		return {}
	var profile: Variant = saved_model_configs[model]
	if profile is Dictionary:
		return profile
	return {}

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
