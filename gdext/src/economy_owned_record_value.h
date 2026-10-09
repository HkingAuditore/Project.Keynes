#pragma once
#include "economy_keyed_variable_records.h"

namespace pk {
template<class T> class EconomyOwnedRecordValue {
    EconomyKeyedVariableRecords<T> _value;
public:
    EconomyOwnedRecordValue(EconomyFieldDescriptor field, const T &initial = T{}) : _value(field) { _value.push_back(initial); }
    EconomyOwnedRecordValue(const EconomyOwnedRecordValue &other) : _value(other._value) {}
    EconomyOwnedRecordValue(EconomyOwnedRecordValue &&other) : _value(std::move(other._value)) {}
    const T &get() const { return _value[0]; }
    EconomyOwnedRecordValue &operator=(const T &value) { _value.write_record(0, value); return *this; }
    EconomyOwnedRecordValue &operator=(const EconomyOwnedRecordValue &other) { return *this = other.get(); }
    ChangeRegistry &registry() { return _value.registry(); }
    const EconomyKeyedVariableRecords<T> &rows() const { return _value; }
};
} // namespace pk
