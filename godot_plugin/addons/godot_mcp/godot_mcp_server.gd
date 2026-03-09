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
		["GET", "/asset/search"]:
			_handle_search_assets(client, query)
		["POST", "/asset/download"]:
			_handle_download_asset(client, body)
		["POST", "/asset/install"]:
			_handle_install_asset(client, body)
		["GET", "/asset/preview"]:
			_handle_preview_asset(client, query)
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


## Blocking HTTP GET to an external host. Returns {"status": int, "body": String}.
func _http_get_external(host: String, path: String, use_tls: bool = true) -> Dictionary:
	var http := HTTPClient.new()
	var port := 443 if use_tls else 80
	var err := http.connect_to_host(host, port)
	if err != OK:
		return {"status": -1, "body": "connect error: %d" % err}

	# Wait for connection (blocking)
	while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
		OS.delay_msec(50)

	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"status": -1, "body": "connection failed, status: %d" % http.get_status()}

	var headers := ["User-Agent: GodotMCP/0.1", "Accept: application/json"]
	err = http.request(HTTPClient.METHOD_GET, path, headers)
	if err != OK:
		return {"status": -1, "body": "request error: %d" % err}

	# Wait for response
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		OS.delay_msec(50)

	if not http.has_response():
		return {"status": -1, "body": "no response"}

	var status_code := http.get_response_code()
	var rb := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			rb.append_array(chunk)
		OS.delay_msec(10)

	return {"status": status_code, "body": rb.get_string_from_utf8()}


## Blocking HTTP GET that returns raw bytes (for downloading zip files).
func _http_get_raw(host: String, path: String, use_tls: bool = true) -> Dictionary:
	var http := HTTPClient.new()
	var port := 443 if use_tls else 80
	var err := http.connect_to_host(host, port)
	if err != OK:
		return {"status": -1, "data": PackedByteArray()}

	while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
		http.poll()
		OS.delay_msec(50)

	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return {"status": -1, "data": PackedByteArray()}

	var headers := ["User-Agent: GodotMCP/0.1"]
	err = http.request(HTTPClient.METHOD_GET, path, headers)
	if err != OK:
		return {"status": -1, "data": PackedByteArray()}

	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		OS.delay_msec(50)

	if not http.has_response():
		return {"status": -1, "data": PackedByteArray()}

	var status_code := http.get_response_code()

	# Handle redirects (3xx)
	if status_code >= 300 and status_code < 400:
		var resp_headers := http.get_response_headers_as_dictionary()
		var location: String = resp_headers.get("Location", resp_headers.get("location", ""))
		if location != "":
			var redir_tls := location.begins_with("https://")
			var prefix_len := 8 if redir_tls else 7
			if location.begins_with("https://") or location.begins_with("http://"):
				var stripped := location.substr(prefix_len)
				var slash := stripped.find("/")
				var redir_host := stripped.substr(0, slash)
				var redir_path := stripped.substr(slash)
				return _http_get_raw(redir_host, redir_path, redir_tls)

	var rb := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			rb.append_array(chunk)
		OS.delay_msec(10)

	return {"status": status_code, "data": rb}


func _handle_search_assets(client: StreamPeerTCP, query: Dictionary) -> void:
	var filter: String = query.get("filter", query.get("query", ""))
	if filter == "":
		_send_response(client, 400, {"error": "Missing 'filter' or 'query' parameter"})
		return

	var max_results: String = query.get("max_results", "10")
	var category: String = query.get("category", "")

	var api_path := "/asset-library/api/asset?filter=%s&max_results=%s" % [filter.uri_encode(), max_results]
	if category != "":
		api_path += "&category=%s" % category.uri_encode()

	var resp := _http_get_external("godotengine.org", api_path, true)
	if resp["status"] != 200:
		_send_response(client, 502, {"error": "Asset Library request failed", "status": resp["status"], "body": resp["body"]})
		return

	var json := JSON.new()
	if json.parse(resp["body"]) != OK:
		_send_response(client, 500, {"error": "Failed to parse Asset Library response"})
		return

	var data: Dictionary = json.data
	var results := []
	for asset in data.get("result", []):
		results.append({
			"id": asset.get("asset_id"),
			"title": asset.get("title"),
			"description": asset.get("description", ""),
			"author": asset.get("author", ""),
			"category": asset.get("category", ""),
			"rating": asset.get("rating", 0),
			"download_url": asset.get("download_url", ""),
			"icon_url": asset.get("icon_url", ""),
		})

	_send_response(client, 200, {"ok": true, "query": filter, "count": results.size(), "results": results})


func _handle_download_asset(client: StreamPeerTCP, body: Dictionary) -> void:
	if not body.has("asset_id"):
		_send_response(client, 400, {"error": "Missing required field: asset_id"})
		return

	var asset_id: String = str(body["asset_id"])

	# 1. Get asset info from the API
	var info_resp := _http_get_external("godotengine.org", "/asset-library/api/asset/%s" % asset_id, true)
	if info_resp["status"] != 200:
		_send_response(client, 502, {"error": "Failed to get asset info", "status": info_resp["status"]})
		return

	var json := JSON.new()
	if json.parse(info_resp["body"]) != OK:
		_send_response(client, 500, {"error": "Failed to parse asset info"})
		return

	var info: Dictionary = json.data
	var title: String = info.get("title", "asset_%s" % asset_id)
	var download_url: String = info.get("download_url", "")
	if download_url == "":
		_send_response(client, 400, {"error": "No download URL for this asset"})
		return

	# 2. Parse download URL and fetch the zip
	var dl_host := ""
	var dl_path := ""
	var dl_tls := true
	if download_url.begins_with("https://") or download_url.begins_with("http://"):
		dl_tls = download_url.begins_with("https://")
		var prefix_len := 8 if dl_tls else 7
		var stripped := download_url.substr(prefix_len)
		var slash := stripped.find("/")
		dl_host = stripped.substr(0, slash)
		dl_path = stripped.substr(slash)
	else:
		_send_response(client, 400, {"error": "Invalid download URL", "url": download_url})
		return

	var zip_resp := _http_get_raw(dl_host, dl_path, dl_tls)
	if zip_resp["status"] != 200:
		_send_response(client, 502, {"error": "Failed to download zip", "status": zip_resp["status"]})
		return

	var zip_data: PackedByteArray = zip_resp["data"]
	if zip_data.size() == 0:
		_send_response(client, 502, {"error": "Downloaded zip is empty"})
		return

	# 3. Save zip, extract, clean up (reuse install logic)
	var safe_name := title.strip_edges()
	# Keep only alphanumeric, space, dash, underscore
	var clean := ""
	for i in range(safe_name.length()):
		var ch := safe_name[i]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == " " or ch == "-" or ch == "_":
			clean += ch
	safe_name = clean.strip_edges().replace(" ", "_")
	if safe_name == "":
		safe_name = "asset_%s" % asset_id

	var tmp_path := "user://tmp_asset.zip"
	var tmp_file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if not tmp_file:
		_send_response(client, 500, {"error": "Cannot create temp file"})
		return
	tmp_file.store_buffer(zip_data)
	tmp_file.close()

	var reader := ZIPReader.new()
	var err := reader.open(tmp_path)
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		_send_response(client, 500, {"error": "Failed to open zip", "code": err})
		return

	var asset_dir := "res://assets/" + safe_name
	DirAccess.make_dir_recursive_absolute(asset_dir)

	var extracted_files := []
	for file_path in reader.get_files():
		if file_path.ends_with("/") or file_path.begins_with("."):
			continue
		var content := reader.read_file(file_path)
		var dest_name := file_path
		var slash_pos := file_path.find("/")
		if slash_pos >= 0:
			dest_name = file_path.substr(slash_pos + 1)
		if dest_name == "":
			continue
		var dest_path := asset_dir.path_join(dest_name)
		var dest_dir := dest_path.get_base_dir()
		DirAccess.make_dir_recursive_absolute(dest_dir)
		var out := FileAccess.open(dest_path, FileAccess.WRITE)
		if out:
			out.store_buffer(content)
			extracted_files.append(dest_path)

	reader.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
	EditorInterface.get_resource_filesystem().scan()

	_send_response(client, 200, {
		"ok": true,
		"asset_id": asset_id,
		"title": title,
		"asset_name": safe_name,
		"directory": asset_dir,
		"files": extracted_files,
		"file_count": extracted_files.size(),
	})


func _handle_install_asset(client: StreamPeerTCP, body: Dictionary) -> void:
	if not body.has("zip_base64") or not body.has("asset_name"):
		_send_response(client, 400, {"error": "Missing required fields: zip_base64, asset_name"})
		return

	var zip_data := Marshalls.base64_to_raw(body["zip_base64"])
	if zip_data.size() == 0:
		_send_response(client, 400, {"error": "Invalid base64 data"})
		return

	# Save zip to a temp file
	var tmp_path := "user://tmp_asset.zip"
	var tmp_file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if not tmp_file:
		_send_response(client, 500, {"error": "Cannot create temp file"})
		return
	tmp_file.store_buffer(zip_data)
	tmp_file.close()

	# Extract zip contents
	var reader := ZIPReader.new()
	var err := reader.open(tmp_path)
	if err != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		_send_response(client, 500, {"error": "Failed to open zip", "code": err})
		return

	var asset_dir := "res://assets/" + body["asset_name"]
	DirAccess.make_dir_recursive_absolute(asset_dir)

	var extracted_files := []
	for file_path in reader.get_files():
		# Skip directories and hidden files
		if file_path.ends_with("/") or file_path.begins_with("."):
			continue
		var content := reader.read_file(file_path)
		# Strip the top-level directory from zip if present
		var dest_name := file_path
		var slash_pos := file_path.find("/")
		if slash_pos >= 0:
			dest_name = file_path.substr(slash_pos + 1)
		if dest_name == "":
			continue
		var dest_path := asset_dir.path_join(dest_name)
		# Ensure subdirectories exist
		var dest_dir := dest_path.get_base_dir()
		DirAccess.make_dir_recursive_absolute(dest_dir)
		var out := FileAccess.open(dest_path, FileAccess.WRITE)
		if out:
			out.store_buffer(content)
			extracted_files.append(dest_path)

	reader.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))

	# Refresh the filesystem so Godot sees the new files
	EditorInterface.get_resource_filesystem().scan()

	_send_response(client, 200, {
		"ok": true,
		"asset_name": body["asset_name"],
		"directory": asset_dir,
		"files": extracted_files,
		"file_count": extracted_files.size(),
	})


func _handle_preview_asset(client: StreamPeerTCP, query: Dictionary) -> void:
	if not query.has("path"):
		_send_response(client, 400, {"error": "Missing 'path' parameter"})
		return

	var path: String = query["path"]
	if not FileAccess.file_exists(path):
		_send_response(client, 404, {"error": "File not found", "path": path})
		return

	var image := Image.new()
	var err := image.load(path)
	if err != OK:
		_send_response(client, 400, {"error": "Cannot load image", "path": path, "code": err})
		return

	# Resize to max 512px on the longest side to save tokens
	var max_size := 512
	if image.get_width() > max_size or image.get_height() > max_size:
		if image.get_width() >= image.get_height():
			var new_h := int(float(image.get_height()) * max_size / image.get_width())
			image.resize(max_size, new_h, Image.INTERPOLATE_LANCZOS)
		else:
			var new_w := int(float(image.get_width()) * max_size / image.get_height())
			image.resize(new_w, max_size, Image.INTERPOLATE_LANCZOS)

	var png_data := image.save_png_to_buffer()
	var base64_str := Marshalls.raw_to_base64(png_data)

	_send_response(client, 200, {
		"ok": true,
		"path": path,
		"format": "png",
		"width": image.get_width(),
		"height": image.get_height(),
		"data_base64": base64_str,
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
