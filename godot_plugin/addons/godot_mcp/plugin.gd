@tool
extends EditorPlugin

var http_server: GodotMCPServer


func _enter_tree() -> void:
	http_server = GodotMCPServer.new()
	add_child(http_server)
	print("[GodotMCP] Plugin enabled — HTTP server starting on port 6789")


func _exit_tree() -> void:
	if http_server:
		http_server.stop()
		http_server.queue_free()
	print("[GodotMCP] Plugin disabled")
