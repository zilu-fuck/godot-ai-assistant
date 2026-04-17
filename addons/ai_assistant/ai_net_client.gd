@tool
extends Node
class_name AINetClient

const CONNECT_TIMEOUT_MS: int = 12000
const RESPONSE_TIMEOUT_MS: int = 25000
const STREAM_IDLE_TIMEOUT_MS: int = 30000

signal chunk_received(content_delta: String, reasoning_delta: String)
signal stream_completed(response_info: Dictionary)
signal stream_failed(error_message: String, failure_info: Dictionary)

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
var _stream_started_at: int = 0
var _request_sent_at: int = 0
var _last_activity_at: int = 0
var _request_stream: bool = true
var _current_request_options: Dictionary = {}
var _received_content_buffer: String = ""
var _received_reasoning_buffer: String = ""

func _ready() -> void:
	set_process(false)

func start_stream(url: String, key: String, body: String) -> Dictionary:
	return start_request(url, key, body, {"stream": true})

func start_request(url: String, key: String, body: String, options: Dictionary = {}) -> Dictionary:
	stop_stream()
	_api_url = url
	_api_key = key
	_body_string = body
	response_code = -1
	response_buffer = ""
	received_content = false
	stream_finished = false
	_request_stream = bool(options.get("stream", true))
	_current_request_options = options.duplicate(true)
	_received_content_buffer = ""
	_received_reasoning_buffer = ""

	var parsed_url: Dictionary = _parse_url(_api_url)
	var host: String = String(parsed_url.get("host", ""))
	var port: int = int(parsed_url.get("port", 443))
	var use_tls: bool = bool(parsed_url.get("use_tls", true))
	var tls_options = TLSOptions.client()
	if not use_tls:
		tls_options = null

	if host.is_empty():
		return {
			"ok": false,
			"message": "The API URL is invalid because the host is missing.",
		}

	var connect_error: int = stream_client.connect_to_host(host, port, tls_options)
	if connect_error != OK:
		stop_stream()
		return {
			"ok": false,
			"message": "Failed to connect to the model service: %s" % error_string(connect_error),
		}

	is_streaming = true
	request_sent = false
	stream_buffer = ""
	_stream_started_at = Time.get_ticks_msec()
	_request_sent_at = 0
	_last_activity_at = _stream_started_at
	set_process(true)
	return {"ok": true}

func stop_stream() -> void:
	is_streaming = false
	set_process(false)
	stream_client.close()
	stream_buffer = ""
	response_buffer = ""
	request_sent = false
	received_content = false
	stream_finished = false
	_stream_started_at = 0
	_request_sent_at = 0
	_last_activity_at = 0
	_request_stream = true
	_current_request_options = {}
	_received_content_buffer = ""
	_received_reasoning_buffer = ""

func _process(_delta) -> void:
	if not is_streaming:
		return

	var timeout_result: Dictionary = _check_timeouts()
	if not timeout_result.is_empty():
		_fail_stream(
			str(timeout_result.get("message", "The request timed out.")),
			{
				"failure_kind": str(timeout_result.get("failure_kind", "timeout")),
				"phase": str(timeout_result.get("phase", _current_phase())),
			}
		)
		return

	var poll_error: int = stream_client.poll()
	_capture_response_code()
	if poll_error != OK:
		var failure_kind: String = "poll_failed"
		if request_sent and received_content:
			failure_kind = "stream_interrupted"
		elif request_sent:
			failure_kind = "response_interrupted"
		_fail_stream(
			_build_failure_message(stream_client.get_status()),
			{
				"failure_kind": failure_kind,
				"phase": _current_phase(),
				"poll_error": poll_error,
			}
		)
		return

	var status: int = stream_client.get_status()

	if status == HTTPClient.STATUS_CONNECTED and not request_sent:
		var headers: Array = ["Content-Type: application/json", "Authorization: Bearer " + _api_key]
		var parsed_url: Dictionary = _parse_url(_api_url)
		var endpoint: String = String(parsed_url.get("path", "/chat/completions"))
		var request_error: int = stream_client.request(HTTPClient.METHOD_POST, endpoint, headers, _body_string)
		if request_error != OK:
			_fail_stream(
				"Failed to send the request: %s" % error_string(request_error),
				{
					"failure_kind": "request_failed",
					"phase": "send_request",
					"request_error": request_error,
				}
			)
			return

		request_sent = true
		_request_sent_at = Time.get_ticks_msec()
		_last_activity_at = _request_sent_at
	elif status == HTTPClient.STATUS_BODY:
		_read_response_body()
	elif status == HTTPClient.STATUS_DISCONNECTED or status == HTTPClient.STATUS_CONNECTION_ERROR:
		if stream_finished:
			stop_stream()
			return

		if _should_complete_non_streaming_success(status):
			_complete_non_streaming_response()
			return

		var failure_kind: String = "connection_interrupted"
		if request_sent and received_content:
			failure_kind = "stream_interrupted"
		elif request_sent:
			failure_kind = "response_interrupted"
		_fail_stream(
			_build_failure_message(status),
			{
				"failure_kind": failure_kind,
				"phase": _current_phase(),
				"status": status,
			}
		)

func _read_response_body() -> void:
	if not stream_client.has_response():
		return

	if response_code == -1:
		response_code = stream_client.get_response_code()

	var chunk: PackedByteArray = stream_client.read_response_body_chunk()
	if chunk.is_empty():
		return

	_last_activity_at = Time.get_ticks_msec()
	var text: String = chunk.get_string_from_utf8()
	if response_code >= 400:
		response_buffer += text
		return

	if _request_stream:
		_parse_sse_chunk(text)
	else:
		response_buffer += text

func _parse_sse_chunk(chunk_text: String) -> void:
	stream_buffer += chunk_text
	var lines: Array = stream_buffer.split("\n")
	stream_buffer = lines[lines.size() - 1]

	for i in range(lines.size() - 1):
		var line: String = String(lines[i]).strip_edges()
		if not line.begins_with("data: "):
			continue

		var data_str: String = line.substr(6).strip_edges()
		if data_str == "[DONE]":
			stream_finished = true
			var response_info: Dictionary = _build_response_info({
				"completed_via": "stream_done",
			})
			stop_stream()
			stream_completed.emit(response_info)
			return

		var json = JSON.parse_string(data_str)
		if not (json is Dictionary) or not json.has("choices"):
			continue

		var delta = json["choices"][0].get("delta", {})
		var reasoning_delta: String = ""
		var content_delta: String = ""
		if delta is Dictionary:
			reasoning_delta = _normalize_message_content(delta.get("reasoning_content", ""))
			content_delta = _normalize_message_content(delta.get("content", ""))

		if reasoning_delta.is_empty() and content_delta.is_empty():
			continue

		if not reasoning_delta.is_empty():
			_received_reasoning_buffer += reasoning_delta
		if not content_delta.is_empty():
			received_content = true
			_received_content_buffer += content_delta

		chunk_received.emit(content_delta, reasoning_delta)

func _complete_non_streaming_response() -> void:
	var parsed: Variant = JSON.parse_string(response_buffer)
	var content: String = ""
	var reasoning: String = ""

	if parsed is Dictionary and parsed.has("choices"):
		var choice: Variant = parsed["choices"][0]
		if choice is Dictionary:
			var message: Variant = choice.get("message", {})
			if message is Dictionary:
				content = _normalize_message_content(message.get("content", ""))
				reasoning = _normalize_message_content(message.get("reasoning_content", ""))
			if content.is_empty():
				content = _normalize_message_content(choice.get("text", ""))

	if content.is_empty() and not response_buffer.strip_edges().is_empty():
		content = response_buffer.strip_edges()

	if not reasoning.is_empty():
		_received_reasoning_buffer += reasoning
	if not content.is_empty():
		received_content = true
		_received_content_buffer += content
		chunk_received.emit(content, reasoning)

	stream_finished = true
	var response_info: Dictionary = _build_response_info({
		"completed_via": "non_stream_response",
	})
	stop_stream()
	stream_completed.emit(response_info)

func _check_timeouts() -> Dictionary:
	var now: int = Time.get_ticks_msec()

	if not request_sent and _stream_started_at > 0 and now - _stream_started_at >= CONNECT_TIMEOUT_MS:
		return {
			"message": "Connecting to the model service timed out.",
			"failure_kind": "connect_timeout",
			"phase": "connect",
		}

	if request_sent and not received_content and _request_sent_at > 0 and now - _request_sent_at >= RESPONSE_TIMEOUT_MS:
		return {
			"message": "Timed out while waiting for the model response.",
			"failure_kind": "first_byte_timeout",
			"phase": "await_first_chunk",
		}

	if request_sent and _last_activity_at > 0 and now - _last_activity_at >= STREAM_IDLE_TIMEOUT_MS:
		return {
			"message": "The response was idle for too long and timed out.",
			"failure_kind": "stream_idle_timeout",
			"phase": _current_phase(),
		}

	return {}

func _fail_stream(message: String, extra: Dictionary = {}) -> void:
	var failure_info: Dictionary = _build_failure_info(extra)
	stop_stream()
	stream_failed.emit(message, failure_info)

func _should_complete_non_streaming_success(status: int) -> bool:
	if _request_stream:
		return false
	if not request_sent:
		return false
	if response_code >= 400:
		return false
	if status != HTTPClient.STATUS_DISCONNECTED and status != HTTPClient.STATUS_CONNECTION_ERROR:
		return false
	return not response_buffer.strip_edges().is_empty()

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
			return "Request failed. HTTP status code: %d" % response_code
		return "Request failed (%d): %s" % [response_code, compact]

	if request_sent and not received_content:
		return "The model connection closed before any content was returned."

	if status == HTTPClient.STATUS_CONNECTION_ERROR:
		return "The connection to the model service was interrupted."

	return "The response ended unexpectedly."

func _build_failure_info(extra: Dictionary = {}) -> Dictionary:
	var info: Dictionary = {
		"failure_kind": str(extra.get("failure_kind", "unknown")),
		"phase": str(extra.get("phase", _current_phase())),
		"response_code": response_code,
		"request_sent": request_sent,
		"received_content": received_content,
		"stream": _request_stream,
		"partial_content": _received_content_buffer,
		"partial_reasoning": _received_reasoning_buffer,
		"response_text": response_buffer,
		"request_options": _current_request_options.duplicate(true),
	}

	for key in extra.keys():
		info[key] = extra[key]
	return info

func _build_response_info(extra: Dictionary = {}) -> Dictionary:
	var info: Dictionary = {
		"response_code": response_code,
		"stream": _request_stream,
		"content": _received_content_buffer,
		"reasoning": _received_reasoning_buffer,
		"request_options": _current_request_options.duplicate(true),
	}
	for key in extra.keys():
		info[key] = extra[key]
	return info

func _current_phase() -> String:
	if not request_sent:
		return "connect"
	if not received_content:
		return "await_first_chunk"
	if _request_stream:
		return "streaming"
	return "read_response"

func _capture_response_code() -> void:
	if response_code != -1:
		return
	if not request_sent:
		return
	if not stream_client.has_response():
		return

	response_code = stream_client.get_response_code()

func _normalize_message_content(value: Variant) -> String:
	if value is String:
		return String(value)
	if value is Array:
		var parts: Array = []
		for part in value:
			if part is String:
				parts.append(String(part))
				continue
			if part is Dictionary:
				var text_part: String = String(part.get("text", ""))
				if text_part.is_empty():
					text_part = String(part.get("content", ""))
				if not text_part.is_empty():
					parts.append(text_part)
		var merged: String = ""
		for part_text in parts:
			merged += String(part_text)
		return merged
	return ""

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
