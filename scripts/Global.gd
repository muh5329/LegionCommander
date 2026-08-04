## Tiny cross-scene registry. Autoloaded as `Global`.
extends Node

## The currently loaded level's root scene (set by main_scene.gd).
var main_scene: Node = null

## The active commander. Set by Character._ready(), read by recruit pods and UI.
var player: Node3D = null
