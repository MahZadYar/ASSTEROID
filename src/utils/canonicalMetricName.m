function metricName = canonicalMetricName(baseMetric, metricVariant)
%canonicalMetricName Build canonical metric field name from base + variant.
%   metricName = canonicalMetricName("EF_vol", "laser") → "EF_vol_laser"
%   metricName = canonicalMetricName("EF_vol", "analyte") → "EF_vol_analyte"
%   metricName = canonicalMetricName("EF_vol", "avg") → "EF_vol_avg"

    arguments
        baseMetric string
        metricVariant string = "avg"
    end

    b = string(baseMetric);
    v = lower(string(metricVariant));
    if strlength(b) == 0
        metricName = "";
        return;
    end
    switch v
        case "laser"
            metricName = b + "_laser";
        case {"weighted", "analyte"}
            metricName = b + "_analyte";
        otherwise
            metricName = b + "_avg";
    end
end
