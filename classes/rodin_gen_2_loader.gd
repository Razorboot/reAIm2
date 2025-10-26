extends Node3D
class_name RodinGen2Loader

const RODIN_API_BASE := "https://api.hyper3d.com/api/v2"
const API_KEY := "1BfAVawDESvzWB0j8Qr88UYu74H2Y0S9W40ftmx0toTg04UZx3Uuo9O8QoYRTxRs" # rotate / do not commit
const POLL_INTERVAL_SEC := 3.0
const TRI_BUDGET := 10000

signal generation_started(task_uuid: String, subscription_key: String)
signal generation_progress(status: String)
signal generation_failed(message: String)
signal generation_completed(model_url: String, instanced_node: Node3D)

func generate_text_to_glb(prompt: String, quality: String = "low", mesh_mode: String = "Raw") -> Node3D:
	# 1) Submit
	var submit := await _submit_generation(prompt, quality, mesh_mode)
	if typeof(submit) != TYPE_DICTIONARY or not submit.has("uuid") or not submit.has("jobs"):
		emit_signal("generation_failed", "Submit failed or unexpected payload.")
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

	# 2) Poll until ALL jobs are Done (or any Failed)
	while true:
		var st := await _check_status_all(subscription_key)
		var state := str(st.get("state", ""))
		if state == "":
			emit_signal("generation_failed", "Status check failed.")
			return null

		var done := int(st.get("done", 0))
		var total := int(st.get("total", 0))
		emit_signal("generation_progress", "%s (%d/%d)" % [state, done, total])

		if state == "Done":
			break
		if state == "Failed":
			emit_signal("generation_failed", "Remote generation failed.")
			return null

		await get_tree().create_timer(POLL_INTERVAL_SEC).timeout

	# tiny grace period for file publication
	await get_tree().create_timer(1.0).timeout

	# 3) Download list (task_uuid only, with retries)
	var entries := await _download_results_with_retry(task_uuid)
	if entries.is_empty():
		emit_signal("generation_failed", "No downloadable files after publication window.")
		return null

	# 4) Pick direct GLB/GLTF (skip ZIP to stay in-memory)
	var asset_url := ""
	for e in entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var name := str(e.get("name", "")).to_lower()
		var url := str(e.get("url", ""))
		if name.ends_with(".glb") or url.ends_with(".glb") or name.ends_with(".gltf") or url.ends_with(".gltf"):
			asset_url = url
			break
	if asset_url == "":
		emit_signal("generation_failed", "No direct .glb/.gltf link in results.")
		return null

	# 5) Download bytes and parse GLB from memory (no saving)
	var bytes := await _download_bytes(asset_url)
	if bytes.is_empty():
		emit_signal("generation_failed", "Model download failed.")
		return null

	var scene = _load_glb_scene_from_bytes(bytes)
	if scene == null:
		emit_signal("generation_failed", "GLB/GLTF parse failed.")
		return null

	var inst = scene#.instantiate()
	var inst3d := inst as Node3D
	if inst3d == null:
		var wrap := Node3D.new()
		wrap.name = "RodinModel"
		wrap.add_child(inst)
		inst3d = wrap

	_auto_place(inst3d)

	var root_scene := get_tree().current_scene
	if root_scene == null:
		var rc := get_tree().root.get_child_count()
		if rc > 0:
			root_scene = get_tree().root.get_child(rc - 1)
		else:
			root_scene = self
	root_scene.add_child(inst3d)

	emit_signal("generation_completed", asset_url, inst3d)
	return inst3d


# ---------------- HTTP ----------------

func _submit_generation(prompt: String, quality: String, mesh_mode: String) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)

	var url := "%s/rodin" % RODIN_API_BASE
	var fields := {
		"tier": "Gen-2",
		"prompt": prompt,
		"geometry_file_format": "glb",
		"material": "PBR",
		"quality": quality,
		"quality_override": TRI_BUDGET,
		"mesh_mode": mesh_mode,
		#"max_triangles": TRI_BUDGET,
		#"triangle_budget": TRI_BUDGET,
		#"max_triangle_count": TRI_BUDGET
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

# Aggregated status: returns { state, done, total }
func _check_status_all(subscription_key: String) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)

	var url := "%s/status" % RODIN_API_BASE
	var headers := PackedStringArray([
		"Authorization: Bearer %s" % API_KEY,
		"Content-Type: application/json",
		"accept: application/json"
	])
	var payload := {"subscription_key": subscription_key}

	_print_http("STATUS ->", url, headers, JSON.stringify(payload))
	var err := http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		remove_child(http); http.queue_free()
		_print_http("STATUS ERR", str(err))
		return {"state": ""}

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	var text := bytes.get_string_from_utf8()
	_print_http("STATUS <-", "HTTP %d" % code, text)
	if code != 200 and code != 201:
		return {"state": ""}

	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or not data.has("jobs"):
		return {"state": ""}

	var total := 0
	var done := 0
	var failed := 0
	var jobs = data["jobs"]

	if jobs is Array:
		total = jobs.size()
		for j in jobs:
			if typeof(j) != TYPE_DICTIONARY: continue
			var s := str(j.get("status", ""))
			if s == "Done": done += 1
			elif s == "Failed": failed += 1
	elif jobs is Dictionary:
		total = 1
		var s := str(jobs.get("status", ""))
		if s == "Done": done = 1
		elif s == "Failed": failed = 1

	if failed > 0:
		return {"state": "Failed", "done": done, "total": total}
	if total > 0 and done >= total:
		return {"state": "Done", "done": done, "total": total}
	return {"state": "Generating", "done": done, "total": total}

# Retry: ONLY task_uuid; tries {"task_uuid":...} then {"uuid":...}; backoff
func _download_results_with_retry(task_uuid: String) -> Array:
	var delays := [0.5, 1.0, 2.0, 4.0]  # ~37.5s worst-case
	for i in range(delays.size() + 1):
		var entries := await _download_results_once(task_uuid, false)
		if entries.is_empty():
			entries = await _download_results_once(task_uuid, true)
		if not entries.is_empty():
			return entries
		if i == delays.size():
			break
		var d = delays[i]
		_print_http("DOWNLOAD retry", "empty list; sleeping", str(d) + "s")
		await get_tree().create_timer(d).timeout
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

	# Common / variant shapes
	if data.has("list") and data["list"] is Array:
		return data["list"]
	if data.has("files") and data["files"] is Array:
		return data["files"]
	if data.has("results") and data["results"] is Array:
		return data["results"]
	if data.has("artifacts") and data["artifacts"] is Array:
		return data["artifacts"]
	if data.has("assets") and data["assets"] is Array:
		return data["assets"]

	# Fallback: preview-only presence (not used for loading)
	if data.has("preview_url"):
		return [ {"name":"preview.webp", "url": str(data["preview_url"])} ]
	if data.has("preview") and typeof(data["preview"]) == TYPE_DICTIONARY and data["preview"].has("url"):
		return [ {"name":"preview.webp", "url": str(data["preview"]["url"])} ]

	return []

func _download_bytes(url: String) -> PackedByteArray:
	var http := HTTPRequest.new()
	add_child(http)

	_print_http("GET ->", url)
	var err := http.request(url)
	if err != OK:
		remove_child(http); http.queue_free()
		_print_http("GET ERR", str(err))
		return PackedByteArray()

	var res = await http.request_completed
	remove_child(http); http.queue_free()

	var code: int = res[1]
	var bytes: PackedByteArray = res[3]
	_print_http("GET <-", "HTTP %d" % code, "[%d bytes]" % bytes.size())
	if code != 200:
		return PackedByteArray()
	return bytes


# ---------------- GLB (in-memory) + placement ----------------

func _load_glb_scene_from_bytes(bytes: PackedByteArray):
	var state := GLTFState.new()
	var doc := GLTFDocument.new()

	# For .glb (no external deps) empty base_path is fine
	var err := doc.append_from_buffer(bytes, "", state, 0)
	if err != OK:
		push_warning("GLTF append_from_buffer failed: %s" % str(err))
		return null

	return doc.generate_scene(state)

func _auto_place(root: Node3D) -> void:
	var aabb := _compute_aabb(root)
	if aabb.size.length() > 0.0001:
		var center := aabb.position + aabb.size * 0.5
		root.translate(-center)
		var target := 1.5
		var longest = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		if longest > 0.0001:
			root.scale = Vector3.ONE * (target / longest)

func _compute_aabb(node: Node) -> AABB:
	var merged := AABB()
	var first := true
	if node is MeshInstance3D:
		var mesh = node.mesh
		if mesh:
			var m_aabb = mesh.get_aabb()
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


# ---------------- Logging ----------------

func _print_http(tag: String, a: Variant = "", b: Variant = "", c: Variant = "") -> void:
	var parts: Array[String] = []
	for v in [a, b, c]:
		if v == null:
			continue
		var s := ""
		if typeof(v) == TYPE_PACKED_STRING_ARRAY:
			s = ",".join(v)
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
