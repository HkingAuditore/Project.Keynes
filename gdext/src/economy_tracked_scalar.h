#pragma once
#include "economy_tracked_column.h"

namespace pk {
template<class T> class EconomyTrackedScalar {
    EconomyTrackedColumn<T> _column;
public:
    EconomyTrackedScalar(ChangeRegistry &registry, EconomyFieldDescriptor field, T value = T{})
        : _column(registry, field) { _column.resize(1, value); }
    EconomyTrackedScalar(const EconomyTrackedScalar &) = delete;
    T get() const { return _column[0]; }
    operator T() const { return get(); }
    EconomyTrackedScalar &operator=(T value) { _column.write_scalar(0, value); return *this; }
    EconomyTrackedScalar &operator=(const EconomyTrackedScalar &other) { return *this = other.get(); }
    EconomyTrackedScalar &operator+=(T value) { return *this = static_cast<T>(get() + value); }
    EconomyTrackedScalar &operator-=(T value) { return *this = static_cast<T>(get() - value); }
    EconomyTrackedScalar &operator|=(T value) { return *this = static_cast<T>(get() | value); }
    EconomyTrackedScalar &operator&=(T value) { return *this = static_cast<T>(get() & value); }
    T operator++() { const T value = static_cast<T>(get() + 1); *this = value; return value; }
    T operator--() { const T value = static_cast<T>(get() - 1); *this = value; return value; }
    T operator++(int) { const T before = get(); ++*this; return before; }
    T operator--(int) { const T before = get(); --*this; return before; }
    const EconomyTrackedColumn<T> &column() const { return _column; }
};
template<> class EconomyTrackedScalar<bool> {
    EconomyTrackedColumn<uint8_t> _column;
public:
    EconomyTrackedScalar(ChangeRegistry &registry, EconomyFieldDescriptor field, bool value = false)
        : _column(registry, field) { _column.resize(1, value ? 1 : 0); }
    EconomyTrackedScalar(const EconomyTrackedScalar &) = delete;
    bool get() const { return _column[0] != 0; }
    operator bool() const { return get(); }
    EconomyTrackedScalar &operator=(bool value) { _column.write_scalar(0, value ? 1 : 0); return *this; }
    EconomyTrackedScalar &operator=(const EconomyTrackedScalar &other) { return *this = other.get(); }
    const EconomyTrackedColumn<uint8_t> &column() const { return _column; }
};
} // namespace pk
