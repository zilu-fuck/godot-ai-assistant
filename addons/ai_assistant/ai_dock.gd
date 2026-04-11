@tool
extends Control

# --- 节点引用 ---
@onready var output_box = $VBoxContainer/RichTextLabel
@onready var input_box = $VBoxContainer/TextEdit
@onready var http_request = $HTTPRequest

# 顶部容器
@onready var session_selector = $VBoxContainer/HBoxContainer_top/SessionSelector
@onready var new_chat_button = $VBoxContainer/HBoxContainer_top/NewChatButton
@onready var delete_chat_button = $VBoxContainer/HBoxContainer_top/DeleteChatButton

# 底部容器
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
const SESSIONS_PATH = "user://ai_sessions.json"

# ==========================================
# ⚙️ 模型能力画像 (解决硬编码的关键)
# ==========================================
const MODEL_PROFILES = {
	"deepseek-chat": {
		"name": "DeepSeek Chat (V3.2)",
		"use_system_role": true,
		"context_style": "default",
		"temperature": 0.7
	},
	"deepseek-reasoner": {
		"name": "DeepSeek Reasoner (R1)",
		"use_system_role": false,      # R1 不建议使用 system 角色
		"context_style": "instruction_prefix", # 指令前置风格
		"temperature": 0.3             # 推理模型通常使用低采样
	}
}

# --- 核心变量 ---
var current_api_url: String = "https://api.deepseek.com/chat/completions"
var current_api_key: String = ""
var current_model: String = "deepseek-chat"

var all_sessions: Dictionary = {} 
var current_session_id: String = ""
var last_generated_code: String = ""
var is_compressing: bool = false

# --- 优化策略变量 ---
const MAX_HISTORY_LENGTH = 15 
var last_sent_script_content: String = "" 
var max_scan_depth = 3 

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

	_setup_model_selector()
	load_config()
	load_all_sessions()
	
	if all_sessions.is_empty():
		_on_new_chat_pressed()
	else:
		_sync_session_ui()
		_load_session_to_ui(all_sessions.keys().back())

func _print_welcome_message():
	output_box.append_text("[color=#888888]系统：AI 助手已就绪。当前模型：" + current_model + "[/color]\n\n")

# ==========================================
# 🌟 会话管理逻辑
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

func _on_delete_chat_pressed():
	if current_session_id == "" or all_sessions.is_empty(): return
	all_sessions.erase(current_session_id)
	if all_sessions.is_empty():
		_on_new_chat_pressed()
	else:
		current_session_id = all_sessions.keys().back()
		_load_session_to_ui(current_session_id)
		_sync_session_ui()
	save_all_sessions_to_disk()
	output_box.append_text("[color=#E06C75]系统：会话已删除。[/color]\n\n")

func _on_session_selected(index: int):
	_save_current_to_memory()
	var ids = all_sessions.keys()
	ids.reverse() 
	current_session_id = ids[index]
	_load_session_to_ui(current_session_id)

func _save_current_to_memory():
	if current_session_id != "" and all_sessions.has(current_session_id):
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
# 🚀 核心发送逻辑 (解耦与优化版)
# ==========================================

func _on_send_pressed():
	var prompt = input_box.text.strip_edges()
	if prompt == "" or current_api_key == "": return
	
	# 获取当前模型的“性格配置”
	var profile = MODEL_PROFILES.get(current_model, MODEL_PROFILES["deepseek-chat"])
	
	# 1. 存入纯净历史 (不带代码上下文)
	_render_message("user", prompt)
	all_sessions[current_session_id]["history"].append({"role": "user", "content": prompt})
	input_box.text = ""
	_set_ui_busy(true)

	# 2. 准备动态代码上下文
	var cur_code = get_current_script_text()
	var code_context = ""
	if cur_code != "":
		if cur_code != last_sent_script_content:
			code_context = "\n\n【当前脚本已更新】:\n```gdscript\n" + cur_code + "\n```"
			last_sent_script_content = cur_code
		else:
			code_context = "\n\n（当前脚本内容未变化）"

	# 3. 组装消息列表
	var messages = []
	
	# 系统提示词 (根据模型画像判断是否添加)
	if profile["use_system_role"]:
		var sys_msg = "你是一个专业 Godot 4 开发助手。回答使用中文，代码用 ```gdscript 包裹。\n"
		sys_msg += get_project_context()
		messages.append({"role": "system", "content": sys_msg})
	
	# 注入历史记录 (截断逻辑)
	var history_for_req = all_sessions[current_session_id]["history"].duplicate()
	if history_for_req.size() > MAX_HISTORY_LENGTH:
		history_for_req = history_for_req.slice(-MAX_HISTORY_LENGTH)
	
	for msg in history_for_req:
		messages.append(msg.duplicate())
	
	# 4. 根据上下文风格拼接最后一条消息
	var last_msg = messages.back()
	if profile["context_style"] == "instruction_prefix":
		last_msg["content"] = "【指令】分析代码并处理需求：\n" + code_context + "\n\n【需求】：" + prompt
	else:
		last_msg["content"] = prompt + code_context

	# 5. 发送请求
	var headers = ["Content-Type: application/json", "Authorization: Bearer " + current_api_key]
	var body = {
		"model": current_model,
		"messages": messages,
		"temperature": profile["temperature"]
	}
	http_request.request(current_api_url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))

func _on_request_completed(_result, response_code, _headers, body):
	_set_ui_busy(false)
	if response_code == 200:
		var json = JSON.parse_string(body.get_string_from_utf8())
		var message = json["choices"][0]["message"]
		var reply = message["content"]
		
		# 处理压缩逻辑
		if is_compressing:
			is_compressing = false
			all_sessions[current_session_id]["history"] = [{"role": "assistant", "content": "【记忆摘要】：\n" + reply}]
			_load_session_to_ui(current_session_id)
			output_box.append_text("[color=#98C379]✅ 压缩完成。[/color]\n")
			return

		# 提取思维链
		var reasoning = message.get("reasoning_content", "")
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
		_sync_session_ui() 
	else:
		output_box.append_text("[color=#E06C75]错误代码: " + str(response_code) + "[/color]\n")

# ==========================================
# 🛠️ 上下文获取 (全项目扫描)
# ==========================================

func get_project_context() -> String:
	var ctx = "\n【项目地图】\n"
	ctx += "--- 单例 (Autoloads) ---\n"
	for prop in ProjectSettings.get_property_list():
		if prop.name.begins_with("autoload/"):
			ctx += "- " + prop.name.replace("autoload/", "") + "\n"
	
	ctx += "\n--- 关键文件结构 ---\n"
	ctx += _scan_directory("res://", 0)
	return ctx

func _scan_directory(path: String, depth: int) -> String:
	if depth > max_scan_depth: return ""
	var result = ""
	var dir = DirAccess.open(path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.begin_with(".") or file_name == "addons":
				file_name = dir.get_next()
				continue
			var full_path = path + file_name
			var indent = "  ".repeat(depth)
			if dir.current_is_dir():
				result += indent + "📁 " + file_name + "/\n"
				result += _scan_directory(full_path + "/", depth + 1)
			else:
				if file_name.ends_with(".gd") or file_name.ends_with(".tscn") or file_name.ends_with(".gdshader"):
					result += indent + "📄 " + file_name + "\n"
			file_name = dir.get_next()
	return result

# ==========================================
# ⚙️ 配置与 UI 辅助
# ==========================================

func _setup_model_selector():
	model_selector.clear()
	var keys = MODEL_PROFILES.keys()
	for i in range(keys.size()):
		var key = keys[i]
		model_selector.add_item(MODEL_PROFILES[key]["name"], i)
		model_selector.set_item_metadata(i, key) # 存入真实的 model 字符串

func _on_model_item_selected(index: int):
	current_model = model_selector.get_item_metadata(index)
	save_config(current_api_url, current_api_key, current_model)

func load_config():
	var config = ConfigFile.new()
	if config.load(CONFIG_PATH) == OK:
		current_api_url = config.get_value("API", "url", "[https://api.deepseek.com/chat/completions](https://api.deepseek.com/chat/completions)")
		current_api_key = config.get_value("API", "key", "")
		current_model = config.get_value("API", "model", "deepseek-chat")
		# 还原 UI 选中状态
		for i in range(model_selector.item_count):
			if model_selector.get_item_metadata(i) == current_model:
				model_selector.selected = i
				break

func save_config(url, key, model):
	var config = ConfigFile.new()
	config.set_value("API", "url", url)
	config.set_value("API", "key", key)
	config.set_value("API", "model", model)
	config.save(CONFIG_PATH)
	current_api_url = url; current_api_key = key; current_model = model

func _on_settings_dialog_confirmed():
	save_config(api_url_input.text, api_key_input.text, model_input.text)

func _on_compress_pressed():
	if current_api_key == "" or not all_sessions.has(current_session_id): return
	var history = all_sessions[current_session_id]["history"]
	if history.size() <= 2: return
	
	is_compressing = true
	_set_ui_busy(true)
	output_box.append_text("[color=#E5C07B]✂️ 正在压缩长对话...[/color]\n")
	
	var raw_text = ""
	for msg in history: raw_text += msg["role"] + ": " + msg["content"] + "\n"
	
	var compress_msg = [
		{"role": "system", "content": "请用一小段话总结以下对话的核心需求。不要代码。"},
		{"role": "user", "content": raw_text}
	]
	
	var headers = ["Content-Type: application/json", "Authorization: Bearer " + current_api_key]
	var body = JSON.stringify({"model": "deepseek-chat", "messages": compress_msg, "temperature": 0.1})
	http_request.request(current_api_url, headers, HTTPClient.METHOD_POST, body)

# --- 原有工具函数保持不变 ---
func _render_message(role: String, content: String, reasoning: String = ""):
	if role == "user":
		output_box.append_text("[color=#98C379][b]🧑 你：[/b][/color]\n" + content + "\n\n")
	else:
		if reasoning != "":
			output_box.append_text("[color=#5C6370][i]🧠 思考逻辑：\n" + reasoning + "\n[/i][/color]\n")
		output_box.append_text("[color=#61AFEF][b]🤖 AI：[/b][/color]\n" + content + "\n")
		output_box.append_text("[color=#555555]------------------------[/color]\n\n")

func extract_code_from_markdown(text: String) -> String:
	var regex = RegEx.new()
	regex.compile("```[a-zA-Z]*\\n([\\s\\S]*?)```")
	var m = regex.search(text)
	return m.get_string(1).strip_edges() if m else ""

func get_current_script_text() -> String:
	var ce = EditorInterface.get_script_editor().get_current_editor()
	return ce.get_base_editor().text if (ce and ce.get_base_editor() is CodeEdit) else ""

func _set_ui_busy(busy: bool):
	send_button.disabled = busy
	new_chat_button.disabled = busy
	compress_button.disabled = busy
	clear_button.disabled = busy
	delete_chat_button.disabled = busy

func _on_clear_pressed():
	if all_sessions.has(current_session_id):
		all_sessions[current_session_id]["history"].clear()
		output_box.clear()
		_print_welcome_message()
		save_all_sessions_to_disk()

func _on_settings_button_pressed():
	api_url_input.text = current_api_url
	api_key_input.text = current_api_key
	model_input.text = current_model
	settings_dialog.popup_centered()

func _on_insert_pressed():
	if last_generated_code == "": return
	var ce = EditorInterface.get_script_editor().get_current_editor()
	if ce and ce.get_base_editor() is CodeEdit:
		ce.get_base_editor().insert_text_at_caret(last_generated_code + "\n")
