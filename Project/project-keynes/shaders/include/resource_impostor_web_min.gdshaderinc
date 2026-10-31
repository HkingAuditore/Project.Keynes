// resource_impostor_web_min.gdshaderinc
// ─────────────────────────────────────────────────────────────────────────
// [web-resource-min] resource_impostor.gdshader 的 web / GLES3 编译期精简变体。
//
// 唯一外部开关：resource_impostor.gdshader 里的 `#ifdef PK_WEB_RESOURCE_MIN`
// （由 ResourceVisualLayer.shader_variant_prefix() 在 Compatibility 后端 prepend，
//   菜单期 WebShaderWarmup 引用的前缀由同一个函数给出，两处逐字相同）。
//
// ── 为什么可以整段删掉 terrain_horizon（依据是代码事实，逐条可查）─────────
//   1. web 上 `DCFeatureFlags.terrain_horizon_gpu_bake_active()` 恒 false
//      （feature_flags.gd:411-416 → `not (mobile or is_web())`；main.gd:2351-2352
//       在 web 上还会显式 set_terrain_horizon_gpu_bake(false)）。
//   2. 因此 map_baker 走 mobile/web 兜底分支，直接 `world.terrain_horizon_tex = null`
//      （map_baker.gd:1166-1167）；web 禁止落 CPU marching。
//   3. ResourceVisualLayer._bind_terrain_textures() 于是把
//      `terrain_horizon_tex_bound` 推成 false
//      （resource_visual_layer.gd 里 `set_shader_parameter("terrain_horizon_tex_bound", …)`）。
//   4. `sample_terrain_horizon()` 在 `!terrain_horizon_tex_bound` 时立即返回中性值
//      （terrain_horizon.gdshaderinc:134-136）——包括 `gi_lut_bound` 那段
//      4 tap × 8 方向 `gi_horizon_lut[nibbles[d]]` 动态下标循环，一次都不会执行。
//   ⇒ 运行期恒为 direct_visibility=1 / sky_visibility=1 / bent_normal=(0,0,1)，
//     与本变体写死的中性值逐位相同，**画面零差异**。
//   5. 同一组中性值也是桌面 LOW 档的返回值（terrain_horizon.gdshaderinc:273-280），
//     所以本变体即使被 MID/HIGH 档选中，结果也与 LOW 档一致（见下面的档位校验）。
//
// ── 另外两个开关同样只是把「驱动本来就要丢掉的死代码」提前到预处理阶段丢掉 ──
//   · PK_VF_NOISE_ONLY：vegetation_forms.gdshaderinc 只保留 vf_hash12 / vf_hash22 /
//     vf_vnoise。resource 侧（resource_forms / resource_topdown_forms /
//     resource_decal_forms）从不用那 17 个近景 vf_* form，全部无用。
//   · resource_solid_forms.gdshaderinc 的 rs3_* 语料：本 shader 是它唯一的
//     include 方，而 rs3_* 在整个工程里被引用 0 次（`rt_resource()` 只用
//     rt_*/rs_geology），所以 shader 里用 #ifndef 整段跳过。
//   两者都不改变任何一个像素，只是让编译器不必解析 85 KB 的死代码。
// ─────────────────────────────────────────────────────────────────────────
#ifndef PK_RESOURCE_IMPOSTOR_WEB_MIN_INC
#define PK_RESOURCE_IMPOSTOR_WEB_MIN_INC

// 档位宏必须与本变体同时出现。缺档位宏时旧行为是"静默地编一份桌面级巨型变体"
// （缺 MOBILE_QUALITY_* → terrain_horizon_evaluate() 不退化 → gi 动态下标循环留着），
// 那正是首次编译 27 424 ms 的根源之一。这里改成编译期硬失败，宁可白屏也不静默变慢。
#if !defined(MOBILE_QUALITY_LOW) && !defined(MOBILE_QUALITY_MID) && !defined(MOBILE_QUALITY_HIGH)
#error "PK_WEB_RESOURCE_MIN requires MOBILE_QUALITY_LOW / _MID / _HIGH (ResourceVisualLayer.shader_variant_prefix)"
#endif

// vegetation_forms.gdshaderinc：只留噪声/哈希叶子，砍掉全部近景 form 语料。
#define PK_VF_NOISE_ONLY

// terrain_horizon.gdshaderinc 的 terrain_horizon_apply_normal()，逐字照抄。
// rv_ambient() 用它把天光可见度折到几何法线上：本变体传入的
// (sky_visibility, bent_normal) 恒为 (1.0, (0,0,1))，与桌面实现同样的入参、同样的公式。
float terrain_horizon_apply_normal(float sky_visibility, vec3 geometric_normal, vec3 bent_normal) {
	if (gi_normal_floor >= 1.0) {
		return clamp(sky_visibility, 0.0, 1.0);
	}
	float align = clamp(dot(normalize(geometric_normal), normalize(bent_normal)), 0.0, 1.0);
	return clamp(sky_visibility * mix(gi_normal_floor, 1.0, align), 0.0, 1.0);
}

#endif // PK_RESOURCE_IMPOSTOR_WEB_MIN_INC
