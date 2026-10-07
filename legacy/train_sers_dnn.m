function model = train_sers_dnn(dataset, varargin)
% train_sers_dnn  Train the dense residual network for SERS EF regression.
%
% model = train_sers_dnn(dataset) expects the dataset struct produced by
% prepare_training_dataset. Optional name-value arguments:
%   'MaxEpochs'      (default 150)
%   'MiniBatchSize'  (default 512)
%   'LearningRate'   (default 1e-3)
%   'Layers'         custom network (dlnetwork or layer array)
%   'Verbose'        (default true)
metricsList = lower(["mape"]);
opts = struct('MaxEpochs', 150, 'MiniBatchSize', 512, 'LearningRate', 1e-3, ...
    'Layers', [], 'Verbose', true);
if mod(numel(varargin), 2) ~= 0
    error('train_sers_dnn:Args', 'Name-value pairs expected.');
end
for k = 1:2:numel(varargin)
    name = varargin{k};
    value = varargin{k+1};
    if ~isfield(opts, name)
        error('train_sers_dnn:BadOption', 'Unknown option: %s', name);
    end
    opts.(name) = value;
end

requiredFields = {'normalize','denormalize','XTrain','YTrain','XValidation', ...
    'YValidation','XTest','YTest'};
for k = 1:numel(requiredFields)
    if ~isfield(dataset, requiredFields{k})
        error('train_sers_dnn:Dataset', 'Dataset missing field: %s', requiredFields{k});
    end
end

XTrain = dataset.normalize(dataset.XTrain);
YTrain = normalizeTargets(dataset);
XValidation = dataset.normalize(dataset.XValidation);
YValidation = normalizeTargets(dataset, 'validation');
XTest = dataset.normalize(dataset.XTest);
YTest = normalizeTargets(dataset, 'test');

numFeatures = size(XTrain, 2);
numTargets = size(YTrain, 2);

if isempty(XValidation)
    validationData = [];
else
    validationData = {XValidation, YValidation};
end

if isempty(opts.Layers)
    netCandidate = localBuildDefaultNetwork(numFeatures, numTargets);
else
    netCandidate = opts.Layers;
end
netArchitecture = localEnsureDlnetwork(netCandidate);
optionsArgs = {
    'ExecutionEnvironment', 'auto', ...
    'Metrics', metricsList, ...
    'MaxEpochs', opts.MaxEpochs, ...
    'MiniBatchSize', opts.MiniBatchSize, ...
    'InitialLearnRate', opts.LearningRate, ...
    'LearnRateSchedule', 'cosine', ... % options: 
    'Shuffle', 'every-epoch', ...
    'Verbose', opts.Verbose, ...
    'VerboseFrequency', 200, ...
    'Plots', 'training-progress' ...
    };
if ~isempty(validationData)
    optionsArgs(end+1:end+4) = {'ValidationData', validationData, 'ValidationFrequency', 200};
end

outputFcn = [];
if opts.Verbose
    outputFcn = @(info)localAdaptDefaultTrainingPlot(info, metricsList);
end

if ~isempty(outputFcn)
    optionsArgs(end+1:end+2) = {'OutputFcn', outputFcn};
end

trainingOpts = trainingOptions('adam', optionsArgs{:});
net = trainnet(XTrain, YTrain, netArchitecture, 'mse', trainingOpts);

% Evaluate validation split for diagnostics.
valCount = size(YValidation, 1);
if valCount == 0
    YPredValidation = zeros(0, numTargets);
else
    valMiniBatch = min(max(1, opts.MiniBatchSize), valCount);
    YPredValidation = minibatchpredict(net, XValidation, MiniBatchSize=valMiniBatch);
end
YPredValidationRaw = dataset.denormalize(YPredValidation);
YValidationRaw = dataset.denormalize(YValidation);
valErrLog = YPredValidation - YValidation;
valLossPerTarget = mean(valErrLog.^2, 1, 'omitnan');
if isempty(valLossPerTarget)
    valLossPerTarget = NaN(1, numTargets);
end
valRmseLog = sqrt(valLossPerTarget);
valErrRaw = YPredValidationRaw - YValidationRaw;
valRmseRaw = sqrt(mean(valErrRaw.^2, 1, 'omitnan'));
if isempty(valRmseRaw)
    valRmseRaw = NaN(1, numTargets);
end
[valMetricsPerTarget, valMetricsAggregate] = localComputeTestMetrics(YValidationRaw, YPredValidationRaw, metricsList);
valLossPerTarget = valLossPerTarget(:);
valRmseLog = valRmseLog(:);
valRmseRaw = valRmseRaw(:);
valLossAggregate = mean(valLossPerTarget, 'omitnan');

if isempty(XTest)
    YPredTest = zeros(0, numTargets);
else
    miniBatchPredictSize = min(opts.MiniBatchSize, size(XTest, 1));
    miniBatchPredictSize = max(miniBatchPredictSize, 1);
    YPredTest = minibatchpredict(net, XTest, MiniBatchSize=miniBatchPredictSize);
end
YPredTestRaw = dataset.denormalize(YPredTest);
YTestRaw = dataset.denormalize(YTest);
errRaw = YPredTestRaw - YTestRaw;
[testMetricsPerTarget, testMetricsAggregate] = localComputeTestMetrics(YTestRaw, YPredTestRaw, metricsList);
if isfield(testMetricsPerTarget, 'rmse')
    rmseRaw = testMetricsPerTarget.rmse(:);
else
    rmseRawFallback = sqrt(mean(errRaw.^2, 1, 'omitnan')); %#ok<UDIM>
    rmseRaw = rmseRawFallback(:);
end
if isempty(rmseRaw)
    rmseRaw = NaN(numTargets, 1);
end

errLog = YPredTest - YTest;
rmseLog = sqrt(mean(errLog.^2, 1, 'omitnan'));
rmseLog = rmseLog(:);
testLossPerTarget = mean(errLog.^2, 1, 'omitnan');
if isempty(testLossPerTarget)
    testLossPerTarget = NaN(1, numTargets);
end
testLossPerTarget = testLossPerTarget(:);
testLossAggregate = mean(testLossPerTarget, 'omitnan');

rmseRaw = rmseRaw(:);

if opts.Verbose
    localDisplayTestMetrics(dataset.targetNames, metricsList, testMetricsPerTarget, testMetricsAggregate);
end

model = struct();
model.net = net;
model.scale = dataset.scale;
model.featureNames = dataset.featureNames;
model.targetNames = dataset.targetNames;
testCount = size(YTest, 1);
validationPerf = struct('count', valCount, ...
    'loss', valLossPerTarget, ...
    'lossAggregate', valLossAggregate, ...
    'rmse', valRmseRaw, ...
    'rmseLog', valRmseLog, ...
    'metrics', valMetricsPerTarget, ...
    'metricsAggregate', valMetricsAggregate);
testPerf = struct('count', testCount, ...
    'loss', testLossPerTarget, ...
    'lossAggregate', testLossAggregate, ...
    'rmse', rmseRaw, ...
    'rmseLog', rmseLog, ...
    'metrics', testMetricsPerTarget, ...
    'metricsAggregate', testMetricsAggregate);
performance = struct('rmse', rmseRaw, ...
    'rmseLog', rmseLog, ...
    'testCount', testCount, ...
    'testMetrics', testMetricsPerTarget, ...
    'testMetricsAggregate', testMetricsAggregate, ...
    'testLoss', testLossPerTarget, ...
    'testLossAggregate', testLossAggregate, ...
    'validation', validationPerf, ...
    'test', testPerf, ...
    'metricsList', metricsList);
model.performance = performance;
model.normalize = dataset.normalize;
model.denormalize = dataset.denormalize;
model.transformFeatures = dataset.transformFeatures;
model.inputCenter = dataset.inputCenter;
model.inputScale = dataset.inputScale;
model.targetLogMask = dataset.targetLogMask;
model.featureLogMask = dataset.featureLogMask;
opts.MetricsList = metricsList;
model.options = opts;
end

function netArchitecture = localBuildDefaultNetwork(numFeatures, numTargets)
netArchitecture = dlnetwork;
netArchitecture = addLayers(netArchitecture, featureInputLayer(numFeatures, 'Name', 'input'));

block1 = [
    fullyConnectedLayer(128, 'Name', 'fc1a')
    batchNormalizationLayer('Name', 'bn1a')
    geluLayer('Name', 'gelu1a')
    fullyConnectedLayer(256, 'Name', 'fc1b')
    batchNormalizationLayer('Name', 'bn1b')
    geluLayer('Name', 'gelu1b')];
netArchitecture = addLayers(netArchitecture, block1);
netArchitecture = addLayers(netArchitecture, fullyConnectedLayer(256, 'Name', 'proj1'));
netArchitecture = addLayers(netArchitecture, additionLayer(2, 'Name', 'add1'));

block2 = [
    fullyConnectedLayer(512, 'Name', 'fc2a')
    batchNormalizationLayer('Name', 'bn2a')
    geluLayer('Name', 'gelu2a')
    fullyConnectedLayer(256, 'Name', 'fc2b')
    batchNormalizationLayer('Name', 'bn2b')
    geluLayer('Name', 'gelu2b')];
netArchitecture = addLayers(netArchitecture, block2);
netArchitecture = addLayers(netArchitecture, additionLayer(2, 'Name', 'add2'));

outLayers = [
    fullyConnectedLayer(128, 'Name', 'fcOutHidden')
    geluLayer('Name', 'geluOutHidden')
    fullyConnectedLayer(numTargets, 'Name', 'fcOut')
    localRegressionIdentityLayer('regression')];
netArchitecture = addLayers(netArchitecture, outLayers);

netArchitecture = connectLayers(netArchitecture, 'input', 'fc1a');
netArchitecture = connectLayers(netArchitecture, 'gelu1b', 'add1/in1');
netArchitecture = connectLayers(netArchitecture, 'input', 'proj1');
netArchitecture = connectLayers(netArchitecture, 'proj1', 'add1/in2');

netArchitecture = connectLayers(netArchitecture, 'add1', 'fc2a');
netArchitecture = connectLayers(netArchitecture, 'gelu2b', 'add2/in1');
netArchitecture = connectLayers(netArchitecture, 'add1', 'add2/in2');

netArchitecture = connectLayers(netArchitecture, 'add2', 'fcOutHidden');

if ~netArchitecture.Initialized
    netArchitecture = initialize(netArchitecture);
end
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

function stop = localAdaptDefaultTrainingPlot(info, metricsList)
persistent plotConfigured

if isempty(plotConfigured)
    plotConfigured = false;
end

stop = false;
if nargin < 2
    metricsList = string.empty(1, 0);
else
    metricsList = string(metricsList);
end

switch info.State
    case "start"
        plotConfigured = false;
    case {"iteration", "done"}
        if plotConfigured
            return;
        end
        fig = localResolveTrainingPlotFigure(info);
        if isempty(fig) || ~isvalid(fig)
            return;
        end
        localConfigureTrainingPlotFigure(fig, metricsList);
        plotConfigured = true;
end
end

function fig = localResolveTrainingPlotFigure(info)
fig = [];

try
    if isstruct(info) && isfield(info, 'TrainingPlot')
        plotRef = info.TrainingPlot;
        if ~isempty(plotRef)
            figCandidate = plotRef.Figure;
            if ~isempty(figCandidate) && isvalid(figCandidate)
                fig = figCandidate;
                return;
            end
        end
    end
catch
end

try
    figCandidates = findall(groot, 'Type', 'figure', 'Name', 'Training Progress');
    if isempty(figCandidates)
        figCandidates = findall(groot, 'Type', 'figure', '-regexp', 'Name', 'Training Progress');
    end
catch
    figCandidates = [];
end

if ~isempty(figCandidates)
    fig = figCandidates(1);
end
end

function localConfigureTrainingPlotFigure(fig, metricsList)
if isempty(fig) || ~isvalid(fig)
    return;
end

metricsList = lower(string(metricsList));
logTokens = ["loss", "rmse", "mse"];

try
    axesArray = findall(fig, 'Type', 'axes');
catch
    axesArray = [];
end

for idx = 1:numel(axesArray)
    ax = axesArray(idx);
    if ~isvalid(ax)
        continue;
    end

    titleLower = "";
    try
        titleObj = get(ax, 'Title');
        if ~isempty(titleObj)
            titleText = string(get(titleObj, 'String'));
            titleLower = lower(strjoin(cellstr(titleText), " "));
        end
    catch
        titleLower = "";
    end

    if any(contains(titleLower, logTokens))
        try
            currentYLim = get(ax, 'YLim');
            if numel(currentYLim) == 2 && currentYLim(1) <= 0
                lowerBound = max(realmin('double'), currentYLim(2) * 1e-3);
                if lowerBound < currentYLim(2)
                    currentYLim(1) = lowerBound;
                    set(ax, 'YLim', currentYLim);
                end
            end
            set(ax, 'YScale', 'log');
        catch
        end
    end

    try
        grid(ax, 'on');
    catch
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
    otherwise
        label = upper(char(metricKey));
end
end
