extends SceneTree

# ─────────────────────────────────────────────────────────────────────────────
# world_fingerprint_test.gd — 「世界指纹」门禁（跟进计划 §2.1，S1）
#
# 做的事：把世界生成结果压成「5 条数组的精确 hash + 一组分布统计」，和提交在仓库里的
# 基线 JSON 比对。世界悄悄变了（改算法 / 改 profile 缺省 / 改 C++ 常数）→ FAIL，
# 并指名**哪个数组变了、哪个统计差多少**；有意改世界的 PR 必须同一次提交里重写基线。
#
# 规格：docs/plans/terrain-followup-verification-plan.md §2.1
# 实现：tests/world/world_fingerprint.gd（可复用 static 工具，三个 golden 测试也用它）
#
# 跑法（root 统一执行；本文件**不**自己启动 Godot / scons）：
#   # 门禁（缺省 assert 模式）：4×60×40（20260718..20260721）+ 2×200×150（20260718..20260719）
#   godot --headless -s res://tests/world/world_fingerprint_test.gd
#   # 重写基线（有意改世界时；生成完把 tests/world/baselines/world_fingerprint.json 一起提交）
#   $env:FINGERPRINT_WRITE="1"; godot --headless -s res://tests/world/world_fingerprint_test.gd
#   # 其他编译配置 / 其他平台（浮点 hash 不可比）：只比分布统计
#   $env:FINGERPRINT_HASH="0"; godot --headless -s res://tests/world/world_fingerprint_test.gd
#   # 容差微调（缺省 5%）
#   $env:FINGERPRINT_STAT_TOL="0.08"
#
# 退出码：
#   · 0：全部种子 hash + stats 都在基线上；或 SKIP（未假装通过，但也无世界漂移证据）
#   · 1：有种子漂移 / 生成失败 / 基线写入失败
#
# SKIP（打印 `SKIP reason=...`，退出码 0，**不假装通过**）：
#   · 基线文件缺失或解析失败（先跑 FINGERPRINT_WRITE=1）
#   · 基线里没有某个种子的行（种子集被改过而没重写基线）
#   · DCWorldExt 类不存在或实例化失败（GDExtension 没编译 / 没加载）
# 生成失败（rc != 0 或 fallback）**不是 SKIP**：合法输入不该失败 ⇒ 计 FAIL。
#
# 口径提醒（计划 §10 K1）：精确 hash 对 float32 的原始字节做 FNV-1a 64，**只在同平台、
# 同编译配置下可比**。换平台/换构建配置时用 FINGERPRINT_HASH=0 只比分布统计。
# ─────────────────────────────────────────────────────────────────────────────

const WORLD_FINGERPRINT := preload("res://tests/world/world_fingerprint.gd")

var _checks := 0
var _failures := 0
var _skips := 0


func _init() -> void:
	var write_mode := OS.get_environment("FINGERPRINT_WRITE").strip_edges() == "1"
	var stat_tol := WORLD_FINGERPRINT.env_stat_tol()
	var compare_hashes := WORLD_FINGERPRINT.env_compare_hashes()
	print("[world-fingerprint] mode=%s stat_tol=%.1f%% compare_hashes=%s godot=%s"
			% ["write" if write_mode else "assert", stat_tol * 100.0,
			str(compare_hashes), str(Engine.get_version_info().get("string", "?"))])
	if not ClassDB.class_exists("DCWorldExt"):
		_skip_all("DCWorldExt class not found（GDExtension 未编译 / 未加载）")
		quit(0)
		return
	var ext: Object = ClassDB.instantiate("DCWorldExt")
	if ext == null:
		_skip_all("DCWorldExt instantiate returned null")
		quit(0)
		return
	var started := Time.get_ticks_msec()
	if write_mode:
		_run_write(ext)
	else:
		_run_assert(ext, stat_tol, compare_hashes)
	print("[world-fingerprint] checks=%d failures=%d skips=%d wall=%dms"
			% [_checks, _failures, _skips, Time.get_ticks_msec() - started])
	quit(0 if _failures == 0 else 1)


func _skip_all(reason: String) -> void:
	_skips += 1
	print("[world-fingerprint] SKIP reason=%s" % reason)
	print("[world-fingerprint] checks=%d failures=%d skips=%d" % [_checks, _failures, _skips])


# ═════════════════════════════════════════════════════════════════════════════
# assert 模式：逐种子比 hash + stats
# ═════════════════════════════════════════════════════════════════════════════

func _run_assert(ext: Object, stat_tol: float, compare_hashes: bool) -> void:
	var loaded := WORLD_FINGERPRINT.load_baseline(WORLD_FINGERPRINT.BASELINE_PATH)
	if not bool(loaded.get("ok", false)):
		_skips += 1
		print("[world-fingerprint] SKIP reason=baseline missing (run with FINGERPRINT_WRITE=1)")
		print("[world-fingerprint] 细节：%s" % str(loaded.get("reason", "")))
		return
	var rows: Dictionary = loaded.get("rows", {})
	print("[world-fingerprint] baseline=%s rows=%d"
			% [WORLD_FINGERPRINT.BASELINE_PATH, rows.size()])
	for entry in WORLD_FINGERPRINT.seed_set():
		var item: Dictionary = entry
		var seed_v := int(item["seed"])
		var w := int(item["w"])
		var h := int(item["h"])
		var t0 := Time.get_ticks_msec()
		var result := WORLD_FINGERPRINT.verify(ext, seed_v, w, h,
				WORLD_FINGERPRINT.BASELINE_PATH, stat_tol, compare_hashes)
		var ms := Time.get_ticks_msec() - t0
		_checks += 1
		var status := str(result.get("status", "skip"))
		match status:
			"ok":
				print("[world-fingerprint] %d %dx%d PASS (%dms) %s %s"
						% [seed_v, w, h, ms, _hash_line(result.get("actual", {})),
						_bake_line(result.get("actual", {}))])
			"drift":
				_failures += 1
				print("[world-fingerprint] %d %dx%d DRIFT (%dms)"
						% [seed_v, w, h, ms])
				print(WORLD_FINGERPRINT.format_report(result))
			"error":
				_failures += 1
				print("[world-fingerprint] %d %dx%d ERROR reason=%s"
						% [seed_v, w, h, str(result.get("reason", "?"))])
			_:
				_skips += 1
				print("[world-fingerprint] %d %dx%d SKIP reason=%s"
						% [seed_v, w, h, str(result.get("reason", "?"))])


# ═════════════════════════════════════════════════════════════════════════════
# write 模式：重写基线（只写全部种子都测成、且 5 条 hash 齐全的基线）
# ═════════════════════════════════════════════════════════════════════════════

func _run_write(ext: Object) -> void:
	var rows: Array = []
	for entry in WORLD_FINGERPRINT.seed_set():
		var item: Dictionary = entry
		var seed_v := int(item["seed"])
		var w := int(item["w"])
		var h := int(item["h"])
		var t0 := Time.get_ticks_msec()
		var row := WORLD_FINGERPRINT.compute(ext, seed_v, w, h)
		var ms := Time.get_ticks_msec() - t0
		_checks += 1
		if not bool(row.get("ok", false)):
			# ok=false 涵盖：base/post_base 失败、数组长度不对、5 条 hash 有一条算不出来。
			# 任一情况都**不写基线** —— 残缺基线会让下一次运行在「基线缺行」上永远 SKIP。
			_failures += 1
			print("  [FAIL] %d %dx%d 测量失败：%s"
					% [seed_v, w, h, str(row.get("reason", "?"))])
			continue
		var meta: Dictionary = row.get("meta", {})
		print("[world-fingerprint/write] %d %dx%d %s %s base_ms=%.2f (%dms)"
				% [seed_v, w, h, _hash_line(row), _bake_line(row),
				float(meta.get("base_ms", -1.0)), ms])
		rows.append(row)
	if _failures > 0:
		print("[world-fingerprint] WRITE ABORTED failures=%d：**不写残缺基线**（先修好生成）"
				% _failures)
		return
	var doc := WORLD_FINGERPRINT.build_baseline_document(rows)
	var written := WORLD_FINGERPRINT.write_baseline(WORLD_FINGERPRINT.BASELINE_PATH, doc)
	_checks += 1
	if not bool(written.get("ok", false)):
		_failures += 1
		print("  [FAIL] 基线写入失败：%s" % str(written.get("reason", "?")))
		return
	print("[world-fingerprint] WROTE seeds=%d path=%s"
			% [rows.size(), str(written.get("path", ""))])
	print("[world-fingerprint] 提交时带上 %s（有意改世界的 PR 必须同一次提交重写基线）"
			% WORLD_FINGERPRINT.BASELINE_PATH)


# ═════════════════════════════════════════════════════════════════════════════
# 小工具
# ═════════════════════════════════════════════════════════════════════════════

# 一行 hash 摘要（只取前 8 位，便于肉眼区分而不刷屏）。
func _hash_line(row: Dictionary) -> String:
	var hashes: Dictionary = row.get("hashes", {})
	var parts := ""
	for key in WORLD_FINGERPRINT.HASH_KEYS:
		var k := str(key)
		var value := str(hashes.get(k, ""))
		parts += "%s=%s " % [k, value.substr(0, 8) if value.length() >= 8 else "--------"]
	return parts.strip_edges()


# bake height_buffer 的覆盖摘要：not-covered（该种子不烘）/ hash 前 8 位 + 尺寸 + 陆地像素
# + 融合几何 pass 耗时。**只被 print 调用、不参与任何判定**（2026-11-18 计划 §5.3 / T2）。
func _bake_line(row: Dictionary) -> String:
	var meta: Dictionary = row.get("meta", {})
	var bake: Dictionary = meta.get("bake", {})
	if bake.is_empty():
		return "bake=absent"
	if not bool(bake.get("measured", false)):
		return "bake=not-covered"
	var hashes: Dictionary = row.get("hashes", {})
	var hash_text := str(hashes.get(WORLD_FINGERPRINT.BAKE_HASH_KEY, ""))
	var brief := hash_text.substr(0, 8) if hash_text.length() >= 8 else "--------"
	return "bake=%s %dx%d land_px=%d %.0fms" % [brief, int(bake.get("w", 0)),
			int(bake.get("h", 0)), int(bake.get("land_px", 0)),
			float(bake.get("ms", -1.0))]
