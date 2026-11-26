extends RefCounted


static func _ensure_query_pool(owner: Variant) -> void:
	if owner._query_pool.size() == 0:
		for i in range(owner._QUERY_POOL_INITIAL):
			owner._query_pool.append(DCQuery.new())
			owner._query_in_use.append(false)


## 从池中取一个 query 实例并 reset 到初始状态。
## 调用方按链式 DSL 配置后调用 for_each_index；执行完 release_query() 归还。
static func query(owner: Variant) -> DCQuery:
	owner._ensure_query_pool()
	for i in range(owner._query_pool.size()):
		if not owner._query_in_use[i]:
			owner._query_in_use[i] = true
			var q: DCQuery = owner._query_pool[i]
			q._reset(owner)
			return q
	# 池子用满了，扩容（罕见路径）
	if owner._query_pool.size() >= owner._QUERY_POOL_MAX:
		if owner._debug:
			push_warning("[DCWorld] query pool reached max=%d; allocating extra query (no pool)" % owner._QUERY_POOL_MAX)
		var qe: DCQuery = DCQuery.new()
		qe._reset(owner)
		return qe
	var qq: DCQuery = DCQuery.new()
	owner._query_pool.append(qq)
	owner._query_in_use.append(true)
	qq._reset(owner)
	return qq


## 把 query 归还池子。若 q 不在池中则忽略（兼容 max 之外临时分配的 query）。
static func release_query(owner: Variant, q: DCQuery) -> void:
	for i in range(owner._query_pool.size()):
		if owner._query_pool[i] == q:
			owner._query_in_use[i] = false
			return
