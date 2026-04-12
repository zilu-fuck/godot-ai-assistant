@tool
extends Control

# ==========================================
# 🧱 节点引用与配置 (Nodes & Config)
# ==========================================

# --- 核心 UI ---
@onready var chat_scroll = $VBoxContainer/ChatScroll
@onready var message_list = $VBoxContainer/ChatScroll/MessageList
@onready var input_box = $VBoxContainer/InputPanel/VBoxContainer/TextEdit

# --- 顶部：会话管理 ---
@onready var session_selector = $VBoxContainer/HBoxContainer_top/SessionSelector
@onready var new_chat_button = $VBoxContainer/HBoxContainer_top/NewChatButton
@onready var delete_chat_button = $VBoxContainer/HBoxContainer_top/DeleteChatButton

# --- 底部：工具栏与动作 ---
@onready var clear_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/ClearButton
@onready var compress_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/CompressButton
@onready var settings_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/SettingsButton
@onready var model_selector = $VBoxContainer/InputPanel/VBoxContainer/Actions/ModelSelector
@onready var insert_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/InsertButton
@onready var send_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/SendButton
@onready var stop_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/StopButton 

# --- 设置弹窗 ---
@onready var settings_dialog = $SettingsDialog
@onready var api_url_input = $SettingsDialog/VBoxContainer/ApiUrlInput
@onready var api_key_input = $SettingsDialog/VBoxContainer/ApiKeyInput
@onready var model_input = $SettingsDialog/VBoxContainer/ModelInput

# --- 常量字典 ---
const CONFIG_PATH = "user://ai_assistant_config.cfg"
const SESSIONS_PATH = "user://ai_sessions.json"
const MAX_HISTORY_LENGTH = 15

const MODEL_PROFILES = {
	"deepseek-chat": {"name": "DeepSeek Chat (V3)", "use_system_role": true, "context_style": "default", "temperature": 0.7},
	"deepseek-reasoner": {"name": "DeepSeek Reasoner (R1)", "use_system_role": false, "context_style": "instruction_prefix", "temperature": 0.3}
}

# ==========================================
# 📊 状态变量 (State Variables)
# ==========================================

var current_api_url: String = "https://api.deepseek.com/chat/completions"
var current_api_key: String = ""
var current_model: String = "deepseek-chat"
var all_sessions: Dictionary = {}
var current_session_id: String = ""
var last_generated_code: String = ""
var is_compressing: bool = false
var max_scan_depth = 3

# --- 流式输出专属状态 ---
var stream_client := HTTPClient.new()
var is_streaming := false
var request_sent := false
var stream_buffer := ""
var current_body_string := ""
var stream_temp_node: RichTextLabel = null
var current_ai_content := ""
var current_ai_reasoning := ""

# ==========================================
# 🚀 1. 初始化与 UI 设置 (Init & UI)
# ==========================================

func _ready():
	set_process(false) 
	
	if not send_button.pressed.is_connected(_on_send_pressed):
		send_button.pressed.connect(_on_send_pressed)
	if not stop_button.pressed.is_connected(_on_stop_pressed):
		stop_button.pressed.connect(_on_stop_pressed)
		
	insert_button.pressed.connect(_on_insert_pressed)
	settings_button.pressed.connect(_on_settings_button_pressed)
	clear_button.pressed.connect(_on_clear_pressed)
	compress_button.pressed.connect(_on_compress_pressed)
	new_chat_button.pressed.connect(_on_new_chat_pressed)
	session_selector.item_selected.connect(_on_session_selected)
	settings_dialog.confirmed.connect(_on_settings_dialog_confirmed)
	delete_chat_button.pressed.connect(_on_delete_chat_pressed)
	model_selector.item_selected.connect(_on_model_selected)

	stop_button.visible = false

	_setup_modern_ui()
	_setup_model_selector()
	load_config()
	load_all_sessions()
	
	if all_sessions.is_empty():
		_on_new_chat_pressed()
	else:
		_sync_session_ui()
		_load_session_to_ui(all_sessions.keys().back())

func _setup_modern_ui():
	var gui = EditorInterface.get_base_control()
	var all_icon_buttons = {
		new_chat_button: "Add", delete_chat_button: "Remove",
		clear_button: "Clear", compress_button: "Scissors",
		settings_button: "Tools", insert_button: "Edit", 
		send_button: "Play", stop_button: "Stop"
	}
	for btn in all_icon_buttons:
		btn.icon = gui.get_theme_icon(all_icon_buttons[btn], "EditorIcons")
		btn.text = ""
		btn.flat = true
		btn.custom_minimum_size = Vector2(28, 28)
		_set_tooltip(btn)

func _set_tooltip(btn):
	if btn == insert_button: btn.tooltip_text = "插入/替换为最后一段代码"
	elif btn == send_button: btn.tooltip_text = "发送 (Enter)"
	elif btn == stop_button: btn.tooltip_text = "终止生成"
	elif btn == clear_button: btn.tooltip_text = "清空当前会话内容"
	elif btn == compress_button: btn.tooltip_text = "总结记忆以节省上下文"
	elif btn == settings_button: btn.tooltip_text = "API设置"
	elif btn == new_chat_button: btn.tooltip_text = "开启新对话"
	elif btn == delete_chat_button: btn.tooltip_text = "删除此对话"

func _set_ui_busy(busy: bool):
	send_button.visible = not busy
	stop_button.visible = busy
	new_chat_button.disabled = busy
	clear_button.disabled = busy
	model_selector.disabled = busy

# ==========================================
# 🎨 2. 核心渲染引擎 (Render Engine)
# ==========================================

func _render_message(role: String, content: String, reasoning: String = ""):
	var role_node = RichTextLabel.new()
	role_node.bbcode_enabled = true
	role_node.fit_content = true
	var color = "#98C379" if role == "user" else "#61AFEF"
	var role_name = "🧑 你" if role == "user" else "🤖 AI"
	role_node.append_text("\n[b][color=%s]%s[/color][/b]" % [color, role_name])
	message_list.add_child(role_node)

	if not reasoning.is_empty():
		var r_box = _create_text_node("[color=#5C6370][i]Thinking...\n%s[/i][/color]" % reasoning)
		message_list.add_child(r_box)

	# 🌟 终极解析引擎：状态机逐行扫描 (100% 免疫截断 Bug)
	var in_code_block = false
	var current_lang = ""
	var text_buffer = ""
	var code_buffer = ""

	var lines = content.split("\n")
	for line in lines:
		if line.strip_edges().begins_with("```"):
			if not in_code_block:
				if not text_buffer.strip_edges().is_empty():
					message_list.add_child(_create_text_node(text_buffer.strip_edges()))
				text_buffer = ""
				in_code_block = true
				current_lang = line.strip_edges().substr(3).strip_edges()
			else:
				if not code_buffer.strip_edges().is_empty():
					message_list.add_child(_create_code_block(code_buffer.strip_edges(), current_lang))
					last_generated_code = code_buffer.strip_edges()
				code_buffer = ""
				in_code_block = false
				current_lang = ""
		else:
			if in_code_block:
				code_buffer += line + "\n"
			else:
				text_buffer += line + "\n"

	# 兜底逻辑：处理被强制截断的残缺内容
	if not text_buffer.strip_edges().is_empty():
		message_list.add_child(_create_text_node(text_buffer.strip_edges()))
	if in_code_block and not code_buffer.strip_edges().is_empty():
		message_list.add_child(_create_code_block(code_buffer.strip_edges(), current_lang))
		last_generated_code = code_buffer.strip_edges()

	await get_tree().process_frame
	chat_scroll.scroll_vertical = chat_scroll.get_v_scroll_bar().max_value

func _create_text_node(txt: String) -> RichTextLabel:
	var lbl = RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.selection_enabled = true
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.text = txt
	return lbl

func _create_code_block(code_text: String, lang: String) -> PanelContainer:
	var panel = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color("#1e1e1e")
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)

	var v_box = VBoxContainer.new()
	panel.add_child(v_box)

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
		await panel.get_tree().create_timer(1.0).timeout
		if is_instance_valid(copy_btn): copy_btn.text = "Copy"
	)
	toolbar.add_child(copy_btn)

	# CodeEdit 渲染与高亮
	var code_edit = CodeEdit.new()
	code_edit.text = code_text
	code_edit.editable = false
	code_edit.context_menu_enabled = false
	code_edit.scroll_fit_content_height = true 
	
	# 🌟 防坍塌保护：预估并强制注入最小高度
	var line_count = code_text.split("\n").size()
	code_edit.custom_minimum_size.y = max(35, line_count * 24)
	
	var empty_style = StyleBoxEmpty.new()
	code_edit.add_theme_stylebox_override("normal", empty_style)
	code_edit.add_theme_stylebox_override("read_only", empty_style)
	code_edit.add_theme_stylebox_override("focus", empty_style)
	
	var gui = EditorInterface.get_base_control()
	if gui.has_theme_font("source", "EditorFonts"):
		code_edit.add_theme_font_override("font", gui.get_theme_font("source", "EditorFonts"))
	code_edit.add_theme_font_size_override("font_size", 14) 
	
	# One Dark 语法高亮
	var highlighter = CodeHighlighter.new()
	highlighter.number_color = Color("#D19A66") 
	highlighter.symbol_color = Color("#ABB2BF") 
	highlighter.function_color = Color("#61AFEF")
	highlighter.member_variable_color = Color("#E06C75")

	var keywords = ["func", "var", "const", "extends", "class_name", "if", "elif", "else", "for", "while", "break", "continue", "pass", "return", "match", "signal", "await", "true", "false", "null", "self", "void", "enum", "preload", "load", "super"]
	for k in keywords: highlighter.add_keyword_color(k, Color("#C678DD"))

	var types = ["int", "float", "String", "bool", "Array", "Dictionary", "Node", "Control", "Node2D", "Node3D", "Vector2", "Vector3", "Color", "Object", "Variant"]
	for t in types: highlighter.add_keyword_color(t, Color("#E5C07B"))

	var annotations = ["@onready", "@export", "@tool", "@warning_ignore", "@rpc"]
	for a in annotations: highlighter.add_keyword_color(a, Color("#C678DD"))

	highlighter.add_color_region('"', '"', Color("#98C379"))
	highlighter.add_color_region("'", "'", Color("#98C379"))
	highlighter.add_color_region("#", "", Color("#5C6370"), true)

	code_edit.syntax_highlighter = highlighter
	v_box.add_child(code_edit)
	
	return panel

# ==========================================
# 📡 3. 聊天与网络请求 (Chat & Network)
# ==========================================

func _on_send_pressed():
	var prompt = input_box.text.strip_edges()
	if prompt == "" or current_api_key == "": return
	
	var profile = MODEL_PROFILES.get(current_model, MODEL_PROFILES["deepseek-chat"])
	
	_render_message("user", prompt)
	all_sessions[current_session_id]["history"].append({"role": "user", "content": prompt})
	input_box.text = ""
	_set_ui_busy(true)

	var context_data = get_smart_script_context()
	var code_context = ""
	if not context_data["text"].is_empty():
		var label = "选中的代码" if context_data["is_selected"] else "当前完整代码"
		code_context = "\n\n【" + label + "】:\n```gdscript\n" + context_data["text"] + "\n```"

	var godot_philosophy = """你是一名资深的 Godot 4 架构师。请严格遵循 Godot“场景树与节点驱动”的设计哲学：
1. 【拒绝硬编码】：坚决避免在 _ready() 中用纯代码动态创建 UI 或复杂的节点树。
2. 【编辑器优先】：在给出代码前，必须先简明扼要地指导用户在 Godot 编辑器中创建什么节点（Node 层级关系），以及需要修改什么 Inspector 属性。
3. 【逻辑抽离】：提供的 GDScript 代码应仅包含核心控制逻辑，通过 @export 或 %UniqueName 引用节点。
4. 【代码规范】：代码必须包裹在 ```gdscript 块中。"""

	var messages = []
	if profile["use_system_role"]:
		messages.append({"role": "system", "content": godot_philosophy})
	
	var history_for_req = all_sessions[current_session_id]["history"].duplicate()
	if history_for_req.size() > MAX_HISTORY_LENGTH:
		history_for_req = history_for_req.slice(-MAX_HISTORY_LENGTH)
	
	for msg in history_for_req: messages.append(msg.duplicate())
		
	var last_msg = messages.back()
	last_msg["content"] += code_context
	
	if not profile["use_system_role"]:
		last_msg["content"] = "[系统指令：" + godot_philosophy + "]\n\n" + last_msg["content"]

	# 🌟 API 请求体，放开 Token 限制
	var body = {
		"model": current_model, 
		"messages": messages, 
		"temperature": profile["temperature"], 
		"stream": true,
		"max_tokens": 8192
	}
	current_body_string = JSON.stringify(body)

	stream_temp_node = _create_text_node("[color=#888888][i]正在连接大模型神经元...[/i][/color]")
	message_list.add_child(stream_temp_node)
	current_ai_content = ""
	current_ai_reasoning = ""
	
	_start_stream_request()

func _on_stop_pressed():
	if is_streaming:
		# 强行加上 ``` 闭合代码块，让提示语回归普通文本区
		current_ai_content += "\n```\n\n[color=#E06C75][i](生成已由用户终止)[/i][/color]"
		_finish_streaming(true)

func _start_stream_request():
	var host = "api.deepseek.com"
	var port = 443
	var tls_options = TLSOptions.client() 
	
	var clean_url = current_api_url.replace("https://", "").replace("http://", "")
	host = clean_url.split("/")[0]
	
	if current_api_url.begins_with("http://"):
		port = 80
		tls_options = null 
		
	stream_client.connect_to_host(host, port, tls_options) 
	is_streaming = true
	request_sent = false
	set_process(true)

# ==========================================
# 🌊 4. 流式解析器 (Streaming Parser)
# ==========================================

func _process(_delta):
	if not is_streaming: return

	stream_client.poll()
	var status = stream_client.get_status()

	if status == HTTPClient.STATUS_CONNECTED and not request_sent:
		var headers = ["Content-Type: application/json", "Authorization: Bearer " + current_api_key]
		var clean_url = current_api_url.replace("https://", "").replace("http://", "")
		var slash_pos = clean_url.find("/")
		var endpoint = "/chat/completions"
		if slash_pos != -1: endpoint = clean_url.substr(slash_pos)
		
		stream_client.request(HTTPClient.METHOD_POST, endpoint, headers, current_body_string)
		request_sent = true

	elif status == HTTPClient.STATUS_BODY or status == HTTPClient.STATUS_CONNECTED:
		if stream_client.has_response():
			var chunk = stream_client.read_response_body_chunk()
			if chunk.size() > 0:
				var text = chunk.get_string_from_utf8()
				_parse_sse_chunk(text)

	elif status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTION_ERROR:
		_finish_streaming()

func _parse_sse_chunk(chunk_text: String):
	stream_buffer += chunk_text
	var lines = stream_buffer.split("\n")
	stream_buffer = lines[lines.size() - 1]

	var ui_updated = false
	for i in range(lines.size() - 1):
		var line = lines[i].strip_edges()
		if line.begins_with("data: "):
			var data_str = line.substr(6).strip_edges()
			if data_str == "[DONE]":
				_finish_streaming()
				return
			
			var json = JSON.parse_string(data_str)
			if json and json is Dictionary and json.has("choices"):
				var delta = json["choices"][0].get("delta", {})
				
				if delta.has("reasoning_content") and delta["reasoning_content"] != null:
					current_ai_reasoning += delta["reasoning_content"]
					ui_updated = true
					
				if delta.has("content") and delta["content"] != null:
					current_ai_content += delta["content"]
					ui_updated = true

	if ui_updated and is_instance_valid(stream_temp_node):
		var display_text = ""
		if current_ai_reasoning != "":
			display_text += "[color=#5C6370][i]Thinking...\n" + current_ai_reasoning + "[/i][/color]\n\n"
		display_text += current_ai_content
		stream_temp_node.text = display_text
		
		await get_tree().process_frame
		chat_scroll.scroll_vertical = chat_scroll.get_v_scroll_bar().max_value

func _finish_streaming(is_forced: bool = false):
	is_streaming = false
	set_process(false)
	stream_client.close()
	stream_buffer = ""

	if is_instance_valid(stream_temp_node):
		stream_temp_node.queue_free()

	_set_ui_busy(false)

	if not current_ai_content.is_empty() or is_forced:
		all_sessions[current_session_id]["history"].append({"role": "assistant", "content": current_ai_content})
		_render_message("assistant", current_ai_content, current_ai_reasoning)

	insert_button.disabled = (last_generated_code == "")
	_save_current_to_memory()
	_sync_session_ui()

# ==========================================
# 🧠 5. 记忆与压缩逻辑 (Memory & Compress)
# ==========================================

func _on_compress_pressed():
	if current_session_id == "" or all_sessions.is_empty(): return
	if is_compressing: return

	var history = all_sessions[current_session_id]["history"]
	if history.size() <= 6:
		var tip = _create_text_node("[color=#888888][i]当前对话较短，无需压缩。[/i][/color]")
		message_list.add_child(tip)
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(tip): tip.queue_free()
		return

	is_compressing = true
	_set_ui_busy(true)

	var loading_node = _create_text_node("[color=#E5C07B][i]🧠 正在提炼历史记忆，释放上下文空间...[/i][/color]")
	message_list.add_child(loading_node)
	await get_tree().process_frame
	chat_scroll.scroll_vertical = chat_scroll.get_v_scroll_bar().max_value

	var keep_count = 4
	var to_compress = history.slice(0, history.size() - keep_count)
	var to_keep = history.slice(history.size() - keep_count)

	var compress_prompt = "作为一名专业的 Godot 程序员，请总结以下我们过去的对话。你的目标是生成一份高密度的'备忘录'，供你之后查阅。请务必提取：\n1. 我当前的项目目标和核心需求。\n2. 我们已经确定的代码结构、命名规范或关键类名。\n3. 我们刚刚解决过的关键 Bug 或避坑指南。\n用简短的列表形式返回，不要废话。\n\n---历史对话记录---\n"
	for msg in to_compress:
		var role_name = "用户" if msg["role"] == "user" else "AI"
		compress_prompt += "【%s】: %s\n" % [role_name, msg["content"].left(800)] 

	var compress_req = HTTPRequest.new()
	add_child(compress_req)
	var body = {"model": "deepseek-chat", "messages": [{"role": "user", "content": compress_prompt}], "temperature": 0.1 }
	var headers = ["Content-Type: application/json", "Authorization: Bearer " + current_api_key]

	compress_req.request_completed.connect(func(_result, response_code, _h, res_body):
		if is_instance_valid(loading_node): loading_node.queue_free()
		is_compressing = false
		_set_ui_busy(false)

		if response_code == 200:
			var json = JSON.parse_string(res_body.get_string_from_utf8())
			var summary = json["choices"][0]["message"]["content"]
			var memory_msg = {"role": "assistant", "content": "✨ [b][color=#E5C07B]已压缩早期上下文。当前记忆备忘录：[/color][/b]\n" + summary}
			all_sessions[current_session_id]["history"] = [memory_msg] + to_keep
			_save_current_to_memory()
			_load_session_to_ui(current_session_id)
		else:
			_render_message("assistant", "[color=#E06C75]压缩记忆失败 (状态码: " + str(response_code) + ")[/color]")

		compress_req.queue_free()
	)
	compress_req.request(current_api_url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))

# ==========================================
# 💾 6. 数据持久化与其他辅助 (Data & Utils)
# ==========================================

func _load_session_to_ui(id: String):
	current_session_id = id
	for child in message_list.get_children(): child.queue_free()
	for msg in all_sessions[id]["history"]: _render_message(msg["role"], msg["content"])

func _on_clear_pressed():
	if all_sessions.has(current_session_id):
		all_sessions[current_session_id]["history"].clear()
		_load_session_to_ui(current_session_id)

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

func get_smart_script_context() -> Dictionary:
	var ce = EditorInterface.get_script_editor().get_current_editor()
	if ce and ce.get_base_editor() is CodeEdit:
		var editor = ce.get_base_editor() as CodeEdit
		if editor.has_selection():
			return {"text": editor.get_selected_text(), "is_selected": true}
		return {"text": editor.text, "is_selected": false}
	return {"text": "", "is_selected": false}

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

func _setup_model_selector():
	model_selector.clear()
	var keys = MODEL_PROFILES.keys()
	for i in range(keys.size()):
		model_selector.add_item(MODEL_PROFILES[keys[i]]["name"], i)
		model_selector.set_item_metadata(i, keys[i])
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
