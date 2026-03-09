@tool
class_name GodotMCPServer
extends Node

const PORT := 8080
const MAX_BODY_SIZE := 1_048_576  # 1 MB

var _tcp_server: TCPServer
var _clients: Array[StreamPeerTCP] = []


func _ready() -> void:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(PORT, "127.0.0.1")
	if err != OK:
		push_error("[GodotMCP] Failed to listen on port %d: %s" % [PORT, error_string(err)])
		return
	print("[GodotMCP] HTTP server listening on 127.0.0.1:%d" % PORT)


func stop() -> void:
	if _tcp_server:
		_tcp_server.stop()
	for client in _clients:
		client.disconnect_from_host()
	_clients.clear()


func _process(_delta: float) -> void:
	if not _tcp_server or not _tcp_server.is_listening():
		return

	# Accept new connections
	while _tcp_server.is_connection_available():
		var peer := _tcp_server.take_connection()
		if peer:
			_clients.append(peer)

	# Process existing connections
	var to_remove: Array[int] = []
	for i in range(_clients.size()):
		var client := _clients[i]
		client.poll()
		if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			if client.get_available_bytes() > 0:
				var data := client.get_utf8_string(client.get_available_bytes())
				if data.length() > 0:
					_handle_request(client, data)
					to_remove.append(i)
		elif client.get_status() == StreamPeerTCP.STATUS_NONE or client.get_status() == StreamPeerTCP.STATUS_ERROR:
			to_remove.append(i)

	# Clean up disconnected clients (reverse order)
	to_remove.reverse()
	for i in to_remove:
		_clients.remove_at(i)


func _handle_request(client: StreamPeerTCP, raw: String) -> void:
	var lines := raw.split("\r\n")
	if lines.size() == 0:
		_send_response(client, 400, {"error": "Empty request"})
		return

	var request_line := lines[0].split(" ")
	if request_line.size() < 2:
		_send_response(client, 400, {"error": "Malformed request line"})
		return

	var method := request_line[0]
	var full_path := request_line[1]

	# Parse path and query string
	var path := full_path
	var query := {}
	if "?" in full_path:
		var parts := full_path.split("?", true, 1)
		path = parts[0]
		query = _parse_query_string(parts[1])

	# Parse body for POST requests
	var body := {}
	if method == "POST":
		var body_start := raw.find("\r\n\r\n")
		if body_start >= 0:
			var body_str := raw.substr(body_start + 4)
			if body_str.length() > 0:
				var json := JSON.new()
				if json.parse(body_str) == OK:
					body = json.data

	_route_request(client, method, path, query, body)


func _parse_query_string(qs: String) -> Dictionary:
	var result := {}
	for pair in qs.split("&"):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2:
			result[kv[0]] = kv[1].uri_decode()
		elif kv.size() == 1:
			result[kv[0]] = ""
	return result


func _route_request(client: StreamPeerTCP, method: String, path: String, query: Dictionary, body: Dictionary) -> void:
	match [method, path]:
		["GET", "/editor/state"]:
			_handle_editor_state(client)
		["GET", "/scene/tree"]:
			_handle_scene_tree(client, query)
		["GET", "/scene/node"]:
			_handle_get_node(client, query)
		["POST", "/scene/node/property"]:
			_handle_set_node_property(client, body)
		["POST", "/editor/run"]:
			_handle_run_scene(client, body)
		["POST", "/editor/stop"]:
			_handle_stop_scene(client)
		["POST", "/script/execute"]:
			_handle_execute_script(client, body)
		["GET", "/project/files"]:
			_handle_project_files(client, query)
		["GET", "/script/read"]:
			_handle_read_script(client, query)
		["POST", "/script/write"]:
			_handle_write_script(client, body)
		_:
			_send_response(client, 404, {"error": "Not found", "path": path})


# ---- Handlers ----

func _handle_editor_state(client: StreamPeerTCP) -> void:
	var editor := EditorInterface.get_editor_main_screen()
	var edited_scene := EditorInterface.get_edited_scene_root()
	var result := {
		"edited_scene": edited_scene.scene_file_path if edited_scene else "",
		"edited_scene_name": edited_scene.name if edited_scene else "",
		"godot_version": Engine.get_version_info(),
	}
	_send_response(client, 200, result)


func _handle_scene_tree(client: StreamPeerTCP, query: Dictionary) -> void:
	var root: Node = null
	if query.has("path") and query["path"] != "":
		var scene := load(query["path"]) as PackedScene
		if not scene:
			_send_response(client, 404, {"error": "Scene not found"})
			return
		root = scene.instantiate()
		var tree := _node_to_dict(root)
		root.queue_free()
		_send_response(client, 200, tree)
	else:
		root = EditorInterface.get_edited_scene_root()
		if not root:
			_send_response(client, 404, {"error": "No scene open"})
			return
		_send_response(client, 200, _node_to_dict(root))


func _node_to_dict(node: Node) -> Dictionary:
	var result := {
		"name": node.name,
		"type": node.get_class(),
		"path": str(node.get_path()) if node.is_inside_tree() else node.name,
		"children": [],
	}
	for child in node.get_children():
		result["children"].append(_node_to_dict(child))
	return result


func _handle_get_node(client: StreamPeerTCP, query: Dictionary) -> void:
	if not query.has("path"):
		_send_response(client, 400, {"error": "Missing 'path' parameter"})
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_send_response(client, 404, {"error": "No scene open"})
		return

	var node := root.get_node_or_null(query["path"])
	if not node:
		_send_response(client, 404, {"error": "Node not found", "path": query["path"]})
		return

	var props := {}
	for prop in node.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_EDITOR:
			var value = node.get(prop["name"])
			props[prop["name"]] = _value_to_json(value)

	_send_response(client, 200, {
		"name": node.name,
		"type": node.get_class(),
		"path": str(node.get_path()),
		"properties": props,
	})


func _handle_set_node_property(client: StreamPeerTCP, body: Dictionary) -> void:
	if not body.has("node_path") or not body.has("property") or not body.has("value"):
		_send_response(client, 400, {"error": "Missing required fields: node_path, property, value"})
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_send_response(client, 404, {"error": "No scene open"})
		return

	var node := root.get_node_or_null(body["node_path"])
	if not node:
		_send_response(client, 404, {"error": "Node not found"})
		return

	node.set(body["property"], body["value"])
	_send_response(client, 200, {"ok": true, "node": body["node_path"], "property": body["property"]})


func _handle_run_scene(client: StreamPeerTCP, body: Dictionary) -> void:
	if body.has("scene") and body["scene"] != "":
		EditorInterface.play_custom_scene(body["scene"])
	else:
		EditorInterface.play_current_scene()
	_send_response(client, 200, {"ok": true, "action": "run"})


func _handle_stop_scene(client: StreamPeerTCP) -> void:
	EditorInterface.stop_playing_scene()
	_send_response(client, 200, {"ok": true, "action": "stop"})


func _handle_execute_script(client: StreamPeerTCP, body: Dictionary) -> void:
	if not body.has("code"):
		_send_response(client, 400, {"error": "Missing 'code' field"})
		return

	var expression := Expression.new()
	var err := expression.parse(body["code"])
	if err != OK:
		_send_response(client, 400, {"error": "Parse error", "message": expression.get_error_text()})
		return

	var result = expression.execute()
	if expression.has_execute_failed():
		_send_response(client, 500, {"error": "Execution failed", "message": expression.get_error_text()})
		return

	_send_response(client, 200, {"ok": true, "result": _value_to_json(result)})


func _handle_project_files(client: StreamPeerTCP, query: Dictionary) -> void:
	var dir_path: String = query.get("dir", "res://")
	var pattern: String = query.get("pattern", "*")

	var files := _list_files_recursive(dir_path, pattern)
	_send_response(client, 200, {"directory": dir_path, "pattern": pattern, "files": files})


func _list_files_recursive(path: String, pattern: String) -> Array:
	var result := []
	var dir := DirAccess.open(path)
	if not dir:
		return result

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		var full_path := path.path_join(file_name)
		if dir.current_is_dir():
			result.append_array(_list_files_recursive(full_path, pattern))
		elif pattern == "*" or file_name.match(pattern):
			result.append(full_path)
		file_name = dir.get_next()
	return result


func _handle_read_script(client: StreamPeerTCP, query: Dictionary) -> void:
	if not query.has("path"):
		_send_response(client, 400, {"error": "Missing 'path' parameter"})
		return

	var file := FileAccess.open(query["path"], FileAccess.READ)
	if not file:
		_send_response(client, 404, {"error": "File not found", "path": query["path"]})
		return

	var content := file.get_as_text()
	_send_response(client, 200, {"path": query["path"], "content": content})


func _handle_write_script(client: StreamPeerTCP, body: Dictionary) -> void:
	if not body.has("path") or not body.has("content"):
		_send_response(client, 400, {"error": "Missing required fields: path, content"})
		return

	var file := FileAccess.open(body["path"], FileAccess.WRITE)
	if not file:
		_send_response(client, 500, {"error": "Cannot write file", "path": body["path"]})
		return

	file.store_string(body["content"])
	_send_response(client, 200, {"ok": true, "path": body["path"]})


# ---- Response helpers ----

func _send_response(client: StreamPeerTCP, status: int, data: Dictionary) -> void:
	var body := JSON.stringify(data)
	var status_text := "OK" if status == 200 else "Error"
	var response := "HTTP/1.1 %d %s\r\n" % [status, status_text]
	response += "Content-Type: application/json\r\n"
	response += "Content-Length: %d\r\n" % body.length()
	response += "Connection: close\r\n"
	response += "Access-Control-Allow-Origin: *\r\n"
	response += "\r\n"
	response += body
	client.put_data(response.to_utf8_buffer())


func _value_to_json(value: Variant) -> Variant:
	if value == null:
		return null
	if value is bool or value is int or value is float or value is String:
		return value
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is Array:
		var arr := []
		for item in value:
			arr.append(_value_to_json(item))
		return arr
	if value is Dictionary:
		var dict := {}
		for key in value:
			dict[str(key)] = _value_to_json(value[key])
		return dict
	return str(value)
