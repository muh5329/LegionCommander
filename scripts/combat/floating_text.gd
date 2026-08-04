## Damage numbers, "block!", "+1 LEGIONARY" - the little bits of text that make
## a mass brawl readable. Built entirely in code so there is no scene to keep in
## sync, and pooled-lite via a hard cap so a 200-unit melee cannot flood the
## scene tree with labels.
class_name FloatingText
extends Label3D

const MAX_CONCURRENT := 90
const GROUP := "floating_text"

static func spawn(
	host: Node,
	world_pos: Vector3,
	body: String,
	color: Color = Color.WHITE,
	scale_mult: float = 1.0,
	lifetime: float = 0.85
) -> void:
	if host == null or not host.is_inside_tree():
		return
	var tree := host.get_tree()
	if tree == null:
		return
	if tree.get_nodes_in_group(GROUP).size() >= MAX_CONCURRENT:
		return

	var label := FloatingText.new()
	label.text = body
	label.modulate = color
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.75)
	label.outline_size = 10
	label.font_size = 56
	label.pixel_size = 0.0032 * scale_mult
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	label.fixed_size = false
	label.shaded = false
	label.add_to_group(GROUP)
	host.add_child(label)

	# Scatter so simultaneous hits don't stack into an unreadable blob.
	var jitter := Vector3(randf_range(-0.35, 0.35), 0.0, randf_range(-0.35, 0.35))
	label.global_position = world_pos + jitter

	var rise := randf_range(0.9, 1.35)
	var tween := label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "global_position:y", label.global_position.y + rise, lifetime) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, lifetime) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)


## Bigger, slower, centred - for "CAMP CAPTURED" style callouts.
static func announce(host: Node, world_pos: Vector3, body: String, color: Color = Color.WHITE) -> void:
	spawn(host, world_pos, body, color, 2.4, 1.8)
