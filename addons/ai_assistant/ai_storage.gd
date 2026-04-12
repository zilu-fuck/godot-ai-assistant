#负责写本地config sessions
@tool
extends Node
class_name AIStorage

# ==========================================
# 📂 常量定义：统一管理文件路径
# ==========================================
const CONFIG_PATH = "user://ai_assistant_config.cfg"
const SESSIONS_PATH = "user://ai_sessions.json"

# ==========================================
# ⚙️ 配置管理 (Settings)
# ==========================================
func load_config() -> Dictionary:
	var config = ConfigFile.new()
	var data = {
		"url": "https://api.deepseek.com/chat/completions",
		"key": "",
		"model": "deepseek-chat"
	}
	
	if config.load(CONFIG_PATH) == OK:
		data.url = config.get_value("API", "url", data.url)
		data.key = config.get_value("API", "key", "")
		data.model = config.get_value("API", "model", data.model)
	return data

func save_config(url: String, key: String, model: String):
	var config = ConfigFile.new()
	config.set_value("API", "url", url)
	config.set_value("API", "key", key)
	config.set_value("API", "model", model)
	config.save(CONFIG_PATH)

# ==========================================
# 💬 会话持久化 (Sessions)
# ==========================================
func load_all_sessions() -> Dictionary:
	if FileAccess.file_exists(SESSIONS_PATH):
		var file = FileAccess.open(SESSIONS_PATH, FileAccess.READ)
		var json = JSON.parse_string(file.get_as_text())
		if json is Dictionary:
			return json
	return {}

func save_sessions(all_sessions: Dictionary):
	var file = FileAccess.open(SESSIONS_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(all_sessions))

# 自动更新标题的逻辑也抽离到这里，减轻主脚本负担
func get_updated_title(history: Array, current_title: String) -> String:
	if history.size() > 0 and current_title.begins_with("新对话"):
		var first_msg = history[0]["content"]
		return first_msg.left(12).strip_edges() + "..."
	return current_title
