# RodinGen2Loader.gd (Godot 4.x)
extends Node
class_name RodinGen2Loader

# --- CONFIG ---
const RODIN_API_BASE := "https://api.hyper3d.com/api/v2"
const API_KEY := "6U224eE8QxWEQtSsSbGLb6TWvzjjMKAf4D7nFlozQPrUyfW7cgiKkKQGdQNzOMoN" # Tip: stash in ProjectSettings or env
const POLL_INTERVAL_SEC := 3.0
const DOWNLOAD_FILENAME := "rodin_model.glb"

# --- SIGNALS ---
signal generation_started(task_uuid: String, subscription_key: String)
signal generation_progress(status: String)
signal generation_failed(message: String)
signal generation_completed(glb_path: String, instanced_node: Node)

# --- PUBLIC ---
## Starts a Text->3D (Gen-2) job from a prompt, downloads GLB, and instances it.
func generate_text_to_glb(prompt: String, quality: String = "medium", mesh_mode: String = "Quad") -> void:
	var submit_res := await _submit_generation(prompt, quality, mesh_mode)
	if typeof(submit_res) != TYPE_DICTIONARY:
		emit_signal("generation_failed", "Submit failed (no JSON).")
		return
	if not submit_res.has("uuid") or not submit_res.has("jobs"):
		emit_signal("generation_failed", "Submit returned unexpected payload.")
		return

	var task_uuid: String = str(submit_res["uuid"])
	var subscription_key: String = ""
	if submit_res["jobs"] is Dictionary and submit_res["jobs"].has("subscription_key"):
		subscription_key = str(submit_res["jobs"]["subscription_key"])
	elif submit_res["jobs"] is Array and submit_res["jobs"].size() > 0 and submit_res["jobs"][0].has("subscription_key"):
		subscription_key = str(submit_res["jobs"][0]["subscription_key"])
	else:
		emit_signal("generation_failed", "Missing subscription_key.")
		return

	emit_signal("generation_started", task_uuid, subscription_key)

	# Poll until Done/Failed
	while true:
		var status := await _check_status(subscription_key)
		if status == "":
			emit_signal("generation_failed", "Status check failed.")
			return
		emit_signal("generation_progress", status)
		if status == "Done":
			break
		if status == "Failed":
			emit_signal("generation_failed", "Remote generation failed.")
			return
		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout

	# Get downloadable files; pick a .glb
	var files := await _download_results(task_uuid)
	if typeof(files) != TYPE_ARRAY or files.is_empty():
		emit_signal("generation_failed", "No downloadable files.")
		return

	var glb_url := ""
	for f in files:
		if typeof(f) == TYPE_DICTIONARY:
			var name := str(f.get("name", "")).to_lower()
			var url := str(f.get("url", ""))
			if name.ends_with(".glb") or url.ends_with(".glb"):
				glb_url = url
				break
	if glb_url == "":
		emit_signal("generation_failed", "No .glb found in results.")
		return

	# Download GLB to user://
	var save_path := "user://%s" % DOWNLOAD_FILENAME
	var ok := await _download_file(glb_url, save_path)
	if not ok:
		emit_signal("generation_failed", "GLB download failed.")
		return

	# Load GLB at runtime
	var scene := _load_glb_scene(save_path)
	if scene == null:
		emit_signal("generation_failed", "GLB parse failed.")
		return

	var inst = scene.instantiate()
	add_child(inst)
	emit_signal("generation_completed", save_path, inst)


# --- HTTP HELPERS ---

# 1) Submit Gen-2 job (multipart/form-data; no images => pure Text->3D)
func _submit_generation(prompt: String, quality: String, mesh_mode: String) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)

	var url := "%s/rodin" % RODIN_API_BASE
	var form_fields := {
		"tier": "Gen-2",
		"prompt": prompt,
		"geometry_file_format": "glb",
		"material": "PBR",
		"quality": quality,          # high|medium|low|extra-low
		"mesh_mode": mesh_mode       # Raw|Quad
	}
	var enc := _encode_multipart(form_fields)
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % API_KEY,
		"Content-Type: %s" % enc.content_type,
		"accept: application/json"
	])

	var err := http.request_raw(url, headers, HTTPClient.METHOD_POST, enc.body)
	if err != OK:
		remove_child(http); http.queue_free()
		return {}

	var result = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if code != 200 and code != 201:
		return {}
	var txt := body.get_string_from_utf8()
	var obj = JSON.parse_string(txt)
	return obj if typeof(obj) == TYPE_DICTIONARY else {}


# 2) Poll status (POST JSON: { subscription_key })
func _check_status(subscription_key: String) -> String:
	var http := HTTPRequest.new()
	add_child(http)

	var url := "%s/status" % RODIN_API_BASE
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % API_KEY,
		"Content-Type: application/json",
		"accept: application/json"
	])
	var payload := {"subscription_key": subscription_key}
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		remove_child(http); http.queue_free()
		return ""

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	if code != 200 and code != 201:
		return ""

	var data = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY or not data.has("jobs"):
		return ""
	var jobs = data["jobs"]
	if jobs is Array and jobs.size() > 0 and jobs[0].has("status"):
		return str(jobs[0]["status"])
	if jobs is Dictionary and jobs.has("status"):
		return str(jobs["status"])
	return ""


# 3) Get download list (POST JSON: { task_uuid })
func _download_results(task_uuid: String) -> Array:
	var http := HTTPRequest.new()
	add_child(http)

	var url := "%s/download" % RODIN_API_BASE
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % API_KEY,
		"Content-Type: application/json",
		"accept: application/json"
	])
	var payload := {"task_uuid": task_uuid}
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		remove_child(http); http.queue_free()
		return []

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	if code != 200 and code != 201:
		return []

	var data = JSON.parse_string(bytes.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		return []
	return data.get("list", [])


# 4) Download arbitrary URL → user:// path
func _download_file(url: String, save_path: String) -> bool:
	var http := HTTPRequest.new()
	add_child(http)

	var err := http.request(url) # GET
	if err != OK:
		remove_child(http); http.queue_free()
		return false

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	if code != 200:
		return false

	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true


# 5) Load GLB at runtime (no reimport pipeline)
func _load_glb_scene(glb_path: String) -> Node:
	var state := GLTFState.new()
	var doc := GLTFDocument.new()
	var err := doc.append_from_file(glb_path, state)
	if err != OK:
		push_warning("GLTF append_from_file failed: %s" % str(err))
		return null
	return doc.generate_scene(state)


# --- MULTIPART (fields only; no files) ---
# Returns { body: PackedByteArray, content_type: String }
func _encode_multipart(fields: Dictionary) -> Dictionary:
	var boundary := "----GodotBoundary_%d" % Time.get_ticks_msec()
	var body := PackedByteArray()

	for name in fields.keys():
		body += ("\r\n--%s\r\n" % boundary).to_utf8_buffer()
		body += ("Content-Disposition: form-data; name=\"%s\"\r\n\r\n" % name).to_utf8_buffer()
		body += str(fields[name]).to_utf8_buffer()

	body += ("\r\n--%s--\r\n" % boundary).to_utf8_buffer()
	return {
		"body": body,
		"content_type": "multipart/form-data; boundary=%s" % boundary
	}
