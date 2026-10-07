function model = train_surrogate_dnn(dataset, options)
% train_surrogate_dnn  Train the dense residual network for spectral surrogate regression.
%
% model = train_surrogate_dnn(dataset) trains using defaults.
% model = train_surrogate_dnn(dataset, options) accepts optional parameters:
%
% Parameters:
%   MaxEpochs       (default 1000) - maximum training epochs
%   MiniBatchSize   (default 512) - samples per mini-batch
%   LearningRate    (default 1e-3) - initial learning rate
%   Layers          (default []) - custom network (dlnetwork or layer array)
%   NetworkConfig   (default struct()) - override default layer widths
%   TargetLossWeights (default []) - per-target loss weights
%   Verbose         (default true) - display training progress
%
% NetworkConfig.normalization (default "layer") selects the per-layer
% normalisation in trunk and heads: "layer" (layerNormalizationLayer,
% per-sample, identical in training and inference) or "batch" (legacy).
%
% Metrics: trainnet monitors RMSE in the training target space (log1p, or
% standardised log1p for v2_physics datasets). After training, validation
% and test splits are evaluated with RMSE, MAE, R^2 and MAPE in physical
% units (after dataset.denormalize), and R^2 per channel in the training
% space (performance.*.rsquaredTrainSpace).

arguments
    dataset struct {mustBeDatasetStruct(dataset)}
    options.MaxEpochs (1,1) uint32 {mustBePositive} = 1000
    options.MiniBatchSize (1,1) uint32 {mustBePositive} = 512
    options.LearningRate (1,1) double {mustBePositive} = 1e-3
    options.Layers = []
    options.NetworkConfig (1,1) struct = struct()
    options.TargetLossWeights (1,:) double = []
    options.Verbose (1,1) logical = true
    options.Optimizer (1,1) string = "adam"
    options.LossFunction (1,1) string = "mse"
    options.LearnRateSchedule (1,1) string = "cosine"
    options.LearnRateDropFactor (1,1) double = 0.1
    options.LearnRateDropPeriod (1,1) double {mustBePositive, mustBeInteger} = 10
    options.GradientThreshold (1,1) double = inf
    options.GradientThresholdMethod (1,1) string = "l2norm"
    options.L2Regularization (1,1) double {mustBeNonnegative} = 0.0001
    options.Momentum (1,1) double = 0.9
    options.GradientDecayFactor (1,1) double = 0.9
    options.SquaredGradientDecayFactor (1,1) double = 0.999
    options.Epsilon (1,1) double = 1e-8
    options.Shuffle (1,1) string = "every-epoch"
    options.ValidationFrequency (1,1) double = NaN
    options.ValidationPatience (1,1) double = NaN
    options.VerboseFrequency (1,1) double = 200
    options.Plots (1,1) string = "training-progress"
    options.ObjectiveMetricName (1,1) string = "loss"
    options.OutputNetwork (1,1) string = "auto"
    options.ExecutionEnvironment (1,1) string = "auto"
    options.PreprocessingEnvironment (1,1) string = "serial"
    options.Acceleration (1,1) string = "auto"
    options.CheckpointPath (1,1) string = ""
    options.CheckpointFrequency (1,1) double = 50
    options.CheckpointFrequencyUnit (1,1) string = "epoch"
    options.ResetInputNormalization (1,1) logical = true
    options.BatchNormalizationStatistics (1,1) string = "auto"
    options.SequenceLength (1,1) string = "longest"
    options.SequencePaddingDirection (1,1) string = "right"
    options.SequencePaddingValue (1,1) double = 0
    options.InputDataFormats (1,1) string = "auto"
    options.TargetDataFormats (1,1) string = "auto"
    options.CategoricalInputEncoding (1,1) string = "integer"
    options.CategoricalTargetEncoding (1,1) string = "auto"
    options.ExtraTrainingOptions cell = {}
    options.StopTrainingFcn function_handle = function_handle.empty
end

% trainnet metric is computed on the training-space targets; MAPE there is
% ill-defined (standardised targets cross zero), so RMSE is monitored.
trainMetricsList = "rmse";
% Evaluation metrics, computed in physical units after denormalisation.
metricsList = ["rmse", "mae", "rsquared", "mape"];
opts = struct();
opts.MaxEpochs = options.MaxEpochs;
opts.MiniBatchSize = options.MiniBatchSize;
opts.LearningRate = options.LearningRate;
opts.Layers = options.Layers;
opts.NetworkConfig = options.NetworkConfig;
opts.TargetLossWeights = options.TargetLossWeights;
opts.Verbose = options.Verbose;
opts.Optimizer = options.Optimizer;
opts.LossFunction = options.LossFunction;
opts.LearnRateSchedule = options.LearnRateSchedule;
opts.LearnRateDropFactor = options.LearnRateDropFactor;
opts.LearnRateDropPeriod = options.LearnRateDropPeriod;
opts.GradientThreshold = options.GradientThreshold;
opts.GradientThresholdMethod = options.GradientThresholdMethod;
opts.L2Regularization = options.L2Regularization;
opts.Momentum = options.Momentum;
opts.GradientDecayFactor = options.GradientDecayFactor;
opts.SquaredGradientDecayFactor = options.SquaredGradientDecayFactor;
opts.Epsilon = options.Epsilon;
opts.Shuffle = options.Shuffle;
opts.ValidationFrequency = options.ValidationFrequency;
opts.ValidationPatience = options.ValidationPatience;
opts.VerboseFrequency = options.VerboseFrequency;
opts.StopTrainingFcn = options.StopTrainingFcn;
opts.Plots = options.Plots;
opts.ObjectiveMetricName = options.ObjectiveMetricName;
opts.OutputNetwork = options.OutputNetwork;
opts.ExecutionEnvironment = options.ExecutionEnvironment;
opts.PreprocessingEnvironment = options.PreprocessingEnvironment;
opts.Acceleration = options.Acceleration;
opts.CheckpointPath = options.CheckpointPath;
opts.CheckpointFrequency = options.CheckpointFrequency;
opts.CheckpointFrequencyUnit = options.CheckpointFrequencyUnit;
opts.ResetInputNormalization = options.ResetInputNormalization;
opts.BatchNormalizationStatistics = options.BatchNormalizationStatistics;
opts.SequenceLength = options.SequenceLength;
opts.SequencePaddingDirection = options.SequencePaddingDirection;
opts.SequencePaddingValue = options.SequencePaddingValue;
opts.InputDataFormats = options.InputDataFormats;
opts.TargetDataFormats = options.TargetDataFormats;
opts.CategoricalInputEncoding = options.CategoricalInputEncoding;
opts.CategoricalTargetEncoding = options.CategoricalTargetEncoding;
opts.ExtraTrainingOptions = options.ExtraTrainingOptions;

if ~isfinite(opts.VerboseFrequency) || opts.VerboseFrequency < 1
    opts.VerboseFrequency = 200;
end
if ~isfinite(opts.SequencePaddingValue)
    opts.SequencePaddingValue = 0;
end
if ~isfinite(opts.ValidationFrequency) || opts.ValidationFrequency < 1
    % Auto-calculate: validate once per epoch based on training set size and MiniBatchSize
    nTrain = size(dataset.XTrain, 1);
    opts.ValidationFrequency = max(1, floor(nTrain / opts.MiniBatchSize));
end

requiredFields = {'normalize','denormalize','XTrain','YTrain','XValidation', ...
    'YValidation','XTest','YTest'};

XTrain = dataset.normalize(dataset.XTrain);
YTrain = normalizeTargets(dataset);
XValidation = dataset.normalize(dataset.XValidation);
YValidation = normalizeTargets(dataset, 'validation');
XTest = dataset.normalize(dataset.XTest);
YTest = normalizeTargets(dataset, 'test');

% Comprehensive validation of normalized data
if opts.Verbose
    fprintf('  Validating normalized training data...\n');
end

% Check XTrain
[isValidX, diagX] = validateDataMatrix(XTrain, 'XTrain', dataset.featureNames);
if ~isValidX
    error('train_sers_dnn:InvalidXTrain', 'XTrain validation failed:\n%s', diagX);
end

% Check YTrain
[isValidY, diagY] = validateDataMatrix(YTrain, 'YTrain', dataset.targetNames);
if ~isValidY
    error('train_sers_dnn:InvalidYTrain', 'YTrain validation failed:\n%s\n\nHint: Check if target values contain -1 (log1p(-1)=-Inf) or negative values requiring log transform.', diagY);
end

% Check validation data if present
if ~isempty(XValidation)
    [isValidXV, diagXV] = validateDataMatrix(XValidation, 'XValidation', dataset.featureNames);
    if ~isValidXV
        error('train_sers_dnn:InvalidXValidation', 'XValidation validation failed:\n%s', diagXV);
    end
end

if ~isempty(YValidation)
    [isValidYV, diagYV] = validateDataMatrix(YValidation, 'YValidation', dataset.targetNames);
    if ~isValidYV
        error('train_sers_dnn:InvalidYValidation', 'YValidation validation failed:\n%s', diagYV);
    end
end

if opts.Verbose
    fprintf('  ✓ All normalized data validated (finite values only)\n');
    fprintf('    XTrain range: [%.3g, %.3g]\n', min(XTrain(:)), max(XTrain(:)));
    fprintf('    YTrain range: [%.3g, %.3g]\n', min(YTrain(:)), max(YTrain(:)));
end

% Ensure data is double precision
XTrain = double(XTrain);
YTrain = double(YTrain);
if ~isempty(XValidation)
    XValidation = double(XValidation);
    YValidation = double(YValidation);
end
if ~isempty(XTest)
    XTest = double(XTest);
    YTest = double(YTest);
end

% Check data statistics for potential issues
if opts.Verbose
    fprintf('  Data statistics:\n');
    for i = 1:min(3, size(XTrain, 2))
        colData = XTrain(:, i);
        fprintf('    Feature %d: mean=%.3g, std=%.3g, range=[%.3g, %.3g]\n', ...
            i, mean(colData), std(colData), min(colData), max(colData));
    end
    for i = 1:size(YTrain, 2)
        colData = YTrain(:, i);
        if i <= numel(dataset.targetNames)
            colName = dataset.targetNames{i};
        else
            colName = sprintf('target_%d', i);
        end
        fprintf('    %s: mean=%.3g, std=%.3g, range=[%.3g, %.3g]\n', ...
            colName, mean(colData), std(colData), min(colData), max(colData));
    end
end

numFeatures = size(XTrain, 2);
numTargets = size(YTrain, 2);

if isempty(XValidation)
    validationData = [];
else
    validationData = {XValidation, YValidation};
end

if isempty(opts.Layers)
    netCandidate = localBuildDefaultNetwork(numFeatures, numTargets, opts.NetworkConfig);
else
    netCandidate = opts.Layers;
end
netArchitecture = localEnsureDlnetwork(netCandidate);

if opts.Verbose
    fprintf('  Network architecture: %d → %d targets\n', numFeatures, numTargets);
end

% Determine solver type
solverType = lower(string(opts.Optimizer));
isBatchSolver = ismember(solverType, ["lbfgs", "lm"]);
isStochasticSolver = ~isBatchSolver;

% Auto-resolve ExecutionEnvironment to GPU if available and set to auto
resolvedExecEnv = string(opts.ExecutionEnvironment);
if strcmpi(resolvedExecEnv, "auto")
    try
        if gpuDeviceCount > 0
            resolvedExecEnv = "gpu";
            if opts.Verbose
                dInfo = gpuDevice;
                fprintf('  Execution environment: GPU auto-selected (%s)\n', dInfo.Name);
            end
        else
            resolvedExecEnv = "cpu";
            if opts.Verbose
                fprintf('  Execution environment: CPU (no GPU detected)\n');
            end
        end
    catch
        resolvedExecEnv = "cpu";
    end
end

% Build base options (common to all solvers)
optionsArgs = {
    'ExecutionEnvironment', char(resolvedExecEnv), ...
    'Verbose', opts.Verbose, ...
    'VerboseFrequency', opts.VerboseFrequency, ...
    'Plots', char(opts.Plots), ...
    'L2Regularization', opts.L2Regularization, ...
    'GradientThreshold', opts.GradientThreshold, ...
    'GradientThresholdMethod', char(opts.GradientThresholdMethod), ...
    'ObjectiveMetricName', char(opts.ObjectiveMetricName), ...
    'OutputNetwork', char(opts.OutputNetwork), ...
    'PreprocessingEnvironment', char(opts.PreprocessingEnvironment), ...
    'Acceleration', char(opts.Acceleration), ...
    'ResetInputNormalization', opts.ResetInputNormalization, ...
    'BatchNormalizationStatistics', char(opts.BatchNormalizationStatistics), ...
    'InputDataFormats', char(opts.InputDataFormats), ...
    'TargetDataFormats', char(opts.TargetDataFormats), ...
    'CategoricalInputEncoding', char(opts.CategoricalInputEncoding), ...
    'CategoricalTargetEncoding', char(opts.CategoricalTargetEncoding) ...
    };

% Add metrics if not empty
if ~isempty(trainMetricsList)
    optionsArgs(end+1:end+2) = {'Metrics', trainMetricsList};
end

% Stochastic solver options
if isStochasticSolver
    optionsArgs(end+1:end+2) = {'MaxEpochs', opts.MaxEpochs};
    optionsArgs(end+1:end+2) = {'MiniBatchSize', opts.MiniBatchSize};
    optionsArgs(end+1:end+2) = {'InitialLearnRate', opts.LearningRate};
    optionsArgs(end+1:end+2) = {'LearnRateSchedule', char(opts.LearnRateSchedule)};
    optionsArgs(end+1:end+2) = {'Shuffle', char(opts.Shuffle)};
    optionsArgs(end+1:end+2) = {'SequenceLength', char(opts.SequenceLength)};
    optionsArgs(end+1:end+2) = {'SequencePaddingDirection', char(opts.SequencePaddingDirection)};
    optionsArgs(end+1:end+2) = {'SequencePaddingValue', opts.SequencePaddingValue};
    
    % Piecewise schedule options
    if strcmpi(opts.LearnRateSchedule, "piecewise")
        optionsArgs(end+1:end+2) = {'LearnRateDropFactor', opts.LearnRateDropFactor};
        optionsArgs(end+1:end+2) = {'LearnRateDropPeriod', opts.LearnRateDropPeriod};
    end
    
    % Optimizer-specific momentum/decay parameters
    if strcmpi(solverType, "sgdm")
        optionsArgs(end+1:end+2) = {'Momentum', opts.Momentum};
    elseif strcmpi(solverType, "adam")
        optionsArgs(end+1:end+2) = {'GradientDecayFactor', opts.GradientDecayFactor};
        optionsArgs(end+1:end+2) = {'SquaredGradientDecayFactor', opts.SquaredGradientDecayFactor};
        optionsArgs(end+1:end+2) = {'Epsilon', opts.Epsilon};
    elseif strcmpi(solverType, "rmsprop")
        optionsArgs(end+1:end+2) = {'SquaredGradientDecayFactor', opts.SquaredGradientDecayFactor};
        optionsArgs(end+1:end+2) = {'Epsilon', opts.Epsilon};
    end
end

% Validation options (only if validation data exists)
if ~isempty(validationData)
    optionsArgs(end+1:end+2) = {'ValidationData', validationData};
    optionsArgs(end+1:end+2) = {'ValidationFrequency', opts.ValidationFrequency};
    if isfinite(opts.ValidationPatience) && opts.ValidationPatience > 0
        optionsArgs(end+1:end+2) = {'ValidationPatience', opts.ValidationPatience};
    end
end

% Checkpoint options (only if path AND frequency specified)
opts.OriginalCheckpointPath = "";
if strlength(opts.CheckpointPath) > 0 && isfinite(opts.CheckpointFrequency) && opts.CheckpointFrequency > 0
    fprintf('  Checkpoint enabled: every %g %s\n', opts.CheckpointFrequency, opts.CheckpointFrequencyUnit);
    
    % Check if path is on OneDrive or other cloud storage
    checkpointPathStr = char(opts.CheckpointPath);
    isOneDrive = contains(checkpointPathStr, 'OneDrive', 'IgnoreCase', true) || ...
                 contains(checkpointPathStr, 'iCloud', 'IgnoreCase', true) || ...
                 contains(checkpointPathStr, 'Dropbox', 'IgnoreCase', true) || ...
                 contains(checkpointPathStr, 'Google Drive', 'IgnoreCase', true);
    
    if isOneDrive
        % OneDrive path - use local temp directory for training, copy back after
        localCheckpointDir = "C:/tmp/DNNCheckPoints";
        if isfolder(localCheckpointDir)
            % Safeguard: preserve any existing checkpoints before clearing
            oldCheckpoints = dir(fullfile(localCheckpointDir, "*.mat"));
            if ~isempty(oldCheckpoints)
                % 1. Copy to original checkpoint path if valid
                if ~isfolder(checkpointPathStr)
                    try mkdir(checkpointPathStr); catch; end
                end
                if isfolder(checkpointPathStr)
                    for k = 1:numel(oldCheckpoints)
                        srcCp = fullfile(oldCheckpoints(k).folder, oldCheckpoints(k).name);
                        dstCp = fullfile(checkpointPathStr, oldCheckpoints(k).name);
                        if ~isfile(dstCp)
                            try copyfile(srcCp, dstCp); catch; end
                        end
                    end
                end
                % 2. Archive to C:/tmp/DNNCheckPoints_archive/<timestamp>
                archiveDir = fullfile("C:/tmp/DNNCheckPoints_archive", ...
                    string(datetime("now", "Format", "yyyyMMdd_HHmmss")));
                try
                    mkdir(archiveDir);
                    for k = 1:numel(oldCheckpoints)
                        copyfile(fullfile(oldCheckpoints(k).folder, oldCheckpoints(k).name), ...
                            fullfile(archiveDir, oldCheckpoints(k).name));
                    end
                    fprintf('    (Preserved %d existing checkpoint(s) to %s)\n', numel(oldCheckpoints), archiveDir);
                catch
                end
            end
            try
                rmdir(localCheckpointDir, 's');
            catch
            end
        end
        mkdir(localCheckpointDir);
        fprintf('    (OneDrive detected: using temp dir %s)\n', localCheckpointDir);
        
        opts.OriginalCheckpointPath = string(checkpointPathStr);
        opts.CheckpointPath = string(localCheckpointDir);
    else
        % Local path - create if it doesn't exist
        if ~isfolder(checkpointPathStr)
            [status, ~] = mkdir(checkpointPathStr);
            if ~status
                warning('train_sers_dnn:CheckpointDirFailed', ...
                    'Failed to create checkpoint directory %s. Checkpointing disabled.', checkpointPathStr);
                opts.CheckpointPath = "";
            end
        end
    end
    
    if strlength(opts.CheckpointPath) > 0
        fprintf('    Location: %s\n', char(opts.CheckpointPath));
        optionsArgs(end+1:end+2) = {'CheckpointPath', char(opts.CheckpointPath)};
        optionsArgs(end+1:end+2) = {'CheckpointFrequency', opts.CheckpointFrequency};
        optionsArgs(end+1:end+2) = {'CheckpointFrequencyUnit', char(opts.CheckpointFrequencyUnit)};
    end
else
    % No checkpointing
    if opts.Verbose
        fprintf('  Checkpoint disabled (specify both CheckpointPath and CheckpointFrequency to enable)\n');
    end
end

% Extra options from free-form field
if ~isempty(opts.ExtraTrainingOptions)
    extraArgs = opts.ExtraTrainingOptions;
    if iscell(extraArgs) && mod(numel(extraArgs), 2) == 0
        optionsArgs = [optionsArgs, extraArgs(:)'];
    end
end

isPlotMonitor = strcmpi(opts.Plots, "training-progress");
outputFcn = @(info)localTrainingOutputFcn(info, trainMetricsList, opts.StopTrainingFcn, isPlotMonitor);
optionsArgs(end+1:end+2) = {'OutputFcn', outputFcn};

if strcmpi(opts.Optimizer, "lm") && ~strcmpi(opts.LossFunction, "mse")
    error('train_sers_dnn:LossFunction', 'LM optimizer requires MSE loss.');
end
trainingOpts = trainingOptions(char(opts.Optimizer), optionsArgs{:});

if opts.Verbose
    fprintf('  Starting training (epochs: %d, batch size: %d, lr: %.1e)...\n', ...
        opts.MaxEpochs, opts.MiniBatchSize, opts.LearningRate);
end

lossFcn = localResolveLossFunction(opts.LossFunction);
weights = [];
if ~isempty(opts.TargetLossWeights)
    weights = localValidateLossWeights(opts.TargetLossWeights, numTargets);
    lossFcn = localWrapWeightedLoss(lossFcn, weights);
end

% Test network initialization with a small forward pass
try
    testBatch = XTrain(1:min(10, size(XTrain, 1)), :);
    testPred = predict(netArchitecture, testBatch);
    if any(~isfinite(testPred(:)))
        error('train_sers_dnn:InitializationFailed', 'Network produces NaN/Inf predictions on test batch.');
    end
    if opts.Verbose
        fprintf('  Network initialization validated.\n');
    end
catch ME
    error('train_sers_dnn:NetworkTest', 'Network forward pass failed: %s', ME.message);
end

% Test loss function if weighted
if ~isempty(weights)
    try
        % Simulate dlarray layout: trainnet uses [nTargets x batch] internally
        testTargets = YTrain(1:min(10, size(YTrain, 1)), :)';  % Transpose to [nTargets x batch]
        testPredT = testPred';  % Also transpose predictions
        testLoss = localWeightedMse(testPredT, testTargets, weights);
        if ~isfinite(testLoss)
            error('Weighted loss function returns NaN/Inf');
        end
        if opts.Verbose
            fprintf('  Weighted loss function validated (test loss: %.6g).\n', testLoss);
        end
    catch ME
        error('train_sers_dnn:LossFunctionTest', 'Loss function test failed: %s', ME.message);
    end
end

try
    net = trainnet(XTrain, YTrain, netArchitecture, lossFcn, trainingOpts);
catch ME
    error('train_sers_dnn:TrainingFailed', 'trainnet failed: %s\n\nDiagnostics:\n  XTrain: [%d x %d], range [%.3g, %.3g]\n  YTrain: [%d x %d], range [%.3g, %.3g]\n  Network inputs: %d, outputs: %d', ...
        ME.message, size(XTrain, 1), size(XTrain, 2), min(XTrain(:)), max(XTrain(:)), ...
        size(YTrain, 1), size(YTrain, 2), min(YTrain(:)), max(YTrain(:)), ...
        numFeatures, numTargets);
end

if opts.Verbose
    fprintf('  ✓ Training complete\n');
end

% Copy checkpoints from temp directory to original path if needed
if strlength(opts.OriginalCheckpointPath) > 0
    try
        cpFiles = dir(fullfile(char(opts.CheckpointPath), '*.mat'));
        if ~isempty(cpFiles)
            if ~isfolder(opts.OriginalCheckpointPath)
                mkdir(char(opts.OriginalCheckpointPath));
            end
            for k = 1:numel(cpFiles)
                copyfile(fullfile(cpFiles(k).folder, cpFiles(k).name), ...
                    fullfile(char(opts.OriginalCheckpointPath), cpFiles(k).name));
            end
            fprintf('  Copied %d checkpoint file(s) to: %s\n', numel(cpFiles), opts.OriginalCheckpointPath);
        end
        % Clean up temp directory
        rmdir(char(opts.CheckpointPath), 's');
    catch ME
        warning('train_sers_dnn:CheckpointCopyFailed', ...
            'Failed to copy checkpoints to original path: %s', ME.message);
    end
end

% Evaluate validation split for diagnostics.
if opts.Verbose
    fprintf('  Evaluating on validation set...\n');
end
valCount = size(YValidation, 1);
[YPredValidationNorm, YPredValidationRaw, valMetricsPerTarget, valMetricsAggregate, valLossPerTarget, valRmseLog, valRmseRaw] = ...
    evaluateModelSplit(net, XValidation, YValidation, dataset, opts.MiniBatchSize, numTargets, metricsList);
valLossAggregate = mean(valLossPerTarget, 'omitnan');

% Evaluate test split
if opts.Verbose
    fprintf('  Evaluating on test set...\n');
end
testCount = size(YTest, 1);
[YPredTestNorm, YPredTestRaw, testMetricsPerTarget, testMetricsAggregate, testLossPerTarget, testRmseLog, testRmseRaw] = ...
    evaluateModelSplit(net, XTest, YTest, dataset, opts.MiniBatchSize, numTargets, metricsList);
testLossAggregate = mean(testLossPerTarget, 'omitnan');

% Per-channel R^2 in the training target space (scale-free; comparable
% across channels irrespective of their physical magnitude).
valR2Train = localRSquared(YValidation, YPredValidationNorm);
testR2Train = localRSquared(YTest, YPredTestNorm);

if opts.Verbose
    fprintf('  ✓ Evaluation complete\n');
    localDisplayTestMetrics(dataset.targetNames, metricsList, testMetricsPerTarget, testMetricsAggregate);
    fprintf('  R^2 (training space) per target: [%s]\n\n', ...
        strjoin(compose('%.4f', testR2Train), ', '));
end

model = struct();
model.net = net;
if isfield(dataset, "scale")
    model.scale = dataset.scale;
else
    model.scale = struct();
end
model.featureNames = dataset.featureNames;
model.targetNames = dataset.targetNames;

validationPerf = struct('count', valCount, ...
    'loss', valLossPerTarget, ...
    'lossAggregate', valLossAggregate, ...
    'rmse', valRmseRaw, ...
    'rmseLog', valRmseLog, ...
    'metrics', valMetricsPerTarget, ...
    'metricsAggregate', valMetricsAggregate, ...
    'rsquaredTrainSpace', valR2Train);

testPerf = struct('count', testCount, ...
    'loss', testLossPerTarget, ...
    'lossAggregate', testLossAggregate, ...
    'rmse', testRmseRaw, ...
    'rmseLog', testRmseLog, ...
    'metrics', testMetricsPerTarget, ...
    'metricsAggregate', testMetricsAggregate, ...
    'rsquaredTrainSpace', testR2Train);

performance = struct('rmse', testRmseRaw, ...
    'rmseLog', testRmseLog, ...
    'testCount', testCount, ...
    'testMetrics', testMetricsPerTarget, ...
    'testMetricsAggregate', testMetricsAggregate, ...
    'testLoss', testLossPerTarget, ...
    'testLossAggregate', testLossAggregate, ...
    'validation', validationPerf, ...
    'test', testPerf, ...
    'metricsList', metricsList, ...
    'trainMetricsList', trainMetricsList);
if isfield(dataset, 'splitMode')
    performance.splitMode = dataset.splitMode;
end
model.performance = performance;
model.normalize = dataset.normalize;
model.denormalize = dataset.denormalize;
if isfield(dataset, 'transformFeatures')
    model.transformFeatures = dataset.transformFeatures;
else
    model.transformFeatures = @(x) x;
end
if isfield(dataset, 'inputCenter'), model.inputCenter = dataset.inputCenter; end
if isfield(dataset, 'inputScale'), model.inputScale = dataset.inputScale; end
if isfield(dataset, 'targetLogMask'), model.targetLogMask = dataset.targetLogMask; end
if isfield(dataset, 'featureLogMask'), model.featureLogMask = dataset.featureLogMask; end
model.inputSize = size(XTrain, 2);
if isfield(dataset, 'FeatureLogTransform'), model.FeatureLogTransform = dataset.FeatureLogTransform; else, model.FeatureLogTransform = false; end
if isfield(dataset, 'IncludeRatios'), model.IncludeRatios = dataset.IncludeRatios; else, model.IncludeRatios = false; end
if isfield(dataset, 'TargetLogTransform'), model.TargetLogTransform = dataset.TargetLogTransform; else, model.TargetLogTransform = false; end
model.inputPreprocessing = "normalize";
model.normalizeIncludesRatios = true;
model.flags = struct( ...
    "FeatureLogTransform", model.FeatureLogTransform, ...
    "IncludeRatios", model.IncludeRatios, ...
    "TargetLogTransform", model.TargetLogTransform, ...
    "InputSize", model.inputSize, ...
    "InputPreprocessing", model.inputPreprocessing, ...
    "NormalizeIncludesRatios", model.normalizeIncludesRatios, ...
    "FeatureNames", {cellstr(model.featureNames)});
opts.MetricsList = metricsList;
opts.TrainMetricsList = trainMetricsList;
model.options = opts;

% v2 physics schema: persist the feature/target statistics so the model is
% self-describing; ensureModelFlags rebuilds normalize/denormalize from them.
if isfield(dataset, 'featureSchema') && isfield(dataset, 'targetTransform')
    model.featureSchema = dataset.featureSchema;
    model.targetTransform = dataset.targetTransform;
    if isfield(dataset, 'baseFeatureNames')
        model.baseFeatureNames = dataset.baseFeatureNames;
    end
    model = ensureModelFlags(model);
end
end

function r2 = localRSquared(YTrue, YPred)
% Per-column coefficient of determination; NaN for empty/constant columns.
if isempty(YTrue)
    r2 = NaN(1, size(YTrue, 2));
    return;
end
ssRes = sum((YPred - YTrue).^2, 1, 'omitnan');
ssTot = sum((YTrue - mean(YTrue, 1, 'omitnan')).^2, 1, 'omitnan');
r2 = 1 - ssRes ./ max(ssTot, eps);
r2(ssTot <= eps) = NaN;
end

function netArchitecture = localBuildDefaultNetwork(numFeatures, numTargets, config)
config = localNormalizeNetworkConfig(config, numTargets);
netArchitecture = dlnetwork;
netArchitecture = addLayers(netArchitecture, featureInputLayer(numFeatures, 'Name', 'input'));

% --- Block 1 ---
block1 = [
    fullyConnectedLayer(config.fc1a, 'Name', 'fc1a')
    localNormLayer('bn1a', config.normalization)
    geluLayer('Name', 'gelu1a')
    fullyConnectedLayer(config.fc1b, 'Name', 'fc1b')
    localNormLayer('bn1b', config.normalization)
    geluLayer('Name', 'gelu1b')];
netArchitecture = addLayers(netArchitecture, block1);
netArchitecture = addLayers(netArchitecture, fullyConnectedLayer(config.proj1, 'Name', 'proj1'));
netArchitecture = addLayers(netArchitecture, additionLayer(2, 'Name', 'add1'));

netArchitecture = connectLayers(netArchitecture, 'input', 'fc1a');
netArchitecture = connectLayers(netArchitecture, 'gelu1b', 'add1/in1');
netArchitecture = connectLayers(netArchitecture, 'input', 'proj1');
netArchitecture = connectLayers(netArchitecture, 'proj1', 'add1/in2');

% --- Injection 1 (Mid): Concatenate Block 1 Output + Input Payload ---
netArchitecture = addLayers(netArchitecture, concatenationLayer(1, 2, 'Name', 'concat_mid'));
netArchitecture = connectLayers(netArchitecture, 'add1', 'concat_mid/in1');
netArchitecture = connectLayers(netArchitecture, 'input', 'concat_mid/in2');

% --- Block 2 ---
block2 = [
    fullyConnectedLayer(config.fc2a, 'Name', 'fc2a')
    localNormLayer('bn2a', config.normalization)
    geluLayer('Name', 'gelu2a')
    fullyConnectedLayer(config.fc2b, 'Name', 'fc2b')
    localNormLayer('bn2b', config.normalization)
    geluLayer('Name', 'gelu2b')];
netArchitecture = addLayers(netArchitecture, block2);
netArchitecture = addLayers(netArchitecture, additionLayer(2, 'Name', 'add2'));

% Residual conn: proj2 projects concat_mid to match fc2b
netArchitecture = addLayers(netArchitecture, fullyConnectedLayer(config.fc2b, 'Name', 'proj2'));

netArchitecture = connectLayers(netArchitecture, 'concat_mid', 'fc2a');
netArchitecture = connectLayers(netArchitecture, 'gelu2b', 'add2/in1');
netArchitecture = connectLayers(netArchitecture, 'concat_mid', 'proj2');
netArchitecture = connectLayers(netArchitecture, 'proj2', 'add2/in2');

% --- Injection 2 (Head): Concatenate Block 2 Output + Input Payload ---
netArchitecture = addLayers(netArchitecture, concatenationLayer(1, 2, 'Name', 'concat_head'));
netArchitecture = connectLayers(netArchitecture, 'add2', 'concat_head/in1');
netArchitecture = connectLayers(netArchitecture, 'input', 'concat_head/in2');

% --- Output Heads ---
if config.useMultiHead
    headInputNames = cell(1, numTargets);
    for i = 1:numTargets
        headName = sprintf('head_%d', i);
        headLayers = localBuildHeadLayers(headName, config.headHiddenSizes, 1, config.normalization);
        netArchitecture = addLayers(netArchitecture, headLayers);
        netArchitecture = connectLayers(netArchitecture, 'concat_head', [headName '_fc1']);
        headInputNames{i} = [headName '_out'];
    end

    netArchitecture = addLayers(netArchitecture, concatenationLayer(1, numTargets, 'Name', 'concatOut'));
    for i = 1:numTargets
        netArchitecture = connectLayers(netArchitecture, headInputNames{i}, sprintf('concatOut/in%d', i));
    end

    netArchitecture = addLayers(netArchitecture, localRegressionIdentityLayer('regression'));
    netArchitecture = connectLayers(netArchitecture, 'concatOut', 'regression');
else
    outLayers = localBuildHeadLayers('out', config.headHiddenSizes, numTargets, config.normalization);
    netArchitecture = addLayers(netArchitecture, outLayers);
    netArchitecture = connectLayers(netArchitecture, 'concat_head', 'out_fc1');
    netArchitecture = addLayers(netArchitecture, localRegressionIdentityLayer('regression'));
    netArchitecture = connectLayers(netArchitecture, 'out_out', 'regression');
end

if ~netArchitecture.Initialized
    netArchitecture = initialize(netArchitecture);
end
end

function config = localNormalizeNetworkConfig(configIn, numTargets)
config = struct();
config.useMultiHead = true;
config.fc1a = 128;
config.fc1b = 256;
config.proj1 = 256;  % Auto-determined: must equal fc1b
config.fc2a = 512;
config.fc2b = 256;   % Auto-determined: must equal fc1b
config.headHiddenSizes = 128;          % Used for both single and multi-head
config.normalization = "layer";        % "layer" (default) | "batch" (legacy)

if nargin < 1 || isempty(configIn)
    config = localValidateNetworkConfig(config, numTargets);
    return;
end

fields = fieldnames(configIn);
for k = 1:numel(fields)
    key = fields{k};
    config.(key) = configIn.(key);
end

config = localValidateNetworkConfig(config, numTargets);
end

function config = localValidateNetworkConfig(config, numTargets)
config.useMultiHead = logical(config.useMultiHead);
config.fc1a = localPosInt(config.fc1a, 'fc1a');
config.fc1b = localPosInt(config.fc1b, 'fc1b');
config.proj1 = localPosInt(config.proj1, 'proj1');
config.fc2a = localPosInt(config.fc2a, 'fc2a');
config.fc2b = localPosInt(config.fc2b, 'fc2b');
config.headHiddenSizes = localPosIntVec(config.headHiddenSizes, 'headHiddenSizes');
config.normalization = lower(string(config.normalization));
if ~ismember(config.normalization, ["layer", "batch"])
    error('train_sers_dnn:NetworkConfig', ...
        'Network config normalization must be "layer" or "batch" (got "%s").', config.normalization);
end

if numTargets < 1
    error('train_sers_dnn:Targets', 'Number of targets must be >= 1.');
end

% Auto-enforce residual connection constraints
% The network has two residual paths:
% 1. input → proj1 → add1/in2  (must match fc1b → add1/in1)
% 2. add1 → add2/in2  (must match fc2b → add2/in1)
% Therefore: proj1 must equal fc1b, and fc2b must equal proj1 (=fc1b)
if config.proj1 ~= config.fc1b
    warning('train_sers_dnn:ArchitectureConstraint', ...
        'proj1 (%d) auto-corrected to fc1b (%d) for residual connection.', ...
        config.proj1, config.fc1b);
    config.proj1 = config.fc1b;
end
if config.fc2b ~= config.fc1b
    warning('train_sers_dnn:ArchitectureConstraint', ...
        'fc2b (%d) auto-corrected to fc1b (%d) for residual connection.', ...
        config.fc2b, config.fc1b);
    config.fc2b = config.fc1b;
end
end

function value = localPosInt(value, name)
if ~isscalar(value) || ~isfinite(value) || value < 1
    error('train_sers_dnn:NetworkConfig', 'Network config %s must be a positive integer.', name);
end
value = round(double(value));
end

function values = localPosIntVec(values, name)
if isempty(values)
    error('train_sers_dnn:NetworkConfig', 'Network config %s cannot be empty.', name);
end
values = double(values(:)');
if any(~isfinite(values)) || any(values < 1)
    error('train_sers_dnn:NetworkConfig', 'Network config %s must be positive integers.', name);
end
values = round(values);
end

function layer = localNormLayer(name, kind)
% Per-layer normalisation. LayerNorm normalises each sample over its
% channels, so its behaviour does not depend on mini-batch composition.
if nargin < 2 || isempty(kind)
    kind = "layer";
end
switch lower(string(kind))
    case "batch"
        layer = batchNormalizationLayer('Name', name);
    otherwise
        layer = layerNormalizationLayer('Name', name);
end
end

function layers = localBuildHeadLayers(prefix, hiddenSizes, outSize, normKind)
if nargin < 3 || isempty(outSize)
    outSize = 1;
end
if nargin < 4
    normKind = "layer";
end
hiddenSizes = localPosIntVec(hiddenSizes, 'headHiddenSizes');
layers = [];
for idx = 1:numel(hiddenSizes)
    fcName = sprintf('%s_fc%d', prefix, idx);
    bnName = sprintf('%s_bn%d', prefix, idx);
    geluName = sprintf('%s_gelu%d', prefix, idx);
    layers = [layers
        fullyConnectedLayer(hiddenSizes(idx), 'Name', fcName)
        localNormLayer(bnName, normKind)
        geluLayer('Name', geluName)]; %#ok<AGROW>
end
layers = [layers
    fullyConnectedLayer(outSize, 'Name', sprintf('%s_out', prefix))];
end

function weights = localValidateLossWeights(weights, numTargets)
weights = double(weights(:)');
if numel(weights) ~= numTargets
    error('train_sers_dnn:LossWeights', 'TargetLossWeights must have %d entries.', numTargets);
end
if any(~isfinite(weights)) || any(weights < 0)
    error('train_sers_dnn:LossWeights', 'TargetLossWeights must be non-negative finite values.');
end
end

function loss = localWeightedMse(Y, T, weights)
% Weighted MSE compatible with trainnet dlarray format.
% Inside trainnet, Y and T are dlarray objects with shape [nTargets × batch].
% weights must be a column vector [nTargets × 1] for correct broadcasting.
weights = reshape(weights, [], 1);  % Column vector for [nTargets x batch] broadcasting
diff = Y - T;
loss = mean(diff .^ 2 .* weights, 'all');
end

function lossFcn = localResolveLossFunction(lossName)
lossKey = lower(string(lossName));
switch lossKey
    case "mse"
        lossFcn = 'mse';
    case "mae"
        lossFcn = 'mae';
    case "huber"
        lossFcn = @localHuberLoss;
    otherwise
        error('train_sers_dnn:LossFunction', 'Unsupported loss function: %s', lossName);
end
end

function loss = localHuberLoss(Y, T)
% Huber loss with delta=1 for dlarray [nTargets x batch].
delta = 1;
diff = Y - T;
absDiff = abs(diff);
quadratic = 0.5 * (absDiff .^ 2);
linear = delta * (absDiff - 0.5 * delta);
useLinear = absDiff > delta;
lossValues = quadratic;
lossValues(useLinear) = linear(useLinear);
loss = mean(lossValues, 'all');
end

function lossFcn = localWrapWeightedLoss(baseLoss, weights)
weights = reshape(weights, [], 1);
if ischar(baseLoss) || isstring(baseLoss)
    baseKey = lower(string(baseLoss));
    switch baseKey
        case "mse"
            lossFcn = @(Y, T) localWeightedMse(Y, T, weights);
        case "mae"
            lossFcn = @(Y, T) localWeightedMae(Y, T, weights);
        otherwise
            lossFcn = @(Y, T) localWeightedHuber(Y, T, weights);
    end
else
    lossFcn = @(Y, T) localWeightedHuber(Y, T, weights);
end
end

function loss = localWeightedMae(Y, T, weights)
weights = reshape(weights, [], 1);
diff = abs(Y - T);
loss = mean(diff .* weights, 'all');
end

function loss = localWeightedHuber(Y, T, weights)
weights = reshape(weights, [], 1);
delta = 1;
diff = Y - T;
absDiff = abs(diff);
quadratic = 0.5 * (absDiff .^ 2);
linear = delta * (absDiff - 0.5 * delta);
useLinear = absDiff > delta;
lossValues = quadratic;
lossValues(useLinear) = linear(useLinear);
loss = mean(lossValues .* weights, 'all');
end

function netArchitecture = localEnsureDlnetwork(spec)
if isa(spec, 'dlnetwork')
    netArchitecture = spec;
elseif isa(spec, 'nnet.cnn.LayerGraph') || isa(spec, 'layerGraph')
    graphSpec = localReplaceRegressionLayers(spec);
    netArchitecture = dlnetwork(graphSpec);
elseif isa(spec, 'nnet.cnn.layer.Layer') || isa(spec, 'nnet.cnn.Layer')
    try
        graphSpec = localReplaceRegressionLayers(layerGraph(spec));
        netArchitecture = dlnetwork(graphSpec);
    catch ME
        error('train_sers_dnn:Layers', 'Unable to convert layer array to dlnetwork: %s', ME.message);
    end
elseif iscell(spec)
    error('train_sers_dnn:Layers', 'Cell array layers are not supported; provide a dlnetwork or layer array.');
elseif isstruct(spec) && isfield(spec, 'Type')
    error('train_sers_dnn:Layers', 'Structure-based layer definitions are not supported with trainnet.');
else
    error('train_sers_dnn:Layers', 'Unsupported network container type: %s', class(spec));
end

if ~netArchitecture.Initialized
    try
        netArchitecture = initialize(netArchitecture);
    catch ME
        error('train_sers_dnn:Layers', 'Unable to initialize network: %s', ME.message);
    end
end
end

function graph = localReplaceRegressionLayers(graph)
layers = graph.Layers;
for idx = 1:numel(layers)
    if isa(layers(idx), 'nnet.cnn.layer.RegressionLayer')
        newLayer = localRegressionIdentityLayer(layers(idx).Name);
        graph = replaceLayer(graph, layers(idx).Name, newLayer);
    end
end
end

function layer = localRegressionIdentityLayer(name)
layer = functionLayer(@(X) X, 'Name', name, 'Formattable', true);
end

function Ynorm = normalizeTargets(dataset, split)
if nargin < 2
    split = 'train';
end
switch split
    case 'train'
        Ynorm = dataset.YTrain;
    case 'validation'
        Ynorm = dataset.YValidation;
    case 'test'
        Ynorm = dataset.YTest;
    otherwise
        error('train_sers_dnn:Split', 'Unknown split: %s', split);
end
end

function stop = localTrainingOutputFcn(info, metricsList, stopCheckFcn, isPlotMonitor) %#ok<INUSD>
persistent lastCheckTic
stop = false;

if nargin < 3
    stopCheckFcn = function_handle.empty;
end
if nargin < 4
    isPlotMonitor = false;
end

% Fast stop check on every iteration
if ~isempty(stopCheckFcn)
    try
        if stopCheckFcn()
            stop = true;
            fprintf('[train_surrogate_dnn] Stop signal detected - terminating training.\n');
            return;
        end
    catch
    end
end

% When MATLAB's training progress monitor is enabled, MATLAB handles rendering
% internally. Do NOT call drawnow inside OutputFcn (MathWorks guideline to prevent
% CEF re-entrant crashes). Only yield to GUI when headless or app-panel (plots='none').
if ~isPlotMonitor
    if isempty(lastCheckTic)
        lastCheckTic = tic;
    end
    if toc(lastCheckTic) > 0.1
        lastCheckTic = tic;
        drawnow limitrate;
    end
end
end

function [metricsPerTarget, metricsAggregate] = localComputeTestMetrics(YTrue, YPred, metricsList)
metricsPerTarget = struct();
metricsAggregate = struct();
if isempty(YTrue) || isempty(YPred)
    return;
end
metricsList = unique(lower(string(metricsList)), 'stable');
numTargets = size(YTrue, 2);

for mIdx = 1:numel(metricsList)
    metricName = metricsList(mIdx);
    switch metricName
        case "rmse"
            diffValues = YPred - YTrue;
            values = sqrt(mean(diffValues.^2, 1, 'omitnan'));
        case "mae"
            values = mean(abs(YPred - YTrue), 1, 'omitnan');
        case "mse"
            diffValues = YPred - YTrue;
            values = mean(diffValues.^2, 1, 'omitnan');
        case "rsquared"
            meanTrue = mean(YTrue, 1, 'omitnan');
            ssTot = sum((YTrue - meanTrue).^2, 1, 'omitnan');
            ssRes = sum((YPred - YTrue).^2, 1, 'omitnan');
            values = 1 - ssRes ./ max(ssTot, eps);
            zeroMask = ssTot <= eps;
            values(zeroMask) = NaN;
        case "mape"
            denom = abs(YTrue);
            denom(denom < 1e-4) = NaN;
            values = mean(abs((YPred - YTrue) ./ denom), 1, 'omitnan');
        otherwise
            continue;
    end
    if isempty(values)
        continue;
    end
    values = reshape(values, 1, numTargets);
    metricsPerTarget.(metricName) = values;
    metricsAggregate.(metricName) = mean(values, 'omitnan');
end
end

function localDisplayTestMetrics(targetNames, metricsList, metricsPerTarget, metricsAggregate)
if isempty(metricsPerTarget)
    return;
end

metricsList = unique(lower(string(metricsList)), 'stable');
if isempty(metricsList)
    return;
end

if isstring(targetNames)
    targetNames = cellstr(targetNames);
elseif ~iscell(targetNames)
    targetNames = cellstr(string(targetNames));
end

fprintf('\nTest metrics summary:\n');
for mIdx = 1:numel(metricsList)
    metricName = metricsList(mIdx);
    fieldName = char(metricName);
    if ~isfield(metricsPerTarget, fieldName)
        continue;
    end
    values = metricsPerTarget.(fieldName);
    if isempty(values)
        continue;
    end

    labelBase = localFormatMetricLabel(metricName);
    values = values(:);
    for t = 1:numel(values)
        metricValue = values(t);
        if ~isfinite(metricValue)
            continue;
        end
        if t <= numel(targetNames) && ~isempty(targetNames{t})
            fprintf('  %s (%s): %.6g\n', labelBase, char(targetNames{t}), metricValue);
        else
            fprintf('  %s (Target %d): %.6g\n', labelBase, t, metricValue);
        end
    end

    if isfield(metricsAggregate, fieldName)
        aggValue = metricsAggregate.(fieldName);
        if isfinite(aggValue)
            fprintf('  %s (avg): %.6g\n', labelBase, aggValue);
        end
    end
end
fprintf('\n');
end

function label = localFormatMetricLabel(metricName)
metricKey = lower(string(metricName));
switch metricKey
    case "rmse"
        label = 'RMSE';
    case "mae"
        label = 'MAE';
    case "mse"
        label = 'MSE';
    case "rsquared"
        label = 'R^2';
    case "mape"
        label = 'MAPE (physical)';
    otherwise
        label = upper(char(metricKey));
end
end

function mustBeDatasetStruct(dataset)
% Validation function for dataset struct
if ~isstruct(dataset)
    throwAsCaller(MException('train_sers_dnn:InvalidDataset', ...
        'dataset must be a struct'));
end
requiredFields = {'normalize','denormalize','XTrain','YTrain','XValidation', ...
    'YValidation','XTest','YTest'};
for k = 1:numel(requiredFields)
    if ~isfield(dataset, requiredFields{k})
        throwAsCaller(MException('train_sers_dnn:MissingField', ...
            'Dataset missing required field: %s', requiredFields{k}));
    end
end
end

function [isValid, diagnostics] = validateDataMatrix(data, name, columnNames)
% validateDataMatrix  Check if data matrix contains only finite values
%
% [isValid, diagnostics] = validateDataMatrix(data, name, columnNames)
%   Returns true if all values are finite, otherwise returns diagnostic string.

isValid = true;
diagnostics = '';

if isempty(data)
    return;
end

% Check for NaN
nanMask = isnan(data);
if any(nanMask(:))
    [nanRows, nanCols] = find(nanMask);
    nanCount = numel(nanRows);
    isValid = false;
    diagnostics = sprintf('  %s contains %d NaN values\n', name, nanCount);
    
    % Show first few problematic columns
    uniqueCols = unique(nanCols);
    for i = 1:min(3, numel(uniqueCols))
        col = uniqueCols(i);
        if col <= numel(columnNames)
            colName = columnNames{col};
        else
            colName = sprintf('col_%d', col);
        end
        rowsAffected = sum(nanCols == col);
        diagnostics = sprintf('%s    Column %d (%s): %d NaN values\n', ...
            diagnostics, col, colName, rowsAffected);
    end
    return;
end

% Check for Inf/-Inf
infMask = isinf(data);
if any(infMask(:))
    [infRows, infCols] = find(infMask);
    infCount = numel(infRows);
    isValid = false;
    diagnostics = sprintf('  %s contains %d Inf/-Inf values\n', name, infCount);
    
    % Show first few problematic columns
    uniqueCols = unique(infCols);
    for i = 1:min(3, numel(uniqueCols))
        col = uniqueCols(i);
        if col <= numel(columnNames)
            colName = columnNames{col};
        else
            colName = sprintf('col_%d', col);
        end
        rowsAffected = sum(infCols == col);
        colData = data(infMask(:, col), col);
        infNeg = sum(colData < 0);
        infPos = sum(colData > 0);
        diagnostics = sprintf('%s    Column %d (%s): %d Inf (%d positive, %d negative)\n', ...
            diagnostics, col, colName, rowsAffected, infPos, infNeg);
    end
    return;
end
end

function [YPredNorm, YPredRaw, metricsPerTarget, metricsAggregate, lossPerTarget, rmseLog, rmseRaw] = ...
    evaluateModelSplit(net, XData, YDataNorm, dataset, miniBatchSize, numTargets, metricsList)
% Evaluate model on a data split and return predictions and metrics
%
% This helper consolidates the redundant evaluation code for validation and test splits.

% Handle empty data
if isempty(XData)
    YPredNorm = zeros(0, numTargets);
    YPredRaw = zeros(0, numTargets);
    metricsPerTarget = struct();
    metricsAggregate = struct();
    lossPerTarget = NaN(0, 1);
    rmseLog = NaN(0, 1);
    rmseRaw = NaN(0, 1);
    return;
end

% Input features are already normalized (log-transformed) from train_sers_dnn setup
% No need to normalize again - XData is already XDataNorm
XDataNorm = XData;

% Predict with simple predict function (not minibatchpredict)
% minibatchpredict requires a datastore, not a matrix
YPredNorm = predict(net, XDataNorm);

% Denormalize predictions and ground truth
YPredRaw = dataset.denormalize(YPredNorm);
YDataRaw = dataset.denormalize(YDataNorm);

% Compute log-space metrics (normalized)
errLog = YPredNorm - YDataNorm;
lossPerTarget = mean(errLog.^2, 1, 'omitnan');
if isempty(lossPerTarget)
    lossPerTarget = NaN(1, numTargets);
end
lossPerTarget = lossPerTarget(:);
rmseLog = sqrt(lossPerTarget);

% Compute raw-space metrics (denormalized)
errRaw = YPredRaw - YDataRaw;
rmseRaw = sqrt(mean(errRaw.^2, 1, 'omitnan'));
if isempty(rmseRaw)
    rmseRaw = NaN(1, numTargets);
end
rmseRaw = rmseRaw(:);

% Compute additional metrics (MAE, R², etc.)
[metricsPerTarget, metricsAggregate] = localComputeTestMetrics(YDataRaw, YPredRaw, metricsList);
end
