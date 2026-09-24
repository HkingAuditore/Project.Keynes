from pathlib import Path
p=Path('Project/project-keynes/tests/authority_player_regression_probe.gd');s=p.read_text();s=s.replace('print("[regression] runtime=", ext.get_runtime_thread_report())','''var gathering = catalog.building_type_ids.find("gathering_camp")
	print("[regression] gathering_index=", gathering)
	print("[regression] subsidy=", facade.set_tax_override_basis_points(handle, 2, &"gathering_camp", -100000, _clock.day_index() + 1, 100))''');s=s.replace('print("[regression] receipts=", facade.poll_worker_command_receipts())','''print("[regression] receipts=", facade.poll_worker_command_receipts())
	print("[regression] tax=", facade.ui_snapshot(handle, 2).tax_policy.business.rates_basis_points[gathering])
	print("[regression] fiscal=", ext.get_country_fiscal_snapshot(handle))''');p.write_text(s)
