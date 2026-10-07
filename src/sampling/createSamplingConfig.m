function cfg = createSamplingConfig(options)
% createSamplingConfig  Create configuration for adaptive parameter sampling.
%
%   cfg = createSamplingConfig() returns a struct with default sampling
%   configuration values for adaptive COMSOL parameter sweep generation.
%
%   cfg = createSamplingConfig(Name=Value) allows customization of specific
%   configuration fields using name-value arguments.
%
%   Configuration Fields:
%   ---------------------
%   Data Source:
%       dataFile        - Path to input data file (MAT or CSV)
%       fromPredictions - If true, load from DNN prediction file
%       predictionFile  - Path to prediction file (when fromPredictions=true)
%
%   Sampling Parameters:
%       numPoints       - Total number of points to generate (default: 100)
%       maxAttempts     - Maximum rejection sampling attempts (default: 1e6)
%       minSeparation   - Minimum distance between generated points (default: 0.2)
%       rtpThreshold    - Radius-to-period ratio threshold (default: 0.49)
%       uniformSampling - If true, use uniform density (default: true)
%
%   Parameter Ranges:
%       periodRange     - [min, max] bounds for period parameter
%       radiusRange     - [min, max] bounds for radius parameter
%       useManualRange  - If true, use specified ranges; else auto-detect
%
%   Metric Configuration:
%       metricNames     - Cell array of metric field names to use
%       metricWeights   - Weights for each metric (same length as metricNames)
%       metricAlphas    - Exponent for each metric (same length as metricNames)
%       overallExponent - Global exponent applied to combined metric
%       blurSigma       - Gaussian blur sigma for metric smoothing
%
%   Output:
%       outputFile      - Output filename for COMSOL parameter list
%       paramNames      - Names of parameters in output file
%       paramUnits      - Units for each parameter
%       includeOriginal - If true, include original data points in output
%
%   Example:
%       % Create config with custom settings
%       cfg = createSamplingConfig( ...
%           dataFile="sweep_data.mat", ...
%           numPoints=200, ...
%           periodRange=[400, 600], ...
%           radiusRange=[100, 200]);
%
%   See also: loadSamplingData, buildSamplingDensity, runAdaptiveSampling

arguments
    options.dataFile (1,1) string = ""
    options.fromPredictions (1,1) logical = false
    options.predictionFile (1,1) string = ""
    options.numPoints (1,1) double {mustBePositive, mustBeInteger} = 100
    options.maxAttempts (1,1) double {mustBePositive} = 1e6
    options.minSeparation (1,1) double {mustBeNonnegative} = 0.2
    options.rtpThreshold (1,1) double {mustBeNonnegative} = 0.49
    options.uniformSampling (1,1) logical = true
    options.periodRange (1,2) double = [NaN, NaN]
    options.radiusRange (1,2) double = [NaN, NaN]
    options.useManualRange (1,1) logical = false
    options.metricNames = {"EF_vol_avg"}
    options.metricWeights (1,:) double = 1
    options.metricAlphas (1,:) double = 1
    options.overallExponent (1,1) double = 1
    options.blurSigma (1,1) double {mustBeNonnegative} = 0
    options.outputFile (1,1) string = "adaptive_sweep_points.txt"
    options.paramNames = {"period", "particle_r"}
    options.paramUnits = {"[nm]", "[nm]"}
    options.includeOriginal (1,1) logical = false
    options.enforceOriginalSpacing (1,1) logical = false
    options.densityThreshold (1,1) double {mustBeNonnegative} = 0
    options.gridResolution (1,1) double {mustBePositive, mustBeInteger} = 1000
    options.xAxisParam (1,1) string = ""
    options.yAxisParam (1,1) string = ""
end

% Build configuration struct
cfg = struct();

% Data source settings
cfg.dataFile = options.dataFile;
cfg.fromPredictions = options.fromPredictions;
cfg.predictionFile = options.predictionFile;
cfg.xAxisParam = options.xAxisParam;
cfg.yAxisParam = options.yAxisParam;

% Sampling parameters
cfg.numPoints = options.numPoints;
cfg.maxAttempts = options.maxAttempts;
cfg.minSeparation = options.minSeparation;
cfg.rtpThreshold = options.rtpThreshold;
cfg.uniformSampling = options.uniformSampling;

% Allow environment variable override for uniform sampling
envUniform = getenv("SERS_UNIFORM_GENERATION");
if ~isempty(envUniform)
    envValue = str2double(envUniform);
    if ~isnan(envValue)
        cfg.uniformSampling = (envValue ~= 0);
    end
end

% Parameter range settings
cfg.periodRange = options.periodRange;
cfg.radiusRange = options.radiusRange;
cfg.useManualRange = options.useManualRange;

% Auto-detect if manual ranges should be used
if ~any(isnan(options.periodRange)) && ~any(isnan(options.radiusRange))
    cfg.useManualRange = true;
end

% Metric configuration
cfg.metricNames = cellstr(string(options.metricNames));
numMetrics = numel(cfg.metricNames);

cfg.metricWeights = expandToLength(options.metricWeights, numMetrics, "metricWeights");
cfg.metricAlphas = expandToLength(options.metricAlphas, numMetrics, "metricAlphas");
cfg.overallExponent = options.overallExponent;
cfg.blurSigma = options.blurSigma;

% Output settings
cfg.outputFile = options.outputFile;
cfg.paramNames = cellstr(string(options.paramNames));
cfg.paramUnits = cellstr(string(options.paramUnits));
cfg.includeOriginal = options.includeOriginal;
cfg.enforceOriginalSpacing = options.enforceOriginalSpacing;

% Advanced settings
cfg.densityThreshold = options.densityThreshold;
cfg.gridResolution = options.gridResolution;

end

function vec = expandToLength(value, targetLength, label)
% expandToLength  Expand scalar to vector or validate vector length.

vec = double(value);
if isscalar(vec) && targetLength > 1
    vec = repmat(vec, 1, targetLength);
end
if numel(vec) > targetLength
    vec = vec(1:targetLength);
elseif numel(vec) < targetLength
    vec = [vec(:)', ones(1, targetLength - numel(vec))];
end
vec = reshape(vec, 1, targetLength);
end
