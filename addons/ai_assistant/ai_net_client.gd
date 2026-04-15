@tool
extends Node
class_name AINetClient

signal chunk_received(content_delta: String, reasoning_delta: String)
signal stream_completed()
signal stream_failed(error_message: String)

var stream_client: HTTPClient = HTTPClient.new()
var is_streaming: bool = false
var request_sent: bool = false
var stream_buffer: String = ""
var response_code: int = -1
var response_buffer: String = ""
var received_content: bool = false
var stream_finished: bool = false

var _api_url: String = ""
var _api_key: String = ""
var _body_string: String = ""

func _ready() -> void:
	set_process(false)

func start_stream(url: String, key: String, body: String) -> void:
	_api_url = url
	_api_key = key
	_body_string = body
	response_code = -1
	response_buffer = ""
	received_content = false
	stream_finished = false

	var parsed_url: Dictionary = _parse_url(_api_url)
	var host: String = String(parsed_url.get("host", ""))
	var port: int = int(parsed_url.get("port", 443))
	var use_tls: bool = bool(parsed_url.get("use_tls", true))
	var tls_options = TLSOptions.client()
	if not use_tls:
		tls_options = null

	if host.is_empty():
		stream_failed.emit("Invalid API URL: missing host.")
		return

	var connect_error: int = stream_client.connect_to_host(host, port, tls_options)
	if connect_error != OK:
		stop_stream()
		stream_failed.emit("Failed to connect to model service: %s" % error_string(connect_error))
		return

	is_streaming = true
	request_sent = false
	stream_buffer = ""
	set_process(true)

func stop_stream() -> void:
	is_streaming = false
	set_process(false)
	stream_client.close()
	stream_buffer = ""
	response_buffer = ""

func _process(_delta) -> void:
	if not is_streaming:
		return

	var poll_error: int = stream_client.poll()
	_capture_response_code()
	if poll_error != OK:
		var error_message: String = _build_failure_message(stream_client.get_status())
		if response_code == -1:
			error_message = "Network poll failed: %s" % error_string(poll_error)
		stop_stream()
		stream_failed.emit(error_message)
		return

	var status: int = stream_client.get_status()

	if status == HTTPClient.STATUS_CONNECTED and not request_sent:
		var headers: Array = ["Content-Type: application/json", "Authorization: Bearer " + _api_key]
		var parsed_url: Dictionary = _parse_url(_api_url)
		var endpoint: String = String(parsed_url.get("path", "/chat/completions"))

		var request_error: int = stream_client.request(HTTPClient.METHOD_POST, endpoint, headers, _body_string)
		if request_error != OK:
			stop_stream()
			stream_failed.emit("Failed to send request: %s" % error_string(request_error))
			return

		request_sent = true

	elif status == HTTPClient.STATUS_BODY:
		if stream_client.has_response():
			if response_code == -1:
				response_code = stream_client.get_response_code()

			var chunk: PackedByteArray = stream_client.read_response_body_chunk()
			if chunk.size() > 0:
				var text: String = chunk.get_string_from_utf8()
				if response_code >= 400:
					response_buffer += text
				else:
					_parse_sse_chunk(text)

	elif status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTION_ERROR:
		if stream_finished:
			stop_stream()
			return

		var error_message: String = _build_failure_message(status)
		stop_stream()
		stream_failed.emit(error_message)

func _parse_sse_chunk(chunk_text: String) -> void:
	stream_buffer += chunk_text
	var lines: Array = stream_buffer.split("\n")
	stream_buffer = lines[lines.size() - 1]

	for i in range(lines.size() - 1):
		var line: String = String(lines[i]).strip_edges()
		if line.begins_with("data: "):
			var data_str: String = line.substr(6).strip_edges()
			if data_str == "[DONE]":
				stream_finished = true
				stop_stream()
				stream_completed.emit()
				return

			var json = JSON.parse_string(data_str)
			if json and json is Dictionary and json.has("choices"):
				var delta = json["choices"][0].get("delta", {})
				var r_content = delta.get("reasoning_content", "")
				var content = delta.get("content", "")

				if r_content != null or content != null:
					var safe_r: String = ""
					var safe_c: String = ""
					if r_content != null:
						safe_r = String(r_content)
					if content != null:
						safe_c = String(content)
					if not safe_c.is_empty() or not safe_r.is_empty():
						received_content = true
					chunk_received.emit(safe_c, safe_r)

func _build_failure_message(status: int) -> String:
	if response_code >= 400:
		var parsed = JSON.parse_string(response_buffer)
		if parsed is Dictionary:
			if parsed.has("error"):
				var error_data = parsed["error"]
				if error_data is Dictionary and error_data.has("message"):
					return "Request failed (%d): %s" % [response_code, String(error_data["message"])]
			if parsed.has("message"):
				return "Request failed (%d): %s" % [response_code, String(parsed["message"])]

		var compact: String = response_buffer.strip_edges()
		if compact.is_empty():
			return "Request failed, HTTP status: %d" % response_code
		return "Request failed (%d): %s" % [response_code, compact]

	if request_sent and not received_content:
		return "Model connection closed without returning content."

	if status == HTTPClient.STATUS_CONNECTION_ERROR:
		return "Connection to model service was interrupted."

	return "Streaming response ended early."

func _capture_response_code() -> void:
	if response_code != -1:
		return
	if not request_sent:
		return
	if not stream_client.has_response():
		return

	response_code = stream_client.get_response_code()

func _parse_url(url: String) -> Dictionary:
	var use_tls: bool = true
	var default_port: int = 443
	var clean_url: String = url.strip_edges()

	if clean_url.begins_with("http://"):
		use_tls = false
		default_port = 80
		clean_url = clean_url.trim_prefix("http://")
	elif clean_url.begins_with("https://"):
		clean_url = clean_url.trim_prefix("https://")

	var slash_pos: int = clean_url.find("/")
	var authority: String = clean_url
	var path: String = "/chat/completions"
	if slash_pos != -1:
		authority = clean_url.substr(0, slash_pos)
		path = clean_url.substr(slash_pos)

	var host: String = authority
	var port: int = default_port
	var colon_pos: int = authority.rfind(":")
	if colon_pos > 0:
		var maybe_port: String = authority.substr(colon_pos + 1)
		if maybe_port.is_valid_int():
			host = authority.substr(0, colon_pos)
			port = maybe_port.to_int()

	if path.is_empty():
		path = "/chat/completions"

	return {
		"host": host,
		"port": port,
		"path": path,
		"use_tls": use_tls,
	}
