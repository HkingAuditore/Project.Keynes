extends SceneTree

const EconomyCatalogScript = preload("res://scripts/economy/economy_catalog.gd")
const CountryFacadeScript = preload("res://scripts/country/country_facade.gd")

var _checks := 0
var _failures := 0


func _init() -> void:
	_run()
	print("runtime country economy transaction: %d checks, %d failures" % [
		_checks, _failures])
	quit(0 if _failures == 0 else 1)


func _run() -> void:
	if not ClassDB.class_exists("DCWorldExt"):
		_fail("DCWorldExt unavailable")
		return
	var compiled: Dictionary = EconomyCatalogScript.compile_native_catalog()
	_expect("catalog compiles", bool(compiled.get("ok", false)))
	if not bool(compiled.get("ok", false)):
		return
	var ext: Object = DCWorldExt.new()
	var country = CountryFacadeScript.new()
	var catalog := compiled.duplicate(true)
	catalog.erase("ok")
	_expect("country configures", bool(country.configure(
		ext, 1, 620260909, load("res://data/country/default_country.tres"),
		compiled).get("ok", false)))
	var goods: PackedStringArray = compiled.get("good_ids", PackedStringArray())
	var grain := goods.find("grain")
	var points := goods.find("technology_points")
	_expect("transaction goods exist", grain >= 0 and points >= 0)
	if grain < 0 or points < 0:
		return
	var packet := {
		"country_ids": PackedStringArray(["country.k2b"]),
		"country_names": PackedStringArray(["K2B"]),
		"country_cash": PackedInt64Array([1000]),
		"territory_offsets": PackedInt32Array([0, 1]),
		"territory_cells": PackedInt32Array([0]),
		"technology_offsets": PackedInt32Array([0, 1]),
		"technology_indices": PackedInt32Array([compiled.technology_ids.find("tech.hunting")]),
		"treasury_offsets": PackedInt32Array([0, 2]),
		"treasury_good_indices": PackedInt32Array([grain, points]),
		"treasury_quantities": PackedInt64Array([50, 100]),
	}
	var boot: Dictionary = country.bootstrap(PackedByteArray([0]), packet)
	_expect("country bootstraps", bool(boot.get("ok", false)))
	if not bool(boot.get("ok", false)):
		return
	var handle := int(country.cell_summary(0).get("country_handle", 0))
	var before: Dictionary = country.treasury_snapshot(handle)
	var before_cash := int(before.get("cash", -1))
	var before_goods: PackedInt64Array = before.get("quantities", PackedInt64Array())
	var before_good_ids: PackedStringArray = before.get("good_ids", PackedStringArray())
	_expect("transaction API is exported",
		ext.has_method("begin_country_economy_treasury_spend")
		and ext.has_method("ack_country_economy_asset_peer_prepared")
		and ext.has_method("commit_country_economy_treasury_spend")
		and ext.has_method("ack_country_economy_asset_peer_applied"))

	var request_id := 77001
	var begin: Dictionary = ext.begin_country_economy_treasury_spend(
		handle, PackedInt32Array([grain, points]), PackedInt64Array([10, 20]),
		100, 33, 7, request_id)
	var tx_id := int(begin.get("transaction_id", 0))
	var session := int(begin.get("session_epoch", 0))
	var country_generation := int(begin.get("country_generation", 0))
	_expect("begin reserves without mutating committed assets",
		bool(begin.get("ok", false)) and tx_id > 0 and session > 0
		and country_generation > 0
		and String(begin.get("status_name", "")) == "awaiting_peer_prepared"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == before_cash)
	var report_reserved: Dictionary = country.report().get(
		"economy_asset_transactions", {})
	_expect("reservation is observable and bounded",
		int(report_reserved.get("in_flight", 0)) == 1
		and int(report_reserved.get("reserved_cash", -1)) == 100
		and int(report_reserved.get("reserved_goods", -1)) == 30)
	var blocked_save: Dictionary = country.begin_save()
	_expect("save is blocked while an asset transaction is in flight",
		not bool(blocked_save.get("ok", true))
		and String(blocked_save.get("reason", "")) ==
			"country_save_economy_asset_transaction_pending"
		and int(blocked_save.get("in_flight", 0)) == 1
		and int(blocked_save.get("reserved_cash", -1)) == 100
		and int(blocked_save.get("reserved_goods", -1)) == 30)
	var replay_begin: Dictionary = ext.begin_country_economy_treasury_spend(
		handle, PackedInt32Array([grain, points]), PackedInt64Array([10, 20]),
		100, 33, 7, request_id)
	_expect("same request replays the in-flight transaction",
		bool(replay_begin.get("replayed", false))
		and int(replay_begin.get("transaction_id", 0)) == tx_id)

	var bad_ack: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		tx_id, session + 1, country_generation, 91, true, "")
	_expect("wrong session is rejected before prepare",
		not bool(bad_ack.get("ok", true))
		and String(bad_ack.get("code", "")) ==
			"country_treasury_async_prepare_identity_mismatch")
	var prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		tx_id, session, country_generation, 91, true, "")
	_expect("peer prepared ACK advances the transaction",
		bool(prepared.get("ok", false))
		and String(prepared.get("status_name", "")) == "peer_prepared"
		and int(prepared.get("peer_generation", 0)) == 91)
	var duplicate_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		tx_id, session, country_generation, 91, true, "")
	_expect("duplicate peer prepared ACK is idempotent",
		bool(duplicate_prepared.get("ok", false))
		and bool(duplicate_prepared.get("replayed", false))
		and String(duplicate_prepared.get("status_name", "")) == "peer_prepared")
	var mismatched_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		tx_id, session, country_generation, 92, true, "")
	_expect("different duplicate peer prepared ACK is rejected",
		not bool(mismatched_prepared.get("ok", true))
		and String(mismatched_prepared.get("code", "")) ==
			"country_treasury_async_prepare_duplicate_mismatch")
	var committed: Dictionary = ext.commit_country_economy_treasury_spend(tx_id)
	_expect("commit decision applies Country assets exactly once",
		bool(committed.get("ok", false))
		and String(committed.get("status_name", "")) == "awaiting_peer_applied"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == before_cash - 100)
	var after_commit: PackedInt64Array = country.treasury_snapshot(handle).get(
		"quantities", PackedInt64Array())
	var after_good_ids: PackedStringArray = country.treasury_snapshot(handle).get(
		"good_ids", PackedStringArray())
	_expect("goods are deducted atomically with cash",
		_good_quantity(after_good_ids, after_commit, goods[grain]) ==
			_good_quantity(before_good_ids, before_goods, goods[grain]) - 10
		and _good_quantity(after_good_ids, after_commit, goods[points]) ==
			_good_quantity(before_good_ids, before_goods, goods[points]) - 20)
	var duplicate_commit: Dictionary = ext.commit_country_economy_treasury_spend(tx_id)
	_expect("commit retry does not apply Country side twice",
		String(duplicate_commit.get("status_name", "")) == "awaiting_peer_applied"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == before_cash - 100)
	var bad_apply: Dictionary = ext.ack_country_economy_asset_peer_applied(
		tx_id, session, country_generation, 92, true, "")
	_expect("wrong peer applied generation is rejected after commit",
		not bool(bad_apply.get("ok", true))
		and String(bad_apply.get("code", "")) ==
			"country_treasury_async_apply_identity_mismatch")
	var applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		tx_id, session, country_generation, 91, true, "")
	_expect("peer applied ACK completes the transaction",
		bool(applied.get("ok", false))
		and String(applied.get("status_name", "")) == "completed")
	var duplicate_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		tx_id, session, country_generation, 91, true, "")
	_expect("completed ACK retry is idempotent",
		bool(duplicate_applied.get("replayed", false))
		and String(duplicate_applied.get("status_name", "")) == "completed")
	var report_done: Dictionary = country.report().get(
		"economy_asset_transactions", {})
	_expect("completed transaction releases reservation and preserves ledger",
		int(report_done.get("in_flight", -1)) == 0
		and int(report_done.get("reserved_cash", -1)) == 0
		and int(report_done.get("reserved_goods", -1)) == 0
		and int(report_done.get("ledger_failures", -1)) == 0)

	var rejected: Dictionary = ext.begin_country_economy_treasury_spend(
		handle, PackedInt32Array([grain]), PackedInt64Array([1]), 1, 34, 8, 77002)
	var rejected_id := int(rejected.get("transaction_id", 0))
	var rejected_ack: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		rejected_id, int(rejected.get("session_epoch", 0)),
		int(rejected.get("country_generation", 0)), 92, false, "market_prepare_rejected")
	var report_rejected: Dictionary = country.report().get(
		"economy_asset_transactions", {})
	_expect("prepare rejection releases reservation without Country mutation",
		String(rejected_ack.get("status_name", "")) == "rejected"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == before_cash - 100
		and int(report_rejected.get("in_flight", -1)) == 0
		and int(report_rejected.get("reserved_cash", -1)) == 0
		and int(report_rejected.get("reserved_goods", -1)) == 0)

	var fiscal_before_cash := int(country.treasury_snapshot(handle).get("cash", -1))
	var fiscal_begin: Dictionary = ext.begin_country_economy_fiscal_reserve(
		handle, 60, 34, 8, 77004)
	var fiscal_id := int(fiscal_begin.get("transaction_id", 0))
	var fiscal_session := int(fiscal_begin.get("session_epoch", 0))
	var fiscal_generation := int(fiscal_begin.get("country_generation", 0))
	_expect("fiscal reserve uses the shared async transaction boundary",
		ext.has_method("begin_country_economy_fiscal_reserve")
		and ext.has_method("commit_country_economy_fiscal_reserve")
		and bool(fiscal_begin.get("ok", false))
		and String(fiscal_begin.get("status_name", "")) == "awaiting_peer_prepared"
		and int(fiscal_begin.get("prepared_quantity", -1)) == 60
		and int(country.treasury_snapshot(handle).get("cash", -1)) == fiscal_before_cash)
	var fiscal_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		fiscal_id, fiscal_session, fiscal_generation, 94, true, "")
	var fiscal_commit: Dictionary = ext.commit_country_economy_fiscal_reserve(fiscal_id)
	_expect("fiscal reserve commits the prepared cash quantity once",
		String(fiscal_prepared.get("status_name", "")) == "peer_prepared"
		and String(fiscal_commit.get("status_name", "")) == "awaiting_peer_applied"
		and int(fiscal_commit.get("committed_quantity", -1)) == 60
		and int(country.treasury_snapshot(handle).get("cash", -1)) == fiscal_before_cash - 60)
	var fiscal_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		fiscal_id, fiscal_session, fiscal_generation, 94, true, "")
	var fiscal_replay: Dictionary = ext.begin_country_economy_fiscal_reserve(
		handle, 60, 34, 8, 77004)
	_expect("fiscal reserve completion and retry are idempotent",
		String(fiscal_applied.get("status_name", "")) == "completed"
		and bool(fiscal_replay.get("replayed", false))
		and String(fiscal_replay.get("status_name", "")) == "completed"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == fiscal_before_cash - 60)

	var return_before_cash := int(country.treasury_snapshot(handle).get("cash", -1))
	var return_begin: Dictionary = ext.begin_country_economy_fiscal_return(
		handle, 20, 34, 8, 77005)
	var return_id := int(return_begin.get("transaction_id", 0))
	var return_session := int(return_begin.get("session_epoch", 0))
	var return_generation := int(return_begin.get("country_generation", 0))
	var return_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		return_id, return_session, return_generation, 95, true, "")
	var return_cash_before_commit := int(country.treasury_snapshot(handle).get("cash", -1))
	var return_commit: Dictionary = ext.commit_country_economy_asset_transaction(return_id)
	var return_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		return_id, return_session, return_generation, 95, true, "")
	_expect("fiscal return credits Country only after peer prepare",
		bool(return_begin.get("ok", false))
		and String(return_begin.get("status_name", "")) == "awaiting_peer_prepared"
		and return_cash_before_commit == return_before_cash
		and String(return_prepared.get("status_name", "")) == "peer_prepared"
		and String(return_commit.get("status_name", "")) == "awaiting_peer_applied"
		and String(return_applied.get("status_name", "")) == "completed"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == return_before_cash + 20)

	var collect_before_cash := int(country.treasury_snapshot(handle).get("cash", -1))
	var collect_begin: Dictionary = ext.begin_country_economy_fiscal_collect(
		handle, 15, 34, 8, 77006)
	var collect_id := int(collect_begin.get("transaction_id", 0))
	var collect_session := int(collect_begin.get("session_epoch", 0))
	var collect_generation := int(collect_begin.get("country_generation", 0))
	var collect_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		collect_id, collect_session, collect_generation, 96, true, "")
	var collect_commit: Dictionary = ext.commit_country_economy_asset_transaction(collect_id)
	var collect_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		collect_id, collect_session, collect_generation, 96, true, "")
	_expect("fiscal collect shares the credit-side conservation path",
		bool(collect_begin.get("ok", false))
		and String(collect_prepared.get("status_name", "")) == "peer_prepared"
		and String(collect_commit.get("status_name", "")) == "awaiting_peer_applied"
		and String(collect_applied.get("status_name", "")) == "completed"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == collect_before_cash + 15)

	var cohort_before_cash := int(country.treasury_snapshot(handle).get("cash", -1))
	var cohort_out_begin: Dictionary = ext.begin_country_economy_cash_to_cohort(
		handle, 25, 34, 8, 77007)
	var cohort_out_id := int(cohort_out_begin.get("transaction_id", 0))
	var cohort_out_session := int(cohort_out_begin.get("session_epoch", 0))
	var cohort_out_generation := int(cohort_out_begin.get("country_generation", 0))
	var cohort_out_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		cohort_out_id, cohort_out_session, cohort_out_generation, 97, true, "")
	var cohort_out_cash_before_commit := int(country.treasury_snapshot(handle).get("cash", -1))
	var cohort_out_commit: Dictionary = ext.commit_country_economy_asset_transaction(cohort_out_id)
	var cohort_out_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		cohort_out_id, cohort_out_session, cohort_out_generation, 97, true, "")
	_expect("Country to cohort cash uses reserved partial quantity and conservation",
		ext.has_method("begin_country_economy_cash_to_cohort")
		and bool(cohort_out_begin.get("ok", false))
		and int(cohort_out_begin.get("prepared_quantity", -1)) == 25
		and cohort_out_cash_before_commit == cohort_before_cash
		and String(cohort_out_prepared.get("status_name", "")) == "peer_prepared"
		and String(cohort_out_commit.get("status_name", "")) == "awaiting_peer_applied"
		and String(cohort_out_applied.get("status_name", "")) == "completed"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == cohort_before_cash - 25)

	var cohort_in_before_cash := int(country.treasury_snapshot(handle).get("cash", -1))
	var cohort_in_begin: Dictionary = ext.begin_country_economy_cash_from_cohort(
		handle, 18, 34, 8, 77008)
	var cohort_in_id := int(cohort_in_begin.get("transaction_id", 0))
	var cohort_in_session := int(cohort_in_begin.get("session_epoch", 0))
	var cohort_in_generation := int(cohort_in_begin.get("country_generation", 0))
	var cohort_in_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		cohort_in_id, cohort_in_session, cohort_in_generation, 98, true, "")
	var cohort_in_commit: Dictionary = ext.commit_country_economy_asset_transaction(cohort_in_id)
	var cohort_in_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		cohort_in_id, cohort_in_session, cohort_in_generation, 98, true, "")
	_expect("Cohort to Country cash uses the credit-side path",
		bool(cohort_in_begin.get("ok", false))
		and String(cohort_in_prepared.get("status_name", "")) == "peer_prepared"
		and String(cohort_in_commit.get("status_name", "")) == "awaiting_peer_applied"
		and String(cohort_in_applied.get("status_name", "")) == "completed"
		and int(country.treasury_snapshot(handle).get("cash", -1)) == cohort_in_before_cash + 18)

	var market_before: Dictionary = country.treasury_snapshot(handle)
	var market_before_goods: PackedInt64Array = market_before.get("quantities", PackedInt64Array())
	var market_before_ids: PackedStringArray = market_before.get("good_ids", PackedStringArray())
	var market_before_grain := _good_quantity(market_before_ids, market_before_goods, goods[grain])
	var market_out_begin: Dictionary = ext.begin_country_economy_good_to_market(
		handle, grain, 12, 34, 8, 77009)
	var market_out_id := int(market_out_begin.get("transaction_id", 0))
	var market_out_session := int(market_out_begin.get("session_epoch", 0))
	var market_out_generation := int(market_out_begin.get("country_generation", 0))
	var market_out_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		market_out_id, market_out_session, market_out_generation, 99, true, "")
	var market_out_cash_before_commit := int(country.treasury_snapshot(handle).get("cash", -1))
	var market_out_commit: Dictionary = ext.commit_country_economy_asset_transaction(market_out_id)
	var market_out_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		market_out_id, market_out_session, market_out_generation, 99, true, "")
	var market_after_out: Dictionary = country.treasury_snapshot(handle)
	var market_after_out_goods: PackedInt64Array = market_after_out.get("quantities", PackedInt64Array())
	var market_after_out_ids: PackedStringArray = market_after_out.get("good_ids", PackedStringArray())
	_expect("Country to market reserves and commits goods without cash mutation",
		ext.has_method("begin_country_economy_good_to_market")
		and bool(market_out_begin.get("ok", false))
		and int(market_out_begin.get("prepared_quantity", -1)) == 12
		and market_out_cash_before_commit == int(market_before.get("cash", -1))
		and String(market_out_prepared.get("status_name", "")) == "peer_prepared"
		and String(market_out_commit.get("status_name", "")) == "awaiting_peer_applied"
		and String(market_out_applied.get("status_name", "")) == "completed"
		and _good_quantity(market_after_out_ids, market_after_out_goods, goods[grain]) == market_before_grain - 12)

	var market_in_before: Dictionary = country.treasury_snapshot(handle)
	var market_in_before_goods: PackedInt64Array = market_in_before.get("quantities", PackedInt64Array())
	var market_in_before_ids: PackedStringArray = market_in_before.get("good_ids", PackedStringArray())
	var market_in_before_grain := _good_quantity(market_in_before_ids, market_in_before_goods, goods[grain])
	var market_in_begin: Dictionary = ext.begin_country_economy_good_from_market(
		handle, grain, 8, 34, 8, 77010)
	var market_in_id := int(market_in_begin.get("transaction_id", 0))
	var market_in_session := int(market_in_begin.get("session_epoch", 0))
	var market_in_generation := int(market_in_begin.get("country_generation", 0))
	var market_in_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		market_in_id, market_in_session, market_in_generation, 100, true, "")
	var market_in_commit: Dictionary = ext.commit_country_economy_asset_transaction(market_in_id)
	var market_in_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		market_in_id, market_in_session, market_in_generation, 100, true, "")
	var market_after_in: Dictionary = country.treasury_snapshot(handle)
	var market_after_in_goods: PackedInt64Array = market_after_in.get("quantities", PackedInt64Array())
	var market_after_in_ids: PackedStringArray = market_after_in.get("good_ids", PackedStringArray())
	_expect("Market to Country credits goods with directional conservation",
		bool(market_in_begin.get("ok", false))
		and int(market_in_begin.get("prepared_quantity", -1)) == 8
		and String(market_in_prepared.get("status_name", "")) == "peer_prepared"
		and String(market_in_commit.get("status_name", "")) == "awaiting_peer_applied"
		and String(market_in_applied.get("status_name", "")) == "completed"
		and _good_quantity(market_after_in_ids, market_after_in_goods, goods[grain]) == market_in_before_grain + 8)
	var market_report: Dictionary = country.report().get("economy_asset_transactions", {})
	_expect("market goods paths leave no residual reservation",
		int(market_report.get("reserved_goods", -1)) == 0
		and int(market_report.get("reserved_cash", -1)) == 0
		and int(market_report.get("in_flight", -1)) == 0)

	var research_before: Dictionary = country.treasury_snapshot(handle)
	var research_before_cash := int(research_before.get("cash", -1))
	var research_before_goods: PackedInt64Array = research_before.get(
		"quantities", PackedInt64Array())
	var research_before_ids: PackedStringArray = research_before.get(
		"good_ids", PackedStringArray())
	var research_before_points := _good_quantity(
		research_before_ids, research_before_goods, goods[points])
	var research_before_snapshot: Dictionary = country.research_snapshot(handle)
	var research_before_purchased := int(
		research_before_snapshot.get("purchased_total", -1))
	var research_begin: Dictionary = ext.begin_country_economy_research_purchase(
		handle, 7, 70, 34, 8, 77011)
	var research_id := int(research_begin.get("transaction_id", 0))
	var research_session := int(research_begin.get("session_epoch", 0))
	var research_generation := int(research_begin.get("country_generation", 0))
	_expect("research purchase exposes the composite async transaction",
		ext.has_method("begin_country_economy_research_purchase")
		and bool(research_begin.get("ok", false))
		and research_id > 0
		and String(research_begin.get("status_name", "")) ==
			"awaiting_peer_prepared"
		and int(research_begin.get("prepared_quantity", -1)) == 7
		and int(research_begin.get("requested_cash", -1)) == 70)
	var research_reserved: Dictionary = country.report().get(
		"economy_asset_transactions", {})
	_expect("research purchase reserves cash without changing Country goods",
		int(research_reserved.get("in_flight", -1)) == 1
		and int(research_reserved.get("reserved_cash", -1)) == 70
		and int(research_reserved.get("reserved_research_points", -1)) == 7
		and int(country.treasury_snapshot(handle).get("cash", -1)) ==
			research_before_cash
		and _good_quantity(
			country.treasury_snapshot(handle).get("good_ids", PackedStringArray()),
			country.treasury_snapshot(handle).get("quantities", PackedInt64Array()),
			goods[points]) == research_before_points)
	var research_blocked_save: Dictionary = country.begin_save()
	_expect("research purchase participates in the save barrier",
		not bool(research_blocked_save.get("ok", true))
		and String(research_blocked_save.get("reason", "")) ==
			"country_save_economy_asset_transaction_pending")
	var research_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		research_id, research_session, research_generation, 101, true, "")
	var research_commit: Dictionary = ext.commit_country_economy_asset_transaction(
		research_id)
	var research_after_commit: Dictionary = country.treasury_snapshot(handle)
	var research_after_commit_goods: PackedInt64Array = research_after_commit.get(
		"quantities", PackedInt64Array())
	var research_after_commit_ids: PackedStringArray = research_after_commit.get(
		"good_ids", PackedStringArray())
	var research_commit_snapshot: Dictionary = country.research_snapshot(handle)
	_expect("research commit atomically debits cash and credits points",
		String(research_prepared.get("status_name", "")) == "peer_prepared"
		and String(research_commit.get("status_name", "")) ==
			"awaiting_peer_applied"
		and int(research_after_commit.get("cash", -1)) ==
			research_before_cash - 70
		and _good_quantity(research_after_commit_ids, research_after_commit_goods,
			goods[points]) == research_before_points + 7
		and int(research_commit_snapshot.get("purchased_total", -1)) ==
			research_before_purchased + 7
		and int(research_commit.get("committed_quantity", -1)) == 7
		and int(research_commit.get("committed_cash", -1)) == 70)
	var research_duplicate_commit: Dictionary = ext.commit_country_economy_asset_transaction(
		research_id)
	_expect("research commit retry does not duplicate the composite write",
		String(research_duplicate_commit.get("status_name", "")) ==
			"awaiting_peer_applied"
		and int(country.treasury_snapshot(handle).get("cash", -1)) ==
			research_before_cash - 70
		and _good_quantity(
			country.treasury_snapshot(handle).get("good_ids", PackedStringArray()),
			country.treasury_snapshot(handle).get("quantities", PackedInt64Array()),
			goods[points]) == research_before_points + 7)
	var research_applied: Dictionary = ext.ack_country_economy_asset_peer_applied(
		research_id, research_session, research_generation, 101, true, "")
	var research_replay: Dictionary = ext.begin_country_economy_research_purchase(
		handle, 7, 70, 34, 8, 77011)
	var research_done_report: Dictionary = country.report().get(
		"economy_asset_transactions", {})
	_expect("research purchase completes and replays idempotently",
		String(research_applied.get("status_name", "")) == "completed"
		and bool(research_replay.get("replayed", false))
		and String(research_replay.get("status_name", "")) == "completed"
		and int(research_done_report.get("in_flight", -1)) == 0
		and int(research_done_report.get("reserved_cash", -1)) == 0
		and int(research_done_report.get("reserved_research_points", -1)) == 0
		and int(research_done_report.get("ledger_failures", -1)) == 0)

	var fault_begin: Dictionary = ext.begin_country_economy_treasury_spend(
		handle, PackedInt32Array([grain]), PackedInt64Array([2]), 5, 35, 9, 77003)
	var fault_id := int(fault_begin.get("transaction_id", 0))
	var fault_session := int(fault_begin.get("session_epoch", 0))
	var fault_generation := int(fault_begin.get("country_generation", 0))
	var wrong_fault_prepare: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		fault_id, fault_session + 1, fault_generation, 93, true, "")
	_expect("wrong session does not advance a fault candidate",
		not bool(wrong_fault_prepare.get("ok", true))
		and String(wrong_fault_prepare.get("code", "")) ==
			"country_treasury_async_prepare_identity_mismatch"
		and int(country.report().get("economy_asset_transactions", {}).get("in_flight", -1)) == 1)
	var fault_prepared: Dictionary = ext.ack_country_economy_asset_peer_prepared(
		fault_id, fault_session, fault_generation, 93, true, "")
	var fault_committed: Dictionary = ext.commit_country_economy_treasury_spend(fault_id)
	var blocked_after_commit: Dictionary = country.begin_save()
	_expect("save remains blocked after Country commit until peer apply",
		String(fault_prepared.get("status_name", "")) == "peer_prepared"
		and String(fault_committed.get("status_name", "")) == "awaiting_peer_applied"
		and not bool(blocked_after_commit.get("ok", true))
		and String(blocked_after_commit.get("reason", "")) ==
			"country_save_economy_asset_transaction_pending")
	var faulted: Dictionary = ext.ack_country_economy_asset_peer_applied(
		fault_id, fault_session, fault_generation, 93, false, "peer_apply_failed")
	var fault_report: Dictionary = country.report().get(
		"economy_asset_transactions", {})
	_expect("peer apply rejection enters FAULTED without pretending completion",
		String(faulted.get("status_name", "")) == "faulted"
		and String(faulted.get("rejection_reason", "")) == "peer_apply_failed"
		and int(fault_report.get("faulted", -1)) == 1
		and int(fault_report.get("in_flight", -1)) == 0
		and int(fault_report.get("reserved_cash", -1)) == 0
		and int(fault_report.get("reserved_goods", -1)) == 0
		and int(fault_report.get("ledger_failures", -1)) == 1)
	var fault_retry: Dictionary = ext.ack_country_economy_asset_peer_applied(
		fault_id, fault_session, fault_generation, 93, true, "")
	_expect("faulted transaction cannot be retried as completed",
		bool(fault_retry.get("replayed", false))
		and String(fault_retry.get("status_name", "")) == "faulted")
	var save_after_fault: Dictionary = country.begin_save()
	_expect("save is available after fault is durably terminal",
		bool(save_after_fault.get("ok", false)))
	if bool(save_after_fault.get("ok", false)):
		while not country.read_save_chunk().is_empty():
			pass
		var ended_save: Dictionary = country.end_save()
		_expect("fault test save completes normally", bool(ended_save.get("ok", false)))


func _expect(label: String, condition: bool) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAIL: " + label)


func _fail(label: String) -> void:
	_failures += 1
	push_error("FAIL: " + label)


func _good_quantity(ids: PackedStringArray, quantities: PackedInt64Array,
		good_id: String) -> int:
	var index := ids.find(good_id)
	return int(quantities[index]) if index >= 0 and index < quantities.size() else 0
