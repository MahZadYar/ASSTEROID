function [resultsOut, resultsWeightedOut] = audit_simulation_consistency(varargin)
% AUDIT_SIMULATION_CONSISTENCY
% Filename-agnostic and content-agnostic simulation consistency diagnostic suite
% for COMSOL / tabular parameter sweeps (supports arbitrary file lists, column
% orders, metric schemas, and optional spatial ROI filtering).
%
% USAGE:
%   audit_simulation_consistency();                                    % Default files in Data/Raw
%   audit_simulation_consistency(fileList);                            % Explicit list/glob/folder of files
%   audit_simulation_consistency(fileList, pRange, rRange);            % Explicit files + spatial ROI
%   audit_simulation_consistency(pRange);                              % Default files + Axis-1 ROI [min, max]
%   audit_simulation_consistency(pRange, rRange);                      % Default files + Axis-1 & Axis-2 ROI
%   audit_simulation_consistency(pRange, rRange, fileList);            % Spatial ROI + explicit file list
%   audit_simulation_consistency(..., 'LaserWavelength', 785.0);       % Optional Name-Value overrides
%
% SUPPORTED NAME-VALUE OPTIONS:
%   'Files'            : string array, cellstr, char path/glob/folder, or dir() struct
%   'pRange'           : 2-element vector [min, max] filtering Axis-1 coordinate
%   'rRange'           : 2-element vector [min, max] filtering Axis-2 coordinate
%   'LaserWavelength'  : target spectral value (default: 785.0 nm, auto-falls back if absent)
%   'WavelengthTol'    : spectral matching tolerance (default: 1e-3)
%   'GeomTol'          : coordinate duplicate tolerance (default: 1e-3)
%   'IncludeAuxiliary' : include diagnostic/analytical check columns like ECC, kappa_V/S (default: false unless only columns available)
%
% EXAMPLES:
%   audit_simulation_consistency({'runA.dat', 'runB.dat'});
%   audit_simulation_consistency(["batch1.dat", "batch2.dat", "batch3.dat"], [400, 906.44], [100, 300]);
%   audit_simulation_consistency('Data/Raw/Sweep*.dat', [800, 1000]);
%
% OUTPUT FIGURES:
%   Figure 1: Probability Density Distributions (PDF: Unweighted Solid vs. Voronoi-Weighted Dashed)
%   Figure 2: Cumulative Distribution Functions (CDF: Unweighted Solid vs. Voronoi-Weighted Dashed)
%   Figure 3: Mean Baseline Carpets (Dynamic Grid, Log Scale Colors)
%   Figure 4: Decadic Logarithmic Error Carpets (Dynamic Grid, Log Scale Colors)
%   Figure 5: Absolute Error Carpets (Dynamic Grid, Log Scale Colors)
%   Figure 6: Bounded Voronoi Cell Area Carpets (Spatial Sampling Density)
%   Figure 7: Publication-Ready Error Distributions (Fira Typography: (a) Absolute, (b) Relative %)

clc; close all;

%% 1. Parse Arguments, Workspace Fallbacks & Paths
scriptDir   = fileparts(mfilename('fullpath'));
projectRoot = fullfile(scriptDir, '..', '..', '..');
cmapFile    = fullfile(scriptDir, '..', 'src', 'vis', 'AssteroidColormap.txt');

% Make ASSTEROID table/schema utilities available when present in repo
assteroidSrc = fullfile(scriptDir, '..', 'src');
if isfolder(assteroidSrc) && ~exist('defaultComsolVarNames', 'file')
    addpath(fullfile(assteroidSrc, 'io'), fullfile(assteroidSrc, 'utils'));
end

[inputFilesSpec, pRange, rRange, opts] = parseDiagnosticInputs(varargin{:});
[filePaths, sourceLabels] = resolveInputFileList(inputFilesSpec, projectRoot);

numFiles = numel(filePaths);
if numFiles < 2
    error('audit_simulation_consistency:NeedMultipleFiles', ...
        'At least 2 simulation files are required for consistency comparison (resolved %d).', numFiles);
end

hasFilter1 = ~isempty(pRange) && ~all(isinf(pRange));
hasFilter2 = ~isempty(rRange) && ~all(isinf(rRange));
if hasFilter1, x1Min = min(pRange); x1Max = max(pRange); else, x1Min = -inf; x1Max = inf; end
if hasFilter2, x2Min = min(rRange); x2Max = max(rRange); else, x2Min = -inf; x2Max = inf; end

fprintf('========================================================================================\n');
fprintf('  AGNOSTIC SIMULATION DUPLICATE ERROR & VORONOI REPEATABILITY AUDIT (%d Input Files)\n', numFiles);
fprintf('  Coordinate Tolerance: %.1e | Spectral Target: %.2f (tol %.1e)\n', ...
    opts.geomTol, opts.laserWlTarget, opts.wlTol);
if hasFilter1 || hasFilter2
    fprintf('  Spatial ROI Filter: Axis-1 in [%.1f, %.1f] | Axis-2 in [%.1f, %.1f]\n', x1Min, x1Max, x2Min, x2Max);
end
fprintf('========================================================================================\n\n');

%% 2. Load All Simulation Files Agnostically (Header & Schema Inference)
fprintf('[1/5] Loading and parsing %d simulation table(s) agnostically...\n', numFiles);
datasets = repmat(struct('path', '', 'label', '', 'table', table(), 'schema', struct(), ...
    'rows', table(), 'coord1', [], 'coord2', []), numFiles, 1);

for fIdx = 1:numFiles
    tRead = tic;
    [T, schema] = loadAgnosticSweepTable(filePaths{fIdx});
    datasets(fIdx).path   = filePaths{fIdx};
    datasets(fIdx).label  = sourceLabels{fIdx};
    datasets(fIdx).table  = T;
    datasets(fIdx).schema = schema;

    metricPreview = strjoin(schema.metricCols, ', ');
    if isempty(metricPreview), metricPreview = '(none)'; end
    fprintf('      [%d] %-18s : %7d rows x %2d cols | Coords: (%s, %s) | Spectral: %-8s | Metrics: {%s} (%.2f s)\n', ...
        fIdx, sourceLabels{fIdx}, height(T), width(T), ...
        schema.coordCols{1}, schema.coordCols{2}, ...
        ternaryStr(isempty(schema.spectralCol), 'none', schema.spectralCol), ...
        metricPreview, toc(tRead));
end

axis1Name = datasets(1).schema.coordCols{1};
axis2Name = datasets(1).schema.coordCols{2};
axis1Label = formatCoordinateAxisLabel(axis1Name, 1);
axis2Label = formatCoordinateAxisLabel(axis2Name, 2);

%% 3. Spectral Filtering & Spatial ROI Subsetting
fprintf('\n[2/5] Filtering spectral target & spatial ROI...\n');
activeSpectral = resolveTargetWavelength(datasets, opts);

for fIdx = 1:numFiles
    T = datasets(fIdx).table;
    sc = datasets(fIdx).schema;

    if ~isempty(sc.spectralCol) && isfinite(activeSpectral)
        lamVals = T.(sc.spectralCol);
        maskSpec = abs(lamVals - activeSpectral) <= opts.wlTol;
        T = T(maskSpec, :);
    end

    c1 = T.(sc.coordCols{1});
    c2 = T.(sc.coordCols{2});
    maskGeom = isfinite(c1) & isfinite(c2);
    if hasFilter1, maskGeom = maskGeom & (c1 >= x1Min) & (c1 <= x1Max); end
    if hasFilter2, maskGeom = maskGeom & (c2 >= x2Min) & (c2 <= x2Max); end
    T = T(maskGeom, :);

    % Deduplicate internal identical coordinates per dataset cleanly
    coords = [T.(sc.coordCols{1}), T.(sc.coordCols{2})];
    [~, uIdx] = unique(round(coords * 1e4), 'rows', 'stable');
    T = T(uIdx, :);

    datasets(fIdx).rows   = T;
    datasets(fIdx).coord1 = T.(sc.coordCols{1});
    datasets(fIdx).coord2 = T.(sc.coordCols{2});
    fprintf('      [%d] %-18s : %d unique geometry rows in active domain\n', fIdx, datasets(fIdx).label, height(T));
end

%% 4. Cross-File Duplicate Matching & Dynamic Metric Discovery
fprintf('\n[3/5] Discovering shared metrics & matching duplicate geometries (tol = %.1e)...\n', opts.geomTol);
[metricNames, metricData, pairLog] = matchAllPairsAndDiscoverMetrics(datasets, opts);

if isempty(metricNames)
    error('check_simulation_duplicate_error:NoMatchedMetrics', ...
        'No shared metrics with >= 4 matched duplicate geometries found across the provided files.');
end

for pIdx = 1:numel(pairLog)
    fprintf('      Pair %-28s : %5d matched geometries | Shared: {%s}\n', ...
        pairLog(pIdx).pairLabel, pairLog(pIdx).numMatched, strjoin(pairLog(pIdx).metrics, ', '));
end
fprintf('      Active metrics ordered for analysis (%d): {%s}\n', numel(metricNames), strjoin(metricNames, ', '));

%% 5. Bounded 2D Voronoi Tessellations (Cached per Distinct Geometry Domain)
fprintf('\n[4/5] Computing bounded 2D Voronoi cell areas for spatial density normalization...\n');
[voronoiDomains, metricDomainIdx] = computeCachedVoronoiDomains(metricData, metricNames);

for d = 1:numel(voronoiDomains)
    vd = voronoiDomains(d);
    fprintf('      Domain %d [%s] (%d cells, %.2f s):\n', d, vd.sourceLabel, numel(vd.areas), vd.elapsedSec);
    fprintf('        Hull area: %.2f | Cell area min=%.4f, med=%.4f, mean=%.4f, max=%.4f | Contrast=%.1fx | N_eff=%.1f/%d (%.1f%%)\n', ...
        vd.hullArea, min(vd.areas), median(vd.areas), mean(vd.areas), max(vd.areas), ...
        max(vd.areas)/min(vd.areas), vd.nEff, numel(vd.areas), (vd.nEff/numel(vd.areas))*100);
end

%% 6. Compute Statistical & Correlation Metrics
fprintf('\n[5/5] Computing unweighted and Voronoi density-normalized error metrics...\n\n');
results = struct();
resultsWeighted = struct();

for i = 1:numel(metricNames)
    mName = metricNames{i};
    md    = metricData.(mName);
    vd    = voronoiDomains(metricDomainIdx(i));

    results.(mName)         = computeMetricErrorStruct(mName, md.y1, md.y2, md.c1, md.c2, md.sourceLabel, []);
    results.(mName).voronoiArea = vd.areas;
    resultsWeighted.(mName) = computeMetricErrorStruct(mName, md.y1, md.y2, md.c1, md.c2, md.sourceLabel, vd.weights);
    resultsWeighted.(mName).voronoiArea = vd.areas;
end

% Formatted summary tables (DRY unified formatter)
printErrorSummaryTable('SET I: UNWEIGHTED (RAW SAMPLE) STATISTICAL ERROR SUMMARY', metricNames, results, false, false);
printErrorSummaryTable('SET I: UNWEIGHTED (RAW SAMPLE) LOGARITHMIC ERROR METRICS', metricNames, results, false, true);
printErrorSummaryTable('SET II: VORONOI AREA-WEIGHTED STATISTICAL ERROR SUMMARY', metricNames, resultsWeighted, true, false);
printErrorSummaryTable('SET II: VORONOI AREA-WEIGHTED LOGARITHMIC ERROR METRICS', metricNames, resultsWeighted, true, true);
printBaselineComparisonTable(metricNames, results, resultsWeighted);

% Dynamic cross-correlations for M >= 2 shared metrics
numMetrics = numel(metricNames);
if numMetrics >= 2
    [B_raw, E_raw, pCommon, rCommon, numCommon] = buildCommonIntersectionMatrices(results, metricNames);
    if numCommon >= 4
        wCommon = computeVoronoiAreaWeights(pCommon, rCommon);

        B_log = log10(max(B_raw, eps));
        E_log = log10(max(E_raw, eps));

        R_cross = corr(B_log, E_log);
        R_err   = corr(E_log, E_log);
        R_base  = corr(B_log, B_log);

        R_cross_W = computeWeightedCorrMatrix(B_log, E_log, wCommon);
        R_err_W   = computeWeightedCorrMatrix(E_log, E_log, wCommon);
        R_base_W  = computeWeightedCorrMatrix(B_log, B_log, wCommon);

        results.correlations = struct('numCommonGeom', numCommon, 'metricLabels', {metricNames}, ...
            'R_cross', R_cross, 'R_err', R_err, 'R_base', R_base);
        resultsWeighted.correlations = struct('numCommonGeom', numCommon, 'metricLabels', {metricNames}, ...
            'weights', wCommon, 'R_cross', R_cross_W, 'R_err', R_err_W, 'R_base', R_base_W);

        printCorrelationTables('SET I: UNWEIGHTED (RAW SAMPLE)', metricNames, R_cross, R_err, R_base, numCommon);
        printCorrelationTables('SET II: VORONOI AREA-WEIGHTED (DENSITY-NORMALIZED)', metricNames, R_cross_W, R_err_W, R_base_W, numCommon);
    else
        fprintf('[Note] Common geometric intersection across all %d metrics has N=%d (< 4); skipping cross-correlation matrices.\n\n', ...
            numMetrics, numCommon);
    end
else
    fprintf('[Note] Only 1 shared metric discovered (%s); skipping cross-metric correlation matrices.\n\n', metricNames{1});
end

%% 7. Diagnostic Visualizations (Rule 05 OKHSL Standards & Fira Typography)
[fontText, fontMath] = resolveFiraFonts();
cmapSeq = resolveSequentialColormap(cmapFile);

% Build dynamic style metadata (diagnostic order vs publication order)
curveStyles = cell(1, numMetrics);
for i = 1:numMetrics
    mName = metricNames{i};
    st = getMetricVisualStyle(mName, i, false);
    curveStyles{i} = struct('name', mName, 'field', mName, 'color', st.color, 'style', '-', 'label', st.label);
end

pubOrder = orderMetricsForPublication(metricNames);
pubStyles = cell(1, numel(pubOrder));
for i = 1:numel(pubOrder)
    mName = pubOrder{i};
    st = getMetricVisualStyle(mName, i, true);
    pubStyles{i} = struct('name', mName, 'field', mName, 'color', st.color, 'label', st.label);
end

deltaSym = char(916); % Unicode Delta (avoids MATLAB Computer Modern \Delta fallback)

% FIGURE 1: 1x3 Probability Density Distributions (PDF)
fig1 = figure('Name', 'Figure 1: Probability Density Distributions (PDF: Unweighted Solid vs. Voronoi-Weighted Dashed)', ...
    'Position', [30, 520, 1750, 480]);
renderDistributionComparison(subplot(1, 3, 1), results, resultsWeighted, curveStyles, 'yAvg', 'auto', ...
    'Mean Baseline Value y_{avg}', '(a) Mean Baseline Probability Density', 'pdf', fontText, fontMath);
renderDistributionComparison(subplot(1, 3, 2), results, resultsWeighted, curveStyles, 'logDiff', 'auto', ...
    sprintf('Decadic Log Error |%slog_{10}| (dex)', deltaSym), '(b) Decadic Logarithmic Error Probability Density', 'pdf', fontText, fontMath);
renderDistributionComparison(subplot(1, 3, 3), results, resultsWeighted, curveStyles, 'absDiff', 'auto', ...
    sprintf('Absolute Discrepancy |%sy|', deltaSym), '(c) Absolute Error Probability Density', 'pdf', fontText, fontMath);
applyFigureFont(fig1, fontText);
drawnow;

% FIGURE 2: 1x3 Cumulative Distribution Functions (CDF)
fig2 = figure('Name', 'Figure 2: Cumulative Distribution Functions (CDF: Unweighted Solid vs. Voronoi-Weighted Dashed)', ...
    'Position', [30, 40, 1750, 480]);
renderDistributionComparison(subplot(1, 3, 1), results, resultsWeighted, curveStyles, 'yAvg', 'auto', ...
    'Mean Baseline Value y_{avg}', '(a) Mean Baseline Cumulative Distribution (CDF)', 'cdf', fontText, fontMath);
renderDistributionComparison(subplot(1, 3, 2), results, resultsWeighted, curveStyles, 'logDiff', 'auto', ...
    sprintf('Decadic Log Error |%slog_{10}| (dex)', deltaSym), '(b) Decadic Logarithmic Error CDF', 'cdf', fontText, fontMath);
renderDistributionComparison(subplot(1, 3, 3), results, resultsWeighted, curveStyles, 'absDiff', 'auto', ...
    sprintf('Absolute Discrepancy |%sy|', deltaSym), '(c) Absolute Error CDF', 'cdf', fontText, fontMath);
applyFigureFont(fig2, fontText);
drawnow;

% FIGURES 3–5: Dynamic M-Metric Carpet Heatmaps
renderMetricCarpetFigure('Figure 3: Mean Simulation Baseline Carpets (Log Scale Colors)', [80, 80], ...
    results, metricNames, 'yAvg', 'Mean Baseline', 'avg', cmapSeq, axis1Label, axis2Label, fontText);

renderMetricCarpetFigure('Figure 4: Logarithmic Error Carpets (Log Scale Colors)', [120, 60], ...
    results, metricNames, 'logDiff', 'Log Error', 'logErr', cmapSeq, axis1Label, axis2Label, fontText);

renderMetricCarpetFigure('Figure 5: Absolute Error Carpets (Log Scale Colors)', [160, 40], ...
    results, metricNames, 'absDiff', 'Absolute Error', 'absErr', cmapSeq, axis1Label, axis2Label, fontText);

% FIGURE 6: Distinct Bounded Voronoi Cell Area Carpets
numDomains = numel(voronoiDomains);
[vRows, vCols] = computeSubplotGrid(numDomains);
fig6 = figure('Name', 'Figure 6: Bounded Voronoi Cell Area Carpets', ...
    'Position', [200, 90, max(560, 560 * vCols), 440 * vRows]);
for d = 1:numDomains
    vd = voronoiDomains(d);
    ax6 = subplot(vRows, vCols, d);
    renderCarpetMap(ax6, vd.c1, vd.c2, vd.areas, cmapSeq, 'auto', ...
        sprintf('Voronoi Cell Area A_i (%s, N=%d)', vd.sourceLabel, numel(vd.areas)), ...
        'log_{10}(A_{Voronoi})', true, axis1Label, axis2Label, fontText);
end
applyFigureFont(fig6, fontText);
drawnow;

% FIGURE 7: 1x2 Publication-Ready Error Distributions (Voronoi-Normalized)
fig7 = figure('Name', 'Figure 7: Publication Error Distributions', 'Position', [100, 200, 1150, 480]);
renderPublicationDistribution(subplot(1, 2, 1), resultsWeighted, pubStyles, 'absDiff', 'auto', ...
    sprintf('Pairwise Discrepancy |%sy|', deltaSym), sprintf('(a) Numerical Noise Floor (Absolute |%sy|)', deltaSym), 'abs', fontText, fontMath);
renderPublicationDistribution(subplot(1, 2, 2), resultsWeighted, pubStyles, 'relErrPct', 'auto', ...
    sprintf('Pairwise Discrepancy |%sy| / y_{avg} (%%)', deltaSym), '(b) Numerical Noise Floor (Relative %)', 'rel', fontText, fontMath);
applyFigureFont(fig7, fontText, fontMath);
drawnow;

fprintf('All 7 diagnostic figure windows rendered successfully.\n');

% Store metadata & export outputs cleanly
results.metadata = struct('files', {filePaths}, 'sourceLabels', {sourceLabels}, ...
    'metrics', {metricNames}, 'spectralTarget', activeSpectral, 'coords', {{axis1Name, axis2Name}});
resultsWeighted.metadata = results.metadata;

if nargout > 0
    resultsOut = results;
    resultsWeightedOut = resultsWeighted;
end
assignin('base', 'results', results);
assignin('base', 'resultsWeighted', resultsWeighted);
end

%% ========================================================================
%  Argument & Input Discovery Helpers
% =========================================================================

function [inputFilesSpec, pRange, rRange, opts] = parseDiagnosticInputs(varargin)
opts = struct('laserWlTarget', 785.0, 'wlTol', 1e-3, 'geomTol', 1e-3, ...
    'includeAuxiliary', false, 'userSetLaserWl', false);
inputFilesSpec = {};
pRange = [];
rRange = [];

% Extract trailing Name-Value pairs cleanly
args = varargin;
nvIdx = numel(args) + 1;
knownKeys = {'Files', 'LaserWavelength', 'WavelengthTol', 'GeomTol', 'IncludeAuxiliary', 'pRange', 'rRange'};
i = 1;
while i <= numel(args)
    if (ischar(args{i}) || (isstring(args{i}) && isscalar(args{i}))) && ...
            any(strcmpi(char(args{i}), knownKeys)) && i < numel(args)
        nvIdx = i;
        break;
    end
    i = i + 1;
end

posArgs = args(1:nvIdx-1);
nvArgs  = args(nvIdx:end);

for k = 1:2:numel(nvArgs)
    key = lower(char(nvArgs{k}));
    val = nvArgs{k+1};
    switch key
        case 'files',            inputFilesSpec = val;
        case 'prange',           pRange = val;
        case 'rrange',           rRange = val;
        case 'laserwavelength',  opts.laserWlTarget = double(val); opts.userSetLaserWl = true;
        case 'wavelengthtol',    opts.wlTol = double(val);
        case 'geomtol',          opts.geomTol = double(val);
        case 'includeauxiliary', opts.includeAuxiliary = logical(val);
    end
end

% Parse positional arguments cleanly (file-first OR coordinate-range-first)
if ~isempty(posArgs)
    a1 = posArgs{1};
    isFileArg1 = iscell(a1) || isstring(a1) || ischar(a1) || isstruct(a1);
    if isFileArg1
        inputFilesSpec = a1;
        if numel(posArgs) >= 2, pRange = posArgs{2}; end
        if numel(posArgs) >= 3, rRange = posArgs{3}; end
    else
        pRange = a1;
        if numel(posArgs) >= 2, rRange = posArgs{2}; end
        if numel(posArgs) >= 3, inputFilesSpec = posArgs{3}; end
    end
end

% Check caller / base workspace variables when not supplied directly
if isempty(inputFilesSpec), inputFilesSpec = getWorkspaceVar('inputFiles', {}); end
if isempty(pRange),         pRange         = getWorkspaceVar('pRange', []);     end
if isempty(rRange),         rRange         = getWorkspaceVar('rRange', []);     end
end

function val = getWorkspaceVar(varName, defaultVal)
val = defaultVal;
if evalin('caller', sprintf('exist(''%s'', ''var'')', varName))
    val = evalin('caller', varName);
elseif evalin('base', sprintf('exist(''%s'', ''var'')', varName))
    val = evalin('base', varName);
end
end

function [filePaths, sourceLabels] = resolveInputFileList(inputSpec, projectRoot)
rawDir = fullfile(projectRoot, 'Data', 'Raw');

% Default backward-compatible list when no custom input files are supplied
if isempty(inputSpec)
    defaults = {'SweepPropeTable_Full.dat', 'SweepPropeTable_Extention1.dat', 'SweepPropeTable_E4_L.dat'};
    candidates = {};
    for k = 1:numel(defaults)
        p = fullfile(rawDir, defaults{k});
        if isfile(p), candidates{end+1} = p; end %#ok<AGROW>
    end
    if numel(candidates) < 2
        % Fall back to all sweep data files in Data/Raw
        candidates = discoverFilesInPattern(rawDir);
    end
    inputSpec = candidates;
end

% Normalize inputSpec into a flat cellstr of existing file paths
tokens = normalizeFileTokens(inputSpec);
resolved = {};
for k = 1:numel(tokens)
    tok = strtrim(tokens{k});
    if isempty(tok), continue; end

    if isfolder(tok) || contains(tok, '*') || contains(tok, '?')
        expanded = discoverFilesInPattern(tok);
        resolved = [resolved, expanded]; %#ok<AGROW>
    elseif isfile(tok)
        resolved{end+1} = tok; %#ok<AGROW>
    elseif isfile(fullfile(rawDir, tok))
        resolved{end+1} = fullfile(rawDir, tok); %#ok<AGROW>
    else
        warning('check_simulation_duplicate_error:FileNotFound', 'Input file not found and skipped: %s', tok);
    end
end

% Preserve order while deduplicating identical canonical paths
filePaths = unique(resolved, 'stable');
sourceLabels = buildCleanSourceLabels(filePaths);
end

function tokens = normalizeFileTokens(inputSpec)
tokens = {};
if isstruct(inputSpec) && isfield(inputSpec, 'name')
    for k = 1:numel(inputSpec)
        if ~inputSpec(k).isdir
            if isfield(inputSpec, 'folder')
                tokens{end+1} = fullfile(inputSpec(k).folder, inputSpec(k).name); %#ok<AGROW>
            else
                tokens{end+1} = inputSpec(k).name; %#ok<AGROW>
            end
        end
    end
elseif isstring(inputSpec)
    tokens = cellstr(inputSpec(:)');
elseif ischar(inputSpec)
    tokens = {inputSpec};
elseif iscell(inputSpec)
    for k = 1:numel(inputSpec)
        tokens{end+1} = char(string(inputSpec{k})); %#ok<AGROW>
    end
end
end

function found = discoverFilesInPattern(patternOrDir)
found = {};
validExts = {'.dat', '.txt', '.csv', '.tsv'};
if isfolder(patternOrDir)
    d = dir(patternOrDir);
else
    d = dir(patternOrDir);
end
for k = 1:numel(d)
    if d(k).isdir, continue; end
    [~, ~, ext] = fileparts(d(k).name);
    if any(strcmpi(ext, validExts))
        found{end+1} = fullfile(d(k).folder, d(k).name); %#ok<AGROW>
    end
end
end

function labels = buildCleanSourceLabels(filePaths)
n = numel(filePaths);
stems = cell(1, n);
dirs  = cell(1, n);
for k = 1:n
    [pDir, stem] = fileparts(filePaths{k});
    [~, parentName] = fileparts(pDir);
    stems{k} = stem;
    dirs{k}  = parentName;
end

% Strip common underscore-terminated prefix if all filenames share one (e.g. 'SweepPropeTable_')
labels = stems;
if n >= 2
    minLen = min(cellfun(@length, stems));
    prefixLen = 0;
    for pos = 1:minLen
        ch = stems{1}(pos);
        if all(cellfun(@(s) s(pos) == ch, stems))
            prefixLen = pos;
        else
            break;
        end
    end
    if prefixLen > 0
        lastUnder = find(stems{1}(1:prefixLen) == '_', 1, 'last');
        if ~isempty(lastUnder) && lastUnder < minLen
            trimmed = cellfun(@(s) s(lastUnder+1:end), stems, 'UniformOutput', false);
            if all(~cellfun(@isempty, trimmed))
                labels = trimmed;
            end
        end
    end
end

% Disambiguate colliding basenames with parent folder
[uLabels, ~, grp] = unique(labels, 'stable');
if numel(uLabels) < n
    for k = 1:n
        if sum(grp == grp(k)) > 1 && ~isempty(dirs{k})
            labels{k} = sprintf('%s/%s', dirs{k}, labels{k});
        end
    end
end
labels = matlab.lang.makeUniqueStrings(labels, {}, 64);
end

%% ========================================================================
%  Agnostic File Parsing & Canonical Schema Inference
% =========================================================================

function [T, schema] = loadAgnosticSweepTable(filePath)
fid = fopen(filePath, 'r');
if fid < 0
    error('check_simulation_duplicate_error:OpenFailed', 'Failed to open file: %s', filePath);
end
cleanupObj = onCleanup(@() fclose(fid));

% Inspect leading comment / header lines dynamically
lastCommentLine = '';
firstDataLine   = '';
headerText      = '';
dataStartPos    = 0;

while true
    pos = ftell(fid);
    line = fgetl(fid);
    if ~ischar(line), break; end
    trimmed = strtrim(line);
    if isempty(trimmed), continue; end

    if startsWith(trimmed, '%') || startsWith(trimmed, '#')
        lastCommentLine = strtrim(trimmed(2:end));
        continue;
    end

    if isNumericDataLine(trimmed)
        firstDataLine = trimmed;
        dataStartPos = pos;
        if ~isempty(lastCommentLine)
            headerText = lastCommentLine;
        end
        break;
    else
        % Un-commented plain text header line (CSV / TSV / plain table)
        headerText = trimmed;
    end
end

if isempty(firstDataLine)
    error('check_simulation_duplicate_error:NoNumericRows', 'No numeric rows found in file: %s', filePath);
end

% Detect delimiter and numeric column count
[delimMode, numCols, isEuroDecimal] = detectLineDelimiter(firstDataLine);

% Extract raw column names matching numCols
rawColNames = parseHeaderSegments(headerText, firstDataLine, delimMode, numCols);

% Read numeric matrix fast and cleanly
if isEuroDecimal
    fseek(fid, 0, 'bof');
    opts = detectImportOptions(filePath, 'Delimiter', ';', 'DecimalSeparator', ',', 'VariableNamingRule', 'preserve');
    Traw = readtable(filePath, opts);
    dataMatrix = table2array(Traw);
else
    fseek(fid, dataStartPos, 'bof');
    fmt = repmat('%f', 1, numCols);
    switch delimMode
        case 'comma'
            dataCell = textscan(fid, fmt, 'Delimiter', ',', 'CollectOutput', true, 'CommentStyle', '%');
        case 'semicolon'
            dataCell = textscan(fid, fmt, 'Delimiter', ';', 'CollectOutput', true, 'CommentStyle', '%');
        otherwise
            dataCell = textscan(fid, fmt, 'Delimiter', {'\t', ' '}, 'MultipleDelimsAsOne', true, ...
                'CollectOutput', true, 'CommentStyle', '%');
    end
    dataMatrix = dataCell{1};
end

if isempty(dataMatrix)
    error('check_simulation_duplicate_error:EmptyData', 'Parsed matrix is empty for file: %s', filePath);
end

actualCols = size(dataMatrix, 2);
if numel(rawColNames) < actualCols
    for k = numel(rawColNames)+1 : actualCols
        rawColNames{k} = sprintf('Col%d', k);
    end
elseif numel(rawColNames) > actualCols
    rawColNames = rawColNames(1:actualCols);
end

canonicalNames = cell(1, actualCols);
for k = 1:actualCols
    canonicalNames{k} = canonicalizeColumnToken(rawColNames{k}, k);
end
canonicalNames = matlab.lang.makeUniqueStrings(canonicalNames, {}, namelengthmax);

T = array2table(dataMatrix, 'VariableNames', canonicalNames);
schema = inferTableSchema(canonicalNames, T);
clear cleanupObj;
end

function tf = isNumericDataLine(lineStr)
% True if all delimiter-separated tokens parse cleanly as finite scalars
tokens = regexp(strrep(lineStr, ',', '.'), '[^;\s]+', 'match');
if contains(lineStr, ',') && ~contains(lineStr, ';')
    tokens = regexp(lineStr, '[^,\s]+', 'match');
end
if isempty(tokens)
    tf = false;
    return;
end
vals = str2double(tokens);
tf = all(~isnan(vals) | strcmpi(tokens, 'NaN'));
end

function [delimMode, numCols, isEuroDecimal] = detectLineDelimiter(firstDataLine)
isEuroDecimal = false;
if contains(firstDataLine, ';')
    delimMode = 'semicolon';
    parts = strsplit(firstDataLine, ';');
    numCols = numel(parts);
    isEuroDecimal = contains(firstDataLine, ',');
elseif contains(firstDataLine, ',')
    delimMode = 'comma';
    parts = strsplit(firstDataLine, ',');
    numCols = numel(parts);
else
    delimMode = 'whitespace';
    parts = regexp(firstDataLine, '\S+', 'match');
    numCols = numel(parts);
end
end

function segs = parseHeaderSegments(headerText, firstDataLine, delimMode, numCols)
segs = {};
if isempty(headerText)
    for k = 1:numCols, segs{k} = sprintf('Col%d', k); end
    return;
end

if strcmp(delimMode, 'comma') && contains(headerText, ',')
    segs = strtrim(strsplit(headerText, ','));
elseif strcmp(delimMode, 'semicolon') && contains(headerText, ';')
    segs = strtrim(strsplit(headerText, ';'));
else
    % Split on tabs (including surrounding spaces) or 2+ spaces cleanly
    segs = strtrim(regexp(headerText, '(?:[ \t]*\t[ \t]*|\s{2,})', 'split'));
    segs = segs(~cellfun(@isempty, segs));

    % Fallback to ASSTEROID token alignment or single-space split if mismatched
    if numel(segs) ~= numCols
        wsSegs = regexp(headerText, '\S+', 'match');
        if numel(wsSegs) == numCols
            segs = wsSegs;
        elseif exist('defaultComsolVarNames', 'file') && exist('detectCanonicalOrderFromHeader', 'file')
            [tokenStarts, ~] = regexp(firstDataLine, '[+-]?\d*\.?\d+(?:[eEdD][+-]?\d+)?');
            [defNames, defRaw] = defaultComsolVarNames();
            mapped = detectCanonicalOrderFromHeader([' ' headerText], defRaw, defNames, tokenStarts + 1);
            if numel(mapped) == numCols && sum(~cellfun(@isempty, mapped)) >= min(3, numCols)
                for k = 1:numCols
                    if isempty(mapped{k}), mapped{k} = sprintf('Col%d', k); end
                end
                segs = mapped;
            end
        end
    end
end
end

function cname = canonicalizeColumnToken(rawSeg, colIdx)
% Maps arbitrary header text (e.g. 'EF_vol (1), <EF>vol', 'Absorptance (%), Atotal', 'MyMetric')
% cleanly into a standardized metric/coordinate identifier via exact token matching.
s = strtrim(char(rawSeg));
if isempty(s)
    cname = sprintf('Col%d', colIdx);
    return;
end

% Split comma-separated COMSOL header expressions and strip trailing units '(...)' / '[...]'
commaParts = strtrim(strsplit(s, ','));
headNoUnits = strtrim(regexprep(commaParts{1}, '\s*[\(\[].*?[\)\]]\s*$', ''));
candidateTokens = unique([ {headNoUnits}, commaParts ], 'stable');

aliasTable = { ...
    {'p', 'period', 'lattice_p', 'pitch'},                       'period'; ...
    {'r', 'particle_r', 'radius', 'sphere_r'},                   'radius'; ...
    {'lam', 'lam0', 'wl', 'lambda', 'lambda0', 'wavelength'},    'lambda'; ...
    {'ee_v', 'eev', 'ef_vol', 'efvol', 'ee_vol', '<ee>vol', '<ef>vol'}, 'EE_V'; ...
    {'ee_s', 'ees', 'ef_surf', 'efsurf', 'ee_surf', '<ee>surf', '<ef>surf'}, 'EE_S'; ...
    {'ef_max', 'efmax', 'e4_max', 'e4max', 'm2_max', 'm2max', '<e4>max', 'max(ef)', 'max(m2)', 'ef_laser_max'}, 'EF_max'; ...
    {'abs', 'absorptance', 'atotal'},                            'Abs'; ...
    {'kappa_v', 'kappav', 'v_corr', 'volcorr'},                  'kappa_V'; ...
    {'kappa_s', 'kappas', 's_corr', 'surfcorr'},                 'kappa_S'; ...
    {'ecc', 'eccheck', 'error_ecmodal'},                         'ECC' ...
    };

for r = 1:size(aliasTable, 1)
    aliases = aliasTable{r, 1};
    for c = 1:numel(candidateTokens)
        tok = lower(strtrim(regexprep(candidateTokens{c}, '\s*[\(\[].*?[\)\]]\s*$', '')));
        if any(strcmpi(tok, aliases))
            cname = aliasTable{r, 2};
            return;
        end
    end
end

cname = matlab.lang.makeValidName(headNoUnits);
if isempty(cname)
    cname = sprintf('Col%d', colIdx);
end
end

function schema = inferTableSchema(colNames, T)
% Dynamically classifies spectral column, 2D coordinate columns, and output metrics
spectralPatterns = {'lambda', 'wavelength', 'freq', 'frequency', 'omega', 'wl'};
coordPatterns    = {'period', 'radius', 'p', 'r', 'pitch', 'diameter', 'gap', ...
    'thickness', 'angle', 'height', 'width', 'length', 'x', 'y', 'param1', 'param2'};

spectralCol = '';
coordCols   = {};
candidates  = {};

for k = 1:numel(colNames)
    cn = colNames{k};
    if ~isnumeric(T.(cn)), continue; end
    if isempty(spectralCol) && any(strcmpi(cn, spectralPatterns))
        spectralCol = cn;
    elseif any(strcmpi(cn, coordPatterns))
        coordCols{end+1} = cn; %#ok<AGROW>
    else
        candidates{end+1} = cn; %#ok<AGROW>
    end
end

% Ensure exactly 2 coordinate columns (reorder canonical [period, radius] if present)
if numel(coordCols) >= 2
    pIdx = find(strcmpi(coordCols, 'period'), 1);
    rIdx = find(strcmpi(coordCols, 'radius'), 1);
    if ~isempty(pIdx) && ~isempty(rIdx)
        extraCoords = coordCols(setdiff(1:numel(coordCols), [pIdx, rIdx], 'stable'));
        metricCols  = [extraCoords, candidates];
        coordCols   = {coordCols{pIdx}, coordCols{rIdx}};
    else
        metricCols = [coordCols(3:end), candidates];
        coordCols  = coordCols(1:2);
    end
else
    % Fallback: promote first available numeric columns to form 2D coordinate pair
    while numel(coordCols) < 2 && ~isempty(candidates)
        coordCols{end+1} = candidates{1}; %#ok<AGROW>
        candidates(1) = [];
    end
    metricCols = candidates;
end

if numel(coordCols) < 2
    error('check_simulation_duplicate_error:MissingCoordinates', ...
        'Could not identify 2 coordinate columns in table (%s).', strjoin(colNames, ', '));
end

schema = struct('spectralCol', spectralCol, 'coordCols', {coordCols}, 'metricCols', {metricCols});
end

function activeSpectral = resolveTargetWavelength(datasets, opts)
hasSpectral = arrayfun(@(d) ~isempty(d.schema.spectralCol), datasets);
if ~any(hasSpectral)
    activeSpectral = NaN;
    fprintf('      No spectral column present in input files; matching all geometries directly.\n');
    return;
end

activeSpectral = opts.laserWlTarget;
anyHits = false;
for k = 1:numel(datasets)
    if ~hasSpectral(k), continue; end
    lam = datasets(k).table.(datasets(k).schema.spectralCol);
    if any(abs(lam - activeSpectral) <= opts.wlTol)
        anyHits = true;
        break;
    end
end

if ~anyHits && ~opts.userSetLaserWl
    % Auto-discover common unique wavelength across spectral datasets
    commonWls = [];
    for k = 1:numel(datasets)
        if ~hasSpectral(k), continue; end
        lam = datasets(k).table.(datasets(k).schema.spectralCol);
        uLam = unique(round(lam / opts.wlTol) * opts.wlTol);
        if isempty(commonWls)
            commonWls = uLam;
        else
            commonWls = intersect(commonWls, uLam);
        end
    end
    if ~isempty(commonWls)
        activeSpectral = commonWls(ceil(numel(commonWls)/2));
        fprintf('      Target lambda0 = %.2f not found; auto-selected common wavelength lambda0 = %.2f.\n', ...
            opts.laserWlTarget, activeSpectral);
    end
else
    fprintf('      Filtering spectral coordinate at target = %.2f (tol = %.1e).\n', activeSpectral, opts.wlTol);
end
end

%% ========================================================================
%  Cross-File Matching, Metric Pooling & Voronoi Domain Caching
% =========================================================================

function [metricNames, metricData, pairLog] = matchAllPairsAndDiscoverMetrics(datasets, opts)
auxColumns = {'ECC', 'ECCheck', 'kappa_V', 'kappa_S', 'V_corr', 'S_corr'};
numFiles = numel(datasets);
pairRecords = struct('i', {}, 'j', {}, 'pairLabel', {}, 'metrics', {}, ...
    'c1', {}, 'c2', {}, 'rowIdx1', {}, 'rowIdx2', {});
pairLog = struct('pairLabel', {}, 'numMatched', {}, 'metrics', {});

for i = 1:numFiles-1
    if height(datasets(i).rows) < 4, continue; end
    for j = i+1:numFiles
        if height(datasets(j).rows) < 4, continue; end

        shared = intersect(datasets(i).schema.metricCols, datasets(j).schema.metricCols, 'stable');
        if isempty(shared), continue; end

        % Filter auxiliary diagnostic/geometric columns unless no physical metrics are shared
        if ~opts.includeAuxiliary
            physShared = shared(~ismember(shared, auxColumns));
            if ~isempty(physShared)
                shared = physShared;
            end
        end

        [idx1, idx2] = matchGeometriesByTolerance( ...
            [datasets(i).coord1, datasets(i).coord2], ...
            [datasets(j).coord1, datasets(j).coord2], opts.geomTol);

        nMatch = numel(idx1);
        pLbl = sprintf('%s vs %s', datasets(i).label, datasets(j).label);
        if nMatch < 4
            continue;
        end

        pr = struct('i', i, 'j', j, 'pairLabel', pLbl, 'metrics', {shared}, ...
            'c1', datasets(i).coord1(idx1), 'c2', datasets(i).coord2(idx1), ...
            'rowIdx1', idx1, 'rowIdx2', idx2);
        pairRecords(end+1) = pr; %#ok<AGROW>
        pairLog(end+1) = struct('pairLabel', pLbl, 'numMatched', nMatch, 'metrics', {shared}); %#ok<AGROW>
    end
end

metricData = struct();
rawMetrics = {};
for p = 1:numel(pairRecords)
    rawMetrics = [rawMetrics, pairRecords(p).metrics]; %#ok<AGROW>
end
rawMetrics = unique(rawMetrics, 'stable');

% Aggregate per metric across contributing file pairs (deduplicating redundant coordinates)
for mIdx = 1:numel(rawMetrics)
    mName = rawMetrics{mIdx};
    pCandidates = [];
    for p = 1:numel(pairRecords)
        if any(strcmp(pairRecords(p).metrics, mName))
            pCandidates(end+1) = p; %#ok<AGROW>
        end
    end

    % Sort pairs with largest geometry overlap first
    nCounts = arrayfun(@(idx) numel(pairRecords(idx).c1), pCandidates);
    [~, ord] = sort(nCounts, 'descend');
    pCandidates = pCandidates(ord);

    c1All = []; c2All = []; y1All = []; y2All = [];
    contributingPairs = {};

    for c = 1:numel(pCandidates)
        pr = pairRecords(pCandidates(c));
        y1 = datasets(pr.i).rows.(mName)(pr.rowIdx1);
        y2 = datasets(pr.j).rows.(mName)(pr.rowIdx2);
        valid = isfinite(y1) & isfinite(y2);
        if sum(valid) < 1, continue; end

        c1p = pr.c1(valid); c2p = pr.c2(valid);
        y1p = y1(valid);    y2p = y2(valid);

        if isempty(c1All)
            c1All = c1p; c2All = c2p; y1All = y1p; y2All = y2p;
            contributingPairs{end+1} = pr.pairLabel; %#ok<AGROW>
        else
            % Append only complementary coordinates not already covered within geomTol
            newCoords = [c1p, c2p];
            curCoords = [c1All, c2All];
            nnIdx = knnsearch(curCoords, newCoords);
            delta = abs(newCoords - curCoords(nnIdx, :));
            isNew = any(delta > opts.geomTol, 2);
            if any(isNew)
                c1All = [c1All; c1p(isNew)]; %#ok<AGROW>
                c2All = [c2All; c2p(isNew)]; %#ok<AGROW>
                y1All = [y1All; y1p(isNew)]; %#ok<AGROW>
                y2All = [y2All; y2p(isNew)]; %#ok<AGROW>
                contributingPairs{end+1} = pr.pairLabel; %#ok<AGROW>
            end
        end
    end

    if numel(c1All) < 4
        continue;
    end

    if numel(contributingPairs) == 1
        srcLabel = contributingPairs{1};
    else
        srcLabel = sprintf('Merged (%d pairs)', numel(contributingPairs));
    end

    metricData.(mName) = struct('c1', c1All, 'c2', c2All, 'y1', y1All, 'y2', y2All, 'sourceLabel', srcLabel);
end

% Canonical diagnostic order: Abs, EE_S, EE_V, EF_max, then any discovered custom metrics
discovered = fieldnames(metricData)';
prefOrder = {'Abs', 'EE_S', 'EE_V', 'EF_max'};
metricNames = [prefOrder(ismember(prefOrder, discovered)), discovered(~ismember(discovered, prefOrder))];
end

function [idx1, idx2] = matchGeometriesByTolerance(coords1, coords2, tol)
% Nearest-neighbor duplicate matching within component-wise tolerance
nnIdx = knnsearch(coords2, coords1);
delta = abs(coords1 - coords2(nnIdx, :));
isMatch = all(delta <= tol, 2);
idx1 = find(isMatch);
idx2 = nnIdx(isMatch);
end

function [domains, metricDomainIdx] = computeCachedVoronoiDomains(metricData, metricNames)
domains = struct('sig', {}, 'sourceLabel', {}, 'c1', {}, 'c2', {}, ...
    'weights', {}, 'areas', {}, 'hullArea', {}, 'nEff', {}, 'elapsedSec', {});
metricDomainIdx = zeros(1, numel(metricNames));

for i = 1:numel(metricNames)
    mName = metricNames{i};
    md = metricData.(mName);
    sig = [numel(md.c1), sum(round(md.c1 * 1e4)), sum(round(md.c2 * 1e4))];

    foundIdx = [];
    for d = 1:numel(domains)
        if isequal(domains(d).sig, sig) && numel(domains(d).c1) == numel(md.c1) && ...
                max(abs(domains(d).c1 - md.c1)) < 1e-3 && max(abs(domains(d).c2 - md.c2)) < 1e-3
            foundIdx = d;
            break;
        end
    end

    if ~isempty(foundIdx)
        metricDomainIdx(i) = foundIdx;
    else
        tVor = tic;
        [w, areas, hullArea] = computeVoronoiAreaWeights(md.c1, md.c2);
        nEff = 1 / sum(w.^2);
        domains(end+1) = struct('sig', sig, 'sourceLabel', md.sourceLabel, ...
            'c1', md.c1, 'c2', md.c2, 'weights', w, 'areas', areas, ...
            'hullArea', hullArea, 'nEff', nEff, 'elapsedSec', toc(tVor)); %#ok<AGROW>
        metricDomainIdx(i) = numel(domains);
    end
end
end

function [B_raw, E_raw, pCommon, rCommon, numCommon] = buildCommonIntersectionMatrices(results, metricNames)
commonCoords = [results.(metricNames{1}).pVals, results.(metricNames{1}).rVals];
geomKeys = cell(1, numel(metricNames));
geomKeys{1} = round(commonCoords * 1e3);

commonKeys = geomKeys{1};
for i = 2:numel(metricNames)
    coordsI = [results.(metricNames{i}).pVals, results.(metricNames{i}).rVals];
    geomKeys{i} = round(coordsI * 1e3);
    commonKeys = intersect(commonKeys, geomKeys{i}, 'rows', 'stable');
end

numCommon = size(commonKeys, 1);
B_raw = zeros(numCommon, numel(metricNames));
E_raw = zeros(numCommon, numel(metricNames));
pCommon = [];
rCommon = [];

if numCommon < 4, return; end

for i = 1:numel(metricNames)
    [~, idxM] = ismember(commonKeys, geomKeys{i}, 'rows');
    st = results.(metricNames{i});
    B_raw(:, i) = st.yAvg(idxM);
    E_raw(:, i) = st.absDiff(idxM);
    if i == 1
        pCommon = st.pVals(idxM);
        rCommon = st.rVals(idxM);
    end
end
end

%% ========================================================================
%  Styling & Formatting Helpers
% =========================================================================

function st = getMetricVisualStyle(mName, idx, isPub)
% Official Rule 05 OKHSL primary anchor palette + deterministic extended cycle
colBlue   = [ 36,  30, 195] / 255; % A40
colPurple = [127,   0, 224] / 255; % B50
colTeal   = [ 39, 146, 141] / 255; % C60
colGold   = [201, 148,  44] / 255; % D70
palette   = {colTeal, colGold, colPurple, colBlue, ...
    [0.85, 0.33, 0.25], [0.30, 0.68, 0.35], [0.15, 0.55, 0.82], [0.65, 0.42, 0.22]};

switch mName
    case 'Abs'
        st.color = colTeal;
        st.label = ternaryStr(isPub, 'Abs^L', 'Abs');
        st.title = 'Absorptance (Abs)';
        st.unit  = '%';
    case 'EE_S'
        st.color = colPurple;
        st.label = ternaryStr(isPub, 'EE_S^L', 'EE_S');
        st.title = 'Surface Enhancement Efficacy (EE_S)';
        st.unit  = '';
    case 'EE_V'
        st.color = colBlue;
        st.label = ternaryStr(isPub, 'EE_V^L', 'EE_V');
        st.title = 'Volumetric Enhancement Efficacy (EE_V)';
        st.unit  = '';
    case {'EF_max', 'E4_max'}
        st.color = colGold;
        st.label = 'EF_{max}^L';
        st.title = 'Hotspot Peak (EF_{max}^L)';
        st.unit  = '';
    otherwise
        st.color = palette{mod(idx - 1, numel(palette)) + 1};
        st.label = strrep(mName, '_', '\_');
        st.title = st.label;
        st.unit  = '';
end
end

function pubOrder = orderMetricsForPublication(metricNames)
prefPub = {'Abs', 'EF_max', 'EE_S', 'EE_V'};
pubOrder = [prefPub(ismember(prefPub, metricNames)), metricNames(~ismember(metricNames, prefPub))];
end

function lbl = formatCoordinateAxisLabel(coordName, axisIdx)
if any(strcmpi(coordName, {'period', 'p'}))
    lbl = 'Period P (nm)';
elseif any(strcmpi(coordName, {'radius', 'particle_r', 'r'}))
    lbl = 'Radius r (nm)';
else
    cleanName = strrep(coordName, '_', '\_');
    if isempty(cleanName)
        lbl = sprintf('Coordinate %d', axisIdx);
    else
        lbl = cleanName;
    end
end
end

function [nRows, nCols] = computeSubplotGrid(nItems)
if nItems <= 1
    nRows = 1; nCols = 1;
elseif nItems == 2
    nRows = 1; nCols = 2;
elseif nItems == 3
    nRows = 1; nCols = 3;
elseif nItems == 4
    nRows = 2; nCols = 2;
else
    nCols = ceil(sqrt(nItems));
    nRows = ceil(nItems / nCols);
end
end

function [fontText, fontMath] = resolveFiraFonts()
availableFonts = listfonts;
if any(strcmpi(availableFonts, 'Fira Sans'))
    fontText = 'Fira Sans';
elseif any(contains(availableFonts, 'Fira', 'IgnoreCase', true))
    firaMatch = availableFonts(contains(availableFonts, 'Fira', 'IgnoreCase', true));
    fontText = firaMatch{1};
else
    fontText = 'Helvetica';
end

% Only use 'Fira Math' when registered directly as a family; weight-suffixed
% OpenType names like 'Fira Math Book' trigger Times fallback in Chromium UI figures.
if any(strcmpi(availableFonts, 'Fira Math'))
    fontMath = 'Fira Math';
else
    fontMath = fontText;
end
end

function applyFigureFont(fig, fontNameStr, fontMathStr)
% Applies figure-wide typography cleanly via MATLAB R2022a+ fontname() API
if isempty(fontNameStr) || ~isgraphics(fig), return; end
if exist('fontname', 'file')
    fontname(fig, fontNameStr);
else
    objs = findall(fig, '-property', 'FontName');
    set(objs, 'FontName', fontNameStr);
end
if nargin >= 3 && ~isempty(fontMathStr) && ~strcmpi(fontMathStr, fontNameStr)
    mathObjs = findall(fig, 'Tag', 'MathAnnot');
    if ~isempty(mathObjs)
        set(mathObjs, 'FontName', fontMathStr);
    end
end
end

function cmapSeq = resolveSequentialColormap(cmapFile)
if isfile(cmapFile)
    cmapRaw = readmatrix(cmapFile, 'FileType', 'text', 'CommentStyle', '%');
    xNodes = linspace(0, 1, size(cmapRaw, 1));
    xDense = linspace(0, 1, 256);
    cmapSeq = interp1(xNodes, cmapRaw, xDense, 'pchip');
else
    cmapSeq = flipud(parula(256));
end
end

function out = ternaryStr(cond, a, b)
if cond, out = a; else, out = b; end
end

%% ========================================================================
%  Visualization Rendering Functions
% =========================================================================

function renderMetricCarpetFigure(figName, figPosXY, results, metricNames, dataField, titleTag, mode, cmapSeq, axis1Label, axis2Label, fontText)
deltaSym = char(916);
nItems = numel(metricNames);
[nRows, nCols] = computeSubplotGrid(nItems);
figW = min(1750, max(580, 560 * nCols));
figH = min(920,  max(440, 420 * nRows));
fig = figure('Name', figName, 'Position', [figPosXY(1), figPosXY(2), figW, figH]);

for i = 1:nItems
    mName = metricNames{i};
    st = results.(mName);
    vs = getMetricVisualStyle(mName, i, false);
    ax = subplot(nRows, nCols, i);

    switch mode
        case 'avg'
            cbarLbl = sprintf('log_{10}(%s_{avg})', vs.label);
        case 'logErr'
            cbarLbl = sprintf('log_{10}(|%slog_{10}(%s)|)', deltaSym, vs.label);
        otherwise
            cbarLbl = sprintf('log_{10}(|%s%s|)', deltaSym, vs.label);
    end
    panelTitle = sprintf('%s %s (Log Scale)', vs.title, titleTag);
    renderCarpetMap(ax, st.pVals, st.rVals, st.(dataField), cmapSeq, 'auto', ...
        panelTitle, cbarLbl, true, axis1Label, axis2Label, fontText);
end
applyFigureFont(fig, fontText);
drawnow;
end

function renderPublicationDistribution(ax, resultsWeighted, pubStyles, dataField, xLimits, xLabelStr, titleStr, errType, fontText, fontMath)
% Renders publication-grade PDF distributions for Voronoi-weighted metrics using default theme and Fira typography
if nargin < 9  || isempty(fontText), fontText = 'Fira Sans'; end
if nargin < 10 || isempty(fontMath), fontMath = fontText; end

hold(ax, 'on'); box(ax, 'on'); grid(ax, 'on');
set(ax, 'XScale', 'log');
set(ax, 'XMinorTick', 'on', 'YMinorTick', 'on');
set(ax, 'FontName', fontText, 'FontSize', 10, 'LineWidth', 1.0, ...
    'TickDir', 'in', 'TickLength', [0.015, 0.025]);

hMetrics = gobjects(numel(pubStyles), 1);
maxVal = 0;
plumbLines = [];
pdfUList = {};
pdfFList = {};
meanVals = [];

for ps = 1:numel(pubStyles)
    fld = pubStyles{ps}.field;
    col = pubStyles{ps}.color;
    lbl = pubStyles{ps}.label;

    v = resultsWeighted.(fld).(dataField);
    w = resultsWeighted.(fld).weights;
    valid = isfinite(v) & (v > 0);
    v = v(valid);
    if isempty(v), continue; end
    w = w(valid);
    w = w / sum(w);
    logV = log10(v);
    mean_w = sum(w .* v);
    meanVals(end+1) = mean_w; %#ok<AGROW>

    % Kernel density estimate (Voronoi area-weighted)
    [f_w, u_w] = ksdensity(logV, 'Weights', w, 'NumPoints', 300);
    hMetrics(ps) = plot(ax, 10.^u_w, f_w, 'Color', col, 'LineWidth', 2.0, ...
        'LineStyle', '-', 'Marker', 'none', 'DisplayName', lbl);

    pdfUList{end+1} = u_w; %#ok<AGROW>
    pdfFList{end+1} = f_w; %#ok<AGROW>
    maxVal = max(maxVal, max(f_w));
    plumbLines = [plumbLines; struct('mw', mean_w, 'col', col, 'lbl', lbl)]; %#ok<AGROW>
end

% Clip X-limits systematically using computeCombinedPdfXLimits default threshold
if isempty(xLimits) || ((ischar(xLimits) || isstring(xLimits)) && strcmpi(xLimits, 'auto'))
    xLimits = computeCombinedPdfXLimits(pdfUList, pdfFList, [], meanVals);
end
xlim(ax, xLimits);
yTop = max(maxVal * 1.15, 0.5);
ylim(ax, [0, yTop]);

% Dashed vertical lines indicating Voronoi-weighted means with vertical value annotations at the top
for k = 1:numel(plumbLines)
    mw = plumbLines(k).mw;
    col = plumbLines(k).col;

    if strcmpi(errType, 'rel')
        if mw < 0.01
            valStr = sprintf('%.2e%%', mw);
        elseif mw < 1.0
            valStr = sprintf('%.3f%%', mw);
        else
            valStr = sprintf('%.2f%%', mw);
        end
    else
        if mw < 0.01
            valStr = sprintf('%.2e', mw);
        elseif mw < 100
            valStr = sprintf('%.2f', mw);
        else
            valStr = sprintf('%.2e', mw);
        end
    end

    plot(ax, [mw, mw], [0, yTop], '--', ...
        'Color', col, 'LineWidth', 1.0, 'Marker', 'none', 'HandleVisibility', 'off');

    text(ax, mw * 1.06, yTop * 0.95, sprintf('%s = %s', char(956), valStr), ...
        'Rotation', 90, 'Color', col, 'FontName', fontMath, 'FontSize', 8.5, 'FontWeight', 'bold', ...
        'HorizontalAlignment', 'right', 'VerticalAlignment', 'top', ...
        'Tag', 'MathAnnot', 'HandleVisibility', 'off');
end

xlabel(ax, xLabelStr, 'FontWeight', 'bold', 'FontSize', 10.5);
ylabel(ax, 'Probability Density dF/d(log_{10}x) [dex^{-1}]', 'FontWeight', 'bold', 'FontSize', 10.5);
title(ax, titleStr, 'FontSize', 11, 'FontWeight', 'bold');

validMetrics = hMetrics(isgraphics(hMetrics));
if ~isempty(validMetrics)
    legend(ax, validMetrics, 'Location', 'northwest', 'FontSize', 9.5, 'Box', 'on');
end
end

function renderDistributionComparison(ax, results, resultsWeighted, curveStyles, dataField, xLimits, xLabelStr, titleStr, plotType, fontText, fontMath)
if nargin < 10 || isempty(fontText), fontText = 'Fira Sans'; end
if nargin < 11 || isempty(fontMath), fontMath = fontText; end %#ok<NASGU>

hold(ax, 'on'); box(ax, 'on'); grid(ax, 'on');
set(ax, 'XScale', 'log');
set(ax, 'XMinorTick', 'on', 'YMinorTick', 'on');
set(ax, 'FontName', fontText, 'FontSize', 10, 'LineWidth', 1.0, ...
    'TickDir', 'in', 'TickLength', [0.015, 0.025]);

isCdf = strcmpi(plotType, 'cdf');
autoXLimits = isempty(xLimits) || ((ischar(xLimits) || isstring(xLimits)) && strcmpi(xLimits, 'auto'));
hMetrics = gobjects(numel(curveStyles), 1);

maxVal = 0;
plumbLines = [];
pdfUList = {};
pdfFList = {};
meanVals = [];

for cs = 1:numel(curveStyles)
    fld = curveStyles{cs}.field;
    col = curveStyles{cs}.color;

    v_u = results.(fld).(dataField);
    valid_u = isfinite(v_u) & (v_u > 0);
    v_u = v_u(valid_u);
    if isempty(v_u), continue; end
    logV_u = log10(v_u);
    mean_u = mean(v_u, 'omitnan');
    meanVals(end+1) = mean_u; %#ok<AGROW>

    v_w = resultsWeighted.(fld).(dataField);
    w_w = resultsWeighted.(fld).weights;
    valid_w = isfinite(v_w) & (v_w > 0);
    v_w = v_w(valid_w);
    if isempty(v_w), continue; end
    w_w = w_w(valid_w);
    w_w = w_w / sum(w_w);
    logV_w = log10(v_w);
    mean_w = sum(w_w .* v_w);
    meanVals(end+1) = mean_w; %#ok<AGROW>

    if isCdf
        [f_u, u_u] = ksdensity(logV_u, 'Function', 'cdf', 'NumPoints', 250);
        hMetrics(cs) = plot(ax, 10.^u_u, f_u, 'Color', col, 'LineWidth', 2.0, ...
            'LineStyle', '-', 'Marker', 'none', 'DisplayName', curveStyles{cs}.label);

        [f_w, u_w] = ksdensity(logV_w, 'Weights', w_w, 'Function', 'cdf', 'NumPoints', 250);
        plot(ax, 10.^u_w, f_w, 'Color', col, 'LineWidth', 2.0, ...
            'LineStyle', '--', 'Marker', 'none', 'HandleVisibility', 'off');

        if autoXLimits
            [fPdfU, uPdfU] = ksdensity(logV_u, 'NumPoints', 250);
            [fPdfW, uPdfW] = ksdensity(logV_w, 'Weights', w_w, 'NumPoints', 250);
            pdfUList{end+1} = uPdfU; %#ok<AGROW>
            pdfFList{end+1} = fPdfU; %#ok<AGROW>
            pdfUList{end+1} = uPdfW; %#ok<AGROW>
            pdfFList{end+1} = fPdfW; %#ok<AGROW>
        end
    else
        [f_u, u_u] = ksdensity(logV_u, 'NumPoints', 250);
        hMetrics(cs) = plot(ax, 10.^u_u, f_u, 'Color', col, 'LineWidth', 2.0, ...
            'LineStyle', '-', 'Marker', 'none', 'DisplayName', curveStyles{cs}.label);

        [f_w, u_w] = ksdensity(logV_w, 'Weights', w_w, 'NumPoints', 250);
        plot(ax, 10.^u_w, f_w, 'Color', col, 'LineWidth', 2.0, ...
            'LineStyle', '--', 'Marker', 'none', 'HandleVisibility', 'off');

        pdfUList{end+1} = u_u; %#ok<AGROW>
        pdfFList{end+1} = f_u; %#ok<AGROW>
        pdfUList{end+1} = u_w; %#ok<AGROW>
        pdfFList{end+1} = f_w; %#ok<AGROW>
        maxVal = max([maxVal, max(f_u), max(f_w)]);
    end

    plumbLines = [plumbLines; struct('mu', mean_u, 'mw', mean_w, 'col', col)]; %#ok<AGROW>
end

if autoXLimits
    xLimits = computeCombinedPdfXLimits(pdfUList, pdfFList, [], meanVals);
end
xlim(ax, xLimits);

if isCdf
    ylim(ax, [0, 1]);
    yTop = 1.0;
    ylabel(ax, 'Cumulative Probability (CDF)', 'FontWeight', 'bold');
    plot(ax, xLimits, [0.5, 0.5], ':', 'Color', [0.65 0.65 0.65], 'LineWidth', 0.8, 'HandleVisibility', 'off');
else
    yTop = max(maxVal * 1.10, 0.5);
    ylim(ax, [0, yTop]);
    ylabel(ax, 'Probability Density dF/d(log_{10}x) [dex^{-1}]', 'FontWeight', 'bold');
end

for k = 1:numel(plumbLines)
    plot(ax, [plumbLines(k).mu, plumbLines(k).mu], [0, yTop], '-', ...
        'Color', plumbLines(k).col, 'LineWidth', 0.5, 'Marker', 'none', 'HandleVisibility', 'off');
    plot(ax, [plumbLines(k).mw, plumbLines(k).mw], [0, yTop], '--', ...
        'Color', plumbLines(k).col, 'LineWidth', 0.5, 'Marker', 'none', 'HandleVisibility', 'off');
end

xlabel(ax, xLabelStr, 'FontWeight', 'bold');
title(ax, titleStr, 'FontSize', 11, 'FontWeight', 'bold');

hSolidGuide  = plot(ax, NaN, NaN, '-', 'Color', [0.4 0.4 0.4], 'LineWidth', 2.0, ...
    'Marker', 'none', 'DisplayName', 'Solid : Unweighted (Raw Sample)');
hDashGuide   = plot(ax, NaN, NaN, '--', 'Color', [0.4 0.4 0.4], 'LineWidth', 2.0, ...
    'Marker', 'none', 'DisplayName', 'Dashed (--) : Voronoi Area-Weighted');
hMeanUGuide  = plot(ax, NaN, NaN, '-', 'Color', [0.4 0.4 0.4], 'LineWidth', 0.5, ...
    'Marker', 'none', 'DisplayName', 'Thin Solid (0.5 pt) : Unweighted Mean');
hMeanWGuide  = plot(ax, NaN, NaN, '--', 'Color', [0.4 0.4 0.4], 'LineWidth', 0.5, ...
    'Marker', 'none', 'DisplayName', 'Thin Dashed (0.5 pt) : Voronoi W-Mean');

validMetrics = hMetrics(isgraphics(hMetrics));
if isCdf
    hMedGuide = plot(ax, NaN, NaN, ':', 'Color', [0.65 0.65 0.65], 'LineWidth', 1.0, ...
        'Marker', 'none', 'DisplayName', 'Dotted Gray (...) : Median (CDF = 0.5)');
    legend(ax, [validMetrics; hSolidGuide; hDashGuide; hMeanUGuide; hMeanWGuide; hMedGuide], ...
        'Location', 'northwest', 'FontSize', 8.0);
else
    legend(ax, [validMetrics; hSolidGuide; hDashGuide; hMeanUGuide; hMeanWGuide], ...
        'Location', 'northwest', 'FontSize', 8.0);
end
end

function xLimits = computeCombinedPdfXLimits(uList, fList, clipFrac, meanVals, expandFactor)
% Computes systematic tight logarithmic x-limits by summing all active PDF curves
% onto a common log10 grid, clipping outer tails where the combined density
% drops below clipFrac (default 0.05 = 5%) of the combined maximum, and extending
% the clipped log-range symmetrically by expandFactor (default 1.1 = +5% each side).
if nargin < 3 || isempty(clipFrac), clipFrac = 0.05; end
if nargin < 5 || isempty(expandFactor), expandFactor = 1.1; end
if isempty(uList)
    xLimits = [1e-6, 1.0];
    return;
end

uMin = min(cellfun(@min, uList));
uMax = max(cellfun(@max, uList));
if ~isfinite(uMin) || ~isfinite(uMax)
    xLimits = [1e-6, 1.0];
    return;
elseif uMin == uMax
    uMin = uMin - 0.5;
    uMax = uMax + 0.5;
end

uGrid = linspace(uMin, uMax, 1200);
combinedPDF = zeros(size(uGrid));
for k = 1:numel(uList)
    uk = uList{k}(:);
    fk = fList{k}(:);
    if numel(uk) < 2, continue; end
    [uUnique, idxU] = unique(uk, 'stable');
    fUnique = fk(idxU);
    combinedPDF = combinedPDF + interp1(uUnique, fUnique(:)', uGrid, 'linear', 0);
end

maxCombined = max(combinedPDF);
if maxCombined > 0
    aboveThresh = find(combinedPDF >= clipFrac * maxCombined);
    if ~isempty(aboveThresh)
        uLeft  = uGrid(aboveThresh(1));
        uRight = uGrid(aboveThresh(end));
    else
        uLeft = uMin;
        uRight = uMax;
    end
else
    uLeft = uMin;
    uRight = uMax;
end

% Extend clipped log-range symmetrically around its midpoint (e.g. 1.1x -> +5% each side)
if expandFactor ~= 1.0 && (uRight > uLeft)
    uMid = 0.5 * (uLeft + uRight);
    halfSpan = 0.5 * (uRight - uLeft) * expandFactor;
    uLeft  = uMid - halfSpan;
    uRight = uMid + halfSpan;
end

% Ensure all overlaid mean plumb lines and vertical labels remain strictly in view
if nargin >= 4 && ~isempty(meanVals)
    posMeans = meanVals(isfinite(meanVals) & (meanVals > 0));
    if ~isempty(posMeans)
        logMeans = log10(posMeans);
        uLeft  = min(uLeft,  min(logMeans) - 0.15);
        uRight = max(uRight, max(logMeans) + 0.15);
    end
end

if uRight <= uLeft
    uRight = uLeft + 1.0;
end
xLimits = 10.^[uLeft, uRight];
end

function renderCarpetMap(ax, c1, c2, v, cmap, cLimits, titleStr, cbarLabel, isLogScale, axis1Label, axis2Label, fontText)
if nargin < 9,  isLogScale = false; end
if nargin < 10 || isempty(axis1Label), axis1Label = 'Coordinate 1'; end
if nargin < 11 || isempty(axis2Label), axis2Label = 'Coordinate 2'; end
if nargin < 12 || isempty(fontText),   fontText   = 'Fira Sans'; end

hold(ax, 'on'); box(ax, 'on'); grid(ax, 'on');
set(ax, 'FontName', fontText, 'TickDir', 'in', 'TickLength', [0.015, 0.025], ...
    'XMinorTick', 'on', 'YMinorTick', 'on');

if isLogScale
    vWork = log10(max(v, 1e-12));
else
    vWork = v;
end

validWork = vWork(isfinite(vWork));
if ischar(cLimits) || isstring(cLimits) || isempty(cLimits)
    if isempty(validWork)
        cMin = 0; cMax = 1;
    else
        cMin = min(validWork);
        cMax = max(validWork);
        if cMin == cMax, cMax = cMin + 1; end
    end
    cLimits = [cMin, cMax];
end

nP = 220; nR = 220;
pq = linspace(min(c1), max(c1), nP);
rq = linspace(min(c2), max(c2), nR);
[Pq, Rq] = meshgrid(pq, rq);

warnState = warning('off', 'MATLAB:scatteredInterpolant:DupPtsAvValuesWarnId');
F = scatteredInterpolant(c1, c2, vWork, 'natural', 'none');
warning(warnState);
Zq = F(Pq, Rq);

try
    k = convhull(c1, c2);
    inHull = inpolygon(Pq, Rq, c1(k), c2(k));
    Zq(~inHull) = NaN;
catch
end

hSurf = pcolor(ax, Pq, Rq, Zq);
shading(ax, 'interp');
set(hSurf, 'EdgeColor', 'none');

colormap(ax, cmap);
cb = colorbar(ax);
ylabel(cb, cbarLabel, 'FontSize', 9, 'FontWeight', 'bold');

if diff(cLimits) > 0
    clim(ax, cLimits);
end

xlabel(ax, axis1Label, 'FontWeight', 'bold');
ylabel(ax, axis2Label, 'FontWeight', 'bold');
title(ax, titleStr, 'FontSize', 11, 'FontWeight', 'bold');
axis(ax, 'tight');
end

%% ========================================================================
%  Voronoi Tessellation & Statistical Computation Helpers
% =========================================================================

function [w, areas, totalHullArea] = computeVoronoiAreaWeights(p, r)
pts = [p(:), r(:)];
N = size(pts, 1);

k = convhull(pts(:, 1), pts(:, 2));
hullPts = pts(k(1:end-1), :);
warnPoly = warning('off', 'MATLAB:polyshape:repairedBySimplify');
hullPoly = polyshape(hullPts(:, 1), hullPts(:, 2), 'Simplify', false);
totalHullArea = area(hullPoly);

cx = mean(pts(:, 1));
cy = mean(pts(:, 2));
span = 5 * max(max(pts(:, 1)) - min(pts(:, 1)), max(pts(:, 2)) - min(pts(:, 2)));
if span == 0, span = 1; end
theta = linspace(0, 2*pi, 33)';
theta(end) = [];
ghostPts = [cx + span * cos(theta), cy + span * sin(theta)];

dt = delaunayTriangulation([pts; ghostPts]);
[V, R] = voronoiDiagram(dt);
inHullV = inpolygon(V(:, 1), V(:, 2), hullPts(:, 1), hullPts(:, 2));

areas = zeros(N, 1);
for i = 1:N
    idx = R{i};
    vx = V(idx, 1);
    vy = V(idx, 2);
    if all(inHullV(idx))
        areas(i) = 0.5 * abs(sum(vx .* [vy(2:end); vy(1)] - [vx(2:end); vx(1)] .* vy));
    else
        cellPoly = polyshape(vx, vy, 'Simplify', false);
        clippedPoly = intersect(cellPoly, hullPoly);
        areas(i) = area(clippedPoly);
    end
end
warning(warnPoly);

areas = max(areas, eps);
w = areas / sum(areas);
end

function qVals = weightedPrctile(x, w, pcts)
valid = isfinite(x) & isfinite(w) & (w > 0);
x = x(valid);
w = w(valid);
[xSort, sIdx] = sort(x(:));
wSort = w(sIdx);
wSort = wSort / sum(wSort);

cumW = cumsum(wSort) - 0.5 * wSort;
[cumWUnique, uIdx] = unique(cumW, 'stable');
xUnique = xSort(uIdx);

qTargets = pcts(:)' / 100;
if isscalar(xUnique)
    qVals = repmat(xUnique, size(qTargets));
else
    qVals = interp1(cumWUnique, xUnique, qTargets, 'linear', 'extrap');
    qVals = max(min(qVals, xSort(end)), xSort(1));
end
end

function Rw = computeWeightedCorrMatrix(X, Y, w)
w = w(:) / sum(w);
muX = sum(w .* X, 1);
muY = sum(w .* Y, 1);
dX = X - muX;
dY = Y - muY;
covXY = (dX' * (w .* dY));
varX  = sum(w .* (dX.^2), 1)';
varY  = sum(w .* (dY.^2), 1)';
Rw = covXY ./ sqrt(max(varX * varY', eps));
end

function printErrorSummaryTable(titleTag, metricNames, statStruct, useWeighted, isLogTable)
prefix = ternaryStr(useWeighted, 'W-', '');
wMet = max([12, cellfun(@length, metricNames)]);
wSrc = max([20, cellfun(@(m) length(statStruct.(m).source), metricNames)]);
ruleWidth = wMet + wSrc + 106;
dblBar = repmat('=', 1, ruleWidth);
sglBar = repmat('-', 1, ruleWidth);

fprintf('%s\n  %s\n%s\n', dblBar, titleTag, dblBar);
if ~isLogTable
    fprintf(['%-' num2str(wMet) 's | %-' num2str(wSrc) 's | %-11s %-11s %-11s | %-11s %-11s %-11s %-11s %-11s\n'], ...
        'Metric', 'Comparison', [prefix 'MAE'], [prefix 'RMSE'], [prefix 'NRMSE(%)'], ...
        [prefix 'Med(%)'], [prefix 'Mean(%)'], [prefix '90th(%)'], [prefix '99th(%)'], 'Max (%)');
    fprintf('%s\n', sglBar);
    for i = 1:numel(metricNames)
        r = statStruct.(metricNames{i});
        fprintf(['%-' num2str(wMet) 's | %-' num2str(wSrc) 's | %-11.4e %-11.4e %-11.4f | %-11.4f %-11.4f %-11.4f %-11.4f %-11.4f\n'], ...
            r.name, r.source, r.MAE, r.RMSE, r.NRMSE_Pct, ...
            r.MedianRelPct, r.MeanRelPct, r.P90RelPct, r.P99RelPct, r.MaxRelPct);
    end
else
    fprintf(['%-' num2str(wMet) 's | %-' num2str(wSrc) 's | %-14s %-14s %-14s %-14s %-14s\n'], ...
        'Metric', 'Comparison', [prefix 'Med Log Err'], [prefix 'Mean Log Err'], ...
        'Max Log Err', [prefix 'RMSLE (dex)'], [prefix 'N-RMSLE (%)']);
    fprintf('%s\n', sglBar);
    for i = 1:numel(metricNames)
        r = statStruct.(metricNames{i});
        fprintf(['%-' num2str(wMet) 's | %-' num2str(wSrc) 's | %-14.4e %-14.4e %-14.4e %-14.4e %-14.4f\n'], ...
            r.name, r.source, r.MedianLogErr, r.MeanLogErr, r.MaxLogErr, r.RMSLE, r.NRMSLE_Pct);
    end
end
fprintf('%s\n\n', dblBar);
end

function printBaselineComparisonTable(metricNames, results, resultsWeighted)
wMet = max([12, cellfun(@length, metricNames)]);
ruleWidth = wMet + 102;
dblBar = repmat('=', 1, ruleWidth);
sglBar = repmat('-', 1, ruleWidth);

fprintf('%s\n  MEAN BASELINE COMPARISON: UNWEIGHTED SAMPLE MEAN vs. VORONOI AREA-WEIGHTED MEAN\n%s\n', dblBar, dblBar);
fprintf(['%-' num2str(wMet) 's | %-18s | %-18s | %-18s | %-18s | %-14s\n'], ...
    'Metric', 'Unweighted Mean', 'Voronoi W-Mean', 'Unweighted Median', 'Voronoi W-Median', 'W-Mean / Mean');
fprintf('%s\n', sglBar);
for i = 1:numel(metricNames)
    ru = results.(metricNames{i});
    rw = resultsWeighted.(metricNames{i});
    fprintf(['%-' num2str(wMet) 's | %-18.4e | %-18.4e | %-18.4e | %-18.4e | %-14.4f\n'], ...
        ru.name, ru.MeanBaseline, rw.MeanBaseline, ru.MedianBaseline, rw.MedianBaseline, rw.MeanBaseline / max(abs(ru.MeanBaseline), eps));
end
fprintf('%s\n\n', dblBar);
end

function printCorrelationTables(headerTag, metricLabels, R_cross, R_err, R_base, numCommon)
M = numel(metricLabels);
wRow = max([16, cellfun(@length, metricLabels) + 1]);
wCol = max([14, cellfun(@length, metricLabels) + 6]);
ruleWidth = max(80, wRow + 3 + (wCol + 1) * M);
dblBar = repmat('=', 1, ruleWidth);
sepLine = repmat('-', 1, ruleWidth);

fprintf('%s\n  %s CROSS-CORRELATIONS OF LOG BASELINES & ERRORS (N = %d)\n%s\n', dblBar, headerTag, numCommon, dblBar);

printMatrixBlock('--- 1. Cross-Correlation R(Log10 Baseline, Log10 Absolute Error) ---', ...
    'Baseline Metric', 'Err', metricLabels, R_cross, sepLine, wRow, wCol);
diagStr = arrayfun(@(k) sprintf('%s (%.4f)', metricLabels{k}, R_cross(k, k)), 1:M, 'UniformOutput', false);
fprintf('  * Diagonal intra-metric scaling: %s\n\n', strjoin(diagStr, ', '));

printMatrixBlock('--- 2. Error-Error Correlation R(Log10 Absolute Error, Log10 Absolute Error) ---', ...
    'Error Metric', 'Err', metricLabels, R_err, sepLine, wRow, wCol);

printMatrixBlock('--- 3. Baseline-Baseline Correlation R(Log10 Baseline, Log10 Baseline) ---', ...
    'Baseline Metric', 'Base', metricLabels, R_base, sepLine, wRow, wCol);

fprintf('%s\n\n', dblBar);
end

function printMatrixBlock(titleLine, rowHdr, colPrefix, labels, Mmat, sepLine, wRow, wCol)
M = numel(labels);
fprintf('%s\n', titleLine);
fprintf(['%-' num2str(wRow) 's | '], rowHdr);
for j = 1:M
    fprintf(['%-' num2str(wCol) 's '], sprintf('%s(%s)', colPrefix, labels{j}));
end
fprintf('\n%s\n', sepLine);
for i = 1:M
    fprintf(['%-' num2str(wRow) 's | '], labels{i});
    for j = 1:M
        fprintf(['%-' num2str(wCol) '.4f '], Mmat(i, j));
    end
    fprintf('\n');
end
fprintf('%s\n\n', sepLine);
end

function res = computeMetricErrorStruct(name, y1, y2, pVals, rVals, sourceStr, w)
if nargin < 7, w = []; end
diff_val = y2 - y1;
abs_diff = abs(diff_val);
y_avg    = (y1 + y2) / 2;

rel_err = (abs_diff ./ max(abs(y1), eps)) * 100;

log1 = log10(max(abs(y1), eps));
log2 = log10(max(abs(y2), eps));
log_diff = abs(log2 - log1);
logRange = max(log1) - min(log1);
physRange = max(y1) - min(y1);

res = struct();
res.name = char(name);
res.source = char(sourceStr);
res.y1 = y1;
res.y2 = y2;
res.yAvg = y_avg;
res.pVals = pVals;
res.rVals = rVals;
res.diff = diff_val;
res.absDiff = abs_diff;
res.relErrPct = rel_err;
res.logDiff = log_diff;
res.weights = w;

if isempty(w)
    res.MeanBaseline   = mean(y_avg, 'omitnan');
    res.MedianBaseline = median(y_avg, 'omitnan');

    res.MAE  = mean(abs_diff, 'omitnan');
    res.RMSE = sqrt(mean(diff_val.^2, 'omitnan'));
    res.NRMSE_Pct = (res.RMSE / max(physRange, eps)) * 100;
    res.MaxAbsErr = max(abs_diff);

    res.MedianRelPct = median(rel_err, 'omitnan');
    res.MeanRelPct   = mean(rel_err, 'omitnan');
    res.P90RelPct    = prctile(rel_err, 90);
    res.P95RelPct    = prctile(rel_err, 95);
    res.P99RelPct    = prctile(rel_err, 99);
    res.MaxRelPct    = max(rel_err);

    res.MedianLogErr = median(log_diff, 'omitnan');
    res.MeanLogErr   = mean(log_diff, 'omitnan');
    res.MaxLogErr    = max(log_diff);
    res.RMSLE        = sqrt(mean((log2 - log1).^2, 'omitnan'));
    res.NRMSLE_Pct   = (res.RMSLE / max(logRange, eps)) * 100;
else
    w = w(:) / sum(w);
    res.MeanBaseline   = sum(w .* y_avg);
    res.MedianBaseline = weightedPrctile(y_avg, w, 50);

    res.MAE  = sum(w .* abs_diff);
    res.RMSE = sqrt(sum(w .* (diff_val.^2)));
    res.NRMSE_Pct = (res.RMSE / max(physRange, eps)) * 100;
    res.MaxAbsErr = max(abs_diff);

    qRel = weightedPrctile(rel_err, w, [50, 90, 95, 99]);
    res.MedianRelPct = qRel(1);
    res.MeanRelPct   = sum(w .* rel_err);
    res.P90RelPct    = qRel(2);
    res.P95RelPct    = qRel(3);
    res.P99RelPct    = qRel(4);
    res.MaxRelPct    = max(rel_err);

    res.MedianLogErr = weightedPrctile(log_diff, w, 50);
    res.MeanLogErr   = sum(w .* log_diff);
    res.MaxLogErr    = max(log_diff);
    res.RMSLE        = sqrt(sum(w .* ((log2 - log1).^2)));
    res.NRMSLE_Pct   = (res.RMSLE / max(logRange, eps)) * 100;
end
end
