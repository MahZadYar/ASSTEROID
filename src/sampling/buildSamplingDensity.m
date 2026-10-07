function density = buildSamplingDensity(cfg, samples)
% buildSamplingDensity  Construct sampling density function from data.
%
%   density = buildSamplingDensity(cfg, samples) builds an interpolated
%   density function that guides the adaptive sampling process. Higher
%   density regions have higher probability of generating sample points.
%
%   Input:
%       cfg     - Configuration struct from createSamplingConfig
%       samples - Samples struct from loadSamplingData
%
%   Output:
%       density - Struct containing:
%             - func: Function handle @(p, r) returning density values
%             - maxValue: Maximum density value for rejection sampling
%             - periodRange: [min, max] period bounds
%             - radiusRange: [min, max] radius bounds
%             - combinedMetric: [N×1] density values at sample points
%
%   The density function combines multiple metrics according to the
%   configuration weights and transformations:
%
%       D(p,r) = (sum_i w_i * M_i(p,r)^alpha_i)^overallExponent
%
%   where w_i are weights, alpha_i are per-metric exponents, and M_i are
%   normalized metric values.
%
%   Example:
%       cfg = createSamplingConfig(dataFile="data.mat", ...
%           metricNames={"EF_vol", "Absorptance"}, ...
%           metricWeights=[0.7, 0.3]);
%       samples = loadSamplingData(cfg);
%       density = buildSamplingDensity(cfg, samples);
%       % Query density at specific point
%       d = density.func(500, 150);
%
%   See also: createSamplingConfig, loadSamplingData, runAdaptiveSampling

arguments
    cfg (1,1) struct
    samples (1,1) struct
end

% Determine parameter ranges
[periodRange, radiusRange] = resolveRanges(cfg, samples);

% Compute combined metric at sample points
combinedMetric = computeCombinedMetric(cfg, samples, periodRange, radiusRange);

% Handle uniform sampling mode
if cfg.uniformSampling
    fprintf("Uniform sampling mode: using flat density.\n");
    finalMetric = ones(samples.numPoints, 1);
else
    finalMetric = combinedMetric;
end

% Clean up invalid values
finalMetric(~isfinite(finalMetric)) = 0;

if all(finalMetric == 0)
    error("buildSamplingDensity:ZeroDensity", ...
        "All density values are zero. Adjust metric weights or data.");
end

% Build interpolated density function
if cfg.uniformSampling
    densityFunc = @(p, r) ones(size(p));
else
    fprintf("Building interpolated density function...\n");
    interpolant = scatteredInterpolant( ...
        samples.period, samples.radius, finalMetric, ...
        "natural", "none");
    densityFunc = @(p, r) evaluateDensity(interpolant, p, r);
end

% Build output struct
density = struct();
density.func = densityFunc;
density.maxValue = 1;
density.periodRange = periodRange;
density.radiusRange = radiusRange;
density.combinedMetric = combinedMetric;
density.finalMetric = finalMetric;

end

%% ========================================================================
function [periodRange, radiusRange] = resolveRanges(cfg, samples)
% resolveRanges  Determine parameter bounds for sampling.

if cfg.useManualRange && ~any(isnan(cfg.periodRange)) && ~any(isnan(cfg.radiusRange))
    periodRange = cfg.periodRange;
    radiusRange = cfg.radiusRange;
else
    periodRange = [min(samples.period), max(samples.period)];
    radiusRange = [min(samples.radius), max(samples.radius)];
end

fprintf("Parameter ranges: period=[%.1f, %.1f], radius=[%.1f, %.1f]\n", ...
    periodRange(1), periodRange(2), radiusRange(1), radiusRange(2));
end

%% ========================================================================
function combinedMetric = computeCombinedMetric(cfg, samples, periodRange, radiusRange)
% computeCombinedMetric  Blend multiple metrics into unified density score.

% Determine in-region mask based on active parameter bounds
pMin = periodRange(1);
pMax = periodRange(2);
rMin = radiusRange(1);
rMax = radiusRange(2);

inRegion = (samples.period >= pMin) & (samples.period <= pMax) & ...
           (samples.radius >= rMin) & (samples.radius <= rMax);

if ~any(inRegion)
    inRegion = true(samples.numPoints, 1);
end

numMetrics = numel(cfg.metricNames);
combinedMetric = zeros(samples.numPoints, 1);

for i = 1:numMetrics
    metric = samples.metrics(:, i);
    
    % Normalize each individual metric to [0, 1] in the given region
    metric = normalizeInRegion(metric, inRegion);
    
    % Apply Gaussian blur if configured
    if cfg.blurSigma > 0
        metric = applyScatteredBlur(samples.period, samples.radius, metric, cfg.blurSigma);
        % Re-normalize to [0, 1] in the given region even after blur
        metric = normalizeInRegion(metric, inRegion);
    end
    
    % Apply per-metric exponent
    alpha = cfg.metricAlphas(i);
    if alpha ~= 1
        metric = metric .^ alpha;
        % Re-normalize after exponent to maintain [0, 1] in region
        metric = normalizeInRegion(metric, inRegion);
    end
    
    % Accumulate weighted contribution
    weight = cfg.metricWeights(i);
    combinedMetric = combinedMetric + weight * metric;
end

% Apply overall exponent
if cfg.overallExponent ~= 1
    combinedMetric = combinedMetric .^ cfg.overallExponent;
    combinedMetric = normalizeInRegion(combinedMetric, inRegion);
end

% Final density normalization to [0, 1] in the given region
combinedMetric = normalizeInRegion(combinedMetric, inRegion);

end

%% ========================================================================
function normalized = normalizeInRegion(values, inRegion)
% normalizeInRegion  Normalize values to [0, 1] range based on given region.

values(~isfinite(values)) = 0;

if nargin < 2 || isempty(inRegion) || ~any(inRegion)
    inRegion = true(size(values));
end

regionVals = values(inRegion);
minVal = min(regionVals, [], 'omitnan');
maxVal = max(regionVals, [], 'omitnan');

if isempty(minVal) || isempty(maxVal) || isnan(minVal) || isnan(maxVal) || (maxVal - minVal < eps)
    normalized = zeros(size(values));
else
    normalized = (values - minVal) / (maxVal - minVal);
    % Clamp to [0, 1] so points outside region do not exceed bounds
    normalized = max(0, min(1, normalized));
end
end

%% ========================================================================
function normalized = normalizeRange(values)
% normalizeRange  Normalize values to [0, 1] range across all elements.
normalized = normalizeInRegion(values, true(size(values)));
end

%% ========================================================================
function d = evaluateDensity(interpolant, p, r)
% evaluateDensity  Evaluate interpolant safely clamped to [0, 1].
d = interpolant(p, r);
d(~isfinite(d)) = 0;
d = max(0, min(1, d));
end

%% ========================================================================
function blurred = applyScatteredBlur(p, r, values, sigma)
% applyScatteredBlur  Apply Gaussian blur to scattered data points.
%
%   This is an approximation using a weighted average of nearby points.

blurred = values;
n = numel(values);

for i = 1:n
    distances = sqrt((p - p(i)).^2 + (r - r(i)).^2);
    weights = exp(-distances.^2 / (2 * sigma^2));
    weights(i) = 0;  % Exclude self
    
    if sum(weights) > eps
        blurred(i) = (values(i) + sum(weights .* values)) / (1 + sum(weights));
    end
end
end
