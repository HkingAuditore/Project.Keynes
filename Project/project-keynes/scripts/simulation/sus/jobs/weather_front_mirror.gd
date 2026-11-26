extends RefCounted

## Copies weather fronts to the DataCore view.


static func sync_fronts_to_world(owner: WeatherRefreshJob, active_fronts: Array) -> void:
	if not owner.data_core_ready():
		return
	if owner._front_pool_base < 0:
		return
	var n: int = mini(active_fronts.size(), owner.MAX_FRONTS_DC)

	# C-01.1：dirty 指纹计算（轻量，不进入 PackedArray 写）。
	# 指纹 = n + 前 n 个 front 的 instance_id 异或 + 内容加权和。
	# is_first_object_typed 同时决定后续走哪条 path。
	var id_xor: int = 0
	var content_hash: float = 0.0
	var is_first_object_typed: bool = n > 0 and active_fronts[0] is WeatherFront
	if is_first_object_typed:
		for i in range(n):
			var f: WeatherFront = active_fronts[i]
			if f == null:
				continue
			id_xor ^= f.get_instance_id()
			content_hash += f.center.x + f.velocity.x * 7.31 + f.intensity * 19.7 + float(f.age_days)
	else:
		for i in range(n):
			var f_any = active_fronts[i]
			if f_any == null:
				continue
			if f_any is Object:
				id_xor ^= f_any.get_instance_id()
	if n == owner._last_sync_n and id_xor == owner._last_sync_id_xor \
			and absf(content_hash - owner._last_sync_content_hash) < 1e-4:
		return  # 指纹完全一致 → 跳过本次全量同步
	owner._last_sync_n = n
	owner._last_sync_id_xor = id_xor
	owner._last_sync_content_hash = content_hash

	# C-01.2：类型分发，走特化的快/慢路径
	if is_first_object_typed:
		owner._sync_fronts_object_path(active_fronts, n)
	else:
		owner._sync_fronts_dict_path(active_fronts, n)


## C-01.2 强类型快路径：active_fronts 元素全为 WeatherFront 实例（≥99% 情形）。
## 循环内零反射，全部走直接成员访问 + PackedArray index 写入。
##
## I2.A.5：ECB pool-aware。不再用 base + i 顺序占段，而是每个 front 持有
## 自己的 world_idx（由 ECB 从 pool free-list 分配）。上轮在 _synced_fronts
## 但本轮不在的 → destroy_in_pool；本轮新出现且 world_idx==-1 的 → create_in_pool。
## flush 在函数尾调一次，把所有 archetype 变更 + free-list 互访一批处理完。
##
## I3.A.2：写入路径全部改走 _world.write_*（DCWorld / DCWorldExt 双兼容）。
## DCWorldExt 下 view_* 是只读快照（拷贝），原本 `view_*(c)[i] = v` 会静默
## 失效；统一为 write_* 后双路径行为一致。
static func _sync_fronts_object_path(owner: WeatherRefreshJob, active_fronts: Array, n: int) -> void:
	var arch_id: int = owner._arch_weather_front
	var ecb: DCCommandBuffer = owner._world.command_buffer()

	# 1) 差分：计算本轮 active 集合（用 instance_id 进 Dictionary，O(n)）
	var active_set: Dictionary = {}
	for i in range(n):
		var f: WeatherFront = active_fronts[i]
		if f != null:
			active_set[f.get_instance_id()] = f

	# 2) destroy：上轮 _synced_fronts 中本轮不在的 → 走 ECB 归还 idx
	for old_f in owner._synced_fronts:
		if old_f == null:
			continue
		if active_set.has(old_f.get_instance_id()):
			continue
		if old_f.world_idx >= 0:
			ecb.destroy_in_pool(owner._pool_id_fronts, old_f.world_idx)
			old_f.world_idx = -1

	# 3) create + 写入：本轮所有 front，未分配 idx 的先走 ECB 拿 idx
	for i in range(n):
		var f2: WeatherFront = active_fronts[i]
		if f2 == null:
			continue
		if f2.world_idx < 0:
			var new_idx: int = ecb.create_in_pool(owner._pool_id_fronts, arch_id)
			if new_idx < 0:
				# free-list 耗尽（front 池满）——跳过该 front 的写入。
				# weather_system 本来有 MAX_FRONTS 守卫，进到这里代表与之不同步。
				continue
			f2.world_idx = new_idx
		var slot_idx: int = f2.world_idx
		owner._world.write_f32(owner._comp_front_pos_x, slot_idx, f2.center.x)
		owner._world.write_f32(owner._comp_front_pos_y, slot_idx, f2.center.y)
		owner._world.write_f32(owner._comp_front_vel_x, slot_idx, f2.velocity.x)
		owner._world.write_f32(owner._comp_front_vel_y, slot_idx, f2.velocity.y)
		owner._world.write_u8(owner._comp_front_kind, slot_idx, f2.type & 0xFF)
		owner._world.write_f32(owner._comp_front_strength, slot_idx, f2.intensity)
		owner._world.write_f32(owner._comp_front_radius, slot_idx, f2.radius)
		owner._world.write_i32(owner._comp_front_age, slot_idx, f2.age_days)

	# 4) flush ECB（archetype 批处理 + free-list 同步）。计时供调试。
	var t_us0: int = Time.get_ticks_usec()
	owner._world.flush_command_buffer()
	owner._last_flush_ms = (Time.get_ticks_usec() - t_us0) / 1000.0

	# 5) 更新跟踪集（浅拷贝 Array 即可，仅记录引用）
	owner._synced_fronts.clear()
	owner._synced_fronts.append_array(active_fronts.slice(0, n))


## C-01.2 慢路径：兼容 Dictionary / 历史 alias 字段名（debug / mock 数据）。
## 仅在首元素不是 WeatherFront 实例时才进入；保留原有反射兼容性，不优化。
##
## I2.A.5：mock 路径不走 ECB pool-aware（Dict 没有 world_idx 字段），继续使用
## base+i 顺序占段与直接 assign_archetype。生产路径若误入此分支会被 push_warning 提醒。
static func _sync_fronts_dict_path(owner: WeatherRefreshJob, active_fronts: Array, n: int) -> void:
	# DOTS-Total-CPP（任务 7）：mock 路径警告限频（生产路径误入 → 仅第一次提醒）
	if not owner._sync_fronts_dict_warned:
		push_warning("[weather_refresh_job] _sync_fronts_dict_path: mock data path; ECB pool-aware path is bypassed. n=%d (subsequent warnings suppressed)" % n)
		owner._sync_fronts_dict_warned = true
	for i in range(n):
		var f = active_fronts[i]
		if f == null:
			continue
		var slot_idx: int = owner._front_pool_base + i
		var is_dict: bool = f is Dictionary
		var c_val: Vector2 = Vector2.ZERO
		if is_dict:
			if f.has("center"):
				c_val = f["center"]
			elif f.has("position"):
				c_val = f["position"]
		else:
			if "center" in f:
				c_val = f.center
			elif "position" in f:
				c_val = f.position
		owner._world.write_f32(owner._comp_front_pos_x, slot_idx, c_val.x)
		owner._world.write_f32(owner._comp_front_pos_y, slot_idx, c_val.y)
		var v_val: Vector2 = Vector2.ZERO
		if is_dict:
			if f.has("velocity"):
				v_val = f["velocity"]
			elif f.has("vel"):
				v_val = f["vel"]
		else:
			if "velocity" in f:
				v_val = f.velocity
			elif "vel" in f:
				v_val = f.vel
		owner._world.write_f32(owner._comp_front_vel_x, slot_idx, v_val.x)
		owner._world.write_f32(owner._comp_front_vel_y, slot_idx, v_val.y)
		var k_int: int = 0
		if is_dict:
			if f.has("type"):
				k_int = int(f["type"]) & 0xFF
			elif f.has("weather_type"):
				k_int = int(f["weather_type"]) & 0xFF
		else:
			if "type" in f:
				k_int = int(f.type) & 0xFF
			elif "weather_type" in f:
				k_int = int(f.weather_type) & 0xFF
		owner._world.write_u8(owner._comp_front_kind, slot_idx, k_int)
		var s_val: float = 0.0
		if is_dict:
			if f.has("intensity"):
				s_val = float(f["intensity"])
			elif f.has("strength"):
				s_val = float(f["strength"])
		else:
			if "intensity" in f:
				s_val = float(f.intensity)
			elif "strength" in f:
				s_val = float(f.strength)
		owner._world.write_f32(owner._comp_front_strength, slot_idx, s_val)
		var r_val: float = 0.0
		if is_dict:
			if f.has("radius"):
				r_val = float(f["radius"])
		else:
			if "radius" in f:
				r_val = float(f.radius)
		owner._world.write_f32(owner._comp_front_radius, slot_idx, r_val)
		var age_val: int = 0
		if is_dict:
			if f.has("age_days"):
				age_val = int(f["age_days"])
			elif f.has("age"):
				age_val = int(f["age"])
		else:
			if "age_days" in f:
				age_val = int(f.age_days)
			elif "age" in f:
				age_val = int(f.age)
		owner._world.write_i32(owner._comp_front_age, slot_idx, age_val)
		owner._world.assign_archetype(slot_idx, owner._arch_weather_front)
	var arch_none: int = owner._world.archetype_none()
	for j in range(n, owner.MAX_FRONTS_DC):
		owner._world.assign_archetype(owner._front_pool_base + j, arch_none)
