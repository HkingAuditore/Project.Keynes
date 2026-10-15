extends SceneTree

## Offline asset build. The game never runs these image resizes or pixel loops.
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var directory := "res://assets/textures/loading_prebaked_v1"
	DirAccess.make_dir_recursive_absolute(directory)
	var noise := MapBaker._build_noise_tex(MapBaker.NOISE_TEX_SIZE, MapBaker.NOISE_TEX_SEED).get_image()
	assert(noise != null and not noise.is_empty())
	assert(ResourceSaver.save(noise,directory+"/noise_rgba.res") == OK)
	for target in [512,1024]:
		for i in MapBaker.TERRAIN_MATERIAL_TEXTURE_PATHS.size():
			var image := Image.load_from_file(MapBaker.TERRAIN_MATERIAL_TEXTURE_PATHS[i])
			image.convert(Image.FORMAT_RGBA8)
			if image.get_size() != Vector2i(target,target):
				image.resize(target,target,Image.INTERPOLATE_LANCZOS)
			image.generate_mipmaps()
			assert(ResourceSaver.save(image,"%s/material_%d_%d.res" % [directory,target,i]) == OK)
	print("[prebake-loading] exact legacy noise and material mipmaps saved")
	quit()
