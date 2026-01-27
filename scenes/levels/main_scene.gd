extends Control

# OnReady Vars
@onready var menu: Control = $Menu
@onready var main_3d: Node3D = $Main3d
@onready var loading_layer: CanvasLayer = $Loading
@onready var progress_bar: ProgressBar = $Loading/Control/ProgressBar
@onready var hud: Control = $HUD


# public vars
var level_instance : Node3D
var level_path: String
var loading := false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	#Global.main_scene = self
	pass # Replace with function body.

func _process(_delta: float) -> void:
	if not loading:
		return

	var progress := []
	var status := ResourceLoader.load_threaded_get_status(level_path, progress)

	if progress.size() > 0:
		progress_bar.value = progress[0] * 100.0

	if status == ResourceLoader.THREAD_LOAD_LOADED:
		var scene: PackedScene = ResourceLoader.load_threaded_get(level_path)
		level_instance = scene.instantiate()
		main_3d.add_child(level_instance)

		loading_layer.visible = false
		loading = false

func load_main_scene() -> void:
	unload_level()

	# Show menu  again
	menu.visible = true
	

	# Hide loading screen just in case
	loading_layer.visible = false
	loading = false
		
	# Hide HUD	
	hud.visible = false

# Public Func
func unload_level() :
	if is_instance_valid(level_instance):
		level_instance.queue_free()
	level_instance = null
	
func load_level(level_name: String) -> void:
	unload_level()

	level_path = "res://scenes/levels/%s/root.tscn" % level_name
	
	# Setup the UI
	menu.visible = false
	hud.visible = true

	loading_layer.visible = true
	progress_bar.value = 0
	loading = true

	ResourceLoader.load_threaded_request(level_path)




func _on_start_button_pressed() -> void:
	load_level("Level1")
	pass # Replace with function body.


func _on_exit_button_pressed() -> void:
	get_tree().quit()
	pass # Replace with function body.


func _on_menu_button_pressed() -> void:
	load_main_scene()
	pass # Replace with function body.
