function dataset = prepare_training_dataset(allData, ri, options)
% prepare_training_dataset  Convert structure-of-arrays spectra into ML-ready matrices.
%
% dataset = prepare_training_dataset(allData, ri) builds feature and target
% matrices using per-sample inputs [p, r, lambda, n, k] and targets
% [Absorptance, M_vol, M_surf, EF_vol, EF_surf]. Geometry and wavelength
% can be optionally log-transformed before standardisation, while targets
% can be optionally stored as log1p(targets).
%
% Parameters:
%   Holdout         (default 0.2) - fraction reserved for validation+test
%   ValSplit        (default 0.5) - validation fraction within holdout
%   Shuffle         (default true) - shuffle entries before splitting
%   RatioLimit      (default []) - optional [min max] allowed for r./p
%   TargetFields    (default all) - cell array of metric field names
%   FeatureSchema   (default "v2_physics") - "v2_physics" | "v1_legacy"
%   SplitMode       (default "geometry") - "geometry" keeps every wavelength
%                   of a (P, r) pair in one split; "row" is the legacy
%                   per-sample split (leaks geometries across splits).
%   IncludeVerticalGap (default false) - v2 only: add h_gap/lambda feature
%   GapHeightUm     (default 0.005) - v2 only: vertical gap height [µm]
%   Seed            (default 0) - RNG seed for the split
%
% v2_physics schema:
%   X stores the 5 raw inputs [p, r, lambda, n, k] (µm); dataset.normalize
%   maps them to the physics feature set (buildPhysicsFeatures) and z-scores
%   with train-split statistics. Targets are Z = log1p(Y), then z-scored per
%   channel with train-split statistics.

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
    options.FeatureSchema (1,1) string {mustBeMember(options.FeatureSchema, ["v2_physics", "v1_legacy"])} = "v2_physics"
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
isV2 = opts.FeatureSchema == "v2_physics";
if isV2
    % Ratios are generated inside buildPhysicsFeatures; X stores raw inputs only.
    opts.IncludeRatios = false;
    opts.FeatureLogTransform = true;
end

featureNames = {'p_um','r_um','lambda_um','n','k'};
if opts.IncludeRatios
    featureNames = [featureNames, {'p_over_lambda','r_over_lambda','p_over_r'}];
end
allTargetFieldOrder = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'};

targetFields = opts.TargetFields(:)';
for tf = targetFields
    if ~ismember(tf{1}, allTargetFieldOrder)
        error('prepare_training_dataset:UnknownTarget', 'Unsupported target field: %s', tf{1});
    end
end

targetNames = targetFields;
% Target-specific log transform: near-field and intensity metrics use log10(1+y),
% while bounded energy ratios (e.g. Absorptance) remain on their linear physical scale.
logFieldNames = ["EF_vol", "EF_surf", "M_vol", "M_surf", "intW_vol", "intW_t"];
if islogical(opts.TargetLogTransform) && isscalar(opts.TargetLogTransform) && opts.TargetLogTransform
    targetLogMask = ismember(string(targetFields), logFieldNames);
elseif islogical(opts.TargetLogTransform) && isscalar(opts.TargetLogTransform) && ~opts.TargetLogTransform
    targetLogMask = false(1, numel(targetFields));
else
    targetLogMask = logical(opts.TargetLogTransform);
end
requiredFields = [{'lambda'}, targetFields];
for f = requiredFields
    if ~isfield(allData, f{1})
        error('prepare_training_dataset:MissingField', 'allData missing field %s', f{1});
    end
end

numRows = structRowCount(allData);
if numRows == 0
    error('prepare_training_dataset:Empty', 'allData contains no rows.');
end

% Vectorized feature extraction
fprintf('  Extracting features from %d geometries...\n', numRows);
featList = {};
respList = {};

% Extract geometry columns (period, radius)
pVals = getColumn(allData, 'period');
rVals = getColumn(allData, 'radius');

fprintf(' average p (raw): %.6e , r (raw): %.6e \n', mean(pVals), mean(rVals));

% Convert nanometers to µm (input data from COMSOL is in meters)
% nanometers -> micrometers: multiply by 1e-3
pVals = double(pVals(:)) * 1e-3;
rVals = double(rVals(:)) * 1e-3;

% Validate geometric values (must be positive for log transform)
if any(pVals <= 0) || any(rVals <= 0)
    invalidP = sum(pVals <= 0);
    invalidR = sum(rVals <= 0);
    warning('prepare_training_dataset:NonPositiveGeometry', ...
        'Found %d non-positive period values and %d non-positive radius values. These will be skipped.', ...
        invalidP, invalidR);
    
    % Additional diagnostics
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

% Extract spectral data
lambdaData = allData.lambda;  % [N × L] array
absorptanceData = getColumn(allData, 'Absorptance');
mVolData = getColumn(allData, 'M_vol');
mSurfData = getColumn(allData, 'M_surf');
efVolData = getColumn(allData, 'EF_vol');
efSurfData = getColumn(allData, 'EF_surf');

% Ensure all have [N × L] shape; pad if needed
maxLambdaWidth = size(lambdaData, 2);
absorptanceData = padSpectra(absorptanceData, maxLambdaWidth);
mVolData = padSpectra(mVolData, maxLambdaWidth);
mSurfData = padSpectra(mSurfData, maxLambdaWidth);
efVolData = padSpectra(efVolData, maxLambdaWidth);
efSurfData = padSpectra(efSurfData, maxLambdaWidth);

% Build full metric matrix [N × L × 5]
metricStack = cat(3, absorptanceData, mVolData, mSurfData, efVolData, efSurfData);

% Data QA: absorptance is stored in percent; values above 100 % are unphysical.
if ismember('Absorptance', targetFields)
    absOver = any(absorptanceData > 100, 2);
    if any(absOver)
        warning('prepare_training_dataset:AbsorptanceAbove100', ...
            ['%d of %d geometries have Absorptance > 100 %% (max %.1f %%). ', ...
             'These are unphysical and are kept in training; check the COMSOL import.'], ...
            nnz(absOver), numRows, max(absorptanceData(:), [], 'omitnan'));
    end
end

% --- P3 Optimization: Parallel batch RI lookups ---
% Collect all unique wavelengths once to enable vectorized RI lookup
fprintf('  Building wavelength lookup cache (P3 parallel RI optimization)...\n');
allWavelengths = double(lambdaData(:));  % Flatten all wavelengths
allWavelengths(isnan(allWavelengths)) = [];  % Remove NaNs
uniqueLambdaMicrometers = unique(allWavelengths * 1e-3);  % Convert nm to µm
nUniqueLambdas = numel(uniqueLambdaMicrometers);

% Perform batch RI lookup for all unique wavelengths at once
% This leverages griddedInterpolant's vectorized operation
% evalRefractiveIndex accepts µm queries regardless of the RI grid unit.
[nBatch, kBatch] = evalRefractiveIndex(ri, uniqueLambdaMicrometers);
nBatch = double(nBatch(:));
kBatch = double(kBatch(:));

% Create lookup table [N × K] for fast per-wavelength RI access
% Row: geometry index, Col: wavelength index
riLookupN = zeros(numRows, nUniqueLambdas);
riLookupK = zeros(numRows, nUniqueLambdas);
for idx = 1:numRows
    lambdaVecMicrometers = double(lambdaData(idx, :)) * 1e-3;
    for j = 1:nUniqueLambdas
        % Find matching wavelength in this row
        matchIdx = find(abs(lambdaVecMicrometers - uniqueLambdaMicrometers(j)) < 1e-9, 1);
        if ~isempty(matchIdx)
            riLookupN(idx, j) = nBatch(j);
            riLookupK(idx, j) = kBatch(j);
        end
    end
end
fprintf('    ✓ Wavelength cache built: %d unique wavelengths\n', nUniqueLambdas);

% Process each row (geometry/sample) with cached RI values
for idx = 1:numRows
    lambdaVec = double(lambdaData(idx, :));
    
    % Skip rows with non-positive geometry
    if ~validGeometryMask(idx)
        continue;
    end
    
    % Find valid wavelengths
    validMask = ~isnan(lambdaVec) & (lambdaVec > 0);  % Also check for non-positive wavelengths
    
    % Check all target metrics are valid at these wavelengths
    metricsAtRow = squeeze(metricStack(idx, :, :));  % [L × 5]
    for tf = targetFields
        tfIdx = find(strcmp(allTargetFieldOrder, tf{1}), 1);
        if ~isempty(tfIdx)
            metricVec = metricsAtRow(:, tfIdx);
            % Ensure metricVec is same shape as validMask (row vector)
            metricVec = reshape(metricVec, size(validMask));
            validMask = validMask & ~isnan(metricVec);
        end
    end
    
    % Skip if no valid wavelengths remain
    if ~any(validMask)
        continue;
    end
    
    % Extract valid data
    lambdaCol = lambdaVec(validMask)' * 1e-3;  % Convert nm to µm, column vector
    
    % Ensure lambda values are positive (sanity check after unit conversion)
    if any(lambdaCol <= 0)
        continue;  % Skip this row if any wavelength became non-positive after conversion
    end
    
    nSamples = numel(lambdaCol);
    
    % Expand geometry to match wavelength count
    p_current = pVals(idx);
    r_current = rVals(idx);
    
    % Double-check that geometry is still positive (should be guaranteed by validGeometryMask)
    if p_current <= 0 || r_current <= 0
        continue;  % Skip this row if geometry became non-positive
    end
    
    pCol = repmat(p_current, nSamples, 1);
    rCol = repmat(r_current, nSamples, 1);
    
    % Look up refractive index from cached batch results
    % Use arrayfun for fully vectorized lookup mapping
    nVals = arrayfun(@(lambda) nBatch(findNearest(uniqueLambdaMicrometers, lambda)), lambdaCol);
    kVals = arrayfun(@(lambda) kBatch(findNearest(uniqueLambdaMicrometers, lambda)), lambdaCol);
    nVals = double(nVals(:));
    kVals = double(kVals(:));
    
    % Extract target metrics at valid wavelengths
    metricsAtRowValid = metricsAtRow(validMask, :);  % [nSamples × 5]
    selectedIdx = cellfun(@(name) find(strcmp(allTargetFieldOrder, name), 1, 'first'), targetFields);
    targetMatrix = metricsAtRowValid(:, selectedIdx);
    
    % Apply log transformation to specified targets (using decimal log: log10(1 + y))
    if any(targetLogMask)
        logInput = targetMatrix(:, targetLogMask);
        
        % Enhancement and intensity metrics are physically non-negative
        if any(logInput(:) < 0)
            logInput = max(logInput, 0);
        end
        
        % Apply decimal log10(1 + y) transformation
        targetMatrix(:, targetLogMask) = log10(1 + logInput);
        
        % Validate no -Inf or NaN after transformation
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
    
    % Assemble feature matrix with RAW values (not log-transformed)
    % Log transform will be applied only in normalizeFeatures during training/validation
    if opts.IncludeRatios
        ratio_PL = pCol ./ lambdaCol;
        ratio_RL = rCol ./ lambdaCol;
        ratio_PR = pCol ./ rCol;
        featList{end+1} = [pCol, rCol, lambdaCol, nVals, kVals, ratio_PL, ratio_RL, ratio_PR]; %#ok<AGROW>
    else
        featList{end+1} = [pCol, rCol, lambdaCol, nVals, kVals]; %#ok<AGROW>
    end
    respList{end+1} = targetMatrix;
end

if isempty(featList)
    error('prepare_training_dataset:NoSamples', 'No usable samples extracted.');
end

X = vertcat(featList{:});
Y = vertcat(respList{:});

if size(X,1) ~= size(Y,1)
    error('prepare_training_dataset:SizeMismatch', ...
        'Feature/target row mismatch (%d vs %d).', size(X,1), size(Y,1));
end

invalidMask = ~all(isfinite([X, Y]), 2);
initialCount = size(X, 1);
if any(invalidMask)
    nanInX = sum(any(isnan(X), 2));
    infInX = sum(any(isinf(X), 2));
    nanInY = sum(any(isnan(Y), 2));
    infInY = sum(any(isinf(Y), 2));
    
    fprintf('  Found non-finite values: %d NaN in X, %d Inf in X, %d NaN in Y, %d Inf in Y\n', ...
        nanInX, infInX, nanInY, infInY);
    
    % Show which target columns have issues
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
if any(invalidMask)
    fprintf('  Removed %d rows with NaN/Inf values\n', sum(invalidMask));
end

% Additional safety check: ensure geometric features are positive when required
needsPositiveGeometry = isV2 || opts.FeatureLogTransform || opts.IncludeRatios;
if needsPositiveGeometry
    geomMask = [true, true, true, false, false];
    geomFeaturesNotPositive = any(X(:, geomMask) <= 0, 2);
    if any(geomFeaturesNotPositive)
        nRemoved = sum(geomFeaturesNotPositive);
        fprintf('  Removed %d rows with non-positive geometric features (p, r, or lambda)\n', nRemoved);
        X(geomFeaturesNotPositive, :) = [];
        Y(geomFeaturesNotPositive, :) = [];
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
        % Group by unique (P, r): every wavelength of a geometry stays in
        % exactly one split, so test metrics measure generalisation to
        % unseen nanostructures rather than spectral interpolation.
        geomKey = round(X(:, 1:2) * 1e6);   % µm -> pm integer key
        [~, ~, geomId] = unique(geomKey, 'rows');
        nGeom = max(geomId);
        geomOrder = 1:nGeom;
        if opts.Shuffle
            geomOrder = randperm(nGeom);
        end
        nHoldG = max(1, round(opts.Holdout * nGeom));
        nTrainG = nGeom - nHoldG;
        nValG = min(round(opts.ValSplit * nHoldG), nHoldG);
        if nTrainG < 1
            error('prepare_training_dataset:TrainSplit', 'Training split is empty. Adjust Holdout or dataset size.');
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
        holdoutCount = max(1, round(opts.Holdout * numSamples));
        trainCount = numSamples - holdoutCount;
        valCount = round(opts.ValSplit * holdoutCount);
        valCount = min(valCount, max(0, numSamples - trainCount));
        if trainCount < 1
            error('prepare_training_dataset:TrainSplit', 'Training split is empty. Adjust Holdout or dataset size.');
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

% DEBUG: Check what's actually in the dataset
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

% Features are already in good scale (0.1-1 µm)
% Store as RAW values; log transform is applied in normalizeFeatures when enabled
trainRaw = XTrain;  % Keep raw values
featureCenter = zeros(1, size(XTrain, 2));  % No centering
featureScale = ones(1, size(XTrain, 2));    % No scaling

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

% Add preprocessing flags for model metadata
dataset.FeatureLogTransform = opts.FeatureLogTransform;
dataset.IncludeRatios = opts.IncludeRatios;
dataset.TargetLogTransform = any(targetLogMask);
dataset.InputSize = size(XTrain, 2);

if isV2
    dataset = localApplyPhysicsSchema(dataset, opts, targetLogActive);
end
end

function dataset = localApplyPhysicsSchema(dataset, opts, targetLogActive)
% v2: physics features + z-scoring (features and targets), train-split stats only.
schema = struct();
schema.Name = "v2_physics";
schema.BaseInputs = ["p_um", "r_um", "lambda_um", "n", "k"];
schema.IncludeVerticalGap = opts.IncludeVerticalGap;
schema.GapHeightUm = opts.GapHeightUm;
[Ftrain, names] = buildPhysicsFeatures(dataset.XTrain, schema);
mu = mean(Ftrain, 1);
sd = std(Ftrain, 0, 1);
sd(~isfinite(sd) | sd < 1e-12) = 1;
schema.FeatureNames = names;
schema.FeatureMean = mu;
schema.FeatureStd = sd;

% Targets: log10-compressed for near-field factors, linear for bounded ratios; z-score each channel.
muZ = mean(dataset.YTrain, 1);
sdZ = std(dataset.YTrain, 0, 1);
sdZ(~isfinite(sdZ) | sdZ < 1e-12) = 1;
tt = struct('Name', "target_specific_zscore", ...
            'LogMask', dataset.targetLogMask, ...
            'LogBase', 10, ...
            'Log1p', dataset.targetLogMask, ...  % backward compat
            'Mean', muZ, ...
            'Std', sdZ);
dataset.YTrain      = (dataset.YTrain - muZ) ./ sdZ;
dataset.YValidation = (dataset.YValidation - muZ) ./ sdZ;
dataset.YTest       = (dataset.YTest - muZ) ./ sdZ;

fprintf('  v2 target standardisation (target-specific log10/linear space): mean = [%s], std = [%s]\n', ...
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
dataset.featureLogMask = false(1, numel(names));   % logs are inside buildPhysicsFeatures
dataset.scale.featureMean = mu;
dataset.scale.featureStd = sd;
dataset.scale.featureTransform = 'v2_physics_zscore';
dataset.scale.featureLogMask = dataset.featureLogMask;
dataset.scale.targetMean = muZ;
dataset.scale.targetStd = sdZ;
dataset.FeatureLogTransform = true;
dataset.IncludeRatios = false;
dataset.InputSize = numel(names);
end

function Xnorm = normalizeFeatures(Xraw, center, scale, featureLogMask)
% Optional log transformation; features are already in good scale (0.1-1 µm)
% No centering or scaling needed to preserve actual physical values
if isempty(Xraw)
    Xnorm = Xraw;
    return;
end

% Apply log transform only when enabled
Xnorm = transformFeatures(Xraw, featureLogMask);
end

function Yraw = denormalizeTargetsLocal(Ytrans, logMask)
Yraw = Ytrans;
if isempty(Yraw)
    return;
end
if any(logMask)
    idx = find(logMask);
    Yraw(:, idx) = exp(Ytrans(:, idx)) - 1;
end
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

% Check INPUT values are positive (required for log transform)
% The OUTPUT can be negative - that's fine! (log of 0.1-1 µm = -2.3 to 0)
if any(geomCols(:) <= 0)
    % Find which rows and columns have non-positive input values
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

% Apply log transform - output will be negative for 0.1-1 µm range, which is OK
Xtrans(:, logMask) = log(geomCols);
end

function dataPadded = padSpectra(data, targetWidth)
% Pad spectral data to target width with NaN
if isempty(data)
    dataPadded = nan(0, targetWidth);
    return;
end
sz = size(data);
if sz(2) >= targetWidth
    dataPadded = data(:, 1:targetWidth);
else
    dataPadded = [data, nan(sz(1), targetWidth - sz(2))];
end
end

function row = getrow(entry, fieldName)
if isfield(entry, fieldName)
    fieldVal = entry.(fieldName);
    if isnumeric(fieldVal) || islogical(fieldVal)
        row = double(fieldVal(:)');
    else
        row = nan(1, numel(fieldVal));
    end
else
    row = [];
end
end

function entry = extractSoARow(S, idx)
entry = struct();
flds = fieldnames(S);
for k = 1:numel(flds)
    fn = flds{k};
    val = S.(fn);
    if isnumeric(val) || islogical(val) || isstring(val)
        if size(val,1) >= idx
            subs = repmat({':'}, 1, ndims(val));
            subs{1} = idx;
            slice = squeeze(val(subs{:}));
            entry.(fn) = slice;
        end
    elseif iscell(val)
        if size(val,1) >= idx
            entry.(fn) = val(idx, :);
        end
    end
end
end

function N = structRowCount(S)
N = 0;
if ~isstruct(S)
    return;
end
flds = fieldnames(S);
for k = 1:numel(flds)
    val = S.(flds{k});
    if ~isempty(val)
        N = size(val, 1);
        return;
    end
end
end

function mustBeAllDataStruct(allData)
% Validate allData is a struct with expected fields
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
% findNearest  Find index of nearest value in array.
% idx = findNearest(searchArray, value) returns the index of the element
% in searchArray that is closest to value in Euclidean distance.
[~, idx] = min(abs(searchArray - value));
end

function mustBeRiStruct(ri)
% Validate refractive index struct
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
