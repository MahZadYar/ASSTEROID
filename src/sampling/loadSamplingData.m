function samples = loadSamplingData(cfg)
% loadSamplingData  Load parameter sweep data for adaptive sampling.
%
%   samples = loadSamplingData(cfg) loads data based on the configuration
%   struct returned by createSamplingConfig. The function automatically
%   detects the data source type and loads accordingly.
%
%   Input:
%       cfg - Configuration struct from createSamplingConfig containing:
%             - dataFile: Path to MAT or CSV data file
%             - fromPredictions: If true, load from prediction file
%             - predictionFile: Path to DNN prediction file
%             - metricNames: Cell array of metric field names to extract
%
%   Output:
%       samples - Struct containing:
%             - period: [N×1] vector of period values
%             - radius: [N×1] vector of radius values
%             - metrics: [N×M] matrix of metric values (M = number of metrics)
%             - metricNames: Cell array of metric names
%             - allData: Original data struct (for reference)
%
%   Supported Data Formats:
%       - MAT files with 'allData' struct containing period/radius fields
%       - CSV/table files with period and radius columns
%       - DNN prediction files with 'predictions' struct
%
%   Example:
%       cfg = createSamplingConfig(dataFile="sweep_data.mat");
%       samples = loadSamplingData(cfg);
%       disp(samples.period);
%
%   See also: createSamplingConfig, buildSamplingDensity

arguments
    cfg (1,1) struct
end

if cfg.fromPredictions
    samples = loadFromPredictions(cfg);
else
    samples = loadFromDataFile(cfg);
end

% Validate output structure
validateSamples(samples);

end

%% ========================================================================
function samples = loadFromDataFile(cfg)
% loadFromDataFile  Load samples from MAT or CSV data file.

if isempty(cfg.dataFile) || cfg.dataFile == ""
    error("loadSamplingData:NoDataFile", ...
        "No data file specified in configuration. Set cfg.dataFile.");
end

fprintf("Loading data from: %s\n", cfg.dataFile);

if isstruct(cfg.dataFile)
    allData = cfg.dataFile;
elseif istable(cfg.dataFile)
    allData = table2struct(cfg.dataFile, "ToScalar", true);
else
    [~, ~, ext] = fileparts(cfg.dataFile);
    if strcmpi(ext, ".mat")
        allData = loadMatFile(cfg.dataFile);
    else
        allData = loadTableFile(cfg.dataFile);
    end
end

% If allData is a container struct with .Sim (e.g. database struct db.Sim)
if isstruct(allData) && isfield(allData, "Sim") && isstruct(allData.Sim)
    allData = allData.Sim;
elseif isstruct(allData) && isfield(allData, "allData") && isstruct(allData.allData)
    allData = allData.allData;
elseif isstruct(allData) && isfield(allData, "data") && isstruct(allData.data)
    allData = allData.data;
end

% Extract geometry parameters
[period, radius] = extractGeometry(allData, cfg);
numPoints = numel(period);

% Reduce multi-dimensional fields to maximums so they match expected 1D size
fnames = fieldnames(allData);
for k = 1:numel(fnames)
    fn = fnames{k};
    fData = allData.(fn);
    if isnumeric(fData) && size(fData, 1) == numPoints && size(fData, 2) > 1
        allData.(fn) = max(fData, [], 2);
    end
end

% Extract metric values
metrics = extractSamplingMetrics(allData, cfg.metricNames, numPoints);

% Build output struct
samples = struct();
samples.period = period;
samples.radius = radius;
samples.metrics = metrics;
samples.metricNames = cfg.metricNames;
samples.allData = allData;
samples.numPoints = numel(period);

fprintf("Loaded %d data points with %d metrics.\n", samples.numPoints, numel(cfg.metricNames));
end

%% ========================================================================
function samples = loadFromPredictions(cfg)
% loadFromPredictions  Load samples from DNN prediction file.

if isempty(cfg.predictionFile) || cfg.predictionFile == ""
    error("loadSamplingData:NoPredictionFile", ...
        "No prediction file specified. Set cfg.predictionFile.");
end

fprintf("Loading predictions from: %s\n", cfg.predictionFile);

S = load(cfg.predictionFile, "predictions", "pSamples", "rSamples");

if ~isfield(S, "predictions")
    error("loadSamplingData:InvalidPredictionFile", ...
        "Prediction file must contain 'predictions' variable.");
end

predictions = S.predictions;
pSamples = S.pSamples;
rSamples = S.rSamples;

% Create grid of all (p, r) combinations
[PGrid, RGrid] = meshgrid(pSamples, rSamples);
period = PGrid(:) * 1e3;  % Convert um to nm
radius = RGrid(:) * 1e3;  % Convert um to nm

% Extract metrics from predictions using robust extractor
metrics = extractSamplingMetrics(struct("predictions", predictions), cfg.metricNames, numel(period));

% Populate allData with geometry and prediction metric fields for subsequent re-extraction
predData = struct("period", period, "radius", radius);
predFields = fieldnames(predictions);
for pIdx = 1:numel(predFields)
    pName = predFields{pIdx};
    pVal = double(predictions.(pName));
    if ndims(pVal) == 3
        predData.(pName) = mean(pVal, 3, "omitnan");
        predData.([pName, '_avg']) = predData.(pName)(:);
    elseif ismatrix(pVal) && size(pVal, 1) == numel(period)
        predData.(pName) = pVal;
    end
end
for mIdx = 1:numel(cfg.metricNames)
    cleanMName = matlab.lang.makeValidName(char(cfg.metricNames{mIdx}));
    predData.(cleanMName) = metrics(:, mIdx);
end

% Build output struct
samples = struct();
samples.period = period;
samples.radius = radius;
samples.metrics = metrics;
samples.metricNames = cfg.metricNames;
samples.predictions = predictions;
samples.allData = predData;
samples.numPoints = numel(period);

fprintf("Loaded %d prediction points with %d metrics.\n", samples.numPoints, numel(cfg.metricNames));
end

%% ========================================================================
function allData = loadMatFile(filename)
% loadMatFile  Load allData struct from MAT file.

S = load(filename);

if isfield(S, "allData")
    allData = S.allData;
elseif isfield(S, "data")
    allData = S.data;
elseif isfield(S, "db") && isstruct(S.db)
    if isfield(S.db, "Sim") && isstruct(S.db.Sim)
        allData = S.db.Sim;
    else
        allData = S.db;
    end
else
    % Try to use the first struct variable found
    fnames = fieldnames(S);
    foundStruct = false;
    for i = 1:numel(fnames)
        if isstruct(S.(fnames{i}))
            allData = S.(fnames{i});
            if isfield(allData, "Sim") && isstruct(allData.Sim)
                allData = allData.Sim;
            end
            foundStruct = true;
            warning("loadSamplingData:InferredVariable", ...
                "Using variable '%s' as data source.", fnames{i});
            break;
        end
    end
    if ~foundStruct
        error("loadSamplingData:NoDataStruct", ...
            "MAT file must contain 'allData' or 'data' struct.");
    end
end
end

%% ========================================================================
function allData = loadTableFile(filename)
% loadTableFile  Load data from CSV or table file.

opts = detectImportOptions(filename);
opts = setvaropts(opts, opts.VariableNames, "TreatAsMissing", {"", "NA", "NaN"});
T = readtable(filename, opts);

% Sanitize variable names
T.Properties.VariableNames = matlab.lang.makeValidName( ...
    T.Properties.VariableNames, "ReplacementStyle", "delete");

% Convert table to struct
allData = struct();
varNames = T.Properties.VariableNames;
for k = 1:numel(varNames)
    rawVals = T{:, k};
    if isnumeric(rawVals)
        allData.(varNames{k}) = double(rawVals(:));
    else
        allData.(varNames{k}) = str2double(string(rawVals(:)));
    end
end
end

%% ========================================================================
function [period, radius] = extractGeometry(allData, cfg)
% extractGeometry  Extract period and radius vectors from data struct.

if nargin < 2
    cfg = struct();
end

% Check if cfg specified axis parameters
xParam = "";
yParam = "";
if isfield(cfg, "xAxisParam") && strlength(string(cfg.xAxisParam)) > 0
    xParam = string(cfg.xAxisParam);
end
if isfield(cfg, "yAxisParam") && strlength(string(cfg.yAxisParam)) > 0
    yParam = string(cfg.yAxisParam);
end

periodCandidates = {"period", "p", "periodicity"};
if strlength(xParam) > 0
    periodCandidates = [{char(xParam)}, periodCandidates];
end

radiusCandidates = {"radius", "r", "particle_r"};
if strlength(yParam) > 0
    radiusCandidates = [{char(yParam)}, radiusCandidates];
end

% Find period field (case-insensitive)
periodField = findFieldIgnoreCase(allData, periodCandidates);
% Find radius field (case-insensitive)
radiusField = findFieldIgnoreCase(allData, radiusCandidates);

% Fallback: if either not found, look for numeric vector fields of same length
if isempty(periodField) || isempty(radiusField)
    fnames = fieldnames(allData);
    vecFields = {};
    for k = 1:numel(fnames)
        fn = fnames{k};
        val = allData.(fn);
        if isnumeric(val) && isvector(val) && numel(val) > 1
            vecFields{end+1} = fn; %#ok<AGROW>
        end
    end
    if isempty(periodField) && numel(vecFields) >= 1
        periodField = vecFields{1};
    end
    if isempty(radiusField) && numel(vecFields) >= 2
        diffIdx = find(~strcmp(vecFields, periodField), 1);
        if ~isempty(diffIdx)
            radiusField = vecFields{diffIdx};
        end
    end
end

if isempty(periodField) || strlength(string(periodField)) == 0
    error("loadSamplingData:NoPeriodField", ...
        "Data must contain a 'period' or input parameter field.");
end

if isempty(radiusField) || strlength(string(radiusField)) == 0
    error("loadSamplingData:NoRadiusField", ...
        "Data must contain a 'radius' or input parameter field.");
end

period = double(allData.(periodField)(:));
radius = double(allData.(radiusField)(:));

if numel(period) ~= numel(radius)
    error("loadSamplingData:SizeMismatch", ...
        "Period (%d) and radius (%d) must have same length.", ...
        numel(period), numel(radius));
end
end

%% ========================================================================
function fieldName = findFieldIgnoreCase(S, candidates)
% findFieldIgnoreCase  Find field name matching any candidate (case-insensitive).

fieldName = '';
if isempty(S) || ~isstruct(S), return; end
fnames = fieldnames(S);

if ischar(candidates) || isstring(candidates)
    candidates = cellstr(candidates);
elseif iscell(candidates)
    candidates = cellfun(@char, candidates, 'UniformOutput', false);
end

% Pass 1: exact or case-insensitive match against candidates
for i = 1:numel(candidates)
    c = char(strtrim(candidates{i}));
    if isempty(c), continue; end
    idx = find(strcmpi(fnames, c), 1);
    if ~isempty(idx)
        fieldName = fnames{idx};
        return;
    end
end

% Pass 2: alias and suffix matching (e.g. EF_vol <-> EF_vol_avg <-> BEE_vol)
for i = 1:numel(candidates)
    c = char(strtrim(candidates{i}));
    if isempty(c), continue; end
    
    altCandidates = { ...
        [c, '_avg'], ...
        regexprep(c, '_(avg|laser|analyte|approx)$', ''), ...
        [c, '_laser'], ...
        [c, '_analyte'] ...
    };
    if strcmpi(c, 'EF_vol') || strcmpi(c, 'EF_vol_avg')
        altCandidates = [altCandidates, {'BEE_vol', 'bee_vol'}];
    elseif strcmpi(c, 'EF_surf') || strcmpi(c, 'EF_surf_avg')
        altCandidates = [altCandidates, {'BEE_surf', 'bee_surf'}];
    elseif strcmpi(c, 'BEE_vol')
        altCandidates = [altCandidates, {'EF_vol_avg', 'EF_vol'}];
    elseif strcmpi(c, 'BEE_surf')
        altCandidates = [altCandidates, {'EF_surf_avg', 'EF_surf'}];
    end
    
    for j = 1:numel(altCandidates)
        candJ = char(altCandidates{j});
        idx = find(strcmpi(fnames, candJ), 1);
        if ~isempty(idx)
            fieldName = fnames{idx};
            return;
        end
    end
end
end

%% ========================================================================
function metrics = extractMetrics(allData, metricNames, numPoints)
% extractMetrics  Extract metric values as matrix from data struct.
metrics = extractSamplingMetrics(allData, metricNames, numPoints);
end

%% ========================================================================
function metrics = extractMetricsFromPredictions(predictions, metricNames, numPoints)
% extractMetricsFromPredictions  Extract metrics from prediction struct.

if isempty(metricNames)
    metrics = zeros(numPoints, 0);
    return;
end

numMetrics = numel(metricNames);
metrics = zeros(numPoints, numMetrics);

for i = 1:numMetrics
    metricName = metricNames{i};
    fieldName = matlab.lang.makeValidName(metricName);
    avgFieldName = matlab.lang.makeValidName([metricName, "_avg"]);
    
    % Prefer averaged field if available
    if isfield(predictions, avgFieldName)
        values = double(predictions.(avgFieldName)(:));
    elseif isfield(predictions, fieldName)
        field3D = double(predictions.(fieldName));
        values = mean(field3D, 3, "omitnan");
        values = values(:);
    else
        warning("loadSamplingData:PredictionMetricNotFound", ...
            "Metric '%s' not found in predictions. Using zeros.", metricName);
        values = zeros(numPoints, 1);
    end
    
    if numel(values) ~= numPoints
        error("loadSamplingData:PredictionSizeMismatch", ...
            "Metric '%s' has %d entries but expected %d.", ...
            metricName, numel(values), numPoints);
    end
    
    metrics(:, i) = values;
end
end

%% ========================================================================
function validateSamples(samples)
% validateSamples  Validate loaded samples structure.

requiredFields = {"period", "radius", "metrics", "numPoints"};
for i = 1:numel(requiredFields)
    if ~isfield(samples, requiredFields{i})
        error("loadSamplingData:InvalidOutput", ...
            "Samples struct missing required field: %s", requiredFields{i});
    end
end

if samples.numPoints == 0
    error("loadSamplingData:NoData", "No data points loaded.");
end
end
