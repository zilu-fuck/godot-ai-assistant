@tool
extends RefCounted
class_name AIMessageNormalizer

const DEFAULT_CONTEXT_CHAR_LIMIT: int = 16000

func normalize_history(history: Array, max_items: int = 0) -> Array:
	var normalized: Array = []

	for raw_message in history:
		if not (raw_message is Dictionary):
			continue

		var role: String = String(raw_message.get("role", "")).strip_edges()
		var content: String = String(raw_message.get("content", "")).strip_edges()
		if role.is_empty() or content.is_empty():
			continue

		if not normalized.is_empty() and normalized.back()["role"] == role:
			normalized.back()["content"] += "\n\n" + content
		else:
			normalized.append({
				"role": role,
				"content": content,
			})

	if max_items > 0 and normalized.size() > max_items:
		normalized = normalized.slice(normalized.size() - max_items)

	return normalized

func clamp_context_text(text: String, max_chars: int = DEFAULT_CONTEXT_CHAR_LIMIT) -> String:
	var cleaned: String = text.strip_edges()
	if cleaned.length() <= max_chars:
		return cleaned

	return cleaned.substr(0, max_chars) + "\n...[truncated]..."
