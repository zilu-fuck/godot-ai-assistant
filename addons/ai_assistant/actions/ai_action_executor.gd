@tool
extends RefCounted
class_name AIActionExecutor

func build_action_for_code(code: String, context_data: Dictionary) -> Dictionary:
	var selected_text: String = String(context_data.get("text", ""))
	var has_selection: bool = bool(context_data.get("is_selected", false)) and not selected_text.is_empty()

	if has_selection:
		return {
			"type": "replace_selection",
			"label": "Replace Selection",
			"content": code,
			"original_text": selected_text,
			"requires_preview": true,
		}

	return {
		"type": "insert_at_caret",
		"label": "Insert At Caret",
		"content": code,
		"original_text": "",
		"requires_preview": false,
	}

func execute_action(action: Dictionary, code_edit: CodeEdit) -> Dictionary:
	if code_edit == null:
		return {
			"ok": false,
			"error": "No editable script is active.",
		}

	var action_type: String = String(action.get("type", ""))
	var content: String = String(action.get("content", ""))
	if content.is_empty():
		return {
			"ok": false,
			"error": "No code is available to apply.",
		}

	match action_type:
		"replace_selection":
			if code_edit.has_selection():
				code_edit.delete_selection()
			code_edit.insert_text_at_caret(content)
		"insert_at_caret":
			code_edit.insert_text_at_caret(content + "\n")
		"show_diff_only":
			return {
				"ok": true,
				"applied": false,
				"log_entry": create_log_entry(action, false),
			}
		_:
			return {
				"ok": false,
				"error": "Unsupported action type: %s" % action_type,
			}

	return {
		"ok": true,
		"applied": true,
		"log_entry": create_log_entry(action, true),
	}

func create_log_entry(action: Dictionary, applied: bool) -> Dictionary:
	return {
		"type": String(action.get("type", "unknown")),
		"label": String(action.get("label", "")),
		"applied": applied,
		"timestamp": "%s %s" % [Time.get_date_string_from_system(), Time.get_time_string_from_system()],
		"preview_required": bool(action.get("requires_preview", false)),
	}
