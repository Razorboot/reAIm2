extends Node

@export var rodin: RodinGen2Loader   # <— typed

func _ready() -> void:
	rodin.generation_progress.connect(func(s): print("status:", s))
	rodin.generation_failed.connect(func(m): push_error(m))
	rodin.generation_completed.connect(func(path, node):
		print("Saved:", path)
	)

	var inst := await rodin.generate_text_to_glb("tiny red dragon statue, low-poly, game-ready")
	if inst:
		print("Spawned:", inst.name, " at ", inst.global_transform.origin)
