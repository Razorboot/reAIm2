extends Node

@export var rodin: RodinGen2Loader   # <— typed

func _ready() -> void:
	pass
	#var start_time_msec = Time.get_ticks_msec()
	#var timeThing = 0
	#
	#rodin.generation_progress.connect(func(s): print("status:", s))
	#rodin.generation_failed.connect(func(m): push_error(m))
	#rodin.generation_completed.connect(func(path, node: RigidBody3D):
		#node.global_position = Vector3(5.0, 3.0, 5.0)
		#timeThing += 1
		#if timeThing == 2:
			#var elapsed_time_sec = float(Time.get_ticks_msec() - start_time_msec) / 1000.0
			#print("TOOK ABOUT " + str(timeThing) + " seconds")
	#)
#
	#var inst := await rodin.generate_text_to_glb("simple square")
