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
var pending_action: Dictionary = {}
var runtime_debug_label: RichTextLabel

func _ready() -> void:
	add_child(net_client)
	add_child(storage)
	add_child(renderer)

	renderer.setup(chat_scroll, message_list)
	model_profiles = provider_profiles.get_profiles()
	runtime.setup(net_client, MAX_HISTORY_LENGTH)

	net_client.chunk_received.connect(_on_chunk_received)
	net_client.stream_completed.connect(_on_stream_completed)
	net_client.stream_failed.connect(_on_stream_failed)
	renderer.apply_code_requested.connect(_on_apply_code_requested)

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

	stop_button.visible = false
	_setup_modern_ui()
	_setup_runtime_debug_label()

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

func _set_tooltip(button: Button) -> void:
	if button == insert_button:
		button.tooltip_text = "应用上一个代码块"
	elif button == send_button:
		button.tooltip_text = "发送 (Enter)"
	elif button == stop_button:
		button.tooltip_text = "停止生成"
	elif button == clear_button:
		button.tooltip_text = "清除当前会话"
	elif button == compress_button:
		button.tooltip_text = "压缩会话内存"
	elif button == settings_button:
		button.tooltip_text = "API 设置"
	elif button == new_chat_button:
		button.tooltip_text = "新建聊天"
	elif button == delete_chat_button:
		button.tooltip_text = "删除此聊天"
	elif button == debug_button:
		button.tooltip_text = "分析剪贴板错误"

func _set_ui_busy(busy: bool) -> void:
	send_button.visible = not busy
	stop_button.visible = busy
	new_chat_button.disabled = busy
	clear_button.disabled = busy
	model_selector.disabled = busy
	debug_button.disabled = busy

func _update_runtime_debug_label(bbcode_text: String) -> void:
	if runtime_debug_label == null:
		return

	var should_show: bool = bbcode_text.contains("Rules Error:")
	runtime_debug_label.visible = should_show
	runtime_debug_label.text = bbcode_text

func _refresh_context_meter() -> void:
	if context_ring == null:
		return

	if current_session_id.is_empty() or not all_sessions.has(current_session_id):
		_apply_context_usage({})
		return

	var preview: Dictionary = runtime.preview_chat_request(input_box.text, all_sessions[current_session_id], {
		"url": current_api_url,
		"model": current_model,
	})
	_apply_context_usage(preview.get("usage", {}))

func _apply_context_usage(usage: Dictionary) -> void:
	if usage.is_empty():
		context_ring.value = 0.0
		context_ring.fill_color = CONTEXT_COLOR_IDLE
		context_ring.tooltip_text = "请先创建或打开一个会话，再查看上下文占用。"
		return

	var raw_ratio: float = float(usage.get("ratio", 0.0))
	var display_ratio: float = clampf(raw_ratio, 0.0, 1.0)
	var risk_level: String = String(usage.get("risk_level", "healthy"))
	var accent: Color = _get_context_accent(risk_level)
	context_ring.value = display_ratio
	context_ring.fill_color = accent
	context_ring.tooltip_text = _build_context_tooltip(usage)

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
	lines.append("状态：%s" % String(usage.get("status_label", "上下文健康")))
	lines.append("预估输入：%s / %s tokens" % [
		_format_token_count(int(usage.get("estimated_input_tokens", 0))),
		_format_token_count(int(usage.get("input_budget_tokens", 0))),
	])
	lines.append("预留输出：%s tokens" % _format_token_count(int(usage.get("estimated_output_tokens", 0))))
	lines.append("上下文窗口：%s tokens" % _format_token_count(int(usage.get("context_window", 0))))
	lines.append("总字符数：%d" % int(usage.get("char_count", 0)))
	if bool(usage.get("over_budget", false)):
		lines.append("提示：已超过输入预算，强烈建议手动压缩。")

	var sources: Array = usage.get("sources", [])
	if not sources.is_empty():
		lines.append("")
		lines.append("主要来源：")
		var count: int = mini(4, sources.size())
		for index in range(count):
			var source: Dictionary = sources[index]
			lines.append("- %s：%s tokens（%d 字符）" % [
				String(source.get("name", "未知来源")),
				_format_token_count(int(source.get("tokens", 0))),
				int(source.get("chars", 0)),
			])

	return "\n".join(lines)

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
		_update_runtime_debug_label(String(result.get("debug_label", "")))
		return

	renderer.render_message("user", prompt)
	input_box.text = ""
	_set_ui_busy(true)
	_update_runtime_debug_label(String(result.get("debug_label", "")))
	_refresh_context_meter()
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
	_finish_streaming(false)

func _on_stream_failed(error_message: String) -> void:
	if is_instance_valid(stream_temp_node):
		stream_temp_node.queue_free()

	_set_ui_busy(false)

	var final_message: String = "[color=#E06C75]%s[/color]" % error_message
	if not current_ai_content.is_empty():
		final_message = current_ai_content + "\n\n[color=#E06C75][i](%s)[/i][/color]" % error_message

	current_ai_content = final_message
	current_ai_reasoning = ""
	_finish_streaming(true)

func _on_stop_pressed() -> void:
	net_client.stop_stream()
	if current_ai_content.is_empty():
		current_ai_content = "[color=#E06C75][i](Stopped manually)[/i][/color]"
	else:
		current_ai_content += "\n\n[color=#E06C75][i](Stopped manually)[/i][/color]"
	_finish_streaming(true)

func _finish_streaming(is_forced: bool) -> void:
	if is_instance_valid(stream_temp_node):
		stream_temp_node.queue_free()

	_set_ui_busy(false)

	if not current_ai_content.is_empty() or is_forced:
		all_sessions[current_session_id]["history"].append({
			"role": "assistant",
			"content": current_ai_content,
		})
		renderer.render_message("assistant", current_ai_content, current_ai_reasoning)
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
	_set_ui_busy(true)

	var result: Dictionary = runtime.compact_session(all_sessions[current_session_id], "manual")

	is_compressing = false
	_set_ui_busy(false)

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

func _on_apply_code_requested(target_code: String) -> void:
	var context_data: Dictionary = get_smart_script_context()
	var action: Dictionary = action_executor.build_action_for_code(target_code, context_data)
	if not bool(action.get("requires_preview", false)):
		_execute_action(action)
		return

	pending_action = action
	_show_diff(String(action.get("original_text", "")), String(action.get("content", "")))

func _show_diff(old_text: String, new_text: String) -> void:
	var gui = EditorInterface.get_base_control()
	if gui.has_theme_font("source", "EditorFonts"):
		diff_text.add_theme_font_override("normal_font", gui.get_theme_font("source", "EditorFonts"))

	diff_text.add_theme_constant_override("line_separation", 10)
	diff_text.add_theme_constant_override("outline_size", 0)
	diff_text.text = _generate_diff_bbcode(old_text, new_text)
	diff_dialog.popup_centered_clamped(Vector2(900, 700))

func _on_diff_confirmed() -> void:
	_execute_action(pending_action)
	pending_action = {}

func _execute_action(action: Dictionary) -> void:
	if action.is_empty():
		return

	var script_editor = EditorInterface.get_script_editor()
	var current_editor = null
	if script_editor != null:
		current_editor = script_editor.get_current_editor()
	var code_edit: CodeEdit = null
	if current_editor and current_editor.get_base_editor() is CodeEdit:
		code_edit = current_editor.get_base_editor()

	var result: Dictionary = action_executor.execute_action(action, code_edit)
	if not bool(result.get("ok", false)):
		renderer.render_message("assistant", "[color=#E06C75]%s[/color]" % String(result.get("error", "Failed to apply code.")))
		return

	if all_sessions.has(current_session_id):
		if not all_sessions[current_session_id].has("action_log") or not (all_sessions[current_session_id]["action_log"] is Array):
			all_sessions[current_session_id]["action_log"] = []
		all_sessions[current_session_id]["action_log"].append(result.get("log_entry", {}))
		storage.save_sessions(all_sessions)

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

func _generate_diff_bbcode(old_text: String, new_text: String) -> String:
	var old_lines = old_text.split("\n")
	var new_lines = new_text.split("\n")
	var bbcode: String = "[b][color=#E5C07B]Code Diff Preview[/color][/b]\n\n"

	var i: int = 0
	var j: int = 0
	var bg_red: String = "#442b30"
	var bg_green: String = "#2b4430"
	var fg_red: String = "#ff959c"
	var fg_green: String = "#b8ffad"

	while i < old_lines.size() or j < new_lines.size():
		if i < old_lines.size() and j < new_lines.size() and old_lines[i].strip_edges() == new_lines[j].strip_edges():
			bbcode += "      " + old_lines[i] + "\n"
			i += 1
			j += 1
		elif j < new_lines.size() and (i >= old_lines.size() or not (new_lines[j] in old_lines.slice(i, i + 5))):
			bbcode += "[bgcolor=%s][color=%s]  +   %s  [/color][/bgcolor]\n" % [bg_green, fg_green, new_lines[j]]
			j += 1
		elif i < old_lines.size():
			bbcode += "[bgcolor=%s][color=%s]  -   %s  [/color][/bgcolor]\n" % [bg_red, fg_red, old_lines[i]]
			i += 1

	return bbcode
