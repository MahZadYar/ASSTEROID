function dataset = prepare_training_dataset(allData, ri, options)
% prepare_training_dataset  Convert structure-of-arrays spectra into ML-ready matrices.
%
% dataset = prepare_training_dataset(allData, ri) builds feature and target
% matrices using per-sample inputs [p, r, lambda, n, k] and targets such as
% [Abs, EF_max, EE_V, EE_S] (or legacy [Absorptance, M_vol, M_surf, EF_vol, EF_surf]).
% Geometry and wavelength can be optionally log-transformed before standardisation,
% while near-field targets are stored as log10(1 + targets).
%
% Parameters:
%   Holdout         (default 0.2) - fraction reserved for validation+test
%   ValSplit        (default 0.5) - validation fraction within holdout
%   Shuffle         (default true) - shuffle entries before splitting
%   RatioLimit      (default []) - optional [min max] allowed for r./p
%   TargetFields    (default ["Absorptance","M_vol","M_surf","EF_vol","EF_surf"])
%   FeatureSchema   (default "v3_physics") - "v3_physics" | "v2_physics" | "v1_legacy"
%                   v3_physics: 8 features [log P, log r, log lambda, eps1, eps2,
%                   P/lambda, r/lambda, log g_norm] (no h_gap/lambda, which is
%                   redundant for a fixed gap). v2_physics: legacy 8/9 features.
%   SplitMode       (default "geometry") - "geometry" keeps every wavelength
%                   of a (P, r) pair in one split; "row" is the legacy
%                   per-sample split (leaks geometries across splits).
%   IncludeVerticalGap (default false) - v2 only: add h_gap/lambda feature
%                   (ignored with a warning for v3_physics)
%   GapHeightUm     (default 0.005) - v2 only: vertical gap height [µm]
%   Seed            (default 0) - RNG seed for the split
%
% Physics-schema datasets also record per-channel physical bounds in
% dataset.targetTransform (LowerBound, UpperBound, BoundKind), used by the
% bounded output heads of the "gs_tensor" / "lean_resnet" architectures:
%   - log-transformed channels (EE/EF/M):  BoundKind "softplus" (log10(1+y) >= 0)
%   - absorptance (Abs / Absorptance):     BoundKind "sigmoid", [0, 100] if the
%                                           data are in percent, else [0, 1]
%   - any other linear channel:            BoundKind "none"

arguments
    allData struct {mustBeAllDataStruct(allData)}
    ri struct {mustBeRiStruct(ri)}
    options.Holdout (1,1) double {mustBeBetween(options.Holdout, 0, 1)} = 0.2
    options.ValSplit (1,1) double {mustBeBetween(options.ValSplit, 0, 1)} = 0.5
    options.Shuffle (1,1) logical = true
    options.RatioLimit (1,:) double = []
    options.TargetFields (1,:) string = ["Absorptance","M_vol","M_surf","EF_vol","EF_surf"]
    options.FeatureLogTransform (1,1) logical = true
    options.IncludeRatios (1,1) logical = true
    options.TargetLogTransform (1,1) logical = true
    options.FeatureSchema (1,1) string {mustBeMember(options.FeatureSchema, ["v3_physics", "v2_physics", "v1_legacy"])} = "v3_physics"
    options.SplitMode (1,1) string {mustBeMember(options.SplitMode, ["geometry", "row"])} = "geometry"
    options.IncludeVerticalGap (1,1) logical = false
    options.GapHeightUm (1,1) double {mustBePositive} = 0.005
    options.Seed (1,1) double = 0
end

opts = struct();
opts.Holdout = options.Holdout;
opts.ValSplit = options.ValSplit;
opts.Shuffle = options.Shuffle;
opts.RatioLimit = options.RatioLimit;
opts.TargetFields = cellstr(options.TargetFields);
opts.FeatureLogTransform = options.FeatureLogTransform;
opts.IncludeRatios = options.IncludeRatios;
opts.TargetLogTransform = options.TargetLogTransform;
opts.FeatureSchema = options.FeatureSchema;
opts.SplitMode = options.SplitMode;
opts.IncludeVerticalGap = options.IncludeVerticalGap;
opts.GapHeightUm = options.GapHeightUm;
opts.Seed = options.Seed;
isV2 = ismember(opts.FeatureSchema, ["v2_physics", "v3_physics"]);   % any physics schema
if opts.FeatureSchema == "v3_physics" && opts.IncludeVerticalGap
    warning('prepare_training_dataset:VerticalGapIgnored', ...
        ['IncludeVerticalGap is ignored for FeatureSchema="v3_physics": with a fixed ', ...
         'gap, h_gap/lambda is a constant multiple of 1/lambda and adds no information.']);
    opts.IncludeVerticalGap = false;
end
if isV2
    % Ratios are generated inside buildPhysicsFeatures; X stores raw inputs only.
    opts.IncludeRatios = false;
    opts.FeatureLogTransform = true;
end

featureNames = {'p_um','r_um','lambda_um','n','k'};
if opts.IncludeRatios
    featureNames = [featureNames, {'p_over_lambda','r_over_lambda','p_over_r'}];
end
supportedTargets = {'EE_V','EE_S','EF_max','Abs','ECC', ...
                    'Absorptance','M_vol','M_surf','EF_vol','EF_surf', ...
                    'M2_vol','M2_surf','E_vol','E_surf','intW_vol','intW_t'};

targetFields = opts.TargetFields(:)';
numTargets = numel(targetFields);
for k = 1:numTargets
    tfName = targetFields{k};
    if ~ismember(tfName, supportedTargets) && ~isfield(allData, tfName)
        error('prepare_training_dataset:UnknownTarget', 'Unsupported target field: %s', tfName);
    end
end

targetNames = targetFields;
% Target-specific log transform: near-field and Enhancement Efficacy/Factor metrics use log10(1+y),
% while bounded energy ratios (e.g. Abs / Absorptance) remain on their linear physical scale.
logFieldNames = ["EE_V", "EE_S", "EF_max", "EF_vol", "EF_surf", ...
                 "M_vol", "M_surf", "M2_vol", "M2_surf", "intW_vol", "intW_t"];
if islogical(opts.TargetLogTransform) && isscalar(opts.TargetLogTransform) && opts.TargetLogTransform
    targetLogMask = ismember(string(targetFields), logFieldNames);
elseif islogical(opts.TargetLogTransform) && isscalar(opts.TargetLogTransform) && ~opts.TargetLogTransform
    targetLogMask = false(1, numTargets);
else
    targetLogMask = logical(opts.TargetLogTransform);
end

if ~isfield(allData, 'lambda')
    error('prepare_training_dataset:MissingField', 'allData missing field lambda');
end
resolvedDataFields = cell(1, numTargets);
for k = 1:numTargets
    resolvedField = resolveTargetFieldInAllData(allData, targetFields{k});
    if isempty(resolvedField)
        error('prepare_training_dataset:MissingField', 'allData missing field %s', targetFields{k});
    end
    resolvedDataFields{k} = resolvedField;
end

numRows = structRowCount(allData);
if numRows == 0
    error('prepare_training_dataset:Empty', 'allData contains no rows.');
end

% Vectorized feature extraction
fprintf('  Extracting features from %d geometries...\n', numRows);
featList = {};
respList = {};
respListRaw = {};

% Extract geometry columns (period, radius)
pVals = getColumn(allData, 'period');
rVals = getColumn(allData, 'radius');

fprintf(' average p (raw): %.6e , r (raw): %.6e \n', mean(pVals), mean(rVals));

% Convert nanometers to µm (nanometers -> micrometers: multiply by 1e-3)
pVals = double(pVals(:)) * 1e-3;
rVals = double(rVals(:)) * 1e-3;

% Validate geometric values (must be positive for log transform)
if any(pVals <= 0) || any(rVals <= 0)
    invalidP = sum(pVals <= 0);
    invalidR = sum(rVals <= 0);
    warning('prepare_training_dataset:NonPositiveGeometry', ...
        'Found %d non-positive period values and %d non-positive radius values. These will be skipped.', ...
        invalidP, invalidR);
    
    if invalidP > 0
        pMin = min(pVals);
        pMax = max(pVals);
        fprintf('    Period range: [%.6e, %.6e] µm (original unit)\n', pMin, pMax);
    end
    if invalidR > 0
        rMin = min(rVals);
        rMax = max(rVals);
        fprintf('    Radius range: [%.6e, %.6e] µm (original unit)\n', rMin, rMax);
    end
end

% Mark rows with valid geometry (positive period and radius)
validGeometryMask = (pVals > 0) & (rVals > 0);
validRowIndices = find(validGeometryMask);
numValidGeometries = numel(validRowIndices);

if numValidGeometries == 0
    error('prepare_training_dataset:NoValidGeometry', ...
        'All rows have non-positive period or radius values. Cannot proceed.');
end

fprintf('  Valid geometries: %d/%d (filtered %d rows with non-positive p or r)\n', ...
    numValidGeometries, numRows, numRows - numValidGeometries);

% Extract spectral data dynamically for all requested targetFields
lambdaData = allData.lambda;  % [N × L] array
maxLambdaWidth = size(lambdaData, 2);
numRowsExpected = size(lambdaData, 1);

metricStack = nan(numRowsExpected, maxLambdaWidth, numTargets);
for k = 1:numTargets
    rawTargetData = getColumn(allData, resolvedDataFields{k});
    paddedTargetData = padSpectra(rawTargetData, maxLambdaWidth, numRowsExpected);
    metricStack(:, :, k) = paddedTargetData;

    % Data QA: absorptance is stored in percent; values outside [0, 100]% violate optical passivity.
    if any(strcmpi(targetFields{k}, {'Abs', 'Absorptance'}))
        absOver = paddedTargetData > 100 | paddedTargetData < 0;
        if any(absOver(:))
            nBad = nnz(absOver);
            maxVal = max(paddedTargetData(:), [], 'omitnan');
            minVal = min(paddedTargetData(:), [], 'omitnan');
            warning('prepare_training_dataset:AbsorptanceAbove100', ...
                ['%d entries across %d geometries have unphysical %s (max = %.2e %%, min = %.2e %%). ', ...
                 'Enforcing optical passivity bounds [0, 100] %% to prevent Z-score variance collapse.'], ...
                nBad, numRows, targetFields{k}, maxVal, minVal);
            paddedTargetData = min(max(paddedTargetData, 0), 100);
            metricStack(:, :, k) = paddedTargetData;
        end
    end
end

% --- P3 Optimization: Parallel batch RI lookups ---
fprintf('  Building wavelength lookup cache (P3 parallel RI optimization)...\n');
allWavelengths = double(lambdaData(:));
allWavelengths(isnan(allWavelengths)) = [];
uniqueLambdaMicrometers = unique(allWavelengths * 1e-3);
nUniqueLambdas = numel(uniqueLambdaMicrometers);

[nBatch, kBatch] = evalRefractiveIndex(ri, uniqueLambdaMicrometers);
nBatch = double(nBatch(:));
kBatch = double(kBatch(:));

fprintf('    ✓ Wavelength cache built: %d unique wavelengths\n', nUniqueLambdas);

% Process each row (geometry/sample) with cached RI values
for idx = 1:numRows
    lambdaVec = double(lambdaData(idx, :));
    
    % Skip rows with non-positive geometry
    if ~validGeometryMask(idx)
        continue;
    end
    
    % Find valid wavelengths
    validMask = ~isnan(lambdaVec) & (lambdaVec > 0);
    
    % Check all target metrics are valid at these wavelengths
    metricsAtRow = reshape(metricStack(idx, :, :), [maxLambdaWidth, numTargets]);  % [L × numTargets]
    for k = 1:numTargets
        metricVec = reshape(metricsAtRow(:, k), size(validMask));
        validMask = validMask & ~isnan(metricVec);
    end
    
    % Skip if no valid wavelengths remain
    if ~any(validMask)
        continue;
    end
    
    % Extract valid data
    lambdaCol = lambdaVec(validMask)' * 1e-3;  % Convert nm to µm, column vector
    
    if any(lambdaCol <= 0)
        continue;
    end
    
    nSamples = numel(lambdaCol);
    
    p_current = pVals(idx);
    r_current = rVals(idx);
    
    if p_current <= 0 || r_current <= 0
        continue;
    end
    
    pCol = repmat(p_current, nSamples, 1);
    rCol = repmat(r_current, nSamples, 1);
    
    % Look up refractive index from cached batch results
    nVals = arrayfun(@(lambda) nBatch(findNearest(uniqueLambdaMicrometers, lambda)), lambdaCol);
    kVals = arrayfun(@(lambda) kBatch(findNearest(uniqueLambdaMicrometers, lambda)), lambdaCol);
    nVals = double(nVals(:));
    kVals = double(kVals(:));
    
    % Extract target metrics at valid wavelengths
    targetMatrix = metricsAtRow(validMask, :);  % [nSamples × numTargets]
    targetMatrixRaw = targetMatrix;
    
    % Apply log transformation to specified targets (using decimal log: log10(1 + y))
    if any(targetLogMask)
        logInput = targetMatrix(:, targetLogMask);
        
        if any(logInput(:) < 0)
            logInput = max(logInput, 0);
        end
        
        targetMatrix(:, targetLogMask) = log10(1 + logInput);
        
        transformedValid = targetMatrix(:, targetLogMask);
        if any(~isfinite(transformedValid(:)))
            infMask = isinf(transformedValid);
            nanMask = isnan(transformedValid);
            numInf = sum(infMask(:));
            numNaN = sum(nanMask(:));
            error('prepare_training_dataset:TargetTransformFailed', ...
                'After log10(1+y): found %d -Inf and %d NaN values in targets.', numInf, numNaN);
        end
    end
    
    if opts.IncludeRatios
        ratio_PL = pCol ./ lambdaCol;
        ratio_RL = rCol ./ lambdaCol;
        ratio_PR = pCol ./ rCol;
        featList{end+1} = [pCol, rCol, lambdaCol, nVals, kVals, ratio_PL, ratio_RL, ratio_PR]; %#ok<AGROW>
    else
        featList{end+1} = [pCol, rCol, lambdaCol, nVals, kVals]; %#ok<AGROW>
    end
    respList{end+1} = targetMatrix;
    respListRaw{end+1} = targetMatrixRaw;
end

if isempty(featList)
    error('prepare_training_dataset:NoSamples', 'No usable samples extracted.');
end

X = vertcat(featList{:});
Y = vertcat(respList{:});
YRaw = vertcat(respListRaw{:});

if size(X,1) ~= size(Y,1)
    error('prepare_training_dataset:SizeMismatch', ...
        'Feature/target row mismatch (%d vs %d).', size(X,1), size(Y,1));
end

invalidMask = ~all(isfinite([X, Y]), 2);
if any(invalidMask)
    nanInX = sum(any(isnan(X), 2));
    infInX = sum(any(isinf(X), 2));
    nanInY = sum(any(isnan(Y), 2));
    infInY = sum(any(isinf(Y), 2));
    
    fprintf('  Found non-finite values: %d NaN in X, %d Inf in X, %d NaN in Y, %d Inf in Y\n', ...
        nanInX, infInX, nanInY, infInY);
    
    if nanInY > 0 || infInY > 0
        for col = 1:size(Y, 2)
            colInvalid = sum(~isfinite(Y(:, col)));
            if colInvalid > 0
                if col <= numel(targetNames)
                    colName = targetNames{col};
                else
                    colName = sprintf('target_%d', col);
                end
                fprintf('    Target %s: %d invalid values\n', colName, colInvalid);
            end
        end
    end
end
X(invalidMask, :) = [];
Y(invalidMask, :) = [];
YRaw(invalidMask, :) = [];
if any(invalidMask)
    fprintf('  Removed %d rows with NaN/Inf values\n', sum(invalidMask));
end

needsPositiveGeometry = isV2 || opts.FeatureLogTransform || opts.IncludeRatios;
if needsPositiveGeometry
    geomMask = [true, true, true, false, false];
    geomFeaturesNotPositive = any(X(:, geomMask) <= 0, 2);
    if any(geomFeaturesNotPositive)
        nRemoved = sum(geomFeaturesNotPositive);
        fprintf('  Removed %d rows with non-positive geometric features (p, r, or lambda)\n', nRemoved);
        X(geomFeaturesNotPositive, :) = [];
        Y(geomFeaturesNotPositive, :) = [];
        YRaw(geomFeaturesNotPositive, :) = [];
    end
end

if size(X, 1) == 0
    error('prepare_training_dataset:NoSamplesAfterGeomCheck', ...
        'All samples were removed during geometric feature validation. Check input data.');
end

if ~isempty(opts.RatioLimit)
    ratio = X(:,2) ./ X(:,1);
    keep = ratio >= opts.RatioLimit(1) & ratio <= opts.RatioLimit(2);
    removedCount = sum(~keep);
    X = X(keep, :);
    Y = Y(keep, :);
    YRaw = YRaw(keep, :);
    if removedCount > 0
        fprintf('  Filtered by r/p ratio: removed %d samples\n', removedCount);
    end
end

numSamples = size(X, 1);
fprintf('  Samples after filtering: %d\n', numSamples);

if numSamples < 20
    warning('prepare_training_dataset:FewSamples', 'Only %d samples remain after filtering.', numSamples);
end

if opts.Shuffle
    rng(opts.Seed, 'twister');
end

switch opts.SplitMode
    case "geometry"
        geomKey = round(X(:, 1:2) * 1e6);   % µm -> pm integer key
        [~, ~, geomId] = unique(geomKey, 'rows');
        nGeom = max(geomId);
        geomOrder = 1:nGeom;
        if opts.Shuffle
            geomOrder = randperm(nGeom);
        end
        if nGeom > 1
            nHoldG = min(nGeom - 1, max(1, round(opts.Holdout * nGeom)));
            nTrainG = nGeom - nHoldG;
            nValG = min(round(opts.ValSplit * nHoldG), nHoldG);
        else
            nHoldG = 0;
            nTrainG = 1;
            nValG = 0;
        end
        trainGeoms = geomOrder(1:nTrainG);
        valGeoms   = geomOrder(nTrainG+1:nTrainG+nValG);
        testGeoms  = geomOrder(nTrainG+nValG+1:end);

        trainIdx = find(ismember(geomId, trainGeoms));
        valIdx   = find(ismember(geomId, valGeoms));
        testIdx  = find(ismember(geomId, testGeoms));
        if opts.Shuffle
            trainIdx = trainIdx(randperm(numel(trainIdx)));
            valIdx   = valIdx(randperm(numel(valIdx)));
            testIdx  = testIdx(randperm(numel(testIdx)));
        end
        assert(isempty(intersect(geomId(trainIdx), geomId(testIdx))) && ...
               isempty(intersect(geomId(trainIdx), geomId(valIdx))) && ...
               isempty(intersect(geomId(valIdx), geomId(testIdx))), ...
            'prepare_training_dataset:GeometryLeak', 'Geometry overlap between splits.');
        fprintf('  Geometry-grouped split: %d / %d / %d geometries (train/val/test)\n', ...
            numel(trainGeoms), numel(valGeoms), numel(testGeoms));

    case "row"
        warning('prepare_training_dataset:RowSplit', ...
            ['SplitMode="row" splits individual (P, r, lambda) samples: wavelengths of ', ...
             'the same geometry land in train and test, inflating test metrics.']);
        permIdx = 1:numSamples;
        if opts.Shuffle
            permIdx = randperm(numSamples);
        end
        if numSamples > 1
            holdoutCount = min(numSamples - 1, max(1, round(opts.Holdout * numSamples)));
            trainCount = numSamples - holdoutCount;
            valCount = min(round(opts.ValSplit * holdoutCount), max(0, numSamples - trainCount));
        else
            trainCount = 1;
            holdoutCount = 0;
            valCount = 0;
        end
        trainIdx = permIdx(1:trainCount)';
        valIdx   = permIdx(trainCount+1:trainCount+valCount)';
        testIdx  = permIdx(trainCount+valCount+1:end)';
end

XTrain = X(trainIdx, :);
YTrain = Y(trainIdx, :);
XValidation = X(valIdx, :);
YValidation = Y(valIdx, :);
XTest = X(testIdx, :);
YTest = Y(testIdx, :);

YTrainRaw = YRaw(trainIdx, :);
YValidationRaw = YRaw(valIdx, :);
YTestRaw = YRaw(testIdx, :);

fprintf('\n=== Dataset Feature Ranges (before normalization) ===\n');
fprintf('XTrain:       p=[%.6e, %.6e], r=[%.6e, %.6e], lambda=[%.6e, %.6e]\n', ...
    min(XTrain(:,1)), max(XTrain(:,1)), min(XTrain(:,2)), max(XTrain(:,2)), ...
    min(XTrain(:,3)), max(XTrain(:,3)));
fprintf('XValidation:  p=[%.6e, %.6e], r=[%.6e, %.6e], lambda=[%.6e, %.6e]\n', ...
    min(XValidation(:,1)), max(XValidation(:,1)), min(XValidation(:,2)), max(XValidation(:,2)), ...
    min(XValidation(:,3)), max(XValidation(:,3)));
fprintf('XTest:        p=[%.6e, %.6e], r=[%.6e, %.6e], lambda=[%.6e, %.6e]\n', ...
    min(XTest(:,1)), max(XTest(:,1)), min(XTest(:,2)), max(XTest(:,2)), ...
    min(XTest(:,3)), max(XTest(:,3)));
fprintf('Are all positive? Train:%s, Val:%s, Test:%s\n', ...
    iif(all(XTrain(:,1:3) > 0, 'all'), 'YES', 'NO'), ...
    iif(all(XValidation(:,1:3) > 0, 'all'), 'YES', 'NO'), ...
    iif(all(XTest(:,1:3) > 0, 'all'), 'YES', 'NO'));
fprintf('\n');

featureCenter = zeros(1, size(XTrain, 2));
featureScale = ones(1, size(XTrain, 2));

scale = struct();
scale.featureMean = featureCenter;
scale.featureStd = featureScale;
if opts.FeatureLogTransform
    scale.featureTransform = 'log_p_r_lambda';
else
    scale.featureTransform = 'raw';
end
featureLogMask = [opts.FeatureLogTransform, opts.FeatureLogTransform, opts.FeatureLogTransform, false, false];
if opts.IncludeRatios
    featureLogMask = [featureLogMask, false, false, false];
end
scale.featureLogMask = featureLogMask;
scale.targetMean = [];
scale.targetStd = [];
scale.targetLog1pMask = targetLogMask;

dataset = struct();
dataset.XTrain = XTrain;
dataset.YTrain = YTrain;
dataset.XValidation = XValidation;
dataset.YValidation = YValidation;
dataset.XTest = XTest;
dataset.YTest = YTest;
dataset.YTrainRaw = YTrainRaw;
dataset.YValidationRaw = YValidationRaw;
dataset.YTestRaw = YTestRaw;
dataset.featureNames = featureNames;
dataset.targetNames = targetNames;
dataset.targetFieldMap = targetFields;
dataset.scale = scale;
targetLogActive = any(targetLogMask);
dataset.normalize = @(Xraw) normalizeFeatures(Xraw, featureCenter, featureScale, featureLogMask);
dataset.denormalize = @(Ytrans) denormalizeModelTargets(Ytrans, targetLogMask, [], [], 10);
dataset.transformFeatures = @(Xraw) transformFeatures(Xraw, featureLogMask);
dataset.inputCenter = featureCenter;
dataset.inputScale = featureScale;
dataset.targetLogMask = targetLogMask;
dataset.featureLogMask = featureLogMask;
dataset.counts = struct('train', size(XTrain,1), 'validation', size(XValidation,1), 'test', size(XTest,1));
dataset.trainIdx = trainIdx;
dataset.valIdx = valIdx;
dataset.testIdx = testIdx;
dataset.splitMode = opts.SplitMode;
dataset.featureSchemaName = opts.FeatureSchema;

dataset.FeatureLogTransform = opts.FeatureLogTransform;
dataset.IncludeRatios = opts.IncludeRatios;
dataset.TargetLogTransform = any(targetLogMask);
dataset.InputSize = size(XTrain, 2);

if isV2
    dataset = localApplyPhysicsSchema(dataset, opts, targetLogActive);
end
end

function resolved = resolveTargetFieldInAllData(allData, tfName)
resolved = '';
if isfield(allData, tfName)
    resolved = tfName;
    return;
end
switch tfName
    case 'EE_V'
        if isfield(allData, 'EF_vol'), resolved = 'EF_vol'; end
    case 'EF_vol'
        if isfield(allData, 'EE_V'), resolved = 'EE_V'; end
    case 'EE_S'
        if isfield(allData, 'EF_surf'), resolved = 'EF_surf'; end
    case 'EF_surf'
        if isfield(allData, 'EE_S'), resolved = 'EE_S'; end
    case 'Abs'
        if isfield(allData, 'Absorptance'), resolved = 'Absorptance'; end
    case 'Absorptance'
        if isfield(allData, 'Abs'), resolved = 'Abs'; end
    case 'EF_max'
        if isfield(allData, 'M2_max'), resolved = 'M2_max'; end
    case 'ECC'
        if isfield(allData, 'ECCheck'), resolved = 'ECCheck'; end
    case 'ECCheck'
        if isfield(allData, 'ECC'), resolved = 'ECC'; end
end
end

function dataset = localApplyPhysicsSchema(dataset, opts, targetLogActive) %#ok<INUSD>
% v2/v3: physics features + z-scoring (features and targets), train-split stats only.
schema = struct();
schema.Name = opts.FeatureSchema;
schema.BaseInputs = ["p_um", "r_um", "lambda_um", "n", "k"];
schema.IncludeVerticalGap = opts.IncludeVerticalGap && opts.FeatureSchema == "v2_physics";
schema.GapHeightUm = opts.GapHeightUm;
[Ftrain, names] = buildPhysicsFeatures(dataset.XTrain, schema);
mu = mean(Ftrain, 1);
sd = std(Ftrain, 0, 1);
sd(~isfinite(sd) | sd < 1e-12) = 1;
schema.FeatureNames = names;
schema.FeatureMean = mu;
schema.FeatureStd = sd;

muZ = mean(dataset.YTrain, 1);
sdZ = std(dataset.YTrain, 0, 1);
sdZ(~isfinite(sdZ) | sdZ < 1e-12) = 1;
tt = struct('Name', "target_specific_zscore", ...
            'LogMask', dataset.targetLogMask, ...
            'LogBase', 10, ...
            'Log1p', dataset.targetLogMask, ...
            'Mean', muZ, ...
            'Std', sdZ);
% Physical bounds per channel (consumed by bounded output heads).
[tt.BoundKind, tt.LowerBound, tt.UpperBound] = localTargetBounds( ...
    dataset.targetNames, dataset.targetLogMask, dataset.YTrainRaw);
dataset.YTrain      = (dataset.YTrain - muZ) ./ sdZ;
dataset.YValidation = (dataset.YValidation - muZ) ./ sdZ;
dataset.YTest       = (dataset.YTest - muZ) ./ sdZ;

fprintf('  Physics-schema target standardisation (target-specific log10/linear space): mean = [%s], std = [%s]\n', ...
    strjoin(compose('%.3f', muZ), ', '), strjoin(compose('%.3f', sdZ), ', '));

dataset.featureSchema = schema;
dataset.targetTransform = tt;
dataset.baseFeatureNames = cellstr(schema.BaseInputs);
dataset.featureNames = cellstr(names);
dataset.normalize = @(Xraw) standardizeModelFeatures(Xraw, schema);
dataset.denormalize = @(Z) denormalizeModelTargets(Z, dataset.targetLogMask, muZ, sdZ, 10);
dataset.transformFeatures = @(Xraw) buildPhysicsFeatures(Xraw, schema);
dataset.inputCenter = mu;
dataset.inputScale = sd;
dataset.featureLogMask = false(1, numel(names));
dataset.scale.featureMean = mu;
dataset.scale.featureStd = sd;
dataset.scale.featureTransform = char(opts.FeatureSchema + "_zscore");
dataset.scale.featureLogMask = dataset.featureLogMask;
dataset.scale.targetMean = muZ;
dataset.scale.targetStd = sdZ;
dataset.FeatureLogTransform = true;
dataset.IncludeRatios = false;
dataset.InputSize = numel(names);
end

function [kind, lower, upper] = localTargetBounds(targetNames, logMask, YRaw)
% Physical range of each target channel in its *transformed* (pre-z-score)
% space. Log channels store log10(1 + y) >= 0; absorptance is bounded by
% passivity, in percent if the raw data exceed 1.5, else as a fraction.
names = string(targetNames);
nT = numel(names);
kind = repmat("none", 1, nT);
lower = -inf(1, nT);
upper = inf(1, nT);
logMask = reshape(logical(logMask), 1, []);
for c = 1:nT
    if c <= numel(logMask) && logMask(c)
        kind(c) = "softplus";
        lower(c) = 0;
    elseif any(strcmpi(names(c), ["Abs", "Absorptance"]))
        kind(c) = "sigmoid";
        lower(c) = 0;
        rawMax = max(YRaw(:, c), [], 'omitnan');
        if isfinite(rawMax) && rawMax > 1.5
            upper(c) = 100;   % stored in percent
        else
            upper(c) = 1;     % stored as a fraction
        end
    end
end
end

function Xnorm = normalizeFeatures(Xraw, center, scale, featureLogMask) %#ok<INUSL>
if isempty(Xraw)
    Xnorm = Xraw;
    return;
end
Xnorm = transformFeatures(Xraw, featureLogMask);
end

function Xtrans = transformFeatures(Xraw, featureLogMask)
Xtrans = double(Xraw);
if isempty(Xtrans)
    return;
end
logMask = featureLogMask;
if ~any(logMask)
    return;
end
geomCols = Xtrans(:, logMask);

if any(geomCols(:) <= 0)
    [badRows, badCols] = find(geomCols <= 0);
    colNames = {'p_um', 'r_um', 'lambda_um'};
    if ~isempty(badRows)
        sampleCount = numel(unique(badRows));
        errorLines = cell(min(5, sampleCount), 1);
        for i = 1:min(5, sampleCount)
            uniqueBadRows = unique(badRows);
            r = uniqueBadRows(i);
            c = badCols(badRows == r);
            c = unique(c);
            colStr = sprintf('%s', strjoin(cellstr(colNames(c)), ', '));
            errorLines{i} = sprintf('    Row %d: non-positive input in %s', r, colStr);
        end
        if sampleCount > 5
            errorLines{6} = sprintf('    ... and %d more rows', sampleCount - 5);
        end
        errorMsg = sprintf('Non-positive INPUT geometric features encountered:\n%s\n', ...
            strjoin(errorLines(1:min(6, end)), newline));
    else
        errorMsg = '';
    end
    error('prepare_training_dataset:NonPositiveFeature', ...
        '%sInput geometric features must be positive for log transform.', errorMsg);
end

Xtrans(:, logMask) = log(geomCols);
end

function dataPadded = padSpectra(data, targetWidth, targetRows)
if nargin < 3
    targetRows = size(data, 1);
end
if isempty(data) || size(data, 1) == 0
    dataPadded = nan(targetRows, targetWidth);
    return;
end
if size(data, 1) ~= targetRows
    if size(data, 1) == 1
        data = repmat(data, targetRows, 1);
    else
        padded = nan(targetRows, targetWidth);
        minR = min(size(data, 1), targetRows);
        minC = min(size(data, 2), targetWidth);
        padded(1:minR, 1:minC) = data(1:minR, 1:minC);
        dataPadded = padded;
        return;
    end
end
sz = size(data);
if sz(2) >= targetWidth
    dataPadded = data(:, 1:targetWidth);
else
    dataPadded = [data, nan(targetRows, targetWidth - sz(2))];
end
end

function mustBeAllDataStruct(allData)
if ~isstruct(allData)
    throwAsCaller(MException('prepare_training_dataset:InvalidAllData', ...
        'allData must be a struct'));
end
if isempty(allData) || isempty(fieldnames(allData))
    throwAsCaller(MException('prepare_training_dataset:EmptyAllData', ...
        'allData struct is empty or has no fields'));
end
end

function idx = findNearest(searchArray, value)
[~, idx] = min(abs(searchArray - value));
end

function mustBeRiStruct(ri)
if ~isstruct(ri)
    throwAsCaller(MException('prepare_training_dataset:InvalidRi', ...
        'ri must be a struct with nFunc and kFunc fields'));
end
if ~isfield(ri, 'nFunc') || ~isfield(ri, 'kFunc')
    throwAsCaller(MException('prepare_training_dataset:MissingRiFields', ...
        'ri struct must contain nFunc and kFunc function handles'));
end
end

function result = iif(condition, trueVal, falseVal)
if condition
    result = trueVal;
else
    result = falseVal;
end
end
