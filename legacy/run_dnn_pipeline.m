% run_dnn_pipeline  End-to-end training workflow for the SERS DNN.
%
% This script:
%   1. Loads prl_sweep.mat (structure-of-arrays allData).
%   2. Loads gold refractive index data from McPeak.csv.
%   3. Prepares the training dataset and trains a DNN, then saves the model.
%
% Dense prediction/visualisation and maxima search have been moved to
% run_prediction_vis.m and run_locate_maxima.m respectively.
%
% Adjust the configuration section to match the desired training
% hyperparameters.

%% Configuration
workDir = pwd;
rawDataFileName = "prl_sweep_cylinder.mat";
riCsv = fullfile(pwd, "McPeak.csv");
outputModelFile =       fullfile(pwd, "sers_dnn_model_cylinder_all.mat");
preTrainedModelFile =   fullfile(pwd, "sers_dnn_model_cylinder_all.mat");
% Training parameters
continueTraining = true; % set true to fine-tune starting from preTrainedModelFile
ratioLimit = [0, 0.49]; % [min, max] r/p ratio for training data filtering
metricsToTrain = {'Absorptance','M_vol','M_surf','EF_vol','EF_surf'}; % list of target metric fields to train on (aliases allowed)
trainOpts.MaxEpochs = 50000;
trainOpts.MiniBatchSize = 1024;
trainOpts.LearningRate = 1e-4;

%% Validate and normalise metrics to train
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
            error('run_dnn_pipeline:UnknownMetric', ...
                'Unsupported metric "%s". Valid options: %s', metricsToTrain{tIdx}, strjoin(availableTargets, ', '));
        end
        metricsCanonical{tIdx} = availableTargets{matchIdx};
    end
end
metricsToTrain = unique(metricsCanonical, 'stable');

if isempty(metricsToTrain)
    warning('run_dnn_pipeline:NoMetrics', 'metricsToTrain was empty. Defaulting to EF_vol.');
    metricsToTrain = {'EF_vol'};
end

%% Load data

disp('Loading structure-of-arrays dataset...');
if ~isfile(rawDataFileName)
    error('run_dnn_pipeline:MissingMat', 'File not found: %s', rawDataFileName);
end
S = load(rawDataFileName, 'allData');
if ~isfield(S, 'allData')
    error('run_dnn_pipeline:MissingAllData', 'Variable allData missing in %s', rawDataFileName);
end
allData = S.allData;

disp('Loading gold refractive index table...');
ri = load_gold_refractive_index(riCsv, 'WavelengthUnit', 'um');

%% Train (optionally continuing from a pretrained network)
fprintf('Preparing training dataset...\n');
dataset = prepare_training_dataset(allData, ri, 'RatioLimit', ratioLimit, ...
    'TargetFields', metricsToTrain);
fprintf('Samples: train=%d, val=%d, test=%d\n', dataset.counts.train, dataset.counts.validation, dataset.counts.test);

initialLayers = [];
if continueTraining %#ok<UNRCH>
    fprintf('Loading pretrained model from %s...\n', preTrainedModelFile);
    if ~isfile(preTrainedModelFile)
        error('run_dnn_pipeline:MissingPretrained', 'Pretrained model not found: %s', preTrainedModelFile);
    end
    loadedPretrained = load(preTrainedModelFile, 'model');
    if ~isfield(loadedPretrained, 'model') || ~isfield(loadedPretrained.model, 'net')
        error('run_dnn_pipeline:InvalidPretrained', ...
            'File %s does not contain a valid pretrained model with field ''net''.', preTrainedModelFile);
    end
    initialLayers = loadedPretrained.model.net;
end

continuationNote = '';
if ~isempty(initialLayers)
    continuationNote = ' (continuation)';
end

fprintf('Training neural network%s...\n', continuationNote);
trainArgs = {
    'MaxEpochs', trainOpts.MaxEpochs, ...
    'MiniBatchSize', trainOpts.MiniBatchSize, ...
    'LearningRate', trainOpts.LearningRate
    };
if ~isempty(initialLayers)
    trainArgs(end+1:end+2) = {'Layers', initialLayers}; %#ok<AGROW>
end
model = train_sers_dnn(dataset, trainArgs{:});
targetNamesCell = cellstr(string(model.targetNames));
valPerf = struct();
if isfield(model.performance, 'validation') && isstruct(model.performance.validation)
    valPerf = model.performance.validation;
end
testPerf = struct();
if isfield(model.performance, 'test') && isstruct(model.performance.test)
    testPerf = model.performance.test;
else
    testPerf.rmse = model.performance.rmse;
    if isfield(model.performance, 'rmseLog')
        testPerf.rmseLog = model.performance.rmseLog;
    end
    if isfield(model.performance, 'testLoss')
        testPerf.loss = model.performance.testLoss;
    end
    if isfield(model.performance, 'testLossAggregate')
        testPerf.lossAggregate = model.performance.testLossAggregate;
    end
end

localPrintSplitMetrics('Validation', valPerf, targetNamesCell);
localPrintSplitMetrics('Test', testPerf, targetNamesCell);

save(outputModelFile, 'model', 'dataset');
fprintf('Saved trained model to %s\n', outputModelFile);

disp('Training workflow complete. Run run_prediction_vis.m for dense predictions or run_locate_maxima.m for maxima analysis.');

try
    localPlotValidationTestPerformance(model);
catch plotErr
    warning('run_dnn_pipeline:PerformancePlot', ...
        'Unable to plot validation/test performance: %s', plotErr.message);
end

function localPrintSplitMetrics(splitName, perf, targetNames)
if ~isstruct(perf) || ~isfield(perf, 'rmse') || isempty(perf.rmse)
    return;
end
names = cellstr(string(targetNames(:)));
fprintf('%s RMSE per target:\n', splitName);
numTargets = numel(names);
for idx = 1:numTargets
    if idx <= numel(perf.rmse)
        rawVal = perf.rmse(idx);
    else
        rawVal = NaN;
    end
    hasLog = isfield(perf, 'rmseLog') && ~isempty(perf.rmseLog) && idx <= numel(perf.rmseLog);
    if hasLog
        logVal = perf.rmseLog(idx);
        fprintf('  %s: %.4g (raw), %.4g (log)\n', names{idx}, rawVal, logVal);
    else
        fprintf('  %s: %.4g\n', names{idx}, rawVal);
    end
end
if isfield(perf, 'lossAggregate') && ~isempty(perf.lossAggregate)
    fprintf('%s loss (mean MSE): %.4g\n', splitName, perf.lossAggregate);
end
end

function localPlotValidationTestPerformance(model)
if ~isstruct(model) || ~isfield(model, 'performance') || ~isfield(model, 'targetNames')
    return;
end
names = cellstr(string(model.targetNames));
if isempty(names)
    return;
end
numTargets = numel(names);
perf = model.performance;

lossData = nan(numTargets, 0);
rmseData = nan(numTargets, 0);
seriesNames = {};

addSplit('validation', 'Validation');
addSplit('test', 'Test');

if isempty(seriesNames)
    return;
end

lossFinite = any(isfinite(lossData), 'all');
rmseFinite = any(isfinite(rmseData), 'all');
if ~lossFinite && ~rmseFinite
    return;
end

fig = figure('Name', 'Validation vs Test Performance');
tiledlayout(fig, 1, 2, 'TileSpacing', 'compact', 'Padding', 'compact');

if lossFinite
    nexttile;
    bar(categorical(names, names), lossData);
    ylabel('MSE (normalized)');
    title('Loss per Target');
    legend(seriesNames, 'Location', 'northwest');
    grid on;
else
    nexttile;
    axis off;
    text(0.5, 0.5, 'No finite loss values', 'HorizontalAlignment', 'center');
end

if rmseFinite
    nexttile;
    bar(categorical(names, names), rmseData);
    ylabel('RMSE (raw units)');
    title('RMSE per Target');
    legend(seriesNames, 'Location', 'northwest');
    grid on;
else
    nexttile;
    axis off;
    text(0.5, 0.5, 'No finite RMSE values', 'HorizontalAlignment', 'center');
end

    function addSplit(fieldName, label)
        splitStruct = localResolveSplitStruct(fieldName);
        if isempty(splitStruct)
            return;
        end
        if isfield(splitStruct, 'count') && splitStruct.count == 0
            return;
        end
        lossData(:, end+1) = padVector(localGetField(splitStruct, 'loss'));
        rmseData(:, end+1) = padVector(localGetField(splitStruct, 'rmse'));
        seriesNames{end+1} = label;
    end

    function values = localGetField(s, fieldName)
        if isstruct(s) && isfield(s, fieldName)
            values = s.(fieldName);
        else
            values = [];
        end
    end

    function splitStruct = localResolveSplitStruct(fieldName)
        splitStruct = [];
        if isfield(perf, fieldName)
            candidate = perf.(fieldName);
            if isstruct(candidate)
                splitStruct = candidate;
            end
        elseif strcmpi(fieldName, 'test')
            candidate = struct();
            if isfield(perf, 'rmse')
                candidate.rmse = perf.rmse;
            end
            if isfield(perf, 'rmseLog')
                candidate.rmseLog = perf.rmseLog;
            end
            if isfield(perf, 'testLoss')
                candidate.loss = perf.testLoss;
            end
            if isfield(perf, 'testLossAggregate')
                candidate.lossAggregate = perf.testLossAggregate;
            end
            if isfield(perf, 'testCount')
                candidate.count = perf.testCount;
            end
            if ~isempty(fieldnames(candidate))
                splitStruct = candidate;
            end
        end
        if isempty(splitStruct)
            return;
        end
        if ~isfield(splitStruct, 'rmse') || isempty(splitStruct.rmse)
            splitStruct = [];
        end
    end

    function col = padVector(vec)
        col = double(vec(:));
        if isempty(col)
            col = NaN(numTargets, 1);
        elseif numel(col) < numTargets
            col(numTargets, 1) = NaN;
        elseif numel(col) > numTargets
            col = col(1:numTargets);
        end
    end
end
