@tool
extends Control

# --- 节点引用 ---
@onready var output_box = $VBoxContainer/RichTextLabel
@onready var input_box = $VBoxContainer/TextEdit
@onready var http_request = $HTTPRequest

# 顶部容器 (对应你的 HBoxContainer_top)
@onready var session_selector = $VBoxContainer/HBoxContainer_top/SessionSelector
@onready var new_chat_button = $VBoxContainer/HBoxContainer_top/NewChatButton
@onready var delete_chat_button = $VBoxContainer/HBoxContainer_top/DeleteChatButton

# 底部容器 (对应你的 HBoxContainer)
@onready var model_selector = $VBoxContainer/HBoxContainer/ModelSelector
@onready var clear_button = $VBoxContainer/HBoxContainer/ClearButton
@onready var compress_button = $VBoxContainer/HBoxContainer/CompressButton
@onready var settings_button = $VBoxContainer/HBoxContainer/SettingsButton
@onready var insert_button = $VBoxContainer/HBoxContainer/InsertButton
@onready var send_button = $VBoxContainer/HBoxContainer/SendButton

@onready var settings_dialog = $SettingsDialog
@onready var api_url_input = $SettingsDialog/VBoxContainer/ApiUrlInput
@onready var api_key_input = $SettingsDialog/VBoxContainer/ApiKeyInput
@onready var model_input = $SettingsDialog/VBoxContainer/ModelInput

const CONFIG_PATH = "user://ai_assistant_config.cfg"
const SESSIONS_PATH = "user://ai_sessions.json" # 🌟 会话存档路径

# --- 核心变量 ---
var current_api_url: String = "https://api.deepseek.com/chat/completions"
var current_api_key: String = ""
var current_model: String = "deepseek-chat"

var all_sessions: Dictionary = {} # 存储所有会话
var current_session_id: String = ""
var last_generated_code: String = ""
var is_compressing: bool = false
const MAX_HISTORY_LENGTH = 15 # 自动截断阈值

func _ready():
	# 连接信号
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

	_setup_model_selector()
	load_config()
	load_all_sessions() # 从本地磁盘读取之前的对话
	
	# 如果是第一次运行，自动创建一个新对话
	if all_sessions.is_empty():
		_on_new_chat_pressed()
	else:
		_sync_session_ui()
		_load_session_to_ui(all_sessions.keys().back()) # 加载最后一个对话

func _print_welcome_message():
	output_box.append_text("[color=#888888]系统：AI 助手已就绪。当前模型：" + current_model + "[/color]\n\n")

# ==========================================
# 🌟 会话持久化与管理
# ==========================================

func _on_new_chat_pressed():
	_save_current_to_memory()
	current_session_id = str(Time.get_unix_time_from_system())
	all_sessions[current_session_id] = {
		"title": "新对话 " + Time.get_time_string_from_system().left(5),
		"history": []
	}
	_sync_session_ui()
	_load_session_to_ui(current_session_id)
	output_box.append_text("[color=#98C379]✨ 已开启新对话。[/color]\n\n")

# 点击 ❌ 按钮：删除当前会话
func _on_delete_chat_pressed():
	if current_session_id == "" or all_sessions.is_empty(): return
	
	# 弹窗确认（可选，这里先做直接删除，效率更高）
	all_sessions.erase(current_session_id)
	
	if all_sessions.is_empty():
		# 如果删光了，自动建个新的
		_on_new_chat_pressed()
	else:
		# 如果还有剩下的，切换到第一个
		current_session_id = all_sessions.keys().back()
		_load_session_to_ui(current_session_id)
		_sync_session_ui()
	
	save_all_sessions_to_disk()
	output_box.append_text("[color=#E06C75]系统：该会话已从硬盘永久删除。[/color]\n\n")

func _on_session_selected(index: int):
	_save_current_to_memory()
	# 因为 UI 倒序显示最新的，所以我们要反转索引找到对应的 ID
	var ids = all_sessions.keys()
	ids.reverse() 
	current_session_id = ids[index]
	_load_session_to_ui(current_session_id)

func _save_current_to_memory():
	if current_session_id != "" and all_sessions.has(current_session_id):
		# 如果还没标题，用第一句提问当标题
		var history = all_sessions[current_session_id]["history"]
		if history.size() > 0 and all_sessions[current_session_id]["title"].begins_with("新对话"):
			all_sessions[current_session_id]["title"] = history[0]["content"].left(12) + "..."
		save_all_sessions_to_disk()

func _load_session_to_ui(id: String):
	current_session_id = id
	output_box.clear()
	_print_welcome_message()
	for msg in all_sessions[id]["history"]:
		_render_message(msg["role"], msg["content"])

func _sync_session_ui():
	session_selector.clear()
	var ids = all_sessions.keys()
	ids.reverse()
	for id in ids:
		session_selector.add_item(all_sessions[id]["title"])
	# 重新定位选中项
	for i in range(ids.size()):
		if ids[i] == current_session_id:
			session_selector.selected = i
			break

func save_all_sessions_to_disk():
	var file = FileAccess.open(SESSIONS_PATH, FileAccess.WRITE)
	if file: file.store_string(JSON.stringify(all_sessions))

func load_all_sessions():
	if FileAccess.file_exists(SESSIONS_PATH):
		var file = FileAccess.open(SESSIONS_PATH, FileAccess.READ)
		var json = JSON.parse_string(file.get_as_text())
		if json is Dictionary: all_sessions = json

# ==========================================
# 🌟 清空与压缩
# ==========================================

func _on_clear_pressed():
	if all_sessions.has(current_session_id):
		all_sessions[current_session_id]["history"].clear()
		output_box.clear()
		_print_welcome_message()
		save_all_sessions_to_disk()

func _on_compress_pressed():
	if current_api_key == "" or not all_sessions.has(current_session_id): return
	var history = all_sessions[current_session_id]["history"]
	if history.size() <= 2: return
	
	is_compressing = true
	_set_ui_busy(true)
	output_box.append_text("[color=#E5C07B]✂️ 正在提炼记忆摘要...[/color]\n")
	
	var raw_text = ""
	for msg in history: raw_text += msg["role"] + ": " + msg["content"] + "\n"
	
	var compress_msg = [
		{"role": "system", "content": "总结以下对话为一段简短备忘录，保留核心逻辑。不要输出代码块。"},
		{"role": "user", "content": raw_text}
	]
	
	var headers = ["Content-Type: application/json", "Authorization: Bearer " + current_api_key]
	var body = JSON.stringify({"model": "deepseek-chat", "messages": compress_msg, "temperature": 0.1})
	http_request.request(current_api_url, headers, HTTPClient.METHOD_POST, body)

# ==========================================
# 🚀 核心请求逻辑
# ==========================================

func _on_send_pressed():
	var prompt = input_box.text.strip_edges()
	if prompt == "" or current_api_key == "": return
	
	_render_message("user", prompt)
	input_box.text = ""
	_set_ui_busy(true)
	
	all_sessions[current_session_id]["history"].append({"role": "user", "content": prompt})
	
	var messages = [
		{"role": "system", "content": "你是一个Godot 4高级架构师。必须用 ```gdscript 包裹代码。"},
		{"role": "system", "content": get_project_context()}
	]
	# 注入历史记录
	for msg in all_sessions[current_session_id]["history"]: messages.append(msg)
	
	# 注入当前脚本上下文
	var cur_code = get_current_script_text()
	if cur_code != "":
		messages.back()["content"] = "【当前脚本】\n```gdscript\n" + cur_code + "\n```\n\n【需求】：" + prompt

	var headers = ["Content-Type: application/json", "Authorization: Bearer " + current_api_key]
	var body = JSON.stringify({"model": current_model, "messages": messages, "temperature": 0.2})
	http_request.request(current_api_url, headers, HTTPClient.METHOD_POST, body)

func _on_request_completed(result, response_code, headers, body):
	_set_ui_busy(false)
	if response_code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		var message = json["choices"][0]["message"]
		var reply = message["content"]
		
		if is_compressing:
			is_compressing = false
			all_sessions[current_session_id]["history"] = [{"role": "assistant", "content": "【记忆摘要】：\n" + reply}]
			_load_session_to_ui(current_session_id)
			output_box.append_text("[color=#98C379]✅ 压缩完成。[/color]\n")
			return

		var reasoning = message.get("reasoning_content", "")
		# 提取思维链
		if "<think>" in reply:
			var parts = reply.split("</think>")
			if parts.size() > 1:
				reasoning = parts[0].replace("<think>", "").strip_edges()
				reply = parts[1].strip_edges()
		
		all_sessions[current_session_id]["history"].append({"role": "assistant", "content": reply})
		_render_message("assistant", reply, reasoning)
		
		last_generated_code = extract_code_from_markdown(reply)
		insert_button.disabled = (last_generated_code == "")
		_save_current_to_memory()
		_sync_session_ui() # 更新标题
	else:
		output_box.append_text("[color=#E06C75]错误: " + str(response_code) + "[/color]\n")

# ==========================================
# 🛠️ 辅助 UI 函数
# ==========================================

func _render_message(role: String, content: String, reasoning: String = ""):
	if role == "user":
		output_box.append_text("[color=#98C379][b]🧑 你：[/b][/color]\n" + content + "\n\n")
	else:
		if reasoning != "":
			output_box.append_text("[color=#5C6370][i]🧠 推理：\n" + reasoning + "\n[/i][/color]\n")
		output_box.append_text("[color=#61AFEF][b]🤖 AI：[/b][/color]\n" + content + "\n")
		output_box.append_text("[color=#555555]------------------------[/color]\n\n")

func _set_ui_busy(busy: bool):
	send_button.disabled = busy
	new_chat_button.disabled = busy
	compress_button.disabled = busy
	clear_button.disabled = busy
	delete_chat_button.disabled = busy # 🌟 忙碌时禁用删除

# --- 以下为你原有的工具函数 (保持不变) ---
func extract_code_from_markdown(text: String) -> String:
	var regex = RegEx.new()
	regex.compile("```[a-zA-Z]*\\n([\\s\\S]*?)```")
	var m = regex.search(text)
	return m.get_string(1).strip_edges() if m else ""

func _on_insert_pressed():
	if last_generated_code == "": return
	var ce = EditorInterface.get_script_editor().get_current_editor()
	if ce and ce.get_base_editor() is CodeEdit:
		ce.get_base_editor().insert_text_at_caret(last_generated_code + "\n")

func get_project_context() -> String:
	var ctx = "【项目地图】\n"
	for prop in ProjectSettings.get_property_list():
		if prop.name.begins_with("autoload/"):
			ctx += "- 单例: " + prop.name.replace("autoload/", "") + "\n"
	return ctx

func get_current_script_text() -> String:
	var ce = EditorInterface.get_script_editor().get_current_editor()
	return ce.get_base_editor().text if (ce and ce.get_base_editor() is CodeEdit) else ""

func _setup_model_selector():
	model_selector.clear()
	model_selector.add_item("Chat", 0)
	model_selector.add_item("Reasoner", 1)
	model_selector.item_selected.connect(_on_model_item_selected)

func _on_model_item_selected(index: int):
	current_model = "deepseek-chat" if index == 0 else "deepseek-reasoner"
	save_config(current_api_url, current_api_key, current_model)

func _sync_ui_with_config():
	model_selector.selected = 1 if "reasoner" in current_model else 0

func load_config():
	var config = ConfigFile.new()
	if config.load(CONFIG_PATH) == OK:
		current_api_url = config.get_value("API", "url", "[https://api.deepseek.com/chat/completions](https://api.deepseek.com/chat/completions)")
		current_api_key = config.get_value("API", "key", "")
		current_model = config.get_value("API", "model", "deepseek-chat")

func save_config(url, key, model):
	var config = ConfigFile.new()
	config.set_value("API", "url", url)
	config.set_value("API", "key", key)
	config.set_value("API", "model", model)
	config.save(CONFIG_PATH)
	current_api_url = url; current_api_key = key; current_model = model

func _on_settings_button_pressed():
	api_url_input.text = current_api_url
	api_key_input.text = current_api_key
	model_input.text = current_model
	settings_dialog.popup_centered()

func _on_settings_dialog_confirmed():
	save_config(api_url_input.text, api_key_input.text, model_input.text)
