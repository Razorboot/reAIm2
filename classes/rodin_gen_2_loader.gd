extends Node3D
class_name RodinGen2Loader

const RODIN_API_BASE := "https://api.hyper3d.com/api/v2"
const API_KEY := "6U224eE8QxWEQtSsSbGLb6TWvzjjMKAf4D7nFlozQPrUyfW7cgiKkKQGdQNzOMoN" # rotate / do not commit
const POLL_INTERVAL_SEC := 3.0
const TRI_BUDGET := 2000        # target triangle count

signal generation_started(task_uuid: String, subscription_key: String)
signal generation_progress(status: String)
signal generation_failed(message: String)
signal generation_completed(model_path: String, instanced_node: Node3D)

# Public: Returns the instanced model Node3D (or null).
func generate_text_to_glb(prompt: String, quality: String = "low", mesh_mode: String = "Quad") -> Node3D:
	# 1) Submit
	var submit := await _submit_generation(prompt, quality, mesh_mode)
	if typeof(submit) != TYPE_DICTIONARY:
		emit_signal("generation_failed", "Submit failed (no JSON).")
		return null
	if not submit.has("uuid") or not submit.has("jobs"):
		emit_signal("generation_failed", "Submit returned unexpected payload.")
		return null

	var task_uuid := str(submit["uuid"])

	var subscription_key := ""
	if submit["jobs"] is Dictionary and submit["jobs"].has("subscription_key"):
		subscription_key = str(submit["jobs"]["subscription_key"])
	elif submit["jobs"] is Array and submit["jobs"].size() > 0 and submit["jobs"][0].has("subscription_key"):
		subscription_key = str(submit["jobs"][0]["subscription_key"])
	else:
		emit_signal("generation_failed", "Missing subscription_key in submit.")
		return null

	emit_signal("generation_started", task_uuid, subscription_key)

	# 2) Poll
	while true:
		var status := await _check_status(subscription_key)
		if status == "":
			emit_signal("generation_failed", "Status check failed.")
			return null
		emit_signal("generation_progress", status)
		if status == "Done":
			break
		if status == "Failed":
			emit_signal("generation_failed", "Remote generation failed.")
			return null
		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout

	# Give Rodin a moment to publish files before first /download
	await get_tree().create_timer(1.0).timeout

	# 3) Download list — ONLY task_uuid with robust retry (avoid NO_SUCH_TASK)
	var entries := await _download_results_with_retry(task_uuid)
	if entries.is_empty():
		emit_signal("generation_failed", "No downloadable files.")
		return null

	# 4) Choose asset URL
	var asset_url := ""
	var asset_type := ""  # "glb" | "gltf" | "zip"

	for e in entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var fname := str(e.get("name", "")).to_lower()
		var url := str(e.get("url", ""))
		if fname.ends_with(".glb") or url.ends_with(".glb"):
			asset_url = url
			asset_type = "glb"
			break
		if fname.ends_with(".gltf") or url.ends_with(".gltf"):
			asset_url = url
			asset_type = "gltf"
			break

	if asset_url == "":
		for e in entries:
			if typeof(e) != TYPE_DICTIONARY:
				continue
			var fname2 := str(e.get("name", "")).to_lower()
			var url2 := str(e.get("url", ""))
			if fname2.ends_with(".zip") or url2.ends_with(".zip"):
				asset_url = url2
				asset_type = "zip"
				break

	if asset_url == "":
		emit_signal("generation_failed", "No .glb/.gltf/.zip in download list.")
		return null

	# 5) Save to user_models/<uuid>
	# For exported games, prefer: var base_dir := "user://user_models"
	var base_dir := "res://user_models"
	DirAccess.make_dir_recursive_absolute(base_dir)
	var job_dir := "%s/%s" % [base_dir, task_uuid]
	DirAccess.make_dir_recursive_absolute(job_dir)

	var model_path := ""
	if asset_type == "zip":
		var zip_path := "%s/result.zip" % job_dir
		var ok_zip := await _download_file(asset_url, zip_path)
		if not ok_zip:
			emit_signal("generation_failed", "ZIP download failed.")
			return null
		model_path = _extract_first_3d_from_zip(zip_path, job_dir)
		if model_path == "":
			emit_signal("generation_failed", "ZIP contained no .glb/.gltf.")
			return null
	else:
		model_path = "%s/model.%s" % [job_dir, asset_type]
		var ok := await _download_file(asset_url, model_path)
		if not ok:
			emit_signal("generation_failed", "Model download failed.")
			return null

	# 6) Load & instance under the **root** scene
	var scene: PackedScene = _load_glb_scene(model_path)
	if scene == null:
		emit_signal("generation_failed", "GLB/GLTF parse failed.")
		return null

	var inst := scene.instantiate()
	var inst3d := inst as Node3D
	if inst3d == null:
		var wrap := Node3D.new()
		wrap.name = "RodinModel"
		wrap.add_child(inst)
		inst3d = wrap

	_auto_place(inst3d)

	var root_scene := get_tree().current_scene
	if root_scene == null:
		# fallback to last child of root if current_scene is null
		var rc := get_tree().root.get_child_count()
		if rc > 0:
			root_scene = get_tree().root.get_child(rc - 1)
		else:
			root_scene = self
	root_scene.add_child(inst3d)

	emit_signal("generation_completed", model_path, inst3d)
	return inst3d


# ---------------- HTTP + LOGGING ----------------

func _submit_generation(prompt: String, quality: String, mesh_mode: String) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)

	var url := "%s/rodin" % RODIN_API_BASE
	# preview_render=true to ensure a preview.webp appears
	var fields := {
		"tier": "Gen-2",
		"prompt": prompt,
		"geometry_file_format": "glb",
		"material": "PBR",
		"quality": quality,          # "low" for speed
		"mesh_mode": mesh_mode,      # "Quad" for nicer topology
		"max_triangles": TRI_BUDGET,
		"triangle_budget": TRI_BUDGET,
		"max_triangle_count": TRI_BUDGET,
		"preview_render": "true"
	}
	var mp := _encode_multipart(fields)
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % API_KEY,
		"Content-Type: %s" % mp.content_type,
		"accept: application/json"
	])

	_print_http("SUBMIT ->", url, headers, "[multipart %d bytes]" % mp.body.size())
	var err := http.request_raw(url, headers, HTTPClient.METHOD_POST, mp.body)
	if err != OK:
		remove_child(http); http.queue_free()
		_print_http("SUBMIT ERR", str(err))
		return {}

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var body: PackedByteArray = res[3]
	var text := body.get_string_from_utf8()
	_print_http("SUBMIT <-", "HTTP %d" % code, text)
	if code != 200 and code != 201:
		return {}
	return JSON.parse_string(text)

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
	var body := JSON.stringify(payload)

	_print_http("STATUS ->", url, headers, body)
	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		remove_child(http); http.queue_free()
		_print_http("STATUS ERR", str(err))
		return ""

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	var text := bytes.get_string_from_utf8()
	_print_http("STATUS <-", "HTTP %d" % code, text)

	if code != 200 and code != 201:
		return ""

	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or not data.has("jobs"):
		return ""
	var jobs = data["jobs"]
	if jobs is Array and jobs.size() > 0 and jobs[0].has("status"):
		return str(jobs[0]["status"])
	if jobs is Dictionary and jobs.has("status"):
		return str(jobs["status"])
	return ""

# Retry: ONLY task_uuid, longer backoff, tries {"task_uuid":...} and {"uuid":...}
func _download_results_with_retry(task_uuid: String) -> Array:
	var attempts := [0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0]  # seconds
	for i in range(attempts.size() + 1):
		var entries := await _download_results_once(task_uuid, false)
		if entries.is_empty():
			entries = await _download_results_once(task_uuid, true)
		if not entries.is_empty():
			return entries

		if i == attempts.size():
			break
		var delay = attempts[i]
		_print_http("DOWNLOAD retry", "empty list; sleeping", str(delay) + "s")
		await get_tree().create_timer(delay).timeout
	return []

func _download_results_once(task_uuid: String, use_alt_key: bool) -> Array:
	var http := HTTPRequest.new()
	add_child(http)

	var url := "%s/download" % RODIN_API_BASE
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % API_KEY,
		"Content-Type: application/json",
		"accept: application/json"
	])

	var payload := {}
	if use_alt_key:
		payload = {"uuid": task_uuid}
	else:
		payload = {"task_uuid": task_uuid}
	var body := JSON.stringify(payload)

	var tag := "DOWNLOAD(uuid)"
	if not use_alt_key:
		tag = "DOWNLOAD(task_uuid)"

	_print_http(tag + " ->", url, headers, body)
	var err := http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		remove_child(http); http.queue_free()
		_print_http("DOWNLOAD ERR", str(err))
		return []

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	var text := bytes.get_string_from_utf8()
	_print_http(tag + " <-", "HTTP %d" % code, text)

	if code != 200 and code != 201:
		return []

	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return []

	# Accept several shapes
	if data.has("list") and data["list"] is Array:
		return data["list"]
	if data.has("files") and data["files"] is Array:
		return data["files"]
	if data.has("results") and data["results"] is Array:
		return data["results"]

	# Fallback: some tenants expose only a preview URL
	if data.has("preview_url"):
		return [ {"name":"preview.webp", "url": str(data["preview_url"])} ]
	if data.has("preview") and typeof(data["preview"]) == TYPE_DICTIONARY and data["preview"].has("url"):
		return [ {"name":"preview.webp", "url": str(data["preview"]["url"])} ]

	return []

func _download_file(url: String, save_path: String) -> bool:
	var http := HTTPRequest.new()
	add_child(http)

	_print_http("GET ->", url)
	var err := http.request(url)
	if err != OK:
		remove_child(http); http.queue_free()
		_print_http("GET ERR", str(err))
		return false

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	_print_http("GET <-", "HTTP %d" % code, "[%d bytes]" % bytes.size())

	if code != 200:
		return false

	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(bytes)
	f.close()
	return true


# ---------------- GLB/ZIP + Placement ----------------

func _load_glb_scene(path: String):
	var state := GLTFState.new()
	var doc := GLTFDocument.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_warning("GLTF append_from_file failed: %s" % str(err))
		return null
	return doc.generate_scene(state)

func _extract_first_3d_from_zip(zip_path: String, out_dir: String) -> String:
	var zr := ZIPReader.new()
	var ok := zr.open(zip_path)
	if ok != OK:
		push_warning("ZIP open failed.")
		return ""
	var files := zr.get_files()
	var chosen := ""
	for p in files:
		var lp := p.to_lower()
		if lp.ends_with(".glb") or lp.ends_with(".gltf"):
			chosen = p
			break
	if chosen == "":
		zr.close()
		return ""
	var bytes := zr.read_file(chosen)
	zr.close()

	var ext := chosen.get_extension().to_lower()
	var out_path := "%s/extracted.%s" % [out_dir, ext]
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_buffer(bytes)
	f.close()
	return out_path

func _auto_place(root: Node3D) -> void:
	var aabb := _compute_aabb(root)
	if aabb.size.length() > 0.0001:
		var center := aabb.position + aabb.size * 0.5
		root.translate(-center)
		var target := 1.5
		var longest: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		if longest > 0.0001:
			root.scale = Vector3.ONE * (target / longest)

func _compute_aabb(node: Node) -> AABB:
	var merged := AABB()
	var first := true
	if node is MeshInstance3D:
		var mesh: Mesh = node.mesh
		if mesh:
			var m_aabb := mesh.get_aabb()
			m_aabb = m_aabb * (node as Node3D).global_transform
			merged = m_aabb
			first = false
	for c in node.get_children():
		var a := _compute_aabb(c)
		if a.size != Vector3.ZERO:
			if first:
				merged = a
				first = false
			else:
				merged = merged.merge(a)
	return merged


# ---------------- Multipart (fields only) ----------------

func _encode_multipart(fields: Dictionary) -> Dictionary:
	var boundary := "----GodotBoundary_%d" % Time.get_ticks_msec()
	var body := PackedByteArray()

	for key in fields.keys():
		body += ("\r\n--%s\r\n" % boundary).to_utf8_buffer()
		body += ("Content-Disposition: form-data; name=\"%s\"\r\n\r\n" % str(key)).to_utf8_buffer()
		body += str(fields[key]).to_utf8_buffer()

	body += ("\r\n--%s--\r\n" % boundary).to_utf8_buffer()

	return {
		"body": body,
		"content_type": "multipart/form-data; boundary=%s" % boundary
	}


# ---------------- Logging helper ----------------

func _print_http(tag: String, a: Variant = "", b: Variant = "", c: Variant = "") -> void:
	var parts: Array[String] = []
	for v in [a, b, c]:
		if v == null:
			continue
		var s := ""
		if typeof(v) == TYPE_PACKED_STRING_ARRAY:
			s = ",".join(v)                # headers
		elif typeof(v) == TYPE_DICTIONARY:
			s = JSON.stringify(v)
		else:
			s = str(v)
		if s != "":
			parts.append(s)
	var line := "[color=gray]" + tag + "[/color]"
	if parts.size() > 0:
		line += " " + " | ".join(parts)
	print_rich(line)
