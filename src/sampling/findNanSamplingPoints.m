function res = findNanSamplingPoints(dataSource, options)
% findNanSamplingPoints  Find data entries with NaN metric values and extract unique geometry inputs.
%
%   res = findNanSamplingPoints(dataSource) scans the provided dataset,
%   finds all metric fields containing NaN values, extracts the unique
%   geometry inputs associated with those NaNs, and generates COMSOL-compatible
%   parameter sweep strings for re-iterating simulation on failed points.
%
%   res = findNanSamplingPoints(dataSource, Name=Value) allows customization.
%
%   Inputs:
%       dataSource - Can be:
%                    - Unified database struct (db) with .Sim
%                    - Struct of arrays (allData or db.Sim)
%                    - Samples struct (from loadSamplingData)
%                    - MATLAB table (from readSweepTable)
%                    - File path to .mat or .dat/.csv file
%
%   Name-Value Arguments:
%       InputNames  - Cell array of input parameter names (default: auto-detected)
%       MetricNames - Cell array of metric names (default: auto-detected)
%       ParamUnits  - Cell array of parameter units (default: auto-detected)
%       Precision   - Decimal precision for formatted output (default: 6)
%
%   Output Struct:
%       res.hasNans           - (logical) True if any NaNs were found in metrics
%       res.count             - (double) Number of unique geometry points with NaNs
%       res.uniquePoints      - [P×D] matrix of unique input parameter values
%       res.inputNames        - Cell array of detected/used input parameter names
%       res.inputUnits        - Cell array of parameter units
%       res.metricsWithNan    - Struct array detailing metrics that contain NaNs
%       res.pointList         - Array of structs describing each unique point
%       res.comsolParamString - String formatted for COMSOL Parametric Sweep
%       res.comsolTableString - String formatted for COMSOL Specified Combinations
%       res.totalNanRows      - Total rows/entries with NaNs
%       res.totalRows         - Total rows/entries in dataset
%
%   See also: exportToComsol, loadSamplingData, readSweepTable

arguments
    dataSource
    options.InputNames cell = {}
    options.MetricNames cell = {}
    options.ParamUnits cell = {}
    options.Precision (1,1) double {mustBePositive, mustBeInteger} = 6
end

    res = struct();
    res.hasNans = false;
    res.count = 0;
    res.uniquePoints = zeros(0, 0);
    res.inputNames = {};
    res.inputUnits = {};
    res.metricsWithNan = struct('name', {}, 'nanCount', {}, 'totalPoints', {});
    res.pointList = {};
    res.comsolParamString = "";
    res.comsolTableString = "";
    res.totalNanRows = 0;
    res.totalRows = 0;

    %% 1. Extract data struct / table
    [dataStruct, schema] = extractDataStruct(dataSource);
    if isempty(dataStruct)
        return;
    end

    %% 2. Determine number of rows / points
    numPoints = getRowCount(dataStruct);
    res.totalRows = numPoints;
    if numPoints == 0
        return;
    end

    %% 3. Identify input parameter names
    inputNames = options.InputNames;
    if isempty(inputNames)
        inputNames = detectInputNames(dataStruct, schema);
    end
    if isempty(inputNames)
        % Fallback
        if isfield(dataStruct, "period") && (isfield(dataStruct, "radius") || isfield(dataStruct, "particle_r"))
            if isfield(dataStruct, "particle_r")
                inputNames = {"period", "particle_r"};
            else
                inputNames = {"period", "radius"};
            end
        else
            inputNames = {"period", "radius"};
        end
    end
    res.inputNames = cellstr(inputNames);

    % Assign default units if not provided
    paramUnits = options.ParamUnits;
    if isempty(paramUnits)
        paramUnits = cell(1, numel(inputNames));
        for k = 1:numel(inputNames)
            pn = lower(string(inputNames{k}));
            if contains(pn, "period") || contains(pn, "radius") || contains(pn, "r") || ...
               contains(pn, "gap") || contains(pn, "thick") || contains(pn, "pitch") || ...
               contains(pn, "height") || contains(pn, "diameter")
                paramUnits{k} = "[nm]";
            elseif contains(pn, "angle")
                paramUnits{k} = "[deg]";
            else
                paramUnits{k} = "";
            end
        end
    end
    res.inputUnits = cellstr(paramUnits);

    %% 4. Extract input parameter values
    numInputs = numel(inputNames);
    inputMatrix = zeros(numPoints, numInputs);
    hasValidInputs = true;
    for k = 1:numInputs
        pName = inputNames{k};
        vals = getColumnValues(dataStruct, pName);
        if isempty(vals) || numel(vals) ~= numPoints
            hasValidInputs = false;
            break;
        end
        inputMatrix(:, k) = double(vals(:));
    end

    if ~hasValidInputs
        return;
    end

    %% 5. Identify metric fields
    metricNames = options.MetricNames;
    if isempty(metricNames)
        metricNames = detectMetricNames(dataStruct, schema, inputNames, numPoints);
    end
    if isempty(metricNames)
        return;
    end

    %% 6. Scan metrics for NaNs
    rowHasNan = false(numPoints, 1);
    metricsWithNan = struct('name', {}, 'nanCount', {}, 'totalPoints', {});
    metricNanMasks = struct();

    for k = 1:numel(metricNames)
        mName = metricNames{k};
        mVals = getColumnValues(dataStruct, mName);
        if isempty(mVals)
            continue;
        end

        % Check if 1D or 2D
        if isvector(mVals)
            mMask = isnan(double(mVals(:)));
        else
            mMask = any(isnan(double(mVals)), 2);
        end

        nanCount = nnz(mMask);
        if nanCount > 0
            metricsWithNan(end+1) = struct( ...
                'name', string(mName), ...
                'nanCount', nanCount, ...
                'totalPoints', numPoints); %#ok<AGROW>
            metricNanMasks.(mName) = mMask;
            rowHasNan = rowHasNan | mMask;
        end
    end

    res.metricsWithNan = metricsWithNan;
    res.totalNanRows = nnz(rowHasNan);

    if ~any(rowHasNan)
        return;
    end

    res.hasNans = true;

    %% 7. Extract unique geometry inputs with NaNs
    nanRows = find(rowHasNan);
    nanInputs = inputMatrix(nanRows, :);
    [uniquePoints, uniqueIdx, ~] = unique(nanInputs, 'rows', 'stable');

    res.count = size(uniquePoints, 1);
    res.uniquePoints = uniquePoints;

    %% 8. Build detailed record for each unique point
    nanMetricNames = {metricsWithNan.name};
    pointList = cell(res.count, 1);

    for p = 1:res.count
        origRow = nanRows(uniqueIdx(p));
        pointParams = struct();
        paramParts = cell(1, numInputs);
        for k = 1:numInputs
            pName = inputNames{k};
            pval = uniquePoints(p, k);
            pointParams.(pName) = pval;
            paramParts{k} = sprintf('%s=%.4g', pName, pval);
        end

        % Check which metrics failed for this point
        failedMetrics = string([]);
        for m = 1:numel(nanMetricNames)
            mn = char(nanMetricNames{m});
            if isfield(metricNanMasks, mn) && metricNanMasks.(mn)(origRow)
                failedMetrics(end+1) = string(mn); %#ok<AGROW>
            end
        end

        pointList{p} = struct( ...
            'id', p, ...
            'params', pointParams, ...
            'paramStr', strjoin(paramParts, ', '), ...
            'values', uniquePoints(p, :), ...
            'failedMetrics', failedMetrics);
    end
    res.pointList = pointList;

    %% 9. Generate COMSOL format strings
    res.comsolParamString = buildComsolParamString(uniquePoints, inputNames, paramUnits, options.Precision);
    res.comsolTableString = buildComsolTableString(uniquePoints, inputNames, paramUnits, options.Precision);

end

%% ========================================================================
%  Helper Functions
%% ========================================================================

function [dataStruct, schema] = extractDataStruct(dataSource)
    dataStruct = [];
    schema = [];

    if ischar(dataSource) || isstring(dataSource)
        fPath = string(dataSource);
        if ~isfile(fPath)
            return;
        end
        [~, ~, ext] = fileparts(fPath);
        if strcmpi(ext, ".mat")
            S = load(fPath);
            if isfield(S, "db") && isstruct(S.db)
                dataSource = S.db;
            elseif isfield(S, "allData") && isstruct(S.allData)
                dataStruct = S.allData;
                return;
            elseif isfield(S, "Sim") && isstruct(S.Sim)
                dataStruct = S.Sim;
                return;
            elseif isfield(S, "data") && isstruct(S.data)
                dataStruct = S.data;
                return;
            else
                dataStruct = S;
                return;
            end
        else
            % Table file (.dat / .csv / .txt)
            T = readSweepTable(fPath);
            dataStruct = table2struct(T, "ToScalar", true);
            return;
        end
    end

    if istable(dataSource)
        dataStruct = table2struct(dataSource, "ToScalar", true);
        return;
    end

    if isstruct(dataSource)
        % Check unified database
        if isfield(dataSource, "Sim") && isstruct(dataSource.Sim)
            dataStruct = dataSource.Sim;
            if isfield(dataSource, "Schema")
                schema = dataSource.Schema;
            end
            return;
        end
        if isfield(dataSource, "allData") && isstruct(dataSource.allData)
            dataStruct = dataSource.allData;
            if isfield(dataSource, "Schema")
                schema = dataSource.Schema;
            end
            return;
        end
        if isfield(dataSource, "samples") && isstruct(dataSource.samples)
            if isfield(dataSource.samples, "allData") && isstruct(dataSource.samples.allData)
                dataStruct = dataSource.samples.allData;
                return;
            else
                dataStruct = dataSource.samples;
                return;
            end
        end
        dataStruct = dataSource;
    end
end

function n = getRowCount(S)
    n = 0;
    if isempty(S) || ~isstruct(S)
        return;
    end
    fn = fieldnames(S);
    for k = 1:numel(fn)
        v = S.(fn{k});
        if isnumeric(v) || islogical(v)
            if ~isempty(v)
                n = size(v, 1);
                return;
            end
        end
    end
end

function vals = getColumnValues(S, colName)
    vals = [];
    if ~isstruct(S) || ~isfield(S, colName)
        return;
    end
    v = S.(colName);
    if isnumeric(v) || islogical(v)
        vals = v;
    end
end

function inputs = detectInputNames(S, schema)
    inputs = {};
    if ~isempty(schema) && isstruct(schema)
        for k = 1:numel(schema)
            if isfield(schema(k), "role") && string(schema(k).role) == "input"
                inputs{end+1} = char(schema(k).name); %#ok<AGROW>
            end
        end
        if ~isempty(inputs)
            return;
        end
    end

    inputPatterns = ["period", "particle_r", "radius", "p", "r", "gap", "thickness", ...
                     "angle", "height", "pitch", "diameter", "width"];
    fn = fieldnames(S);
    for k = 1:numel(fn)
        name = fn{k};
        if any(strcmpi(name, inputPatterns))
            v = S.(name);
            if isnumeric(v) && isvector(v)
                inputs{end+1} = name; %#ok<AGROW>
            end
        end
    end
end

function metrics = detectMetricNames(S, schema, inputNames, numRows)
    metrics = {};
    if ~isempty(schema) && isstruct(schema)
        for k = 1:numel(schema)
            if isfield(schema(k), "role") && string(schema(k).role) == "metric"
                metrics{end+1} = char(schema(k).name); %#ok<AGROW>
            end
        end
        if ~isempty(metrics)
            return;
        end
    end

    nonMetricPatterns = ["lambda", "lambda0", "wl", "wavelength", "freq", "frequency", ...
                         "omega", "f", "source", "laserwl", "stokeswindow", "shifts", ...
                         "ramanshift", "ramanwindow", "ramanwindoweffective"];

    fn = fieldnames(S);
    for k = 1:numel(fn)
        name = fn{k};
        if ismember(name, inputNames)
            continue;
        end
        if any(strcmpi(name, nonMetricPatterns))
            continue;
        end
        v = S.(name);
        if isnumeric(v) && size(v, 1) == numRows
            metrics{end+1} = name; %#ok<AGROW>
        end
    end
end

function str = buildComsolParamString(points, paramNames, paramUnits, precision)
% buildComsolParamString  Format for COMSOL Parametric Sweep (param "val1 val2..." unit).
    lines = cell(numel(paramNames), 1);
    numPts = size(points, 1);
    valFmt = sprintf('%%.%dg', precision);

    for col = 1:numel(paramNames)
        pname = char(paramNames{col});
        punit = '';
        if col <= numel(paramUnits) && ~isempty(paramUnits{col})
            punit = char(paramUnits{col});
        end

        vals = points(:, col)';
        valStrs = cell(1, numPts);
        for i = 1:numPts
            valStrs{i} = sprintf(valFmt, vals(i));
        end
        valList = strjoin(valStrs, ' ');

        if isempty(punit)
            lines{col} = sprintf('%s "%s"', pname, valList);
        else
            lines{col} = sprintf('%s "%s" %s', pname, valList, punit);
        end
    end
    str = string(strjoin(lines, newline));
end

function str = buildComsolTableString(points, paramNames, paramUnits, precision)
% buildComsolTableString  Format for COMSOL Specified Combinations table.
    headerCols = cell(1, numel(paramNames));
    for c = 1:numel(paramNames)
        pname = char(paramNames{c});
        if c <= numel(paramUnits) && ~isempty(paramUnits{c})
            headerCols{c} = sprintf('%s %s', pname, paramUnits{c});
        else
            headerCols{c} = pname;
        end
    end
    headerLine = sprintf('%% %s', strjoin(headerCols, '\t'));

    numPts = size(points, 1);
    numCols = size(points, 2);
    lines = cell(numPts + 1, 1);
    lines{1} = headerLine;
    valFmt = sprintf('%%.%dg', precision);

    for r = 1:numPts
        rowVals = cell(1, numCols);
        for c = 1:numCols
            rowVals{c} = sprintf(valFmt, points(r, c));
        end
        lines{r+1} = strjoin(rowVals, '\t');
    end
    str = string(strjoin(lines, newline));
end
