#include "economy_runtime.h"

#include <algorithm>
#include <limits>

namespace pk {

void NativeEconomyRuntime::replace_employment_metrics_for_cell(
        int32_t cell, int64_t owner_jobs, int64_t employee_jobs,
        int64_t unemployed_population) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    const size_t cells = static_cast<size_t>(_cell_count.get());
    if (_employment_metrics_epoch_by_cell.size() != cells) {
        _employment_metrics_epoch_by_cell.assign(
            cells, std::numeric_limits<int64_t>::min());
        _employment_owner_jobs_by_cell.assign(cells, 0);
        _employment_employee_jobs_by_cell.assign(cells, 0);
        _employment_unemployed_by_cell.assign(cells, 0);
    }
    const size_t index = static_cast<size_t>(cell);
    if (_employment_metrics_epoch_by_cell[index] == _epoch_id.get()) {
        _filled_owner_jobs = saturating_sub(
            _filled_owner_jobs, _employment_owner_jobs_by_cell[index],
            _saturation_count);
        _filled_employee_jobs = saturating_sub(
            _filled_employee_jobs, _employment_employee_jobs_by_cell[index],
            _saturation_count);
        _unemployed_population = saturating_sub(
            _unemployed_population, _employment_unemployed_by_cell[index],
            _saturation_count);
    }
    _employment_metrics_epoch_by_cell[index] = _epoch_id.get();
    _employment_owner_jobs_by_cell[index] = std::max<int64_t>(0, owner_jobs);
    _employment_employee_jobs_by_cell[index] = std::max<int64_t>(0, employee_jobs);
    _employment_unemployed_by_cell[index] = std::max<int64_t>(
        0, unemployed_population);
    _filled_owner_jobs = saturating_add(
        _filled_owner_jobs, _employment_owner_jobs_by_cell[index],
        _saturation_count);
    _filled_employee_jobs = saturating_add(
        _filled_employee_jobs, _employment_employee_jobs_by_cell[index],
        _saturation_count);
    _unemployed_population = saturating_add(
        _unemployed_population, _employment_unemployed_by_cell[index],
        _saturation_count);
}

} // namespace pk
