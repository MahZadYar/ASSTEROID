function [metrics, resolvedNames] = extractSamplingMetrics(dataSource, metricNames, numPoints)
% extractSamplingMetrics Extract 1D metric vectors for adaptive sampling.
%
%   [metrics, resolvedNames] = extractSamplingMetrics(dataSource, metricNames, numPoints)
%   extracts column vectors corresponding to each requested metric in metricNames
%   from dataSource (struct, table, or samples struct).
%
%   Inputs:
%       dataSource  - Struct, table, or samples struct containing data
%       metricNames - String array or cell array of metric names to extract
%       numPoints   - (Optional) Expected number of points/rows
%
%   Outputs:
%       metrics       - [numPoints x numMetrics] double matrix
%       resolvedNames - String array of actual field names used
%
%   See also: loadSamplingData, buildSamplingDensity, adaptiveSamplingConfig

if nargin < 2 || isempty(metricNames)
    if nargin >= 3 && ~isempty(numPoints)
        metrics = zeros(numPoints, 0);
    else
        metrics = zeros(0, 0);
    end
    resolvedNames = string.empty;
    return;
end

% Ensure metricNames is string array
if iscell(metricNames)
    while isscalar(metricNames) && iscell(metricNames{1})
        metricNames = metricNames{1};
    end
    metricNames = string(metricNames);
else
    metricNames = string(metricNames);
end
metricNames = metricNames(~ismissing(metricNames) & strlength(strtrim(metricNames)) > 0);
numMetrics = numel(metricNames);

% Unwrap dataSource
allData = struct();
predictions = [];

if istable(dataSource)
    allData = table2struct(dataSource, "ToScalar", true);
elseif isstruct(dataSource)
    if isfield(dataSource, "predictions") && ~isempty(dataSource.predictions)
        predictions = dataSource.predictions;
    end
    if isfield(dataSource, "allData") && isstruct(dataSource.allData) && ~isempty(fieldnames(dataSource.allData))
        allData = dataSource.allData;
    elseif isfield(dataSource, "Sim") && isstruct(dataSource.Sim)
        allData = dataSource.Sim;
    elseif isfield(dataSource, "data") && isstruct(dataSource.data)
        allData = dataSource.data;
    else
        allData = dataSource;
    end
end

% Determine numPoints if not provided
if nargin < 3 || isempty(numPoints) || numPoints <= 0
    if isfield(allData, "period") && ~isempty(allData.period)
        numPoints = numel(allData.period);
    elseif isfield(allData, "p") && ~isempty(allData.p)
        numPoints = numel(allData.p);
    else
        f = fieldnames(allData);
        numPoints = 0;
        for k = 1:numel(f)
            v = allData.(f{k});
            if isnumeric(v) && isvector(v) && numel(v) > 1
                numPoints = numel(v);
                break;
            end
        end
    end
end

metrics = zeros(numPoints, numMetrics);
resolvedNames = repmat("", 1, numMetrics);

dataFields = fieldnames(allData);

for i = 1:numMetrics
    mName = strtrim(char(metricNames(i)));
    if isempty(mName)
        continue;
    end
    
    found = false;
    val = [];
    actualName = "";
    
    % --- Strategy 1: Check allData struct ---
    if ~isempty(dataFields)
        % Build ordered search candidates for this metric
        candidates = getSearchCandidates(mName);
        
        for cIdx = 1:numel(candidates)
            cand = candidates{cIdx};
            fIdx = find(strcmpi(dataFields, cand), 1);
            if ~isempty(fIdx)
                fieldName = dataFields{fIdx};
                rawVal = allData.(fieldName);
                if ~isnumeric(rawVal)
                    rawVal = str2double(string(rawVal));
                end
                
                % If this candidate is a 2D matrix matching numPoints x K,
                % check if a 1D averaged alternative exists in candidates first
                if size(rawVal, 1) == numPoints && size(rawVal, 2) > 1
                    alt1dFound = false;
                    for altIdx = (cIdx+1):numel(candidates)
                        altCand = candidates{altIdx};
                        altFIdx = find(strcmpi(dataFields, altCand), 1);
                        if ~isempty(altFIdx)
                            altVal = allData.(dataFields{altFIdx});
                            if isnumeric(altVal) && numel(altVal) == numPoints
                                rawVal = altVal;
                                fieldName = dataFields{altFIdx};
                                alt1dFound = true;
                                break;
                            end
                        end
                    end
                    if ~alt1dFound
                        % Reduce 2D matrix to 1D via row-wise maximum
                        rawVal = max(double(rawVal), [], 2);
                    end
                end
                
                rawVal = double(rawVal(:));
                if numel(rawVal) == numPoints
                    val = rawVal;
                    actualName = string(fieldName);
                    found = true;
                    break;
                end
            end
        end
    end
    
    % --- Strategy 2: Check predictions struct if not found in allData ---
    if ~found && ~isempty(predictions) && isstruct(predictions)
        predCandidates = {mName, [mName, '_broad'], [mName, '_avg'], regexprep(mName, '_(broad|broadband|avg|laser|analyte|weighted|approx)$', '')};
        pFields = fieldnames(predictions);
        for pIdx = 1:numel(predCandidates)
            pCand = predCandidates{pIdx};
            matchIdx = find(strcmpi(pFields, pCand), 1);
            if ~isempty(matchIdx)
                pName = pFields{matchIdx};
                pVal = double(predictions.(pName));
                if ndims(pVal) == 3
                    val = mean(pVal, 3, "omitnan");
                    val = val(:);
                elseif ismatrix(pVal) && size(pVal, 1) == numPoints && size(pVal, 2) > 1
                    val = max(pVal, [], 2);
                else
                    val = pVal(:);
                end
                if numel(val) == numPoints
                    actualName = string(pName);
                    found = true;
                    break;
                end
            end
        end
    end
    
    if found && ~isempty(val)
        % Ensure clean finite numbers (replace NaN/Inf with 0)
        val(~isfinite(val)) = 0;
        metrics(:, i) = val;
        resolvedNames(i) = actualName;
    else
        warning("extractSamplingMetrics:MetricNotFound", ...
            "Metric '%s' not found in dataset. Using zeros.", mName);
        metrics(:, i) = zeros(numPoints, 1);
        resolvedNames(i) = string(mName);
    end
end

end

%% ========================================================================
function candidates = getSearchCandidates(mName)
% getSearchCandidates Build prioritized candidate field names for metric lookup.
candidates = {mName};

% Normalize key for alias lookups
baseKey = lower(regexprep(mName, '[^a-zA-Z0-9_]', ''));
stem = regexprep(baseKey, '_(broad|broadband|avg|laser|analyte|weighted|approx)$', '');

if contains(baseKey, "ee_v") || contains(baseKey, "ef_vol") || contains(baseKey, "bee_vol")
    if contains(baseKey, "laser") || contains(baseKey, "approx")
        candidates = [candidates, {'EE_V_laser', 'EF_vol_laser', 'EF_vol_approx', 'EE_V_broad', 'EF_vol_avg', 'EE_V', 'EF_vol'}];
    elseif contains(baseKey, "analyte") || contains(baseKey, "weighted") || contains(baseKey, "aee_vol")
        candidates = [candidates, {'EE_V_analyte', 'EF_vol_analyte', 'AEE_vol', 'aee_vol', 'EE_V_broad', 'EF_vol_avg', 'EE_V', 'EF_vol'}];
    elseif contains(baseKey, "bee")
        candidates = [candidates, {'BEE_vol', 'bee_vol', 'EE_V_broad', 'EF_vol_avg', 'EE_V', 'EF_vol', 'EE_V_laser', 'EF_vol_laser'}];
    else
        candidates = [candidates, {'EE_V_broad', 'EF_vol_avg', 'EE_V', 'EF_vol', 'BEE_vol', 'bee_vol', 'EE_V_laser', 'EF_vol_laser', 'EE_V_analyte', 'EF_vol_analyte'}];
    end
elseif contains(baseKey, "ee_s") || contains(baseKey, "ef_surf") || contains(baseKey, "bee_surf")
    if contains(baseKey, "laser") || contains(baseKey, "approx")
        candidates = [candidates, {'EE_S_laser', 'EF_surf_laser', 'EF_surf_approx', 'EE_S_broad', 'EF_surf_avg', 'EE_S', 'EF_surf'}];
    elseif contains(baseKey, "analyte") || contains(baseKey, "weighted") || contains(baseKey, "aee_surf")
        candidates = [candidates, {'EE_S_analyte', 'EF_surf_analyte', 'AEE_surf', 'aee_surf', 'EE_S_broad', 'EF_surf_avg', 'EE_S', 'EF_surf'}];
    elseif contains(baseKey, "bee")
        candidates = [candidates, {'BEE_surf', 'bee_surf', 'EE_S_broad', 'EF_surf_avg', 'EE_S', 'EF_surf', 'EE_S_laser', 'EF_surf_laser'}];
    else
        candidates = [candidates, {'EE_S_broad', 'EF_surf_avg', 'EE_S', 'EF_surf', 'BEE_surf', 'bee_surf', 'EE_S_laser', 'EF_surf_laser', 'EE_S_analyte', 'EF_surf_analyte'}];
    end
elseif contains(baseKey, "ef_max") || contains(baseKey, "m2_max")
    if contains(baseKey, "laser")
        candidates = [candidates, {'EF_max_laser', 'EF_laser_max', 'EF_max_broad', 'EF_max_avg', 'EF_max'}];
    elseif contains(baseKey, "analyte")
        candidates = [candidates, {'EF_max_analyte', 'EF_max_broad', 'EF_max_avg', 'EF_max'}];
    else
        candidates = [candidates, {'EF_max_broad', 'EF_max_avg', 'EF_max_laser', 'EF_max'}];
    end
elseif contains(baseKey, "abs")
    if contains(baseKey, "laser")
        candidates = [candidates, {'Abs_laser', 'Absorptance_laser', 'Abs_broad', 'Abs_avg', 'Absorptance_avg', 'Absorptance', 'Abs'}];
    elseif contains(baseKey, "analyte")
        candidates = [candidates, {'Abs_analyte', 'Absorptance_analyte', 'Abs_broad', 'Abs_avg', 'Absorptance_avg', 'Absorptance', 'Abs'}];
    else
        candidates = [candidates, {'Abs_broad', 'Abs_avg', 'Absorptance_broad', 'Absorptance_avg', 'Absorptance', 'Abs', 'Abs_laser'}];
    end
elseif contains(baseKey, "m_vol")
    candidates = [candidates, {'M_vol_laser', 'M_vol', 'm_vol'}];
elseif contains(baseKey, "m_surf")
    candidates = [candidates, {'M_surf_laser', 'M_surf', 'm_surf'}];
else
    % Generic fallback
    candidates = [candidates, {[mName, '_broad']}, {[mName, '_avg']}, {stem}, {[mName, '_laser']}];
end

candidates = unique(candidates, 'stable');
end
