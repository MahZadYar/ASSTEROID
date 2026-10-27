function metricName = canonicalMetricName(baseMetric, metricVariant)
%canonicalMetricName Build canonical metric field name from base + variant.
%   metricName = canonicalMetricName("EE_V", "laser")   -> "EE_V_laser"
%   metricName = canonicalMetricName("EE_V", "broad")   -> "EE_V_broad"
%   metricName = canonicalMetricName("EE_V", "analyte") -> "EE_V_analyte"
%   metricName = canonicalMetricName("EF_vol", "avg")   -> "EF_vol_avg"

    arguments
        baseMetric string
        metricVariant string = "broad"
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
        case {"broad", "broadband"}
            metricName = b + "_broad";
        case "avg"
            metricName = b + "_avg";
        otherwise
            metricName = b + "_broad";
    end
end
