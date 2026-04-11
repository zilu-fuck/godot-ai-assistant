@tool
extends Control

# --- 节点引用 (根据新结构更新) ---
@onready var chat_scroll = $VBoxContainer/ChatScroll
@onready var message_list = $VBoxContainer/ChatScroll/MessageList
@onready var input_box = $VBoxContainer/InputPanel/VBoxContainer/TextEdit
@onready var http_request = $HTTPRequest

# 顶部
@onready var session_selector = $VBoxContainer/HBoxContainer_top/SessionSelector
@onready var new_chat_button = $VBoxContainer/HBoxContainer_top/NewChatButton
@onready var delete_chat_button = $VBoxContainer/HBoxContainer_top/DeleteChatButton

# 工具栏与动作
@onready var clear_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/ClearButton
@onready var compress_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/CompressButton
@onready var settings_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/SettingsButton
@onready var model_selector = $VBoxContainer/InputPanel/VBoxContainer/Actions/ModelSelector
@onready var insert_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/InsertButton
@onready var send_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/SendButton

# 设置弹窗
@onready var settings_dialog = $SettingsDialog
@onready var api_url_input = $SettingsDialog/VBoxContainer/ApiUrlInput
@onready var api_key_input = $SettingsDialog/VBoxContainer/ApiKeyInput
@onready var model_input = $SettingsDialog/VBoxContainer/ModelInput

# --- 配置与常量 ---
const CONFIG_PATH = "user://ai_assistant_config.cfg"
const SESSIONS_PATH = "user://ai_sessions.json"

const MODEL_PROFILES = {
	"deepseek-chat": {"name": "DeepSeek Chat (V3)", "use_system_role": true, "context_style": "default", "temperature": 0.7},
	"deepseek-reasoner": {"name": "DeepSeek Reasoner (R1)", "use_system_role": false, "context_style": "instruction_prefix", "temperature": 0.3}
}

# --- 核心变量 ---
var current_api_url: String = "https://api.deepseek.com/chat/completions"
var current_api_key: String = ""
var current_model: String = "deepseek-chat"
var all_sessions: Dictionary = {}
var current_session_id: String = ""
var last_generated_code: String = ""
var is_compressing: bool = false
var last_sent_script_content: String = ""
const MAX_HISTORY_LENGTH = 15
var max_scan_depth = 3
var thinking_node: Control = null # 用来追踪"思考中"的临时节点
var dots_timer: Timer = null # 思考动画定时器

# ==========================================
# 🚀 1. 初始化
# ==========================================

func _ready():
	http_request.request_completed.connect(_on_request_completed)
	send_button.pressed.connect(_on_send_pressed)
	insert_button.pressed.connect(_on_insert_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	compress_button.pressed.connect(_on_compress_pressed)
	new_chat_button.pressed.connect(_on_new_chat_pressed)
	session_selector.item_selected.connect(_on_session_selected)
	settings_dialog.confirmed.connect(_on_settings_dialog_confirmed)
	delete_chat_button.pressed.connect(_on_delete_chat_pressed)
	model_selector.item_selected.connect(_on_model_selected)

	_setup_modern_ui()
	_setup_model_selector()
	load_config()
	load_all_sessions()
	
	if all_sessions.is_empty():
		_on_new_chat_pressed()
	else:
		_sync_session_ui()
		_load_session_to_ui(all_sessions.keys().back())
	dots_timer = Timer.new()
	dots_timer.wait_time = 0.5
	dots_timer.autostart = true
	add_child(dots_timer)
	dots_timer.timeout.connect(func():
		if thinking_node and thinking_node is RichTextLabel:
			var t = thinking_node.text
			if t.ends_with("..."): thinking_node.text = t.replace("...", ".")
			else: thinking_node.text += "."
	)

func _exit_tree():
	# 清理定时器，防止内存泄漏
	if dots_timer:
		dots_timer.stop()
		dots_timer.queue_free()

func _setup_modern_ui():
	var gui = EditorInterface.get_base_control()
	var all_icon_buttons = {
		new_chat_button: "Add", delete_chat_button: "Remove",
		clear_button: "Clear", compress_button: "Scissors",
		settings_button: "Tools", insert_button: "Edit", send_button: "Play"
	}
	for btn in all_icon_buttons:
		btn.icon = gui.get_theme_icon(all_icon_buttons[btn], "EditorIcons")
		btn.text = ""
		btn.flat = true
		btn.custom_minimum_size = Vector2(28, 28)
		_set_tooltip(btn)

func _set_tooltip(btn):
	if btn == insert_button: btn.tooltip_text = "插入最后一段代码"
	elif btn == send_button: btn.tooltip_text = "发送 (Enter)"
	elif btn == clear_button: btn.tooltip_text = "清空当前会话内容"
	elif btn == compress_button: btn.tooltip_text = "总结记忆以节省上下文"
	elif btn == settings_button: btn.tooltip_text = "API设置"
	elif btn == new_chat_button: btn.tooltip_text = "开启新对话"
	elif btn == delete_chat_button: btn.tooltip_text = "删除此对话"

# ==========================================
# 🚀 2. 核心渲染逻辑 (Cursor 风格实现)
# ==========================================

func _render_message(role: String, content: String, reasoning: String = ""):
	# 1. 渲染角色标题
	var role_node = RichTextLabel.new()
	role_node.bbcode_enabled = true
	role_node.fit_content = true
	var color = "#98C379" if role == "user" else "#61AFEF"
	var role_name = "🧑 你" if role == "user" else "🤖 AI"
	role_node.append_text("\n[b][color=%s]%s[/color][/b]" % [color, role_name])
	message_list.add_child(role_node)

	# 2. 如果有深度思考过程 (R1模型)
	if not reasoning.is_empty():
		var r_box = _create_text_node("[color=#5C6370][i]Thinking...\n%s[/i][/color]" % reasoning)
		message_list.add_child(r_box)

	# 3. 解析并渲染混合内容 (文字 + 代码块)
	var regex = RegEx.new()
	# 匹配 Markdown 代码块: ```lang\ncode\n```
	regex.compile("```([a-z]*)\\n([\\s\\S]*?)```")
	
	var last_pos = 0
	var matches = regex.search_all(content)
	
	for m in matches:
		# 渲染代码块之前的文字
		var text_chunk = content.substr(last_pos, m.get_start() - last_pos).strip_edges()
		if not text_chunk.is_empty():
			message_list.add_child(_create_text_node(text_chunk))
		
		# 渲染独立代码块
		var lang = m.get_string(1)
		var code = m.get_string(2).strip_edges()
		message_list.add_child(_create_code_block(code, lang))
		
		last_generated_code = code # 更新最后生成的代码供"插入"按钮使用
		last_pos = m.get_end()

	# 渲染剩余的文字内容
	var final_chunk = content.substr(last_pos).strip_edges()
	if not final_chunk.is_empty():
		message_list.add_child(_create_text_node(final_chunk))
	
	# 4. 自动滚动到底部
	await get_tree().process_frame # 等待 UI 节点创建并完成排版
	chat_scroll.scroll_vertical = chat_scroll.get_v_scroll_bar().max_value

# 助手函数：创建普通文本节点
func _create_text_node(txt: String) -> RichTextLabel:
	var lbl = RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.selection_enabled = true
	# 🌟 关键：让标签横向撑满
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL 
	lbl.text = txt
	return lbl

# 助手函数：创建带一键复制的代码块 (Cursor 核心 UI)
func _create_code_block(code_text: String, lang: String) -> PanelContainer:
	var panel = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# 设置代码块深色背景样式
	var style = StyleBoxFlat.new()
	style.bg_color = Color("#1e1e1e") # 经典的深灰色背景
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)

	var v_box = VBoxContainer.new()
	panel.add_child(v_box)

	# 顶部工具栏 (语言标签 + 复制按钮)
	var toolbar = HBoxContainer.new()
	v_box.add_child(toolbar)
	
	var lang_label = Label.new()
	lang_label.text = lang.to_upper() if not lang.is_empty() else "CODE"
	lang_label.add_theme_color_override("font_color", Color("#888888"))
	lang_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(lang_label)

	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.flat = true
	copy_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(code_text)
		copy_btn.text = "Copied!"
		await get_tree().create_timer(1.0).timeout
		copy_btn.text = "Copy"
	)
	toolbar.add_child(copy_btn)

	# 代码展示区域
	var code_label = RichTextLabel.new()
	code_label.bbcode_enabled = true
	code_label.fit_content = true
	code_label.selection_enabled = true
	# 使用内置等宽字体
	var mono_font = EditorInterface.get_base_control().get_theme_font("source", "EditorFonts")
	code_label.add_theme_font_override("normal_font", mono_font)
	code_label.text = code_text
	v_box.add_child(code_label)
	
	return panel

# ==========================================
# 🚀 3. 逻辑与网络请求 (适配新渲染)
# ==========================================

func _on_send_pressed():
	var prompt = input_box.text.strip_edges()
	if prompt == "" or current_api_key == "": return
	
	var profile = MODEL_PROFILES.get(current_model, MODEL_PROFILES["deepseek-chat"])
	
	# 渲染用户消息
	_render_message("user", prompt)
	all_sessions[current_session_id]["history"].append({"role": "user", "content": prompt})
	input_box.text = ""
	_set_ui_busy(true)

	# 🌟 新增：显示"思考中"提示
	thinking_node = _create_text_node("[color=#888888][i]AI 正在思考并组织语言...[/i][/color]")
	message_list.add_child(thinking_node)
	# 确保滚动到底部
	await get_tree().process_frame
	chat_scroll.scroll_vertical = chat_scroll.get_v_scroll_bar().max_value

	# 准备代码上下文
	var cur_code = get_current_script_text()
	var code_context = ""
	if not cur_code.is_empty():
		code_context = "\n\n【当前代码】:\n```gdscript\n" + cur_code + "\n```"

	var messages = []
	if profile["use_system_role"]:
		messages.append({"role": "system", "content": "你是一个 Godot 4 专家。使用中文，代码必须包裹在 ```gdscript 块中。"})
	
	var history_for_req = all_sessions[current_session_id]["history"].duplicate()
	if history_for_req.size() > MAX_HISTORY_LENGTH:
		history_for_req = history_for_req.slice(-MAX_HISTORY_LENGTH)
	
	for msg in history_for_req: messages.append(msg.duplicate())
		
	# 注入代码上下文到最后一条消息
	var last_msg = messages.back()
	last_msg["content"] += code_context

	var body = {"model": current_model, "messages": messages, "temperature": profile["temperature"]}
	var headers = ["Content-Type: application/json", "Authorization: Bearer " + current_api_key]
	http_request.request(current_api_url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))

func _on_request_completed(_result, response_code, _headers, body):
	
	# 🌟 新增：移除"思考中"提示
	if thinking_node:
		thinking_node.queue_free()
		thinking_node = null
		
	_set_ui_busy(false)
	
	if response_code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		var message = json["choices"][0]["message"]
		var reply = message["content"]
		var reasoning = message.get("reasoning_content", "")
		
		# 处理没有 reasoning 字段但包含 <think> 的情况
		if "<think>" in reply:
			var parts = reply.split("</think>")
			if parts.size() > 1:
				reasoning = parts[0].replace("<think>", "").strip_edges()
				reply = parts[1].strip_edges()
				
		all_sessions[current_session_id]["history"].append({"role": "assistant", "content": reply})
		_render_message("assistant", reply, reasoning)
		insert_button.disabled = (last_generated_code == "")
		_save_current_to_memory()
		_sync_session_ui() 
	else:
		_render_message("assistant", "[color=#E06C75]请求失败 (状态码: " + str(response_code) + ")[/color]")

# ==========================================
# 🚀 4. 会话与配置 (节点清空逻辑更新)
# ==========================================

func _load_session_to_ui(id: String):
	current_session_id = id
	# 清空当前 MessageList 下的所有子节点
	for child in message_list.get_children():
		child.queue_free()
	
	# 重渲染所有消息
	for msg in all_sessions[id]["history"]:
		_render_message(msg["role"], msg["content"])

func _on_clear_pressed():
	if all_sessions.has(current_session_id):
		all_sessions[current_session_id]["history"].clear()
		_load_session_to_ui(current_session_id)

# --- 保持原有逻辑不变的部分 ---
func _on_new_chat_pressed():
	_save_current_to_memory()
	current_session_id = str(Time.get_unix_time_from_system())
	all_sessions[current_session_id] = {"title": "新对话 " + Time.get_time_string_from_system().left(5), "history": []}
	_sync_session_ui()
	_load_session_to_ui(current_session_id)

func _on_delete_chat_pressed():
	if current_session_id == "" or all_sessions.is_empty(): return
	all_sessions.erase(current_session_id)
	current_session_id = all_sessions.keys().back() if not all_sessions.is_empty() else ""
	if current_session_id == "": _on_new_chat_pressed()
	else: _load_session_to_ui(current_session_id)
	_sync_session_ui()
	save_all_sessions_to_disk()

func _on_session_selected(index: int):
	_save_current_to_memory()
	var ids = all_sessions.keys()
	ids.reverse()
	current_session_id = ids[index]
	_load_session_to_ui(current_session_id)

func _sync_session_ui():
	session_selector.clear()
	var ids = all_sessions.keys()
	ids.reverse()
	for id in ids: session_selector.add_item(all_sessions[id]["title"])
	for i in range(ids.size()):
		if ids[i] == current_session_id:
			session_selector.selected = i
			break

func _save_current_to_memory():
	if current_session_id != "" and all_sessions.has(current_session_id):
		var history = all_sessions[current_session_id]["history"]
		if history.size() > 0 and all_sessions[current_session_id]["title"].begins_with("新对话"):
			all_sessions[current_session_id]["title"] = history[0]["content"].left(12) + "..."
		save_all_sessions_to_disk()

func save_all_sessions_to_disk():
	var file = FileAccess.open(SESSIONS_PATH, FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(all_sessions))

func load_all_sessions():
	if FileAccess.file_exists(SESSIONS_PATH):
		var file = FileAccess.open(SESSIONS_PATH, FileAccess.READ)
		var json = JSON.parse_string(file.get_as_text())
		if json is Dictionary: all_sessions = json

func load_config():
	var config = ConfigFile.new()
	if config.load(CONFIG_PATH) == OK:
		current_api_url = config.get_value("API", "url", "https://api.deepseek.com/chat/completions")
		current_api_key = config.get_value("API", "key", "")
		current_model = config.get_value("API", "model", "deepseek-chat")

func _on_settings_dialog_confirmed():
	current_api_url = api_url_input.text
	current_api_key = api_key_input.text
	current_model = model_input.text
	var config = ConfigFile.new()
	config.set_value("API", "url", current_api_url)
	config.set_value("API", "key", current_api_key)
	config.set_value("API", "model", current_model)
	config.save(CONFIG_PATH)

func get_current_script_text() -> String:
	var ce = EditorInterface.get_script_editor().get_current_editor()
	return ce.get_base_editor().text if (ce and ce.get_base_editor() is CodeEdit) else ""

func _on_insert_pressed():
	if last_generated_code == "": return
	var ce = EditorInterface.get_script_editor().get_current_editor()
	if ce and ce.get_base_editor() is CodeEdit:
		ce.get_base_editor().insert_text_at_caret(last_generated_code + "\n")

func _on_settings_button_pressed():
	api_url_input.text = current_api_url
	api_key_input.text = current_api_key
	model_input.text = current_model
	settings_dialog.popup_centered()

func _set_ui_busy(busy: bool):
	send_button.disabled = busy
	new_chat_button.disabled = busy
	clear_button.disabled = busy

func _setup_model_selector():
	model_selector.clear()
	var keys = MODEL_PROFILES.keys()
	for i in range(keys.size()):
		model_selector.add_item(MODEL_PROFILES[keys[i]]["name"], i)
		model_selector.set_item_metadata(i, keys[i])
	# 设置当前选中的模型
	for i in range(keys.size()):
		if model_selector.get_item_metadata(i) == current_model:
			model_selector.selected = i
			break

func _on_model_selected(index: int):
	current_model = model_selector.get_item_metadata(index)

func _input(event):
	if input_box.has_focus() and event is InputEventKey and event.pressed:
		if event.keycode == KEY_ENTER and not event.shift_pressed:
			_on_send_pressed()
			get_viewport().set_input_as_handled()

func _on_compress_pressed():
	# 简化版的压缩逻辑，渲染时按正常流程走
	pass
