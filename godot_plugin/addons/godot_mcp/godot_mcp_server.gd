@tool
class_name GodotMCPServer
extends Node

const PORT := 6789
const MAX_BODY_SIZE := 1_048_576  # 1 MB

const MAX_LOG_ENTRIES := 100

var _tcp_server: TCPServer
var _clients: Array[StreamPeerTCP] = []
var _log_buffer: Array[Dictionary] = []
var _log_file_pos: int = 0


func _ready() -> void:
	_tcp_server = TCPServer.new()
	var err := _tcp_server.listen(PORT, "127.0.0.1")
	if err != OK:
		push_error("[GodotMCP] Failed to listen on port %d: %s" % [PORT, error_string(err)])
		return
	# Track the current end of the Godot log file so we only read new entries
	var log_path := OS.get_user_data_dir().path_join("logs/godot.log")
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f:
		f.seek_end(0)
		_log_file_pos = f.get_position()
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
		["POST", "/scene/save"]:
			_handle_save_scene(client, body)
		["POST", "/scene/node/create"]:
			_handle_create_node(client, body)
		["POST", "/scene/node/delete"]:
			_handle_delete_node(client, body)
		["GET", "/viewport/screenshot"]:
			_handle_viewport_screenshot(client)
		["GET", "/editor/screenshot"]:
			_handle_viewport_screenshot(client)
		["GET", "/editor/logs"]:
			_handle_get_logs(client, query)
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

	var user_code: String = body["code"]

	# Wrap user code in a GDScript class with a run() method
	var source := "@tool\nextends Node\n\nfunc run():\n"
	for line in user_code.split("\n"):
		source += "\t" + line + "\n"
	# If the user code doesn't explicitly return, add a null return
	if not "\treturn" in source:
		source += "\treturn null\n"

	var script := GDScript.new()
	script.source_code = source
	var err := script.reload()
	if err != OK:
		_send_response(client, 400, {"error": "Parse error", "code": err, "source": source})
		return

	# Create the object and add it to the scene tree temporarily so it has access to the tree
	var obj: Node = Node.new()
	obj.set_script(script)
	Engine.get_main_loop().root.add_child(obj)
	var result = obj.run()
	obj.queue_free()

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


func _handle_save_scene(client: StreamPeerTCP, body: Dictionary) -> void:
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_send_response(client, 404, {"error": "No scene open"})
		return

	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err != OK:
		_send_response(client, 500, {"error": "Failed to pack scene", "code": err})
		return

	var save_path: String = root.scene_file_path
	if body.has("path") and body["path"] != "":
		save_path = body["path"]

	if save_path == "":
		_send_response(client, 400, {"error": "Scene has no file path. Provide a 'path' parameter."})
		return

	err = ResourceSaver.save(scene, save_path)
	if err != OK:
		_send_response(client, 500, {"error": "Failed to save scene", "code": err})
		return

	_send_response(client, 200, {"ok": true, "path": save_path})


func _handle_create_node(client: StreamPeerTCP, body: Dictionary) -> void:
	if not body.has("type"):
		_send_response(client, 400, {"error": "Missing required field: type"})
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_send_response(client, 404, {"error": "No scene open"})
		return

	# Find the parent node
	var parent: Node = root
	if body.has("parent_path") and body["parent_path"] != "":
		parent = root.get_node_or_null(body["parent_path"])
		if not parent:
			_send_response(client, 404, {"error": "Parent node not found", "path": body["parent_path"]})
			return

	# Create the node by class name
	var node: Node = ClassDB.instantiate(body["type"])
	if not node:
		_send_response(client, 400, {"error": "Unknown node type", "type": body["type"]})
		return

	# Set the name if provided
	if body.has("name") and body["name"] != "":
		node.name = body["name"]

	parent.add_child(node)
	node.owner = root

	_send_response(client, 200, {
		"ok": true,
		"name": node.name,
		"type": body["type"],
		"path": str(node.get_path()),
	})


func _handle_delete_node(client: StreamPeerTCP, body: Dictionary) -> void:
	if not body.has("node_path"):
		_send_response(client, 400, {"error": "Missing required field: node_path"})
		return

	var root := EditorInterface.get_edited_scene_root()
	if not root:
		_send_response(client, 404, {"error": "No scene open"})
		return

	var node := root.get_node_or_null(body["node_path"])
	if not node:
		_send_response(client, 404, {"error": "Node not found", "path": body["node_path"]})
		return

	if node == root:
		_send_response(client, 400, {"error": "Cannot delete the root node"})
		return

	var node_name := node.name
	var node_path := str(node.get_path())
	node.get_parent().remove_child(node)
	node.queue_free()

	_send_response(client, 200, {"ok": true, "deleted": node_path, "name": node_name})


func _handle_viewport_screenshot(client: StreamPeerTCP) -> void:
	# Check if the edited scene is 2D or 3D
	var edited_root := EditorInterface.get_edited_scene_root()
	var is_2d := edited_root and (edited_root is Node2D or edited_root is Control)

	var image: Image = null

	if is_2d:
		# For 2D scenes, find the 2D editor SubViewport via the edited scene's viewport
		var scene_viewport := edited_root.get_viewport()
		if scene_viewport:
			image = scene_viewport.get_texture().get_image()
	else:
		# For 3D scenes, use the 3D viewport
		var viewport_3d := EditorInterface.get_editor_viewport_3d(0)
		if viewport_3d:
			image = viewport_3d.get_texture().get_image()

	# Fallback: main editor viewport
	if not image:
		var main_vp := EditorInterface.get_base_control().get_viewport()
		if main_vp:
			image = main_vp.get_texture().get_image()

	if not image:
		_send_response(client, 500, {"error": "Failed to capture viewport image"})
		return

	var png_data := image.save_png_to_buffer()
	var base64_str := Marshalls.raw_to_base64(png_data)

	_send_response(client, 200, {
		"ok": true,
		"format": "png",
		"width": image.get_width(),
		"height": image.get_height(),
		"data_base64": base64_str,
	})


func _handle_get_logs(client: StreamPeerTCP, query: Dictionary) -> void:
	# Read new lines from Godot's log file since last check
	var log_path := OS.get_user_data_dir().path_join("logs/godot.log")
	var f := FileAccess.open(log_path, FileAccess.READ)
	if f:
		f.seek(_log_file_pos)
		while f.get_position() < f.get_length():
			var line := f.get_line()
			if line.strip_edges() == "":
				continue
			var level := "info"
			if "ERROR" in line or "error" in line:
				level = "error"
			elif "WARNING" in line or "warning" in line:
				level = "warning"
			_log_buffer.append({
				"message": line,
				"level": level,
				"timestamp": Time.get_ticks_msec(),
			})
		_log_file_pos = f.get_position()

	# Trim to MAX_LOG_ENTRIES
	while _log_buffer.size() > MAX_LOG_ENTRIES:
		_log_buffer.pop_front()

	# Optional: filter by level
	var filter_level: String = query.get("level", "")
	var entries := []
	for entry in _log_buffer:
		if filter_level == "" or entry["level"] == filter_level:
			entries.append(entry)

	var clear: String = query.get("clear", "")
	if clear == "true":
		_log_buffer.clear()

	_send_response(client, 200, {
		"ok": true,
		"count": entries.size(),
		"logs": entries,
	})


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
