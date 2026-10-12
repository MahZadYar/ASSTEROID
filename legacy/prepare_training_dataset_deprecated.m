function dataset = prepare_training_dataset(allData, ri, varargin)
% prepare_training_dataset  Convert structure-of-arrays spectra into ML-ready matrices.
%
% dataset = prepare_training_dataset(allData, ri) builds feature and target
% matrices using per-sample inputs [p, r, lambda, n, k] and targets
% [Absorptance, M_vol, M_surf, EF_vol, EF_surf]. Geometry and wavelength
% are log-transformed before standardisation, while targets are
% stored as log1p(targets). Optional name-value arguments:
%   'Holdout'   fraction reserved for validation+test (default 0.2)
%   'ValSplit'  validation fraction within holdout (default 0.5)
%   'Shuffle'   true to shuffle entries (default true)
%   'RatioLimit' optional [min max] allowed for r./p (default [])
%   'TargetFields' cell array of metric field names to use as targets
%                 (default all available metrics)

opts = struct('Holdout', 0.1, 'ValSplit', 0.9, 'Shuffle', true, 'RatioLimit', []);
opts.TargetFields = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'};
if mod(numel(varargin), 2) ~= 0
    error('prepare_training_dataset:Args', 'Name-value pairs expected.');
end
for i = 1:2:numel(varargin)
    name = varargin{i};
    val = varargin{i+1};
    if ~isfield(opts, name)
        error('prepare_training_dataset:BadOption', 'Unknown option: %s', name);
    end
    opts.(name) = val;
end

featureNames = {'p_um','r_um','lambda_um','n','k'};
allTargetFieldOrder = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'};

targetFields = opts.TargetFields(:)';
for tf = targetFields
    if ~ismember(tf{1}, allTargetFieldOrder)
        error('prepare_training_dataset:UnknownTarget', 'Unsupported target field: %s', tf{1});
    end
end

targetNames = targetFields;
targetLogMask = true(1, numel(targetFields));
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

featList = {};
respList = {};
for idx = 1:numRows
    entry = extractSoARow(allData, idx);
    if isfield(entry, 'period')
        pVal = double(entry.period(1)) * 1e-3; % convert from nm to um
    else
        pVal = NaN;
    end
    if isfield(entry, 'radius')
        rVal = double(entry.radius(1)) * 1e-3; % convert from nm to um
    else
        rVal = NaN;
    end
    lambdaVec = getrow(entry, 'lambda');
    absorptanceVec = getrow(entry, 'Absorptance');
    mVolVec = getrow(entry, 'M_vol');
    mSurfVec = getrow(entry, 'M_surf');
    efVolVec = getrow(entry, 'EF_vol');
    efSurfVec = getrow(entry, 'EF_surf');

    if isempty(lambdaVec)
        continue;
    end

    validMask = ~isnan(lambdaVec);
    metricVectors = struct('Absorptance', absorptanceVec, 'M_vol', mVolVec, ...
        'M_surf', mSurfVec, 'EF_vol', efVolVec, 'EF_surf', efSurfVec);
    for tf = targetFields
        vec = metricVectors.(tf{1});
        validMask = validMask & ~isnan(vec);
    end
    lambdaVec = lambdaVec(validMask);
    if isempty(lambdaVec)
        continue;
    end
    lambdaCol = lambdaVec(:) * 1e-3; % convert nm to µm
    absCol = absorptanceVec(validMask);
    mVolCol = mVolVec(validMask);
    mSurfCol = mSurfVec(validMask);
    efVolCol = efVolVec(validMask);
    efSurfCol = efSurfVec(validMask);

    absCol = absCol(:);
    mVolCol = mVolCol(:);
    mSurfCol = mSurfCol(:);
    efVolCol = efVolCol(:);
    efSurfCol = efSurfCol(:);

    dataMatrix = [absCol, mVolCol, mSurfCol, efVolCol, efSurfCol];
    selectedIdx = cellfun(@(name) find(strcmp(allTargetFieldOrder, name), 1, 'first'), targetFields);
    targetMatrix = dataMatrix(:, selectedIdx);
    if any(targetLogMask)
        logInput = targetMatrix(:, targetLogMask);
        if any(logInput(:) < -1)
            error('prepare_training_dataset:TargetRange', ...
                'Targets contain values less than -1; cannot apply log1p safely.');
        end
        epsOffset = eps(1);
        logInput = max(logInput, -1 + epsOffset);
        targetMatrix(:, targetLogMask) = log1p(logInput);
    end
    nVals = ri.nFunc(lambdaCol);
    kVals = ri.kFunc(lambdaCol);
    nVals = nVals(:);
    kVals = kVals(:);
    pCol = repmat(pVal, numel(lambdaCol), 1);
    rCol = repmat(rVal, numel(lambdaCol), 1);

    featList{end+1} = [pCol, rCol, lambdaCol, nVals, kVals]; %#ok<AGROW>
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
X(invalidMask, :) = [];
Y(invalidMask, :) = [];

if ~isempty(opts.RatioLimit)
    ratio = X(:,2) ./ X(:,1);
    keep = ratio >= opts.RatioLimit(1) & ratio <= opts.RatioLimit(2);
    X = X(keep, :);
    Y = Y(keep, :);
end

numSamples = size(X, 1);
if numSamples < 20
    warning('prepare_training_dataset:FewSamples', 'Only %d samples remain after filtering.', numSamples);
end

permIdx = 1:numSamples;
if opts.Shuffle
    rng('default');
    permIdx = randperm(numSamples);
end

X = X(permIdx, :);
Y = Y(permIdx, :);

holdoutCount = max(1, round(opts.Holdout * numSamples));
trainCount = numSamples - holdoutCount;
valCount = round(opts.ValSplit * holdoutCount);
valCount = min(valCount, max(0, numSamples - trainCount));

if trainCount < 1
    error('prepare_training_dataset:TrainSplit', 'Training split is empty. Adjust Holdout or dataset size.');
end


XTrain = X(1:trainCount, :);
YTrain = Y(1:trainCount, :);
XHoldout = X(trainCount+1:end, :);
YHoldout = Y(trainCount+1:end, :);

XValidation = XHoldout(1:valCount, :);
YValidation = YHoldout(1:valCount, :);
XTest = XHoldout(valCount+1:end, :);
YTest = YHoldout(valCount+1:end, :);

trainTransformed = transformFeatures(XTrain);
featureCenter = mean(trainTransformed, 1);
featureScale = std(trainTransformed, 0, 1);
featureScale(featureScale == 0) = 1;

scale = struct();
scale.featureMean = featureCenter;
scale.featureStd = featureScale;
scale.featureTransform = 'log_p_r_lambda';
scale.featureLogMask = [true, true, true, false, false];
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
dataset.normalize = @(Xraw) normalizeFeatures(Xraw, featureCenter, featureScale);
dataset.denormalize = @(Ytrans) denormalizeTargetsLocal(Ytrans, targetLogMask);
dataset.transformFeatures = @transformFeatures;
dataset.inputCenter = featureCenter;
dataset.inputScale = featureScale;
dataset.targetLogMask = targetLogMask;
dataset.featureLogMask = [true, true, true, false, false];
dataset.counts = struct('train', size(XTrain,1), 'validation', size(XValidation,1), 'test', size(XTest,1));
end

function Xnorm = normalizeFeatures(Xraw, center, scale)
if isempty(Xraw)
    Xnorm = Xraw;
    return;
end
Xtrans = transformFeatures(Xraw);
Xnorm = bsxfun(@minus, Xtrans, center);
Xnorm = bsxfun(@rdivide, Xnorm, scale);
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

function Xtrans = transformFeatures(Xraw)
Xtrans = double(Xraw);
if isempty(Xtrans)
    return;
end
logMask = [true, true, true, false, false];
geomCols = Xtrans(:, logMask);
if any(geomCols(:) <= 0)
    error('prepare_training_dataset:NonPositiveFeature', 'Encountered non-positive geometric feature for log transform.');
end
Xtrans(:, logMask) = log(geomCols);
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
