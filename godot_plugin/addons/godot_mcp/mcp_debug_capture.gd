@tool
class_name MCPDebugCapture
extends Node

const MAX_MESSAGES := 500

var _messages: Array[Dictionary] = []


func _ready() -> void:
	if EngineDebugger.has_capture("mcp"):
		EngineDebugger.unregister_message_capture("mcp")
	EngineDebugger.register_message_capture("mcp", _on_debug_message)


func _exit_tree() -> void:
	if EngineDebugger.has_capture("mcp"):
		EngineDebugger.unregister_message_capture("mcp")


func _on_debug_message(message: String, data: Array) -> bool:
	var level := "info"
	if "error" in message.to_lower():
		level = "error"
	elif "warning" in message.to_lower():
		level = "warning"

	_messages.append({
		"message": message,
		"data": data.map(func(d): return str(d)),
		"level": level,
		"timestamp": Time.get_ticks_msec(),
	})

	while _messages.size() > MAX_MESSAGES:
		_messages.pop_front()

	return true


func get_messages(filter_level: String = "", clear: bool = false) -> Array:
	var result := []
	for msg in _messages:
		if filter_level == "" or msg["level"] == filter_level:
			result.append(msg)
	if clear:
		_messages.clear()
	return result
