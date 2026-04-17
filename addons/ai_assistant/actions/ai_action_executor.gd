@tool
extends RefCounted
class_name AIActionExecutor

const AUTO_APPLY_CONFIDENCE: float = 0.90
const TARGET_SELECTION_DELTA: float = 0.08
const LARGE_REPLACEMENT_LINE_THRESHOLD: int = 40

const ACTION_EXPLAIN_ONLY: String = "explain_only"
const ACTION_SHOW_DIFF_ONLY: String = "show_diff_only"
const ACTION_INSERT_AT_CARET: String = "insert_at_caret"
const ACTION_REPLACE_SELECTION: String = "replace_selection"
const ACTION_CREATE_SCENE: String = "create_scene"

const EXEC_REPLACE_TEXT_RANGE: String = "replace_text_range"
const EXEC_REPLACE_CODE_BLOCK: String = "replace_code_block"
const EXEC_REPLACE_FILE: String = "replace_file"
const EXEC_INSERT_AT_CARET: String = "insert_at_caret"
const EXEC_INSERT_AT_FILE_END: String = "insert_at_file_end"
const EXEC_CREATE_SCENE_FILE: String = "create_scene_file"

func build_action_for_code(code: String, context_data: Dictionary) -> Dictionary:
	var selected_text: String = str(context_data.get("text", ""))
	var has_selection: bool = bool(context_data.get("is_selected", false)) and not selected_text.is_empty()

	if has_selection:
		return prepare_candidate_for_ui({
			"action_type": ACTION_REPLACE_SELECTION,
			"execution_type": EXEC_REPLACE_TEXT_RANGE,
			"label": "替换选中内容",
			"content": code,
			"original_text": selected_text,
			"requires_preview": true,
			"intent": "modify_code",
			"risk_level": "medium",
			"requires_confirmation": true,
			"requires_secondary_confirmation": false,
			"confirmed": false,
			"secondary_confirmed": false,
			"target_kind": "selection",
			"target_shape": "selection",
			"target_label": "当前选区",
			"match_reason": "编辑器里已经有选区，所以这段生成代码可以直接替换它。",
			"confidence": 1.0,
		})

	return prepare_candidate_for_ui({
		"action_type": ACTION_INSERT_AT_CARET,
		"execution_type": EXEC_INSERT_AT_CARET,
		"label": "插入到光标处",
		"content": code,
		"original_text": "",
		"requires_preview": true,
		"intent": "modify_code",
		"risk_level": "low",
		"requires_confirmation": true,
		"requires_secondary_confirmation": false,
		"confirmed": false,
		"secondary_confirmed": false,
		"target_kind": "caret",
		"target_shape": "snippet",
		"target_label": "光标位置",
		"match_reason": "没有找到更可靠的替换目标，所以回退为在光标处插入。",
		"confidence": 0.35,
	})

func inspect_generated_block(code: String, language: String) -> Dictionary:
	var cleaned_code: String = code.strip_edges()
	var normalized_language: String = language.to_lower()
	if cleaned_code.is_empty():
		return {
			"is_applyable": false,
			"reason": "这个代码块是空的。",
			"code_shape": "empty",
			"line_count": 0,
			"risk_level": "low",
			"default_action_type": ACTION_EXPLAIN_ONLY,
			"default_button_label": "",
		}
	if _looks_like_scene_file(cleaned_code, normalized_language):
		var scene_root_name: String = extract_scene_root_name(cleaned_code)
		var line_count: int = cleaned_code.split("\n").size()
		var risk_level: String = "medium"
		var default_button_label: String = "创建场景"
		var reason: String = "这个代码块看起来是一个 Godot 场景文件，可以创建为场景资源。"
		if line_count >= LARGE_REPLACEMENT_LINE_THRESHOLD:
			risk_level = "high"
			default_button_label = "预览"
			reason = "这个场景代码块比较大，因此会先进入预览模式再创建。"

		return {
			"is_applyable": true,
			"reason": reason,
			"code_shape": "scene_file",
			"line_count": line_count,
			"risk_level": risk_level,
			"default_action_type": ACTION_CREATE_SCENE,
			"default_button_label": default_button_label,
			"scene_root_name": scene_root_name,
			"content_kind": "scene_file",
		}
	if not normalized_language.is_empty() and normalized_language not in ["gd", "gdscript"]:
		return {
			"is_applyable": false,
			"reason": "当前 Dock 只支持应用 GDScript 代码块。",
			"code_shape": "unsupported_language",
			"line_count": cleaned_code.split("\n").size(),
			"risk_level": "low",
			"default_action_type": ACTION_EXPLAIN_ONLY,
			"default_button_label": "",
		}
	if not _looks_like_gdscript_edit(cleaned_code):
		return {
			"is_applyable": false,
			"reason": "这个代码块看起来不像一个可直接应用的 GDScript 修改目标。",
			"code_shape": "snippet",
			"line_count": cleaned_code.split("\n").size(),
			"risk_level": "low",
			"default_action_type": ACTION_EXPLAIN_ONLY,
			"default_button_label": "",
		}

	var code_shape: String = _classify_generated_code_shape(cleaned_code)
	var line_count: int = cleaned_code.split("\n").size()
	var risk_level: String = "medium"
	var default_action_type: String = ACTION_REPLACE_SELECTION
	var default_button_label: String = "应用"
	var reason: String = "建议先审查这次代码改动，再决定是否应用。"

	if code_shape == "full_file" or line_count >= LARGE_REPLACEMENT_LINE_THRESHOLD:
		risk_level = "high"
		default_action_type = ACTION_SHOW_DIFF_ONLY
		default_button_label = "预览"
		reason = "这个代码块看起来像整文件或大段替换，因此会先进入预览模式。"
	elif code_shape == "single_function":
		reason = "这个代码块看起来像单个函数的替换建议。"
	else:
		reason = "这个代码块看起来像一次聚焦的代码修改建议。"

	return {
		"is_applyable": true,
		"reason": reason,
		"code_shape": code_shape,
		"line_count": line_count,
		"risk_level": risk_level,
		"default_action_type": default_action_type,
		"default_button_label": default_button_label,
	}

func inspect_generated_code(code: String, language: String) -> Dictionary:
	return inspect_generated_block(code, language)

func validate_scene_text(scene_text: String) -> Dictionary:
	var cleaned_scene: String = scene_text.strip_edges()
	if cleaned_scene.is_empty():
		return {
			"ok": false,
			"reason": "empty_scene",
			"message": "场景内容为空，无法创建场景文件。",
		}
	if not _looks_like_scene_file(cleaned_scene, "tscn"):
		return {
			"ok": false,
			"reason": "invalid_scene_header",
			"message": "这段内容看起来不是有效的 Godot 场景文件。",
		}

	var lines: Array = cleaned_scene.split("\n")
	for index in range(lines.size()):
		var line: String = str(lines[index]).strip_edges()
		if not line.begins_with("[ext_resource "):
			continue
		return {
			"ok": false,
			"reason": "external_resources_not_allowed",
			"message": "当前场景创建只接受纯 .tscn 内容。请不要返回 ext_resource；如果需要脚本，请单独提供一个 gdscript 代码块。",
			"line": index + 1,
		}
	return {
		"ok": true,
	}

func extract_scene_root_name(scene_text: String) -> String:
	var regex: RegEx = RegEx.new()
	if regex.compile("\\[node\\s+name=\"([^\"]+)\"") != OK:
		return ""
	var result: RegExMatch = regex.search(scene_text)
	if result == null:
		return ""
	return result.get_string(1).strip_edges()

func prepare_candidate_for_ui(action: Dictionary) -> Dictionary:
	var prepared: Dictionary = action.duplicate(true)
	prepared["risk_badge"] = _build_risk_badge(prepared)
	prepared["selection_label"] = build_target_selection_label(prepared)
	prepared["preview_bbcode"] = build_target_preview_bbcode(prepared)
	prepared["review_data"] = build_action_review_data(prepared)
	return prepared

func build_target_selection_label(action: Dictionary) -> String:
	var segments: Array = []
	var target_path: String = str(action.get("target_path", "")).strip_edges()
	var badge: String = str(action.get("risk_badge", "")).strip_edges()
	if not badge.is_empty():
		segments.append(badge)
	if not target_path.is_empty():
		segments.append(target_path)
	segments.append(str(action.get("target_label", action.get("label", "Target"))))
	segments.append("%.0f%%" % (float(action.get("confidence", 0.0)) * 100.0))

	var reason: String = str(action.get("match_reason", "")).strip_edges()
	if not reason.is_empty():
		segments.append(reason)

	return " | ".join(segments)

func build_target_preview_bbcode(action: Dictionary) -> String:
	var lines: Array = []
	lines.append("[b][color=#E5C07B]目标候选[/color][/b]")
	lines.append("动作：%s" % _localize_action_type(str(action.get("action_type", ACTION_EXPLAIN_ONLY))))
	lines.append("目标：%s" % str(action.get("target_label", action.get("label", "改动"))))
	var target_path: String = str(action.get("target_path", "")).strip_edges()
	if not target_path.is_empty():
		lines.append("文件：%s" % target_path)
	var companion_script_target_path: String = str(action.get("companion_script_target_path", "")).strip_edges()
	if not companion_script_target_path.is_empty():
		lines.append("配套脚本：%s" % companion_script_target_path)
	var start_line: int = int(action.get("start_line", -1))
	var end_line: int = int(action.get("end_line", -1))
	if start_line >= 0 and end_line >= start_line:
		lines.append("行号：%d-%d" % [start_line + 1, end_line + 1])
	lines.append("风险：%s" % _localize_risk_level(str(action.get("risk_level", "unknown"))))
	lines.append("置信度：%.0f%%" % (float(action.get("confidence", 0.0)) * 100.0))
	lines.append("原因：%s" % str(action.get("match_reason", "没有记录目标匹配原因。")))
	lines.append("")
	lines.append("[b]%s[/b]" % ("现有场景内容" if str(action.get("action_type", "")) == ACTION_CREATE_SCENE else "当前代码"))
	lines.append("[code]")
	var original_text: String = str(action.get("original_text", ""))
	lines.append(_truncate_preview_code(original_text if not original_text.is_empty() else "（新文件）"))
	lines.append("[/code]")
	return "\n".join(lines)

func build_action_review_data(action: Dictionary) -> Dictionary:
	var risk_level: String = str(action.get("risk_level", "unknown"))
	var target_label: String = str(action.get("target_label", action.get("label", "Change")))
	var secondary_message: String = "这是一个%s改动，目标为 %s。请再次确认后再应用。" % [
		_localize_risk_level(risk_level).to_lower(),
		target_label,
	]
	if str(action.get("action_type", "")) == ACTION_CREATE_SCENE:
		secondary_message = "这是一个%s场景操作，目标为 %s。写入场景文件前请再次确认。" % [
			_localize_risk_level(risk_level).to_lower(),
			target_label,
		]
	return {
		"dialog_title": "审查改动：%s" % target_label,
		"confirm_text": "继续" if action_requires_secondary_confirmation(action) else _default_confirm_text(action),
		"bbcode": _build_action_review_bbcode(action),
		"requires_secondary_confirmation": action_requires_secondary_confirmation(action),
		"secondary_confirmation_title": "确认高风险改动",
		"secondary_confirmation_message": secondary_message,
	}

func action_requires_secondary_confirmation(action: Dictionary) -> bool:
	return bool(action.get("requires_secondary_confirmation", false))

func is_high_risk(action: Dictionary) -> bool:
	return str(action.get("risk_level", "")) == "high" or action_requires_secondary_confirmation(action)

func plan_code_application(code: String, code_edit: CodeEdit, script_path: String = "", active_script_path: String = "") -> Dictionary:
	var cleaned_code: String = code.strip_edges()
	if code_edit == null:
		return {
			"ok": false,
			"message": "当前没有可编辑的脚本。",
		}
	if cleaned_code.is_empty():
		return {
			"ok": false,
			"message": "没有可应用的代码。",
		}

	var selection_range: Dictionary = {}
	if code_edit.has_selection():
		selection_range = {
			"original_text": code_edit.get_selected_text(),
			"start_line": code_edit.get_selection_from_line(),
			"end_line": code_edit.get_selection_to_line(),
			"start_column": code_edit.get_selection_from_column(),
			"end_column": code_edit.get_selection_to_column(),
		}

	return plan_code_application_for_text(
		cleaned_code,
		code_edit.text,
		script_path,
		code_edit.get_caret_line(),
		selection_range,
		active_script_path
	)

func plan_code_application_for_text(code: String, source_text: String, script_path: String = "", caret_line: int = -1, selection_range: Dictionary = {}, active_script_path: String = "") -> Dictionary:
	var cleaned_code: String = code.strip_edges()
	if cleaned_code.is_empty():
		return {
			"ok": false,
			"message": "没有可应用的代码。",
		}

	var code_shape: String = _classify_generated_code_shape(cleaned_code)
	var candidates: Array = []
	var generated_function_name: String = _extract_primary_function_name(cleaned_code)
	var function_blocks: Array = _collect_function_blocks(source_text)
	var caret_block: Dictionary = _find_block_for_line(function_blocks, caret_line)

	if code_shape == "full_file":
		candidates.append(_build_full_file_candidate(cleaned_code, source_text, script_path))
	elif not selection_range.is_empty():
		candidates.append(_build_selection_candidate(cleaned_code, selection_range, script_path))

	if code_shape == "single_function":
		for block in function_blocks:
			if not (block is Dictionary):
				continue
			if generated_function_name.is_empty():
				continue
			if str(block.get("name", "")) != generated_function_name:
				continue

			var confidence: float = 0.96
			var reason: String = "在目标文件里匹配到了同名函数 `%s`。" % generated_function_name
			if not caret_block.is_empty() and int(caret_block.get("start_line", -1)) == int(block.get("start_line", -2)):
				confidence = 0.99
				reason = "在当前光标位置匹配到了同一个函数 `%s`。" % generated_function_name
			candidates.append(_build_block_candidate(cleaned_code, block, script_path, confidence, reason))

		if candidates.is_empty() and not caret_block.is_empty():
			candidates.append(_build_block_candidate(
				cleaned_code,
				caret_block,
				script_path,
				0.78,
				"没有找到完全同名的函数，所以回退为当前光标所在函数。"
			))

	if code_shape != "full_file" and caret_line >= 0:
		candidates.append(_build_insert_candidate(cleaned_code, caret_line, script_path))
	elif code_shape != "full_file":
		candidates.append(_build_file_end_candidate(cleaned_code, source_text, script_path))

	candidates = _dedupe_candidates(candidates)
	for index in range(candidates.size()):
		if not (candidates[index] is Dictionary):
			continue
		candidates[index] = prepare_candidate_for_ui(_finalize_candidate(candidates[index], active_script_path))
	candidates.sort_custom(_sort_candidates)

	var primary_candidate: Dictionary = {}
	if not candidates.is_empty():
		primary_candidate = candidates[0]

	var auto_apply: bool = false
	var requires_target_selection: bool = candidates.size() > 1
	if candidates.size() == 1:
		auto_apply = true
		requires_target_selection = false
	elif candidates.size() > 1:
		var top_confidence: float = float(candidates[0].get("confidence", 0.0))
		var second_confidence: float = float(candidates[1].get("confidence", 0.0))
		auto_apply = top_confidence >= AUTO_APPLY_CONFIDENCE and (top_confidence - second_confidence) >= TARGET_SELECTION_DELTA
		requires_target_selection = not auto_apply

	return {
		"ok": true,
		"script_path": script_path,
		"source_text": source_text,
		"generated_function_name": generated_function_name,
		"code_shape": code_shape,
		"candidates": candidates,
		"primary_candidate": primary_candidate,
		"auto_apply": auto_apply,
		"requires_target_selection": requires_target_selection,
	}

func plan_scene_creation(scene_text: String, target_path: String, existing_text: String = "", active_scene_path: String = "") -> Dictionary:
	var cleaned_scene: String = scene_text.strip_edges()
	if cleaned_scene.is_empty():
		return {
			"ok": false,
			"message": "没有可创建的场景内容。",
		}
	if target_path.strip_edges().is_empty():
		return {
			"ok": false,
			"message": "没有可用于创建场景的目标路径。",
		}
	if not _looks_like_scene_file(cleaned_scene, "tscn"):
		return {
			"ok": false,
			"message": "选中的代码块看起来不像 Godot 场景文件。",
		}

	var validation: Dictionary = validate_scene_text(cleaned_scene)
	if not bool(validation.get("ok", false)):
		return {
			"ok": false,
			"reason": str(validation.get("reason", "invalid_scene")),
			"message": str(validation.get("message", "场景内容未通过校验。")),
		}

	var root_name: String = extract_scene_root_name(cleaned_scene)
	var candidate: Dictionary = {
		"action_type": ACTION_CREATE_SCENE,
		"execution_type": EXEC_CREATE_SCENE_FILE,
		"label": "创建场景" if existing_text.is_empty() else "替换场景文件",
		"content": cleaned_scene,
		"original_text": existing_text,
		"requires_preview": true,
		"intent": "create_scene",
		"risk_level": "medium" if existing_text.is_empty() else "high",
		"requires_confirmation": true,
		"requires_secondary_confirmation": not existing_text.is_empty(),
		"confirmed": false,
		"secondary_confirmed": false,
		"target_kind": "scene_file",
		"target_shape": "scene_file",
		"target_label": root_name if not root_name.is_empty() else "场景文件",
		"target_name": root_name,
		"target_path": target_path,
		"match_reason": "运行时为这次生成的场景选择了这个 `.tscn` 路径。",
		"confidence": 0.95,
	}
	candidate = prepare_candidate_for_ui(_finalize_candidate(candidate, active_scene_path))
	return {
		"ok": true,
		"code_shape": "scene_file",
		"candidates": [candidate],
		"primary_candidate": candidate,
		"auto_apply": true,
		"requires_target_selection": false,
	}

func can_execute_action(action: Dictionary, code_edit: CodeEdit, confirmed: bool = false) -> Dictionary:
	if action.is_empty():
		return {
			"ok": false,
			"reason": "missing_action",
			"message": "当前没有可执行的动作。",
		}

	var action_type: String = str(action.get("action_type", ""))
	var execution_type: String = str(action.get("execution_type", ""))
	var content: String = str(action.get("content", ""))
	var requires_confirmation: bool = bool(action.get("requires_confirmation", false))
	var requires_secondary_confirmation: bool = action_requires_secondary_confirmation(action)

	match action_type:
		ACTION_SHOW_DIFF_ONLY, ACTION_EXPLAIN_ONLY:
			return {
				"ok": true,
				"reason": "allowed",
			}
		ACTION_CREATE_SCENE:
			if execution_type != EXEC_CREATE_SCENE_FILE:
				return {
					"ok": false,
					"reason": "unsupported_action",
					"message": "不支持的场景创建方案：%s" % execution_type,
				}
			if content.is_empty():
				return {
					"ok": false,
					"reason": "missing_content",
					"message": "没有可创建的场景内容。",
				}
			if str(action.get("target_path", "")).strip_edges().is_empty():
				return {
					"ok": false,
					"reason": "missing_target_path",
					"message": "缺少场景创建的目标路径。",
				}
			if requires_confirmation and not confirmed:
				return {
					"ok": false,
					"reason": "confirmation_required",
					"message": "创建这个场景前需要先确认预览。",
				}
			if requires_secondary_confirmation and not bool(action.get("secondary_confirmed", false)):
				return {
					"ok": false,
					"reason": "secondary_confirmation_required",
					"message": "这个高风险场景改动需要额外确认一次。",
				}
			return {
				"ok": true,
				"reason": "allowed",
			}
		ACTION_REPLACE_SELECTION, ACTION_INSERT_AT_CARET:
			if execution_type == EXEC_INSERT_AT_CARET and code_edit == null:
				return {
					"ok": false,
					"reason": "missing_editor",
					"message": "当前没有可编辑的脚本。",
				}
			if content.is_empty():
				return {
					"ok": false,
					"reason": "missing_content",
					"message": "没有可应用的代码。",
				}
			if execution_type == EXEC_REPLACE_TEXT_RANGE:
				var range_start_line: int = int(action.get("start_line", -1))
				var range_end_line: int = int(action.get("end_line", -1))
				var range_start_column: int = int(action.get("start_column", -1))
				var range_end_column: int = int(action.get("end_column", -1))
				if range_start_line < 0 or range_end_line < range_start_line:
					return {
						"ok": false,
						"reason": "missing_target_range",
						"message": "目标文本范围无效。",
					}
				if range_start_column < 0 or range_end_column < 0:
					return {
						"ok": false,
						"reason": "missing_target_range",
						"message": "目标文本范围无效。",
					}
			if execution_type == EXEC_REPLACE_CODE_BLOCK:
				var start_line: int = int(action.get("start_line", -1))
				var end_line: int = int(action.get("end_line", -1))
				if start_line < 0 or end_line < start_line:
					return {
						"ok": false,
						"reason": "missing_target_range",
						"message": "目标代码块范围无效。",
					}
			if execution_type == EXEC_INSERT_AT_FILE_END and int(action.get("insert_line", -1)) < 0:
				return {
					"ok": false,
					"reason": "missing_target_range",
					"message": "目标文件末尾位置无效。",
				}
			if requires_confirmation and not confirmed:
				return {
					"ok": false,
					"reason": "confirmation_required",
					"message": "应用这个动作前需要先确认预览。",
				}
			if requires_secondary_confirmation and not bool(action.get("secondary_confirmed", false)):
				return {
					"ok": false,
					"reason": "secondary_confirmation_required",
					"message": "这个高风险改动需要额外确认一次。",
				}
			return {
				"ok": true,
				"reason": "allowed",
			}
		_:
			return {
				"ok": false,
				"reason": "unsupported_action",
				"message": "不支持的动作类型：%s" % action_type,
			}

func execute_action(action: Dictionary, code_edit: CodeEdit) -> Dictionary:
	var gate: Dictionary = can_execute_action(action, code_edit, bool(action.get("confirmed", false)))
	if not bool(gate.get("ok", false)):
		return {
			"ok": false,
			"error": str(gate.get("message", "动作执行被阻止。")),
			"reason": str(gate.get("reason", "blocked")),
		}

	var execution_type: String = str(action.get("execution_type", ""))
	var content: String = str(action.get("content", ""))

	match execution_type:
		EXEC_REPLACE_TEXT_RANGE:
			code_edit.text = _replace_text_range(
				code_edit.text,
				int(action.get("start_line", -1)),
				int(action.get("start_column", -1)),
				int(action.get("end_line", -1)),
				int(action.get("end_column", -1)),
				content
			)
			code_edit.set_caret_line(max(0, int(action.get("start_line", 0))))
			code_edit.set_caret_column(max(0, int(action.get("start_column", 0))))
		EXEC_REPLACE_CODE_BLOCK:
			code_edit.text = _replace_line_range(
				code_edit.text,
				int(action.get("start_line", -1)),
				int(action.get("end_line", -1)),
				content
			)
			code_edit.set_caret_line(max(0, int(action.get("start_line", 0))))
			code_edit.set_caret_column(0)
		EXEC_INSERT_AT_CARET:
			code_edit.insert_text_at_caret(content + "\n")
		EXEC_INSERT_AT_FILE_END:
			code_edit.text = _append_to_text(code_edit.text, content)
			code_edit.set_caret_line(max(0, int(action.get("insert_line", 0))))
			code_edit.set_caret_column(0)
		EXEC_REPLACE_FILE:
			code_edit.text = str(action.get("content", ""))
			code_edit.set_caret_line(0)
			code_edit.set_caret_column(0)
		_:
			return {
				"ok": false,
				"error": "不支持的执行类型：%s" % execution_type,
			}

	return {
		"ok": true,
		"applied": true,
		"log_entry": create_log_entry(action, true),
	}

func create_log_entry(action: Dictionary, applied: bool) -> Dictionary:
	var extra_target_paths: Array = []
	var companion_script_target_path: String = str(action.get("companion_script_target_path", "")).strip_edges()
	if not companion_script_target_path.is_empty():
		extra_target_paths.append(companion_script_target_path)

	return {
		"action_type": str(action.get("action_type", "unknown")),
		"execution_type": str(action.get("execution_type", "unknown")),
		"label": str(action.get("label", "")),
		"intent": str(action.get("intent", "unknown")),
		"risk_level": str(action.get("risk_level", "unknown")),
		"high_risk": is_high_risk(action),
		"applied": applied,
		"timestamp": "%s %s" % [Time.get_date_string_from_system(), Time.get_time_string_from_system()],
		"preview_required": bool(action.get("requires_preview", false)),
		"requires_confirmation": bool(action.get("requires_confirmation", false)),
		"requires_secondary_confirmation": action_requires_secondary_confirmation(action),
		"confirmed": bool(action.get("confirmed", false)),
		"secondary_confirmed": bool(action.get("secondary_confirmed", false)),
		"target_kind": str(action.get("target_kind", "unknown")),
		"target_label": str(action.get("target_label", "")),
		"target_path": str(action.get("target_path", "")),
		"extra_target_paths": extra_target_paths,
		"match_reason": str(action.get("match_reason", "")),
		"confidence": float(action.get("confidence", 0.0)),
	}

func apply_action_to_text(action: Dictionary, original_text: String) -> Dictionary:
	var execution_type: String = str(action.get("execution_type", ""))
	match execution_type:
		EXEC_REPLACE_TEXT_RANGE:
			return {
				"ok": true,
				"text": _replace_text_range(
					original_text,
					int(action.get("start_line", -1)),
					int(action.get("start_column", -1)),
					int(action.get("end_line", -1)),
					int(action.get("end_column", -1)),
					str(action.get("content", ""))
				),
			}
		EXEC_REPLACE_CODE_BLOCK:
			return {
				"ok": true,
				"text": _replace_line_range(
					original_text,
					int(action.get("start_line", -1)),
					int(action.get("end_line", -1)),
					str(action.get("content", ""))
				),
			}
		EXEC_INSERT_AT_FILE_END:
			return {
				"ok": true,
				"text": _append_to_text(original_text, str(action.get("content", ""))),
			}
		EXEC_INSERT_AT_CARET:
			var insert_line: int = int(action.get("start_line", -1))
			if insert_line < 0:
				insert_line = int(action.get("insert_line", -1))
			if insert_line < 0:
				return {
					"ok": true,
					"text": _append_to_text(original_text, str(action.get("content", ""))),
				}
			return {
				"ok": true,
				"text": _insert_at_line(original_text, insert_line, str(action.get("content", ""))),
			}
		EXEC_REPLACE_FILE:
			return {
				"ok": true,
				"text": str(action.get("content", "")),
			}
		EXEC_CREATE_SCENE_FILE:
			return {
				"ok": true,
				"text": str(action.get("content", "")),
			}
		_:
			return {
				"ok": false,
				"message": "不支持的文本变换类型：%s" % execution_type,
			}

func _build_selection_candidate(code: String, selection_range: Dictionary, script_path: String) -> Dictionary:
	return {
		"action_type": ACTION_REPLACE_SELECTION,
		"execution_type": EXEC_REPLACE_TEXT_RANGE,
		"label": "替换选中内容",
		"content": code,
		"original_text": str(selection_range.get("original_text", "")),
		"requires_preview": true,
		"intent": "modify_code",
		"risk_level": "medium",
		"requires_confirmation": true,
		"requires_secondary_confirmation": false,
		"confirmed": false,
		"secondary_confirmed": false,
		"target_kind": "selection",
		"target_shape": "selection",
		"target_label": "当前选区",
		"target_path": script_path,
		"match_reason": "编辑器里已经有选区。",
		"confidence": 1.0,
		"start_line": int(selection_range.get("start_line", -1)),
		"end_line": int(selection_range.get("end_line", -1)),
		"start_column": int(selection_range.get("start_column", -1)),
		"end_column": int(selection_range.get("end_column", -1)),
	}

func _build_block_candidate(code: String, block: Dictionary, script_path: String, confidence: float, reason: String) -> Dictionary:
	var function_name: String = str(block.get("name", "function"))
	return {
		"action_type": ACTION_REPLACE_SELECTION,
		"execution_type": EXEC_REPLACE_CODE_BLOCK,
		"label": "替换 %s" % str(block.get("label", "代码块")),
		"content": code,
		"original_text": str(block.get("text", "")),
		"requires_preview": true,
		"intent": "modify_code",
		"risk_level": "medium",
		"requires_confirmation": true,
		"requires_secondary_confirmation": false,
		"confirmed": false,
		"secondary_confirmed": false,
		"target_kind": "code_block",
		"target_shape": "single_function",
		"target_label": str(block.get("label", "代码块")),
		"target_name": function_name,
		"target_path": script_path,
		"match_reason": reason,
		"confidence": confidence,
		"start_line": int(block.get("start_line", -1)),
		"end_line": int(block.get("end_line", -1)),
	}

func _build_full_file_candidate(code: String, source_text: String, script_path: String) -> Dictionary:
	var lines: Array = source_text.split("\n")
	var end_line: int = max(0, lines.size() - 1)
	var end_column: int = 0
	if not lines.is_empty():
		end_column = str(lines[end_line]).length()

	return {
		"action_type": ACTION_REPLACE_SELECTION,
		"execution_type": EXEC_REPLACE_FILE,
		"label": "替换文件",
		"content": code,
		"original_text": source_text,
		"requires_preview": true,
		"intent": "modify_code",
		"risk_level": "high",
		"requires_confirmation": true,
		"requires_secondary_confirmation": true,
		"confirmed": false,
		"secondary_confirmed": false,
		"target_kind": "file",
		"target_shape": "full_file",
		"target_label": "整个文件",
		"target_path": script_path,
		"match_reason": "生成代码看起来像完整脚本，因此目标指向整个文件。",
		"confidence": 0.99,
		"start_line": 0,
		"end_line": end_line,
		"start_column": 0,
		"end_column": end_column,
	}

func _build_insert_candidate(code: String, caret_line: int, script_path: String) -> Dictionary:
	return {
		"action_type": ACTION_INSERT_AT_CARET,
		"execution_type": EXEC_INSERT_AT_CARET,
		"label": "插入到光标处",
		"content": code,
		"original_text": "",
		"requires_preview": true,
		"intent": "modify_code",
		"risk_level": "low",
		"requires_confirmation": true,
		"requires_secondary_confirmation": false,
		"confirmed": false,
		"secondary_confirmed": false,
		"target_kind": "caret",
		"target_shape": "snippet",
		"target_label": "光标位置",
		"target_path": script_path,
		"match_reason": "没有找到更可靠的替换目标，所以回退为在光标处插入。",
		"confidence": 0.35,
		"start_line": caret_line,
		"end_line": caret_line,
	}

func _build_file_end_candidate(code: String, source_text: String, script_path: String) -> Dictionary:
	var lines: Array = source_text.split("\n")
	var insert_line: int = max(0, lines.size() - 1)
	return {
		"action_type": ACTION_INSERT_AT_CARET,
		"execution_type": EXEC_INSERT_AT_FILE_END,
		"label": "追加到文件末尾",
		"content": code,
		"original_text": "",
		"requires_preview": true,
		"intent": "modify_code",
		"risk_level": "medium",
		"requires_confirmation": true,
		"requires_secondary_confirmation": false,
		"confirmed": false,
		"secondary_confirmed": false,
		"target_kind": "file_end",
		"target_shape": "snippet",
		"target_label": "文件末尾",
		"target_path": script_path,
		"match_reason": "没有找到匹配函数，所以最安全的回退方案是追加到文件末尾。",
		"confidence": 0.62,
		"insert_line": insert_line,
	}

func _finalize_candidate(action: Dictionary, active_script_path: String) -> Dictionary:
	var finalized: Dictionary = action.duplicate(true)
	var replacement_line_count: int = str(finalized.get("content", "")).split("\n").size()
	var original_line_count: int = str(finalized.get("original_text", "")).split("\n").size()
	var affected_line_count: int = original_line_count
	var start_line: int = int(finalized.get("start_line", -1))
	var end_line: int = int(finalized.get("end_line", -1))
	if start_line >= 0 and end_line >= start_line:
		affected_line_count = max(affected_line_count, (end_line - start_line) + 1)

	var execution_type: String = str(finalized.get("execution_type", ""))
	if execution_type == EXEC_REPLACE_FILE:
		finalized["risk_level"] = "high"
		finalized["requires_secondary_confirmation"] = true
	if execution_type == EXEC_CREATE_SCENE_FILE and not str(finalized.get("original_text", "")).strip_edges().is_empty():
		finalized["risk_level"] = "high"
		finalized["requires_secondary_confirmation"] = true
		_append_match_reason(finalized, "这个场景路径已经存在，所以在这里创建会替换当前场景文件。")

	if execution_type in [EXEC_REPLACE_TEXT_RANGE, EXEC_REPLACE_CODE_BLOCK, EXEC_REPLACE_FILE] and max(replacement_line_count, affected_line_count) >= LARGE_REPLACEMENT_LINE_THRESHOLD:
		finalized["risk_level"] = "high"
		finalized["requires_secondary_confirmation"] = true
		_append_match_reason(finalized, "这次替换覆盖了较大的代码区域，需要更严格的确认。")

	if execution_type in [EXEC_INSERT_AT_FILE_END, EXEC_CREATE_SCENE_FILE] and replacement_line_count >= LARGE_REPLACEMENT_LINE_THRESHOLD:
		finalized["risk_level"] = "high"
		finalized["requires_secondary_confirmation"] = true
		if execution_type == EXEC_CREATE_SCENE_FILE:
			_append_match_reason(finalized, "这个生成场景足够大，需要高风险确认。")
		else:
			_append_match_reason(finalized, "这次追加内容足够大，需要高风险确认。")

	var target_path: String = str(finalized.get("target_path", "")).strip_edges()
	if finalized.get("intent", "") == "modify_code" and not target_path.is_empty() and not active_script_path.is_empty() and target_path != active_script_path:
		finalized["risk_level"] = "high"
		finalized["requires_secondary_confirmation"] = true
		_append_match_reason(finalized, "这个方案会修改当前活动编辑器之外的另一个文件。")

	return finalized

func _append_match_reason(action: Dictionary, extra_reason: String) -> void:
	var existing_reason: String = str(action.get("match_reason", "")).strip_edges()
	var cleaned_extra: String = extra_reason.strip_edges()
	if cleaned_extra.is_empty():
		return
	if existing_reason.is_empty():
		action["match_reason"] = cleaned_extra
	else:
		action["match_reason"] = "%s %s" % [existing_reason, cleaned_extra]

func _extract_primary_function_name(code: String) -> String:
	for raw_line in code.split("\n"):
		var line: String = raw_line.strip_edges()
		if not line.begins_with("func "):
			continue

		var after_keyword: String = line.substr(5).strip_edges()
		var open_paren: int = after_keyword.find("(")
		if open_paren <= 0:
			return ""
		return after_keyword.substr(0, open_paren).strip_edges()

	return ""

func _classify_generated_code_shape(code: String) -> String:
	var stripped_code: String = code.strip_edges()
	if stripped_code.is_empty():
		return "snippet"
	if stripped_code.begins_with("extends ") or stripped_code.contains("\nextends "):
		return "full_file"
	if stripped_code.begins_with("class_name ") or stripped_code.contains("\nclass_name "):
		return "full_file"

	var top_level_declarations: int = 0
	var function_count: int = 0
	for raw_line in stripped_code.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if line.begins_with("func "):
			function_count += 1
			continue
		if line.begins_with("@onready ") or line.begins_with("var ") or line.begins_with("const ") or line.begins_with("signal "):
			top_level_declarations += 1
			continue

	if function_count > 1:
		return "full_file"
	if function_count == 1 and top_level_declarations == 0:
		return "single_function"
	if function_count >= 1 and top_level_declarations >= 1:
		return "full_file"
	return "snippet"

func _collect_function_blocks(text: String) -> Array:
	var blocks: Array = []
	var lines: Array = text.split("\n")

	for index in range(lines.size()):
		var line: String = str(lines[index])
		var stripped: String = _lstrip(line)
		if not stripped.begins_with("func "):
			continue

		var indent: int = line.length() - stripped.length()
		var name: String = _extract_primary_function_name(stripped)
		var end_index: int = lines.size() - 1

		for next_index in range(index + 1, lines.size()):
			var candidate_line: String = str(lines[next_index])
			var candidate_stripped: String = _lstrip(candidate_line)
			if candidate_stripped.is_empty() or candidate_stripped.begins_with("#"):
				continue

			var candidate_indent: int = candidate_line.length() - candidate_stripped.length()
			if candidate_indent <= indent:
				end_index = next_index - 1
				break
		blocks.append({
			"name": name,
			"label": "Function %s()" % name,
			"start_line": index,
			"end_line": max(index, end_index),
			"text": "\n".join(lines.slice(index, max(index, end_index) + 1)),
		})

	return blocks

func _find_block_for_line(blocks: Array, line_number: int) -> Dictionary:
	for block in blocks:
		if not (block is Dictionary):
			continue
		if line_number >= int(block.get("start_line", -1)) and line_number <= int(block.get("end_line", -1)):
			return block
	return {}

func _replace_line_range(original_text: String, start_line: int, end_line: int, replacement: String) -> String:
	var lines: Array = original_text.split("\n")
	var safe_start: int = clampi(start_line, 0, max(0, lines.size() - 1))
	var safe_end: int = clampi(end_line, safe_start, max(0, lines.size() - 1))
	var before: Array = lines.slice(0, safe_start)
	var after: Array = lines.slice(safe_end + 1)
	var replacement_lines: Array = replacement.split("\n")
	var merged: Array = []
	merged.append_array(before)
	merged.append_array(replacement_lines)
	merged.append_array(after)
	return "\n".join(merged)

func _replace_text_range(original_text: String, start_line: int, start_column: int, end_line: int, end_column: int, replacement: String) -> String:
	var lines: Array = original_text.split("\n")
	if lines.is_empty():
		lines = [""]

	var safe_start_line: int = clampi(start_line, 0, max(0, lines.size() - 1))
	var safe_end_line: int = clampi(end_line, safe_start_line, max(0, lines.size() - 1))
	var start_text: String = str(lines[safe_start_line])
	var end_text: String = str(lines[safe_end_line])
	var safe_start_column: int = clampi(start_column, 0, start_text.length())
	var safe_end_column: int = clampi(end_column, 0, end_text.length())
	var prefix: String = start_text.substr(0, safe_start_column)
	var suffix: String = end_text.substr(safe_end_column)
	var before: Array = lines.slice(0, safe_start_line)
	var after: Array = lines.slice(safe_end_line + 1)
	var replacement_lines: Array = replacement.split("\n")
	if replacement_lines.is_empty():
		replacement_lines = [""]

	replacement_lines[0] = prefix + str(replacement_lines[0])
	replacement_lines[replacement_lines.size() - 1] = str(replacement_lines[replacement_lines.size() - 1]) + suffix

	var merged: Array = []
	merged.append_array(before)
	merged.append_array(replacement_lines)
	merged.append_array(after)
	return "\n".join(merged)

func _append_to_text(original_text: String, content: String) -> String:
	var cleaned_content: String = content.strip_edges()
	if cleaned_content.is_empty():
		return original_text
	if original_text.strip_edges().is_empty():
		return cleaned_content + "\n"

	var result: String = original_text
	if not result.ends_with("\n"):
		result += "\n"
	result += "\n" + cleaned_content + "\n"
	return result

func _insert_at_line(original_text: String, line_index: int, content: String) -> String:
	var cleaned_content: String = content.strip_edges()
	if cleaned_content.is_empty():
		return original_text

	var lines: Array = original_text.split("\n")
	if lines.is_empty():
		lines = [""]

	var safe_index: int = clampi(line_index, 0, lines.size())
	var before: Array = lines.slice(0, safe_index)
	var after: Array = lines.slice(safe_index)
	var inserted_lines: Array = cleaned_content.split("\n")
	var merged: Array = []
	merged.append_array(before)
	merged.append_array(inserted_lines)
	merged.append_array(after)
	return "\n".join(merged)

func _dedupe_candidates(candidates: Array) -> Array:
	var deduped: Array = []
	var seen: Dictionary = {}

	for candidate in candidates:
		if not (candidate is Dictionary):
			continue

		var key: String = "%s|%s|%s|%s|%s" % [
			str(candidate.get("execution_type", "")),
			str(candidate.get("target_label", "")),
			str(candidate.get("target_path", "")),
			str(candidate.get("start_line", -1)),
			str(candidate.get("end_line", -1)),
		]
		if seen.has(key):
			continue
		seen[key] = true
		deduped.append(candidate)

	return deduped

func _sort_candidates(a: Dictionary, b: Dictionary) -> bool:
	return float(a.get("confidence", 0.0)) > float(b.get("confidence", 0.0))

func _build_action_review_bbcode(action: Dictionary) -> String:
	var lines: Array = []
	lines.append("[b][color=#E5C07B]改动审查[/color][/b]")
	lines.append("动作：%s" % _localize_action_type(str(action.get("action_type", ACTION_EXPLAIN_ONLY))))
	lines.append("操作：%s" % _describe_operation(action))
	lines.append("目标：%s" % str(action.get("target_label", action.get("label", "改动"))))
	var target_path: String = str(action.get("target_path", "")).strip_edges()
	if not target_path.is_empty():
		lines.append("文件：%s" % target_path)
	var companion_script_target_path: String = str(action.get("companion_script_target_path", "")).strip_edges()
	if not companion_script_target_path.is_empty():
		lines.append("配套脚本：%s" % companion_script_target_path)
	var start_line: int = int(action.get("start_line", -1))
	var end_line: int = int(action.get("end_line", -1))
	if start_line >= 0 and end_line >= start_line:
		lines.append("行号：%d-%d" % [start_line + 1, end_line + 1])
	lines.append("风险：%s" % _localize_risk_level(str(action.get("risk_level", "unknown"))))
	lines.append("置信度：%.0f%%" % (float(action.get("confidence", 0.0)) * 100.0))
	lines.append("原因：%s" % str(action.get("match_reason", "没有记录目标匹配原因。")))
	if action_requires_secondary_confirmation(action):
		lines.append("警告：这个改动在执行前还需要再确认一次。")
	lines.append("")
	lines.append(_generate_diff_bbcode(
		str(action.get("original_text", "")),
		str(action.get("content", "")),
	))
	return "\n".join(lines)

func _generate_diff_bbcode(old_text: String, new_text: String) -> String:
	var old_lines: Array = old_text.split("\n")
	var new_lines: Array = new_text.split("\n")
	var bbcode: String = "[b][color=#E5C07B]内容差异预览[/color][/b]\n\n"

	var i: int = 0
	var j: int = 0
	var bg_red: String = "#442b30"
	var bg_green: String = "#2b4430"
	var fg_red: String = "#ff959c"
	var fg_green: String = "#b8ffad"

	while i < old_lines.size() or j < new_lines.size():
		if i < old_lines.size() and j < new_lines.size() and old_lines[i].strip_edges() == new_lines[j].strip_edges():
			bbcode += "      " + old_lines[i] + "\n"
			i += 1
			j += 1
		elif j < new_lines.size() and (i >= old_lines.size() or not (new_lines[j] in old_lines.slice(i, i + 5))):
			bbcode += "[bgcolor=%s][color=%s]  +   %s  [/color][/bgcolor]\n" % [bg_green, fg_green, new_lines[j]]
			j += 1
		elif i < old_lines.size():
			bbcode += "[bgcolor=%s][color=%s]  -   %s  [/color][/bgcolor]\n" % [bg_red, fg_red, old_lines[i]]
			i += 1

	return bbcode

func _truncate_preview_code(code: String, max_lines: int = 18) -> String:
	var lines: Array = code.split("\n")
	if lines.size() <= max_lines:
		return code
	return "\n".join(lines.slice(0, max_lines)) + "\n..."

func _build_risk_badge(action: Dictionary) -> String:
	if is_high_risk(action):
		return "高风险"
	var risk_level: String = str(action.get("risk_level", ""))
	if risk_level == "medium":
		return "需审查"
	return ""

func _localize_action_type(action_type: String) -> String:
	match action_type:
		ACTION_EXPLAIN_ONLY:
			return "仅解释"
		ACTION_SHOW_DIFF_ONLY:
			return "预览改动"
		ACTION_INSERT_AT_CARET:
			return "插入代码"
		ACTION_REPLACE_SELECTION:
			return "替换代码"
		ACTION_CREATE_SCENE:
			return "创建场景"
		_:
			return action_type

func _localize_execution_type(execution_type: String) -> String:
	match execution_type:
		EXEC_REPLACE_TEXT_RANGE:
			return "替换文本范围"
		EXEC_REPLACE_CODE_BLOCK:
			return "替换代码块"
		EXEC_REPLACE_FILE:
			return "替换整个文件"
		EXEC_INSERT_AT_CARET:
			return "在光标处插入"
		EXEC_INSERT_AT_FILE_END:
			return "追加到文件末尾"
		EXEC_CREATE_SCENE_FILE:
			return "创建场景文件"
		_:
			return execution_type

func _describe_operation(action: Dictionary) -> String:
	match str(action.get("execution_type", "")):
		EXEC_REPLACE_TEXT_RANGE:
			return "替换选中的文本范围。"
		EXEC_REPLACE_CODE_BLOCK:
			return "替换匹配到的代码块。"
		EXEC_REPLACE_FILE:
			return "替换整个目标文件。"
		EXEC_INSERT_AT_CARET:
			return "在光标位置插入生成代码。"
		EXEC_INSERT_AT_FILE_END:
			return "把生成代码追加到文件末尾。"
		EXEC_CREATE_SCENE_FILE:
			if str(action.get("original_text", "")).strip_edges().is_empty():
				return "创建一个新的场景文件。"
			return "替换现有场景文件内容。"
		_:
			return _localize_action_type(str(action.get("action_type", ACTION_EXPLAIN_ONLY)))

func _default_confirm_text(action: Dictionary) -> String:
	if str(action.get("action_type", "")) == ACTION_CREATE_SCENE:
		return "创建场景"
	return "应用改动"

func _localize_risk_level(risk_level: String) -> String:
	match risk_level:
		"low":
			return "低"
		"medium":
			return "中"
		"high":
			return "高"
		_:
			return "未知"

func _looks_like_gdscript_edit(code_text: String) -> bool:
	var normalized_code: String = code_text.to_lower()
	return _contains_any(normalized_code, [
		"extends ", "class_name ", "func ", "var ", "const ", "signal ",
		"@tool", "@onready", "match ", "await ", "return ", "if ", "for ",
	])

func _looks_like_scene_file(code_text: String, language: String = "") -> bool:
	var stripped: String = code_text.strip_edges()
	var normalized_language: String = language.to_lower()
	if normalized_language in ["tscn", "scene"] and stripped.begins_with("[gd_scene"):
		return true
	return stripped.begins_with("[gd_scene") and stripped.contains("[node ")

func _contains_any(text: String, patterns: Array) -> bool:
	for pattern in patterns:
		if text.contains(String(pattern)):
			return true
	return false

func _lstrip(text: String) -> String:
	var index: int = 0
	while index < text.length():
		var code: int = text.unicode_at(index)
		if code != 32 and code != 9:
			break
		index += 1
	return text.substr(index)
