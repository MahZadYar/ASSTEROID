function samples = updateSamplesMetrics(samples, cfg)
%updateSamplesMetrics Update sampling metrics on samples structure.
%   samples = updateSamplesMetrics(samples, cfg) extracts metric values
%   from the sample points using the metric names specified in cfg.
%
%   Inputs:
%       samples - struct containing sampling dataset (.numPoints, etc.)
%       cfg     - struct containing .metricNames (string or cellstr array)
%
%   Outputs:
%       samples - struct with updated .metrics, .metricNames, .numMetrics,
%                 and .resolvedMetricNames fields.

    if isempty(samples)
        return;
    end
    if isempty(cfg) || ~isfield(cfg, "metricNames")
        return;
    end
    names = string(cfg.metricNames);
    if isempty(names)
        return;
    end
    nP = samples.numPoints;
    [metrics, resolvedNames] = extractSamplingMetrics(samples, names, nP);
    samples.metrics = metrics;
    samples.metricNames = cellstr(names);
    samples.numMetrics = numel(names);
    samples.resolvedMetricNames = resolvedNames;
end
