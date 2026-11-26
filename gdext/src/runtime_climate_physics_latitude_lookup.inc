inline double pkw_lat_at(const float *lat_norm, const float *pos_y,
                         double origin, double inv_span, int i) {
    const double ny = (lat_norm != nullptr)
        ? double(lat_norm[i])
        : ((double(pos_y[i]) - origin) * inv_span);
    return (ny < 0.0) ? 0.0 : ((ny > 1.0) ? 1.0 : ny);
}
