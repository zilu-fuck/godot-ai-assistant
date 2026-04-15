@tool
extends RefCounted
class_name AIProviderAdapter

func build_request(runtime_request: Dictionary) -> Dictionary:
	var profile: Dictionary = runtime_request.get("profile", {})
	var provider: String = String(profile.get("provider", "deepseek_compatible"))

	match provider:
		"deepseek_compatible":
			return _build_deepseek_request(runtime_request)
		"openai_compatible":
			return _build_openai_request(runtime_request)
		_:
			return _build_deepseek_request(runtime_request)

func _build_deepseek_request(runtime_request: Dictionary) -> Dictionary:
	var payload: Dictionary = {
		"model": String(runtime_request.get("model", "deepseek-chat")),
		"messages": runtime_request.get("messages", []),
		"temperature": float(runtime_request.get("temperature", 0.7)),
		"stream": bool(runtime_request.get("stream", true)),
		"max_tokens": int(runtime_request.get("max_tokens", 8192)),
	}

	return {
		"payload": payload,
		"body": JSON.stringify(payload),
	}

func _build_openai_request(runtime_request: Dictionary) -> Dictionary:
	var payload: Dictionary = {
		"model": String(runtime_request.get("model", "openai-chat")),
		"messages": runtime_request.get("messages", []),
		"temperature": float(runtime_request.get("temperature", 0.7)),
		"stream": bool(runtime_request.get("stream", true)),
		"max_tokens": int(runtime_request.get("max_tokens", 8192)),
	}

	return {
		"payload": payload,
		"body": JSON.stringify(payload),
	}
