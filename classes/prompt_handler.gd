extends Node


## Import


## Init
func _ready():
	# Setup mic
	pass
	
# 1) Send prompt to your backend (or directly to API) and poll until a GLB URL is ready
# 2) Download GLB to user:// and load it with GLTFDocument

func _download_and_load_glb(glb_url: String) -> void:
	var http := HTTPRequest.new()
	add_child(http)
	http.request(glb_url)  # GET the .glb
	await http.request_completed
	var code = http.get_response_code()
	if code != 200: return

	var bytes: PackedByteArray = http.get_body()
	var glb_path := "user://generated.glb"
	var f := FileAccess.open(glb_path, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()

	var state := GLTFState.new()
	var doc := GLTFDocument.new()
	var err := doc.append_from_file(glb_path, state)
	if err != OK: return

	# Get first mesh/scene and instance it
	var scene := doc.generate_scene(state)  # builds a PackedScene
	var inst = scene.instantiate()
	add_child(inst)
	
	print("Genned model is: ")
	print(inst.get_class())
