function metricName = canonicalMetricName(baseMetric, metricVariant)
%canonicalMetricName Build canonical metric field name from base + variant.
%   metricName = canonicalMetricName("EE_V", "laser")   -> "EE_V_laser"
%   metricName = canonicalMetricName("EE_V", "broad")   -> "EE_V_broad"
%   metricName = canonicalMetricName("EE_V", "analyte") -> "EE_V_analyte"
%   metricName = canonicalMetricName("EE_V", "H2S")     -> "EE_V_H2S"
%   metricName = canonicalMetricName("EF_vol", "avg")   -> "EF_vol_avg"

    arguments
        baseMetric string
        metricVariant string = "broad"
    end

    b = string(baseMetric);
    if isempty(b)
        metricName = b;
        return;
    end

    parsed = parseMetricVariantName(metricVariant, IsVariantToken=true);
    if parsed.isVariantToken && strlength(parsed.variant) > 0
        sfx = "_" + parsed.variant;
    else
        sfx = "_broad";
    end

    metricName = strings(size(b));
    nonEmpty = strlength(b) > 0;
    metricName(nonEmpty) = b(nonEmpty) + sfx;
    metricName(~nonEmpty) = "";
end
