@tool
extends EditorPlugin

# 用来保存我们实例化的 UI 面板
var dock

func _enter_tree():
	# 插件激活时调用：加载我们刚才做的 UI 场景
	dock = preload("res://addons/ai_assistant/ai_dock.tscn").instantiate()
	
	# 将它添加到编辑器的右侧面板 (Right Upper Layer)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

func _exit_tree():
	# 插件关闭时调用：清理垃圾，防止内存泄漏
	if dock:
		remove_control_from_docks(dock)
		dock.free()
