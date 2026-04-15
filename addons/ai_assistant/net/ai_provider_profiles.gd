@tool
extends RefCounted
class_name AIProviderProfiles

const PROFILES: Dictionary = {
	"deepseek-chat": {
		"name": "DeepSeek Chat (V3)",
		"provider": "deepseek_compatible",
		"default_url": "https://api.deepseek.com/chat/completions",
		"context_window": 65536,
		"reserved_output_tokens": 8192,
		"use_system_role": true,
		"temperature": 0.7,
		"supports_system_role": true,
		"supports_reasoning_delta": false,
		"supports_streaming": true,
		"supports_tool_calls": false,
		"supports_cache_hints": false,
	},
	"deepseek-reasoner": {
		"name": "DeepSeek Reasoner (R1)",
		"provider": "deepseek_compatible",
		"default_url": "https://api.deepseek.com/chat/completions",
		"context_window": 65536,
		"reserved_output_tokens": 8192,
		"use_system_role": false,
		"temperature": 0.3,
		"supports_system_role": false,
		"supports_reasoning_delta": true,
		"supports_streaming": true,
		"supports_tool_calls": false,
		"supports_cache_hints": false,
	},
	"openai-chat": {
		"name": "OpenAI Compatible Chat",
		"provider": "openai_compatible",
		"default_url": "https://api.openai.com/v1/chat/completions",
		"context_window": 128000,
		"reserved_output_tokens": 8192,
		"use_system_role": true,
		"temperature": 0.7,
		"supports_system_role": true,
		"supports_reasoning_delta": false,
		"supports_streaming": true,
		"supports_tool_calls": true,
		"supports_cache_hints": false,
	},
}

func get_profiles() -> Dictionary:
	return PROFILES.duplicate(true)

func get_profile(model: String) -> Dictionary:
	return PROFILES.get(model, PROFILES["deepseek-chat"]).duplicate(true)

func resolve_profile(model: String, api_url: String = "") -> Dictionary:
	if PROFILES.has(model):
		var exact: Dictionary = PROFILES[model].duplicate(true)
		exact["resolved_model"] = model
		exact["is_builtin_profile"] = true
		return exact

	var inferred: Dictionary = _infer_profile(model, api_url)
	inferred["resolved_model"] = model
	inferred["is_builtin_profile"] = false
	return inferred

func get_profile_keys() -> Array:
	var keys: Array = []
	for key in PROFILES.keys():
		keys.append(String(key))
	return keys

func _infer_profile(model: String, api_url: String) -> Dictionary:
	var lowered_model: String = model.to_lower()
	var lowered_url: String = api_url.to_lower()

	if lowered_url.contains("api.openai.com") or lowered_url.contains("/openai/") or lowered_url.contains("openrouter.ai"):
		return {
			"name": model,
			"provider": "openai_compatible",
			"default_url": "https://api.openai.com/v1/chat/completions",
			"context_window": 128000,
			"reserved_output_tokens": 8192,
			"use_system_role": true,
			"temperature": 0.7,
			"supports_system_role": true,
			"supports_reasoning_delta": false,
			"supports_streaming": true,
			"supports_tool_calls": true,
			"supports_cache_hints": false,
		}

	if lowered_model.contains("reasoner") or lowered_model.contains("r1"):
		return {
			"name": model,
			"provider": "deepseek_compatible",
			"default_url": "https://api.deepseek.com/chat/completions",
			"context_window": 65536,
			"reserved_output_tokens": 8192,
			"use_system_role": false,
			"temperature": 0.3,
			"supports_system_role": false,
			"supports_reasoning_delta": true,
			"supports_streaming": true,
			"supports_tool_calls": false,
			"supports_cache_hints": false,
		}

	var provider: String = "openai_compatible"
	var default_url: String = "https://api.openai.com/v1/chat/completions"
	if lowered_url.contains("deepseek"):
		provider = "deepseek_compatible"
		default_url = "https://api.deepseek.com/chat/completions"

	return {
		"name": model,
		"provider": provider,
		"default_url": default_url,
		"context_window": 65536 if provider == "deepseek_compatible" else 128000,
		"reserved_output_tokens": 8192,
		"use_system_role": true,
		"temperature": 0.7,
		"supports_system_role": true,
		"supports_reasoning_delta": false,
		"supports_streaming": true,
		"supports_tool_calls": lowered_url.contains("openai") or lowered_url.contains("openrouter"),
		"supports_cache_hints": false,
	}
