@tool
extends Control

# ==========================================
# 🧱 节点引用
# ==========================================
@onready var chat_scroll = $VBoxContainer/ChatScroll
@onready var message_list = $VBoxContainer/ChatScroll/MessageList
@onready var input_box = $VBoxContainer/InputPanel/VBoxContainer/TextEdit

@onready var session_selector = $VBoxContainer/HBoxContainer_top/SessionSelector
@onready var new_chat_button = $VBoxContainer/HBoxContainer_top/NewChatButton
@onready var delete_chat_button = $VBoxContainer/HBoxContainer_top/DeleteChatButton

@onready var clear_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/ClearButton
@onready var compress_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/CompressButton
@onready var settings_button = $VBoxContainer/InputPanel/VBoxContainer/Toolbar/SettingsButton
@onready var model_selector = $VBoxContainer/InputPanel/VBoxContainer/Actions/ModelSelector
@onready var insert_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/InsertButton
@onready var send_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/SendButton
@onready var stop_button = $VBoxContainer/InputPanel/VBoxContainer/Actions/StopButton 

@onready var settings_dialog = $SettingsDialog
@onready var api_url_input = $SettingsDialog/VBoxContainer/ApiUrlInput
@onready var api_key_input = $SettingsDialog/VBoxContainer/ApiKeyInput
@onready var model_input = $SettingsDialog/VBoxContainer/ModelInput

# ==========================================
# 🧩 核心引擎与组件模块
# ==========================================
var net_client := AINetClient.new()
var storage := AIStorage.new()
var renderer := AIChatRenderer.new()

# ==========================================
# 📊 状态变量
# ==========================================
const MAX_HISTORY_LENGTH = 15
const MODEL_PROFILES = {
	"deepseek-chat": {"name": "DeepSeek Chat (V3)", "use_system_role": true, "temperature": 0.7},
	"deepseek-reasoner": {"name": "DeepSeek Reasoner (R1)", "use_system_role": false, "temperature": 0.3}
}

var current_api_url: String = ""
var current_api_key: String = ""
var current_model: String = ""
var all_sessions: Dictionary = {}
var current_session_id: String = ""
var is_compressing: bool = false

var stream_temp_node: RichTextLabel = null
var current_ai_content := ""
var current_ai_reasoning := ""

# ==========================================
# 🚀 初始化逻辑
# ==========================================
func _ready():
	# 挂载组件
	add_child(net_client)
	add_child(storage)
	add_child(renderer)
	
	renderer.setup(chat_scroll, message_list)
	
	net_client.chunk_received.connect(_on_chunk_received)
	net_client.stream_completed.connect(_on_stream_completed)
	
	# UI 信号
	send_button.pressed.connect(_on_send_pressed)
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
	
	var config = storage.load_config()
	current_api_url = config.url
	current_api_key = config.key
	current_model = config.model
	
	all_sessions = storage.load_all_sessions()
	if all_sessions.is_empty(): _on_new_chat_pressed()
	else: _sync_session_ui(); _load_session_to_ui(all_sessions.keys().back())

func _setup_modern_ui():
	var gui = EditorInterface.get_base_control()
	var all_icon_buttons = {
		new_chat_button: "Add", delete_chat_button: "Remove", clear_button: "Clear", compress_button: "Scissors",
		settings_button: "Tools", insert_button: "Edit", send_button: "Play", stop_button: "Stop"
	}
	for btn in all_icon_buttons:
		btn.icon = gui.get_theme_icon(all_icon_buttons[btn], "EditorIcons")
		btn.text = ""; btn.flat = true; btn.custom_minimum_size = Vector2(28, 28)

func _set_ui_busy(busy: bool):
	send_button.visible = not busy; stop_button.visible = busy
	new_chat_button.disabled = busy; clear_button.disabled = busy; model_selector.disabled = busy

# ==========================================
# 💬 发送逻辑与工作流
# ==========================================
func _on_send_pressed():
	var prompt = input_box.text.strip_edges()
	if prompt == "" or current_api_key == "": return
	var profile = MODEL_PROFILES.get(current_model, MODEL_PROFILES["deepseek-chat"])
	
	renderer.render_message("user", prompt)
	all_sessions[current_session_id]["history"].append({"role": "user", "content": prompt})
	input_box.text = ""; _set_ui_busy(true)

	var context_data = get_smart_script_context()
	var code_context = ""
	if not context_data["text"].is_empty():
		code_context = "\n\n【" + ("选中的代码" if context_data["is_selected"] else "当前代码") + "】:\n```gdscript\n" + context_data["text"] + "\n```"

	var godot_philosophy = "你是一名资深的 Godot 4 架构师。请遵循场景驱动哲学，拒绝硬编码。代码必须包裹在 ```gdscript 块中。"
	var messages = []
	if profile["use_system_role"]: messages.append({"role": "system", "content": godot_philosophy})
	
	var history_req = all_sessions[current_session_id]["history"].slice(-MAX_HISTORY_LENGTH)
	for msg in history_req: messages.append(msg.duplicate())
	messages.back()["content"] += code_context
	if not profile["use_system_role"]: messages.back()["content"] = "[系统指令：" + godot_philosophy + "]\n\n" + messages.back()["content"]

	current_ai_content = ""; current_ai_reasoning = ""
	stream_temp_node = renderer.create_stream_node()
	
	var body = JSON.stringify({"model": current_model, "messages": messages, "temperature": profile["temperature"], "stream": true, "max_tokens": 8192})
	net_client.start_stream(current_api_url, current_api_key, body)

func _on_chunk_received(c_delta, r_delta):
	if r_delta != "": current_ai_reasoning += r_delta
	if c_delta != "": current_ai_content += c_delta
	renderer.update_stream_node(stream_temp_node, current_ai_content, current_ai_reasoning)

func _on_stream_completed(): _finish_streaming(false)
func _on_stop_pressed():
	net_client.stop_stream()
	current_ai_content += "\n```\n\n[color=#E06C75][i](已手动终止)[/i][/color]"
	_finish_streaming(true)

func _finish_streaming(is_forced):
	if is_instance_valid(stream_temp_node): stream_temp_node.queue_free()
	_set_ui_busy(false)
	if not current_ai_content.is_empty() or is_forced:
		all_sessions[current_session_id]["history"].append({"role": "assistant", "content": current_ai_content})
		renderer.render_message("assistant", current_ai_content, current_ai_reasoning)
		all_sessions[current_session_id]["title"] = storage.get_updated_title(all_sessions[current_session_id]["history"], all_sessions[current_session_id]["title"])
		_sync_session_ui()
	
	insert_button.disabled = (renderer.last_generated_code == "")
	storage.save_sessions(all_sessions)

# ==========================================
# 🧠 压缩与智能辅助逻辑
# ==========================================
func _on_compress_pressed():
	if current_session_id == "" or all_sessions.is_empty() or is_compressing: return
	var history = all_sessions[current_session_id]["history"]
	if history.size() <= 6:
		var tip = renderer.create_system_tip("[color=#888888][i]当前对话较短，无需压缩。[/i][/color]")
		message_list.add_child(tip)
		await get_tree().create_timer(2.0).timeout
		if is_instance_valid(tip): tip.queue_free()
		return

	is_compressing = true; _set_ui_busy(true)
	var loading_node = renderer.create_system_tip("[color=#E5C07B][i]🧠 正在提炼历史记忆，释放上下文空间...[/i][/color]")
	message_list.add_child(loading_node)

	var to_compress = history.slice(0, history.size() - 4)
	var to_keep = history.slice(history.size() - 4)

	var compress_prompt = "作为Godot专家，请生成对话备忘录提取：1.核心需求。2.已确定代码结构。3.Bug或避坑指南。用简短列表返回。\n---历史---\n"
	for msg in to_compress: compress_prompt += "【%s】: %s\n" % ["用户" if msg["role"] == "user" else "AI", msg["content"].left(800)] 

	var compress_req = HTTPRequest.new(); add_child(compress_req)
	var body = {"model": "deepseek-chat", "messages": [{"role": "user", "content": compress_prompt}], "temperature": 0.1 }
	
	compress_req.request_completed.connect(func(_res, code, _h, res_body):
		if is_instance_valid(loading_node): loading_node.queue_free()
		is_compressing = false; _set_ui_busy(false)

		if code == 200:
			var json = JSON.parse_string(res_body.get_string_from_utf8())
			all_sessions[current_session_id]["history"] = [{"role": "assistant", "content": "✨ [b][color=#E5C07B]已压缩早期上下文。当前记忆备忘录：[/color][/b]\n" + json["choices"][0]["message"]["content"]}] + to_keep
			_load_session_to_ui(current_session_id)
			storage.save_sessions(all_sessions)
		else:
			renderer.render_message("assistant", "[color=#E06C75]压缩记忆失败 (状态码: " + str(code) + ")[/color]")
		compress_req.queue_free()
	)
	compress_req.request(current_api_url, ["Content-Type: application/json", "Authorization: Bearer " + current_api_key], HTTPClient.METHOD_POST, JSON.stringify(body))

func get_smart_script_context():
	var ce = EditorInterface.get_script_editor().get_current_editor()
	if ce and ce.get_base_editor() is CodeEdit:
		var ed = ce.get_base_editor()
		if ed.has_selection(): return {"text": ed.get_selected_text(), "is_selected": true}
		return {"text": ed.text, "is_selected": false}
	return {"text": "", "is_selected": false}

func _on_insert_pressed():
	if renderer.last_generated_code == "": return
	var ce = EditorInterface.get_script_editor().get_current_editor()
	if ce and ce.get_base_editor() is CodeEdit:
		ce.get_base_editor().insert_text_at_caret(renderer.last_generated_code + "\n")

# ==========================================
# ⚙️ 界面杂项事件
# ==========================================
func _on_settings_dialog_confirmed():
	current_api_url = api_url_input.text; current_api_key = api_key_input.text; current_model = model_input.text
	storage.save_config(current_api_url, current_api_key, current_model)
func _load_session_to_ui(id):
	current_session_id = id; renderer.clear_chat()
	for m in all_sessions[id]["history"]: renderer.render_message(m["role"], m["content"])
func _on_clear_pressed():
	if all_sessions.has(current_session_id): all_sessions[current_session_id]["history"].clear(); _load_session_to_ui(current_session_id)
func _on_new_chat_pressed():
	current_session_id = str(Time.get_unix_time_from_system())
	all_sessions[current_session_id] = {"title": "新对话 " + Time.get_time_string_from_system().left(5), "history": []}
	_sync_session_ui(); _load_session_to_ui(current_session_id)
func _on_delete_chat_pressed():
	all_sessions.erase(current_session_id)
	current_session_id = all_sessions.keys().back() if not all_sessions.is_empty() else ""
	if current_session_id == "": _on_new_chat_pressed()
	else: _load_session_to_ui(current_session_id)
	_sync_session_ui(); storage.save_sessions(all_sessions)
func _on_session_selected(idx):
	var ids = all_sessions.keys(); ids.reverse()
	current_session_id = ids[idx]; _load_session_to_ui(current_session_id)
func _sync_session_ui():
	session_selector.clear()
	var ids = all_sessions.keys(); ids.reverse()
	for id in ids: session_selector.add_item(all_sessions[id]["title"])
	for i in ids.size(): if ids[i] == current_session_id: session_selector.selected = i; break
func _on_model_selected(idx): current_model = model_selector.get_item_metadata(idx)
func _setup_model_selector():
	model_selector.clear()
	for i in MODEL_PROFILES.size():
		var k = MODEL_PROFILES.keys()[i]
		model_selector.add_item(MODEL_PROFILES[k]["name"], i)
		model_selector.set_item_metadata(i, k)
func _on_settings_button_pressed():
	api_url_input.text = current_api_url; api_key_input.text = current_api_key; model_input.text = current_model; settings_dialog.popup_centered()
func _input(ev):
	if input_box.has_focus() and ev is InputEventKey and ev.pressed and ev.keycode == KEY_ENTER and not ev.shift_pressed:
		_on_send_pressed(); get_viewport().set_input_as_handled()
