@tool
extends EditorPlugin

var http_server: GodotMCPServer
var debug_capture: MCPDebugCapture


func _enter_tree() -> void:
	debug_capture = MCPDebugCapture.new()
	add_child(debug_capture)

	http_server = GodotMCPServer.new()
	http_server.debug_capture = debug_capture
	add_child(http_server)
	print("[GodotMCP] Plugin enabled — HTTP server starting on port 6789")


func _exit_tree() -> void:
	if http_server:
		http_server.stop()
		http_server.queue_free()
	if debug_capture:
		debug_capture.queue_free()
	print("[GodotMCP] Plugin disabled")
