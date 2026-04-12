#负责http连接，sse流式解析
@tool
extends Node
class_name AINetClient

# ==========================================
# 📡 自定义信号：让外部 UI 监听网络状态
# ==========================================
signal chunk_received(content_delta: String, reasoning_delta: String)
signal stream_completed()

# ==========================================
# 📊 内部状态变量
# ==========================================
var stream_client := HTTPClient.new()
var is_streaming := false
var request_sent := false
var stream_buffer := ""

var _api_url := ""
var _api_key := ""
var _body_string := ""

func _ready():
	# 网络节点默认不执行帧循环，节省性能
	set_process(false)

# ==========================================
# 🚀 暴露给外部的启动接口
# ==========================================
func start_stream(url: String, key: String, body: String):
	_api_url = url
	_api_key = key
	_body_string = body

	var host = "api.deepseek.com"
	var port = 443
	var tls_options = TLSOptions.client() 
	
	var clean_url = _api_url.replace("https://", "").replace("http://", "")
	host = clean_url.split("/")[0]
	
	if _api_url.begins_with("http://"):
		port = 80
		tls_options = null 
		
	stream_client.connect_to_host(host, port, tls_options) 
	is_streaming = true
	request_sent = false
	stream_buffer = ""
	set_process(true) # 启动轮询

# ==========================================
# 🛑 暴露给外部的停止接口
# ==========================================
func stop_stream():
	is_streaming = false
	set_process(false)
	stream_client.close()
	stream_buffer = ""

# ==========================================
# 🌊 内部核心轮询与解析逻辑
# ==========================================
func _process(_delta):
	if not is_streaming: return

	stream_client.poll()
	var status = stream_client.get_status()

	if status == HTTPClient.STATUS_CONNECTED and not request_sent:
		var headers = ["Content-Type: application/json", "Authorization: Bearer " + _api_key]
		var clean_url = _api_url.replace("https://", "").replace("http://", "")
		var slash_pos = clean_url.find("/")
		var endpoint = "/chat/completions"
		if slash_pos != -1: endpoint = clean_url.substr(slash_pos)
		
		stream_client.request(HTTPClient.METHOD_POST, endpoint, headers, _body_string)
		request_sent = true

	elif status == HTTPClient.STATUS_BODY or status == HTTPClient.STATUS_CONNECTED:
		if stream_client.has_response():
			var chunk = stream_client.read_response_body_chunk()
			if chunk.size() > 0:
				var text = chunk.get_string_from_utf8()
				_parse_sse_chunk(text)

	elif status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTION_ERROR:
		stop_stream()
		stream_completed.emit() # 通知外部断开了

func _parse_sse_chunk(chunk_text: String):
	stream_buffer += chunk_text
	var lines = stream_buffer.split("\n")
	stream_buffer = lines[lines.size() - 1]

	for i in range(lines.size() - 1):
		var line = lines[i].strip_edges()
		if line.begins_with("data: "):
			var data_str = line.substr(6).strip_edges()
			if data_str == "[DONE]":
				stop_stream()
				stream_completed.emit() # 正常结束，发出信号
				return
			
			var json = JSON.parse_string(data_str)
			if json and json is Dictionary and json.has("choices"):
				var delta = json["choices"][0].get("delta", {})
				
				var r_content = delta.get("reasoning_content", "")
				var content = delta.get("content", "")
				
				# 发射信号，把碎片化数据扔给主 UI
				if r_content != null or content != null:
					var safe_r = r_content if r_content != null else ""
					var safe_c = content if content != null else ""
					chunk_received.emit(safe_c, safe_r)
