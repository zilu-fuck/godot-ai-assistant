@tool
extends Control
class_name AIContextRing

signal activated

const START_ANGLE: float = -PI * 0.5
const FULL_ARC: float = TAU
const LABEL_TEXT_COLOR: Color = Color("d7dae0")
const LABEL_TEXT_MUTED_COLOR: Color = Color("8b93a3")

@export var display_text: String = "--":
	set(new_value):
		display_text = new_value
		_sync_label()
		queue_redraw()

@export var risk_level: String = "idle":
	set(new_value):
		risk_level = new_value
		_sync_label()
		queue_redraw()

@export var value: float = 0.0:
	set(new_value):
		value = clampf(new_value, 0.0, 1.0)
		_sync_label()
		queue_redraw()

@export var thickness: float = 4.0:
	set(new_value):
		thickness = maxf(new_value, 2.0)
		queue_redraw()

@export var track_color: Color = Color("2c313a"):
	set(new_value):
		track_color = new_value
		queue_redraw()

@export var fill_color: Color = Color("61afef"):
	set(new_value):
		fill_color = new_value
		queue_redraw()

@export var inner_color: Color = Color("15181d"):
	set(new_value):
		inner_color = new_value
		queue_redraw()

var _display_label: Label
var _is_hovered: bool = false
var _pulse_time: float = 0.0

func _ready() -> void:
	custom_minimum_size = Vector2(36, 36)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_ensure_label()
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	set_process(true)
	_sync_label()

func _process(delta: float) -> void:
	if risk_level in ["watch", "compress", "limit"]:
		_pulse_time += delta
		queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		emit_signal("activated")
		accept_event()

func _draw() -> void:
	var center: Vector2 = size * 0.5
	var radius: float = maxf(9.0, minf(size.x, size.y) * 0.5 - thickness - 1.0)
	var steps: int = 64
	var pulse_alpha: float = 0.0
	if risk_level in ["watch", "compress", "limit"]:
		pulse_alpha = 0.10 + 0.10 * (sin(_pulse_time * 4.0) * 0.5 + 0.5)

	if pulse_alpha > 0.0:
		var pulse_color: Color = fill_color.lightened(0.1)
		pulse_color.a = pulse_alpha
		draw_circle(center, radius + thickness * 0.9, pulse_color)

	draw_arc(center, radius, START_ANGLE, START_ANGLE + FULL_ARC, steps, track_color, thickness, true)

	if value > 0.0:
		draw_arc(
			center,
			radius,
			START_ANGLE,
			START_ANGLE + FULL_ARC * value,
			steps,
			fill_color,
			thickness,
			true
		)

	draw_circle(center, maxf(0.0, radius - thickness * 0.9), inner_color)
	_draw_risk_dot(center, radius)

	if _is_hovered:
		var hover_color: Color = fill_color
		hover_color.a = 0.28
		draw_arc(center, radius + thickness * 0.85, START_ANGLE, START_ANGLE + FULL_ARC, steps, hover_color, maxf(1.5, thickness * 0.4), true)

func _draw_risk_dot(center: Vector2, radius: float) -> void:
	var dot_radius: float = maxf(2.0, thickness * 0.42)
	var dot_angle: float = START_ANGLE + FULL_ARC * 0.16
	var dot_center: Vector2 = center + Vector2(cos(dot_angle), sin(dot_angle)) * (radius + thickness * 0.25)
	var dot_color: Color = LABEL_TEXT_MUTED_COLOR

	match risk_level:
		"healthy":
			dot_color = fill_color.lightened(0.15)
		"watch", "compress", "limit":
			dot_color = fill_color
		_:
			dot_color = LABEL_TEXT_MUTED_COLOR
			dot_color.a = 0.7

	draw_circle(dot_center, dot_radius, dot_color)

func _ensure_label() -> void:
	if _display_label != null:
		return

	_display_label = Label.new()
	_display_label.name = "ValueLabel"
	_display_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_display_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_display_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_display_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_display_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_display_label.anchor_left = 0.0
	_display_label.anchor_top = 0.0
	_display_label.anchor_right = 1.0
	_display_label.anchor_bottom = 1.0
	_display_label.offset_left = 0.0
	_display_label.offset_top = 0.0
	_display_label.offset_right = 0.0
	_display_label.offset_bottom = 0.0
	_display_label.add_theme_font_size_override("font_size", 9)
	add_child(_display_label)

func _sync_label() -> void:
	if _display_label == null:
		return

	_display_label.text = display_text
	_display_label.add_theme_color_override("font_color", LABEL_TEXT_COLOR if risk_level != "idle" else LABEL_TEXT_MUTED_COLOR)

func _on_mouse_entered() -> void:
	_is_hovered = true
	queue_redraw()

func _on_mouse_exited() -> void:
	_is_hovered = false
	queue_redraw()
