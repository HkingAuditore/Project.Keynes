extends RefCounted


static func from_snapshot(population_summary: Dictionary) -> PackedInt64Array:
	var employed_population = int(population_summary.get("employed_population", 0))
	var unemployed_population = int(population_summary.get("unemployed_population", 0))
	if not population_summary.has("employed_population") \
			and population_summary.has("populations"):
		var pops: PackedInt64Array = population_summary.get("populations", PackedInt64Array())
		var owners: PackedInt64Array = population_summary.get(
			"owner_employed_by_cohort", PackedInt64Array())
		var employees: PackedInt64Array = population_summary.get(
			"employee_employed_by_cohort", PackedInt64Array())
		employed_population = 0
		unemployed_population = 0
		for i in range(pops.size()):
			var cohort_pop = maxi(0, int(pops[i]))
			var cohort_emp = mini(cohort_pop,
				(maxi(0, int(owners[i])) if i < owners.size() else 0)
				+ (maxi(0, int(employees[i])) if i < employees.size() else 0))
			employed_population += cohort_emp
			unemployed_population += cohort_pop - cohort_emp
	return PackedInt64Array([employed_population, unemployed_population])
