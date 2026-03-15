@tool
extends EditorScript

const INPUT_DIR := "res://assets/modular_terrain_collection"
const OUTPUT_DIR := "res://assets/grid_map/low_poly_t"

func _run():
	var dir := DirAccess.open(INPUT_DIR)
	if dir == null:
		push_error("Cannot open input directory")
		return

	DirAccess.make_dir_recursive_absolute(OUTPUT_DIR)

	dir.list_dir_begin()
	var file_name := dir.get_next()

	while file_name != "":
		if not dir.current_is_dir() and file_name.to_lower().ends_with(".obj"):
			convert_obj(file_name)
		file_name = dir.get_next()

	dir.list_dir_end()
	print("OBJ conversion finished!")

func convert_obj(file_name: String):
	var obj_path := INPUT_DIR + "/" + file_name
	var mesh := load(obj_path)

	if mesh == null or not mesh is Mesh:
		push_warning("Failed to load mesh: " + obj_path)
		return

	# Root node IS the MeshInstance3D
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = file_name.get_basename()
	mesh_instance.mesh = mesh

	# Pack scene
	var packed_scene := PackedScene.new()
	var result := packed_scene.pack(mesh_instance)

	if result != OK:
		push_error("Failed to pack scene for " + file_name)
		return

	var output_path := OUTPUT_DIR + "/" + file_name.get_basename() + ".tscn"
	var save_result := ResourceSaver.save(packed_scene, output_path)

	if save_result == OK:
		print("Saved:", output_path)
	else:
		push_error("Failed to save scene: " + output_path)
