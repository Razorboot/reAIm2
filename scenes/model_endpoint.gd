extends Node

@export var rodin: Node3D

func _ready():
	rodin.generation_progress.connect(func(s): print("status:", s))
	rodin.generation_failed.connect(func(m): push_error(m))
	rodin.generation_completed.connect(func(path, node):
		print("Saved:", path)
	)

	# Example:
	await rodin.generate_text_to_glb("tiny red dragon statue, low-poly, game-ready")
