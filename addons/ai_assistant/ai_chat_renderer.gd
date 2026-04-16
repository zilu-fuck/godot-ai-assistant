@tool
extends Node
class_name AIChatRenderer

signal response_action_requested(block_index: int)

var chat_scroll: ScrollContainer
var message_list: VBoxContainer
var last_generated_code: String = ""

func setup(scroll: ScrollContainer, list: VBoxContainer) -> void:
	chat_scroll = scroll
	message_list = list

func clear_chat() -> void:
	for child in message_list.get_children():
		child.queue_free()
	last_generated_code = ""

func render_message(role: String, content: String, reasoning: String = "", render_options: Dictionary = {}) -> void:
	var role_node: RichTextLabel = RichTextLabel.new()
	role_node.bbcode_enabled = true
	role_node.fit_content = true
	var color: String = "#61AFEF"
	if role == "user":
		color = "#98C379"
	var role_name: String = "AI"
	if role == "user":
		role_name = "You"
	role_node.append_text("\n[b][color=%s]%s[/color][/b]" % [color, role_name])
	message_list.add_child(role_node)

	if not reasoning.is_empty():
		message_list.add_child(create_system_tip("[color=#5C6370][i]Thinking...\n%s[/i][/color]" % reasoning))

	if role == "assistant":
		last_generated_code = ""

	var in_code_block: bool = false
	var current_lang: String = ""
	var text_buffer: String = ""
	var code_buffer: String = ""
	var code_block_index: int = 0
	var lines: Array = content.split("\n")

	for line in lines:
		if line.strip_edges().begins_with("```"):
			if not in_code_block:
				if not text_buffer.strip_edges().is_empty():
					message_list.add_child(_create_text_node(text_buffer.strip_edges()))
				text_buffer = ""
				in_code_block = true
				current_lang = line.strip_edges().substr(3).strip_edges()
			else:
				if not code_buffer.strip_edges().is_empty():
					var resolved_code: String = code_buffer.strip_edges()
					var code_block_action: Dictionary = _resolve_code_block_action(render_options, code_block_index)
					message_list.add_child(_create_code_block(resolved_code, current_lang, code_block_index, code_block_action))
					if bool(code_block_action.get("show_primary_action", false)):
						last_generated_code = resolved_code
					code_block_index += 1
				code_buffer = ""
				in_code_block = false
				current_lang = ""
		else:
			if in_code_block:
				code_buffer += line + "\n"
			else:
				text_buffer += line + "\n"

	if not text_buffer.strip_edges().is_empty():
		message_list.add_child(_create_text_node(text_buffer.strip_edges()))
	if in_code_block and not code_buffer.strip_edges().is_empty():
		var trailing_code: String = code_buffer.strip_edges()
		var trailing_action: Dictionary = _resolve_code_block_action(render_options, code_block_index)
		message_list.add_child(_create_code_block(trailing_code, current_lang, code_block_index, trailing_action))
		if bool(trailing_action.get("show_primary_action", false)):
			last_generated_code = trailing_code

	_scroll_to_bottom()

func create_stream_node() -> RichTextLabel:
	var node: RichTextLabel = _create_text_node("[color=#888888][i]Connecting to model...[/i][/color]")
	message_list.add_child(node)
	_scroll_to_bottom()
	return node

func update_stream_node(node: RichTextLabel, content: String, reasoning: String) -> void:
	if not is_instance_valid(node):
		return
	var text: String = ""
	if reasoning != "":
		text += "[color=#5C6370][i]Thinking...\n" + reasoning + "[/i][/color]\n\n"
	node.text = text + content
	_scroll_to_bottom()

func create_system_tip(bbcode_text: String) -> RichTextLabel:
	return _create_text_node(bbcode_text)

func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	if is_instance_valid(chat_scroll):
		chat_scroll.scroll_vertical = chat_scroll.get_v_scroll_bar().max_value

func _create_text_node(txt: String) -> RichTextLabel:
	var lbl: RichTextLabel = RichTextLabel.new()
	lbl.bbcode_enabled = true
	lbl.fit_content = true
	lbl.selection_enabled = true
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.text = txt
	return lbl

func _create_code_block(code_text: String, lang: String, block_index: int, action: Dictionary = {}) -> PanelContainer:
	var panel: PanelContainer = PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color("#1e1e1e")
	style.set_corner_radius_all(6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)

	var v_box: VBoxContainer = VBoxContainer.new()
	panel.add_child(v_box)

	var toolbar: HBoxContainer = HBoxContainer.new()
	v_box.add_child(toolbar)

	var lang_label: Label = Label.new()
	lang_label.text = "CODE"
	if not lang.is_empty():
		lang_label.text = lang.to_upper()
	lang_label.add_theme_color_override("font_color", Color("#888888"))
	lang_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(lang_label)

	if bool(action.get("show_primary_action", false)):
		var apply_btn: Button = Button.new()
		apply_btn.text = String(action.get("button_label", "Preview"))
		apply_btn.flat = true
		apply_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		apply_btn.tooltip_text = String(action.get("button_tooltip", action.get("reason", "Review this AI-generated change before applying it.")))
		apply_btn.pressed.connect(func():
			response_action_requested.emit(block_index)
		)
		toolbar.add_child(apply_btn)

	var copy_btn: Button = Button.new()
	copy_btn.text = "Copy"
	copy_btn.flat = true
	copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(code_text)
		copy_btn.text = "Copied!"
		await panel.get_tree().create_timer(1.0).timeout
		if is_instance_valid(copy_btn):
			copy_btn.text = "Copy"
	)
	toolbar.add_child(copy_btn)

	var code_edit: CodeEdit = CodeEdit.new()
	code_edit.text = code_text
	code_edit.editable = false
	code_edit.scroll_fit_content_height = true
	code_edit.custom_minimum_size.y = max(35, code_text.split("\n").size() * 24)

	var empty_style: StyleBoxEmpty = StyleBoxEmpty.new()
	code_edit.add_theme_stylebox_override("normal", empty_style)
	code_edit.add_theme_stylebox_override("read_only", empty_style)

	var gui = EditorInterface.get_base_control()
	if gui.has_theme_font("source", "EditorFonts"):
		code_edit.add_theme_font_override("font", gui.get_theme_font("source", "EditorFonts"))

	var highlighter: CodeHighlighter = CodeHighlighter.new()
	highlighter.number_color = Color("#D19A66")
	highlighter.function_color = Color("#61AFEF")
	highlighter.member_variable_color = Color("#E06C75")
	var keywords: Array = ["func", "var", "const", "extends", "class_name", "if", "elif", "else", "for", "while", "return", "await", "true", "false", "null"]
	for k in keywords:
		highlighter.add_keyword_color(k, Color("#C678DD"))
	highlighter.add_color_region('"', '"', Color("#98C379"))
	highlighter.add_color_region("#", "", Color("#5C6370"), true)

	code_edit.syntax_highlighter = highlighter
	v_box.add_child(code_edit)
	return panel

func _resolve_code_block_action(render_options: Dictionary, block_index: int) -> Dictionary:
	var actions = render_options.get("code_block_actions", [])
	if not (actions is Array):
		return {}
	if block_index < 0 or block_index >= actions.size():
		return {}
	if actions[block_index] is Dictionary:
		return actions[block_index]
	return {}
