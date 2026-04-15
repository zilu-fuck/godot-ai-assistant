@tool
extends Control
class_name AIContextRing

const START_ANGLE: float = -PI * 0.5
const FULL_ARC: float = TAU

@export var value: float = 0.0:
	set(new_value):
		value = clampf(new_value, 0.0, 1.0)
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

func _ready() -> void:
	custom_minimum_size = Vector2(28, 28)
	mouse_filter = Control.MOUSE_FILTER_STOP

func _draw() -> void:
	var center: Vector2 = size * 0.5
	var radius: float = maxf(8.0, minf(size.x, size.y) * 0.5 - thickness)
	var steps: int = 64

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
