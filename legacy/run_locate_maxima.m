% run_locate_maxima  Locate spectral-average maxima via MultiStart.
%
% This script loads a trained model (and optionally regenerates dense
% predictions) before running the MultiStart-based search implemented in
% find_local_maxima. Results are displayed in the command window and
% overlaid on a pcolor map of the spectral average.

%% Configuration
workDir = pwd;
riCsv = fullfile(pwd, "McPeak.csv");
outputModelFile = fullfile(pwd, "sers_dnn_model_cylinder_all.mat");
outputPredictionFile = fullfile(pwd, "sers_dnn_dense_predictions_cylinder_all.mat");

metricsToTrain = {'Absorptance'}; % primary metric must match the trained model
ratioLimit = [0, 0.49]; % [min, max] r/p ratio allowed during the search


recomputePredictions = true; % default to loading cached predictions unless user overrides

pSamples = linspace(0.800, 0.950, 301);   % um (used if recomputing)
rSamples = linspace(0.050, 0.500, 451);   % um (used if recomputing)
lambdaSamples = linspace(0.785, 0.785, 1); % um (used if recomputing)

% MultiStart parameters
numLocalMaxima = 15;
multiStartPoints = 1000;
multiStartUseParallel = true;
multiStartDisplay = 'off'; % 'off'|'final'|'iter'|'diagnose'
InitialPoints = [];
FunctionTolerance = 1e-9;
StepTolerance = 1e-9;
MaxIterations = 1e4;

%% Candidate search parameters
gradientPercentile = 50; % percentile threshold for gradient magnitude pruning
laplacianFactor = 1;   % fraction of strongest negative Laplacian retained
neighborSuppressionRadius = 3; % grid cells suppressed around accepted seeds
localWindowRadiusSteps = 6;    % half-width in grid steps for local MultiStart bounds
minLocalWindow = 0.001;         % minimum half-width (um) for local bounds safety
neighborTolerance = 1e-9;      % tolerance when comparing neighbours for plateaus

%% Normalise metric selection
availableTargets = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'};
aliasKeys = {'absorptance','abs','m_vol','mvol','m_surf','msurf','ef_vol','efvol','ef_surf','efsrf'};
aliasValues = {'Absorptance','Absorptance','M_vol','M_vol','M_surf','M_surf','EF_vol','EF_vol','EF_surf','EF_surf'};
aliasMap = containers.Map(aliasKeys, aliasValues);
normalizedTargets = cellfun(@(s) lower(regexprep(s, '\s+', '')), metricsToTrain, 'UniformOutput', false);
metricsCanonical = cell(size(normalizedTargets));
for tIdx = 1:numel(normalizedTargets)
    key = regexprep(normalizedTargets{tIdx}, '[^a-z0-9_]', '');
    if isKey(aliasMap, key)
        metricsCanonical{tIdx} = aliasMap(key);
    else
        matchIdx = find(strcmpi(key, availableTargets), 1);
        if isempty(matchIdx)
            error('run_locate_maxima:UnknownMetric', ...
                'Unsupported metric "%s". Valid options: %s', metricsToTrain{tIdx}, strjoin(availableTargets, ', '));
        end
        metricsCanonical{tIdx} = availableTargets{matchIdx};
    end
end
metricsToTrain = unique(metricsCanonical, 'stable');
if isempty(metricsToTrain)
    error('run_locate_maxima:NoMetrics', 'metricsToTrain must contain at least one metric.');
end
primaryMetric = metricsToTrain{1};
primaryMetricAvgField = matlab.lang.makeValidName([primaryMetric, '_avg']);
primaryMetricLabel = strrep(primaryMetric, '_', '\_');

%% Load model and refractive index
if ~isfile(outputModelFile)
    error('run_locate_maxima:MissingModel', 'Trained model not found: %s', outputModelFile);
end
modelStruct = load(outputModelFile, 'model');
if ~isfield(modelStruct, 'model')
    error('run_locate_maxima:InvalidModelFile', 'File %s does not contain variable ''model''.', outputModelFile);
end
model = modelStruct.model;

ri = load_gold_refractive_index(riCsv, 'WavelengthUnit', 'um');

%% Ensure dense predictions are available
if recomputePredictions
    fprintf('Regenerating dense predictions for metric %s...\n', primaryMetric);
    predictions = predict_dense_spectrum(model, pSamples, rSamples, lambdaSamples, ri);
    save(outputPredictionFile, 'predictions', 'pSamples', 'rSamples', 'lambdaSamples');
    fprintf('Saved dense prediction volumes to %s\n', outputPredictionFile);
end

if ~exist('predictions', 'var')
    if ~isfile(outputPredictionFile)
        error('run_locate_maxima:MissingPredictions', ...
            'Dense predictions file not found: %s. Set recomputePredictions=true to regenerate.', outputPredictionFile);
    end
    loadedPred = load(outputPredictionFile, 'predictions', 'pSamples', 'rSamples', 'lambdaSamples');
    if ~isfield(loadedPred, 'predictions')
        error('run_locate_maxima:InvalidPredictionFile', ...
            'File %s does not contain variable ''predictions''.', outputPredictionFile);
    end
    predictions = loadedPred.predictions;
    if isfield(loadedPred, 'pSamples'), pSamples = loadedPred.pSamples; end
    if isfield(loadedPred, 'rSamples'), rSamples = loadedPred.rSamples; end
    if isfield(loadedPred, 'lambdaSamples'), lambdaSamples = loadedPred.lambdaSamples; end
    fprintf('Loaded dense predictions from %s\n', outputPredictionFile);
end

if ~isfield(predictions, 'PGrid') || ~isfield(predictions, 'RGrid')
    error('run_locate_maxima:MissingGrids', 'Predictions must include PGrid and RGrid for visualisation.');
end

%% Prepare MultiStart parameters
if isempty(lambdaSamples)
    error('run_locate_maxima:LambdaSamples', 'lambdaSamples must be available for the MultiStart search.');
end

ratioLowerVal = 0;
ratioUpperVal = inf;
if ~isempty(ratioLimit)
    ratioLowerVal = ratioLimit(1);
    if numel(ratioLimit) >= 2
        ratioUpperVal = ratioLimit(2);
    end
end

pBounds = [min(pSamples), max(pSamples)];
rBounds = [min(rSamples), max(rSamples)];

if exist('find_local_maxima', 'file') ~= 2
    error('run_locate_maxima:HelperMissing', 'find_local_maxima.m not available on the MATLAB path.');
end

%% Analyse dense grid and seed local MultiStart runs
avgMetricGrid = double(predictions.(primaryMetricAvgField));
if ~any(isfinite(avgMetricGrid), 'all')
    error('run_locate_maxima:AvgGridEmpty', 'No finite samples found in %s.', primaryMetricAvgField);
end

pSamples = double(pSamples(:)');
rSamples = double(rSamples(:)');
if size(avgMetricGrid, 1) ~= numel(rSamples) || size(avgMetricGrid, 2) ~= numel(pSamples)
    error('run_locate_maxima:GridSizeMismatch', ...
        'Averaged grid size (%dx%d) does not match sample vectors (%d x %d).', ...
        size(avgMetricGrid, 1), size(avgMetricGrid, 2), numel(rSamples), numel(pSamples));
end

dpSpacing = localGridSpacing(pSamples);
drSpacing = localGridSpacing(rSamples);
if dpSpacing <= 0 || drSpacing <= 0
    error('run_locate_maxima:Spacing', 'Require at least two unique samples in p and r to compute gradients.');
end

[dFdR, dFdP] = gradient(avgMetricGrid, drSpacing, dpSpacing);
gradMagnitude = hypot(dFdP, dFdR); % gradient magnitude field

[pMesh, rMesh] = meshgrid(pSamples, rSamples);
divergenceField = divergence(pMesh, rMesh, dFdP, dFdR);
laplacianField = del2(avgMetricGrid, drSpacing, dpSpacing);

finiteMask = isfinite(avgMetricGrid);
gradFinite = gradMagnitude(finiteMask);
if isempty(gradFinite)
    gradThreshold = inf;
else
    gradSorted = sort(gradFinite(:));
    idx = max(1, round(numel(gradSorted) * gradientPercentile / 100));
    gradThreshold = max(1e-6, gradSorted(idx));
end

laplaceFinite = laplacianField(finiteMask);
if isempty(laplaceFinite)
    laplacianThreshold = 0;
else
    laplaceMin = min(laplaceFinite);
    if laplaceMin < 0
        laplacianThreshold = -max(1e-6, laplacianFactor * abs(laplaceMin));
    else
        laplacianThreshold = 0;
    end
end

basePeakMask = localFindLocalMaxima(avgMetricGrid, finiteMask, neighborTolerance);
peakMask = basePeakMask & (gradMagnitude <= gradThreshold);
if laplacianThreshold < 0
    peakMask = peakMask & (laplacianField <= laplacianThreshold);
else
    peakMask = peakMask & (laplacianField < 0);
end

ratioMask = true(size(avgMetricGrid));
if ratioLowerVal > 0 || isfinite(ratioUpperVal)
    ratioGrid = rMesh ./ pMesh;
    if ratioLowerVal > 0
        ratioMask = ratioMask & (ratioGrid >= ratioLowerVal);
    end
    if isfinite(ratioUpperVal)
        ratioMask = ratioMask & (ratioGrid <= ratioUpperVal);
    end
end
peakMask = peakMask & ratioMask;

if ~any(peakMask(:))
    warning('run_locate_maxima:FiltersTooRestrictive', ['Gradient/Laplacian filters removed all candidates; ', ...
        'falling back to raw local maxima.']);
    peakMask = basePeakMask & ratioMask;
end

peakMask(1,:) = false;
peakMask(end,:) = false;
peakMask(:,1) = false;
peakMask(:,end) = false;

[candRows, candCols] = find(peakMask);
candidateIdx = sub2ind(size(avgMetricGrid), candRows, candCols);
candidateValues = avgMetricGrid(candidateIdx);
[candidateValues, sortOrder] = sort(candidateValues, 'descend');
candRows = candRows(sortOrder);
candCols = candCols(sortOrder);
candidateIdx = candidateIdx(sortOrder);

keepMask = localSuppressCandidates(candRows, candCols, neighborSuppressionRadius, size(avgMetricGrid));
candRows = candRows(keepMask);
candCols = candCols(keepMask);
candidateIdx = candidateIdx(keepMask);
candidateValues = candidateValues(keepMask);

candidateCount = numel(candidateValues);
candP = pSamples(candCols);
candR = rSamples(candRows);
candRatio = candR ./ candP;
candGrad = gradMagnitude(candidateIdx);
candLap = laplacianField(candidateIdx);
candDiv = divergenceField(candidateIdx);

candidateTable = table((1:candidateCount)', candP(:), candR(:), candRatio(:), candidateValues(:), ...
    candGrad(:), candLap(:), candDiv(:), 'VariableNames', ...
    {'CandidateIndex','P_um','R_um','Ratio','GridValue','GradMag','Laplacian','Divergence'});

if candidateCount == 0
    warning('run_locate_maxima:NoCandidates', ['No stationary points detected in dense grid; ', ...
        'falling back to global MultiStart search.']);
    fprintf('Running global MultiStart search for metric %s...\n', primaryMetric);
    [maximaResults, msSolutions, msOutput] = find_local_maxima(model, ri, lambdaSamples, ...
        'MetricName', primaryMetric, ...
        'InitialPoints', InitialPoints, ...
        'FunctionTolerance', FunctionTolerance, ...
        'StepTolerance', StepTolerance, ...
        'MaxIterations', MaxIterations, ...
        'NumMaxima', numLocalMaxima, ...
        'NumStartPoints', multiStartPoints, ...
        'PBounds', pBounds, ...
        'RBounds', rBounds, ...
        'RatioLower', ratioLowerVal, ...
        'RatioUpper', ratioUpperVal, ...
        'UseParallel', multiStartUseParallel, ...
        'Display', multiStartDisplay);
    if isempty(maximaResults)
        warning('run_locate_maxima:NoMaximaFound', 'Global MultiStart search completed but returned no maxima.');
    else
        disp('Top spectral-average maxima identified via MultiStart:');
        disp(maximaResults);
    end
else
    fprintf('Identified %d candidate maxima from dense grid analysis.\n', candidateCount);
    disp(candidateTable);

    maxSeeds = min(numLocalMaxima, candidateCount);
    if maxSeeds < candidateCount
        fprintf('Refining top %d candidates (of %d total).\n', maxSeeds, candidateCount);
    end

    localPadP = max(localWindowRadiusSteps * dpSpacing, minLocalWindow);
    localPadR = max(localWindowRadiusSteps * drSpacing, minLocalWindow);
    localStartPoints = max(20, ceil(multiStartPoints / max(1, maxSeeds)));

    maximaBlocks = cell(0, 1);
    for seedIdx = 1:maxSeeds
        pSeed = candP(seedIdx);
        rSeed = candR(seedIdx);

        pLocal = [max(pBounds(1), pSeed - localPadP), min(pBounds(2), pSeed + localPadP)];
        rLocal = [max(rBounds(1), rSeed - localPadR), min(rBounds(2), rSeed + localPadR)];

        if pLocal(1) >= pLocal(2)
            pLocal = [max(pBounds(1), pSeed - dpSpacing), min(pBounds(2), pSeed + dpSpacing)];
        end
        if rLocal(1) >= rLocal(2)
            rLocal = [max(rBounds(1), rSeed - drSpacing), min(rBounds(2), rSeed + drSpacing)];
        end

        rLocal(1) = max(rLocal(1), ratioLowerVal * pLocal(1));
        if isfinite(ratioUpperVal)
            rLocal(2) = min(rLocal(2), ratioUpperVal * pLocal(2));
        end
        if rLocal(1) >= rLocal(2)
            rLocal = [max(rBounds(1), rSeed - drSpacing), min(rBounds(2), rSeed + drSpacing)];
        end

        fprintf('  Refining seed #%d at [p=%.4f, r=%.4f] with local bounds p=[%.4f,%.4f], r=[%.4f,%.4f]...\n', ...
            seedIdx, pSeed, rSeed, pLocal(1), pLocal(2), rLocal(1), rLocal(2));
        
        try
            [localMax, ~, ~] = find_local_maxima(model, ri, lambdaSamples, ...
                'MetricName', primaryMetric, ...
                'InitialPoints', [pSeed, rSeed], ...
                'FunctionTolerance', FunctionTolerance, ...
                'StepTolerance', StepTolerance, ...
                'MaxIterations', MaxIterations, ...
                'NumMaxima', 1, ...
                'NumStartPoints', localStartPoints, ...
                'PBounds', pLocal, ...
                'RBounds', rLocal, ...
                'RatioLower', ratioLowerVal, ...
                'RatioUpper', ratioUpperVal, ...
                'UseParallel', multiStartUseParallel, ...
                'Display', 'final');
        catch err
            warning('run_locate_maxima:LocalRefinementFailed', ...
                'Local refinement failed for candidate %d (%s). Error: %s', ...
                seedIdx, primaryMetric, err.message);
            fprintf('  Stack trace:\n%s\n', err.getReport());
            continue;
        end

        if isempty(localMax)
            fprintf('  Seed #%d returned empty result.\n', seedIdx);
            continue;
        end
        
        fprintf('  Seed #%d converged to [p=%.4f, r=%.4f] with %s=%.4g\n', ...
            seedIdx, localMax.P_um(1), localMax.R_um(1), primaryMetric, localMax.(primaryMetricAvgField)(1));

        localMax.SeedIndex = repmat(seedIdx, height(localMax), 1);
        localMax.SeedP_um = repmat(pSeed, height(localMax), 1);
        localMax.SeedR_um = repmat(rSeed, height(localMax), 1);
        localMax.SeedValue = repmat(candidateValues(seedIdx), height(localMax), 1);
        maximaBlocks{end+1} = localMax; %#ok<AGROW>
    end

    if isempty(maximaBlocks)
        warning('run_locate_maxima:NoRefinedMaxima', 'Local refinement returned no maxima.');
        maximaResults = table();
    else
        maximaResults = vertcat(maximaBlocks{:});
        maximaResults = sortrows(maximaResults, {'SeedIndex', primaryMetricAvgField}, {'ascend','descend'});
    end

    if ~isempty(maximaResults)
        fprintf('Refined %d maxima via localised MultiStart runs (one per region).\n', height(maximaResults));
        disp(maximaResults);
    else
        warning('run_locate_maxima:NoMaximaFound', 'Local refinement completed but returned no maxima.');
    end

    msSolutions = [];
    msOutput = [];
end

%% Visualise average map with maxima overlay
if exist('avgMetricGrid', 'var') && ~isempty(avgMetricGrid)
    figure;
    hPcolor = pcolor(pMesh * 1e3, rMesh * 1e3, avgMetricGrid);
    set(hPcolor, 'EdgeColor', 'none');
    set(gca, 'YDir', 'normal');
    xlabel('p (nm)');
    ylabel('r (nm)');
    title(sprintf('Average %s across \\lambda', primaryMetricLabel));
    colorbar;
    hold on;
    legendEntries = {};
    legendHandles = [];
    if ~isempty(candidateTable)
        hSeeds = scatter(candidateTable.P_um * 1e3, candidateTable.R_um * 1e3, 36, 'k', 'x', 'LineWidth', 1.1);
        legendHandles(end+1) = hSeeds; %#ok<AGROW>
        legendEntries{end+1} = 'Seeds'; %#ok<AGROW>
    end
    if exist('maximaResults', 'var') && istable(maximaResults) && ~isempty(maximaResults)
        hMax = scatter(maximaResults.P_um * 1e3, maximaResults.R_um * 1e3, 70, 'w', 'filled', 'MarkerEdgeColor', 'k');
        legendHandles(end+1) = hMax; %#ok<AGROW>
        legendEntries{end+1} = 'Refined maxima'; %#ok<AGROW>
        for idx = 1:height(maximaResults)
            text(maximaResults.P_um(idx) * 1e3, maximaResults.R_um(idx) * 1e3, ...
                sprintf('  #%d', idx), 'Color', 'w', 'FontWeight', 'bold');
        end
    end
    if ~isempty(legendEntries)
        legend(legendHandles, legendEntries, 'Location', 'southoutside', 'Orientation', 'horizontal');
    end
    hold off;
else
    warning('run_locate_maxima:AvgFieldMissing', ...
        'Predictions do not contain averaged field %s.', primaryMetricAvgField);
end

%% Local helpers
function peakMask = localFindLocalMaxima(grid, finiteMask, tol)
gridSize = size(grid);
gridClean = grid;
gridClean(~finiteMask) = -inf;
gridPadded = -inf(gridSize(1) + 2, gridSize(2) + 2);
gridPadded(2:end-1, 2:end-1) = gridClean;
center = gridPadded(2:end-1, 2:end-1);
peakMask = finiteMask;
offsets = [-1 -1; -1 0; -1 1; 0 -1; 0 1; 1 -1; 1 0; 1 1];
for k = 1:size(offsets, 1)
    dy = offsets(k, 1);
    dx = offsets(k, 2);
    neighbor = gridPadded((2+dy):(end-1+dy), (2+dx):(end-1+dx));
    peakMask = peakMask & (center >= neighbor - tol);
end
peakMask(~finiteMask) = false;
end

function keepMask = localSuppressCandidates(rows, cols, radius, gridSize)
numCandidates = numel(rows);
keepMask = false(numCandidates, 1);
if numCandidates == 0
    return;
end
selected = false(gridSize);
for idx = 1:numCandidates
    r = rows(idx);
    c = cols(idx);
    rRange = max(1, r - radius):min(gridSize(1), r + radius);
    cRange = max(1, c - radius):min(gridSize(2), c + radius);
    if any(selected(rRange, cRange), 'all')
        continue;
    end
    keepMask(idx) = true;
    selected(rRange, cRange) = true;
end
end

function h = localGridSpacing(samples)
samples = double(samples(:)');
if numel(samples) < 2
    h = 0;
else
    diffs = diff(samples);
    h = median(abs(diffs));
end
end
