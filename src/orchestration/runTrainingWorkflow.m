function results = runTrainingWorkflow(cfg, reporter)
%runTrainingWorkflow Orchestrate end-to-end DNN training for SERS prediction.
%
%   results = runTrainingWorkflow(cfg) loads SoA data, refractive index,
%   prepares training dataset, trains DNN, and optionally saves artifacts.
%
%   results = runTrainingWorkflow(cfg, reporter) reports progress through a
%   ProgressReporter instance (console, silent, or callback).
%
%   Inputs:
%       cfg      – struct from trainingConfig
%       reporter – (optional) ProgressReporter. Defaults to silent.
%
%   Outputs:
%       results  – struct with fields:
%           .model        – Trained model struct (net, performance, targetNames, ...)
%           .dataset      – Prepared training dataset struct
%           .summary      – Training statistics summary
%           .cfg          – Config snapshot
%           .elapsedTotal – Wall-clock seconds
%
%   Example (CLI):
%       cfg = trainingConfig(WorkDir="D:\data", RawDataFiles="sweep.mat");
%       results = runTrainingWorkflow(cfg, ProgressReporter.console());
%
%   See also: trainingConfig, prepare_training_dataset, train_sers_dnn,
%             validatePipelineConfig, visualizeTrainingResults, ProgressReporter

arguments
    cfg      (1,1) struct
    reporter       = ProgressReporter.silent()
end

    totalTimer = tic;

    %% 0. Working directory
    if cfg.workDir ~= "" && cfg.workDir ~= string(pwd)
        cd(cfg.workDir);
    end
    reporter.info("=== SERS DNN Training Workflow ===");

    %% 1. Validate configuration
    reporter.start("Validate", "Validating pipeline configuration...");
    legacyCfg = buildLegacyConfig(cfg);
    try
        validatePipelineConfig(legacyCfg);
        reporter.complete("Validate", "Configuration valid.");
    catch ME
        reporter.fail("Validate", "Validation failed: " + ME.message);
        rethrow(ME);
    end

    %% 2. Load raw SoA data files
    reporter.start("LoadData", sprintf("Loading %d data file(s)...", numel(cfg.rawDataFiles)));
    allData = loadAndMergeDataFiles(cfg, reporter);
    nTotal = structRowCount(allData);
    reporter.complete("LoadData", sprintf("Combined: %d geometry entries.", nTotal));

    %% 3. Load refractive index
    reporter.start("LoadRI", "Loading gold refractive index...");
    if isfile(cfg.riCsvFile)
        ri = load_gold_refractive_index(cfg.riCsvFile, "WavelengthUnit", "um");
        reporter.complete("LoadRI", sprintf("Loaded RI from file: %d wavelength samples.", numel(ri.lambda)));
    else
        reporter.info("RI file not found — using built-in default McPeak data.");
        ri = getDefaultRefractiveIndex(SearchDir=cfg.workDir, WavelengthUnit="um");
        reporter.complete("LoadRI", sprintf("Using default RI: %d wavelength samples.", numel(ri.lambda)));
    end

    %% 4. Prepare training dataset
    reporter.start("PrepDataset", "Preparing training dataset...");
    dataset = prepare_training_dataset(allData, ri, ...
        RatioLimit   = cfg.ratioLimit, ...
        TargetFields = cfg.metricsToTrain, ...
        Holdout      = cfg.holdout, ...
        ValSplit     = cfg.valSplit, ...
        FeatureLogTransform = cfg.featureLogTransform, ...
        IncludeRatios       = cfg.includeRatios, ...
        TargetLogTransform  = cfg.targetLogTransform, ...
        FeatureSchema       = localCfgField(cfg, "featureSchema", "v2_physics"), ...
        SplitMode           = localCfgField(cfg, "splitMode", "geometry"), ...
        IncludeVerticalGap  = localCfgField(cfg, "includeVerticalGap", false), ...
        GapHeightUm         = localCfgField(cfg, "gapHeightUm", 0.005));
    reporter.complete("PrepDataset", sprintf( ...
        "Train: %d | Val: %d | Test: %d samples.", ...
        dataset.counts.train, dataset.counts.validation, dataset.counts.test));

    %% 5. Optionally load pretrained model
    initialLayers = [];
    if cfg.continueTraining
        reporter.start("LoadPretrained", "Loading pretrained model for fine-tuning...");
        if cfg.preTrainedModelFile ~= "" && isfile(cfg.preTrainedModelFile)
            try
                [initialLayers, preloadMsg] = loadPretrainedNetwork(cfg.preTrainedModelFile);
                if isempty(initialLayers)
                    reporter.warn("LoadPretrained", "Pretrained model missing network; training from scratch.");
                else
                    reporter.complete("LoadPretrained", preloadMsg);
                end
            catch ME
                reporter.warn("LoadPretrained", "Failed to read pretrained model: " + ME.message);
            end
        else
            reporter.warn("LoadPretrained", "Pretrained file not found; training from scratch.");
        end
        % A pretrained network is only reusable when its input layer matches
        % the current feature schema (v1: 5 or 8 inputs, v2: 8 or 9).
        if ~isempty(initialLayers)
            pretrainedInput = NaN;
            try
                if isprop(initialLayers, "Layers")
                    layersList = initialLayers.Layers;
                    inputIdx = find(arrayfun(@(l) isa(l, "nnet.cnn.layer.FeatureInputLayer") || ...
                        contains(class(l), "InputLayer", "IgnoreCase", true), layersList), 1);
                    if ~isempty(inputIdx) && isprop(layersList(inputIdx), "InputSize")
                        pretrainedInput = double(layersList(inputIdx).InputSize);
                    elseif isprop(layersList(1), "InputSize")
                        pretrainedInput = double(layersList(1).InputSize);
                    end
                end
            catch
                pretrainedInput = NaN;
            end
            if isfinite(pretrainedInput) && pretrainedInput ~= dataset.InputSize
                reporter.warn("LoadPretrained", sprintf( ...
                    "Pretrained network expects %d inputs but the %s dataset provides %d; training from scratch.", ...
                    pretrainedInput, string(localCfgField(cfg, "featureSchema", "v2_physics")), dataset.InputSize));
                initialLayers = [];
            end
        end
    end

    %% 6. Auto-generate checkpoint path if frequency specified but path empty
    checkpointPath = cfg.checkpointPath;
    if isfinite(cfg.checkpointFrequency) && cfg.checkpointFrequency > 0
        if checkpointPath == ""
            % Auto-generate checkpoint directory in workDir
            checkpointPath = fullfile(cfg.workDir, "DNNCheckpoints");
            [~, modelBase, ~] = fileparts(cfg.outputModelFile);
            checkpointPath = fullfile(checkpointPath, modelBase);
            reporter.info(sprintf("Auto-generating checkpoint path: %s", checkpointPath));
        end
    end

    %% 7. Train DNN
    reporter.start("Train", sprintf("Training DNN (%d epochs, lr=%.2g)...", cfg.maxEpochs, cfg.learningRate));
    trainArgs = {dataset, ...
        "MaxEpochs",     cfg.maxEpochs, ...
        "MiniBatchSize", cfg.miniBatchSize, ...
        "LearningRate",  cfg.learningRate, ...
        "Verbose",       cfg.verbose, ...
        "NetworkConfig", cfg.networkConfig, ...
        "TargetLossWeights", cfg.targetLossWeights, ...
        "Optimizer",     cfg.optimizer, ...
        "LossFunction",  cfg.lossFunction, ...
        "LearnRateSchedule", cfg.learnRateSchedule, ...
        "LearnRateDropFactor", cfg.learnRateDropFactor, ...
        "LearnRateDropPeriod", cfg.learnRateDropPeriod, ...
        "GradientThreshold", cfg.gradientThreshold, ...
        "GradientThresholdMethod", cfg.gradientThresholdMethod, ...
        "L2Regularization", cfg.l2Regularization, ...
        "Momentum", cfg.momentum, ...
        "GradientDecayFactor", cfg.gradientDecayFactor, ...
        "SquaredGradientDecayFactor", cfg.squaredGradientDecayFactor, ...
        "Epsilon", cfg.epsilon, ...
        "Shuffle", cfg.shuffle, ...
        "ValidationFrequency", cfg.validationFrequency, ...
        "ValidationPatience", cfg.validationPatience, ...
        "VerboseFrequency", cfg.verboseFrequency, ...
        "Plots", cfg.plots, ...
        "ObjectiveMetricName", cfg.objectiveMetricName, ...
        "OutputNetwork", cfg.outputNetwork, ...
        "ExecutionEnvironment", cfg.executionEnvironment, ...
        "PreprocessingEnvironment", cfg.preprocessingEnvironment, ...
        "Acceleration", cfg.acceleration, ...
        "CheckpointPath", checkpointPath, ...
        "CheckpointFrequency", cfg.checkpointFrequency, ...
        "CheckpointFrequencyUnit", cfg.checkpointFrequencyUnit, ...
        "ResetInputNormalization", cfg.resetInputNormalization, ...
        "BatchNormalizationStatistics", cfg.batchNormalizationStatistics, ...
        "SequenceLength", cfg.sequenceLength, ...
        "SequencePaddingDirection", cfg.sequencePaddingDirection, ...
        "SequencePaddingValue", cfg.sequencePaddingValue, ...
        "InputDataFormats", cfg.inputDataFormats, ...
        "TargetDataFormats", cfg.targetDataFormats, ...
        "CategoricalInputEncoding", cfg.categoricalInputEncoding, ...
        "CategoricalTargetEncoding", cfg.categoricalTargetEncoding, ...
        "ExtraTrainingOptions", cfg.extraTrainingOptions};
    if ~isempty(initialLayers)
        trainArgs = [trainArgs, {"Layers", initialLayers}];
    end
    if isfield(cfg, "stopTrainingFcn") && ~isempty(cfg.stopTrainingFcn)
        trainArgs = [trainArgs, {"StopTrainingFcn", cfg.stopTrainingFcn}];
    elseif isobject(reporter) && ismethod(reporter, "isStopRequested")
        trainArgs = [trainArgs, {"StopTrainingFcn", @() reporter.isStopRequested()}];
    end
    model = train_surrogate_dnn(trainArgs{:});
    if isobject(reporter) && ismethod(reporter, "isStopRequested") && reporter.isStopRequested()
        reporter.info("Training terminated by user.");
    else
        reporter.complete("Train", "Training complete.");
    end

    %% 8. Build summary
    summary = buildTrainingSummary(model, dataset, cfg);
    reporter.info(sprintf("RMSE (test): %s", formatRMSE(model)));

    %% 9. Save artifacts
    if cfg.saveArtifacts
        reporter.start("Save", "Saving model and dataset...");
        w = whos("model");
        if w.bytes > 2e9
            save(cfg.outputModelFile, "model", "dataset", "-v7.3");
        else
            save(cfg.outputModelFile, "model", "dataset");
        end
        reporter.complete("Save", sprintf("Saved to: %s", cfg.outputModelFile));
    else
        reporter.info("SaveArtifacts=false — model not written to disk.");
    end

    %% 10. Pack model metadata into unified database
    if isfield(cfg, 'databaseFile') && strlength(cfg.databaseFile) > 0
        reporter.start("PackDB", "Packing model metadata into database...");
        dbFile = cfg.databaseFile;
        if isfile(dbFile)
            db = load(dbFile, "db").db;
        else
            db = createDatabaseStruct();
        end

        db.Model.Source       = "Training.DNN";
        db.Model.TrainingDate = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
        db.Model.TrainDataRef = "Sim";
        db.Model.NetFile      = string(cfg.outputModelFile);
        db.Model.TargetNames  = string(model.targetNames);

        % Store the dlnetwork object directly (MATLAB .mat v7.3 supports this)
        if isfield(model, 'net') && isa(model.net, 'dlnetwork')
            db.Model.Net = model.net;
            db.Model.InputSize = model.net.Layers(1).InputSize;
        end

        % Hyperparameters
        db.Model.Hyperparams = struct( ...
            'MaxEpochs', cfg.maxEpochs, ...
            'MiniBatchSize', cfg.miniBatchSize, ...
            'LearningRate', cfg.learningRate, ...
            'Optimizer', cfg.optimizer, ...
            'LossFunction', cfg.lossFunction, ...
            'L2Regularization', cfg.l2Regularization, ...
            'LearnRateSchedule', cfg.learnRateSchedule, ...
            'LearnRateDropFactor', cfg.learnRateDropFactor, ...
            'LearnRateDropPeriod', cfg.learnRateDropPeriod);

        % Preprocessing flags (taken from the model: v2 forces IncludeRatios=false)
        db.Model.Preprocessing = struct( ...
            'FeatureLogTransform', logical(model.FeatureLogTransform), ...
            'IncludeRatios', logical(model.IncludeRatios), ...
            'TargetLogTransform', logical(model.TargetLogTransform), ...
            'InputPreprocessing', string(model.inputPreprocessing));

        % v2 physics schema: feature and target statistics (required to rebuild
        % normalize/denormalize when the model is restored from the database).
        if isfield(model, 'featureSchema') && isfield(model, 'targetTransform')
            db.Model.FeatureSchema   = model.featureSchema;
            db.Model.TargetTransform = model.targetTransform;
        elseif isfield(db.Model, 'FeatureSchema')
            db.Model = rmfield(db.Model, intersect({'FeatureSchema', 'TargetTransform'}, fieldnames(db.Model)));
        end

        % Normalization parameters (HDF5-safe numerics)
        if isfield(model, 'normalize') || isfield(model, 'featureMean')
            scale = struct();
            if isfield(model, 'featureMean')
                scale.featureMean = model.featureMean;
                scale.featureStd  = model.featureStd;
            end
            if isfield(model, 'targetMean')
                scale.targetMean = model.targetMean;
                scale.targetStd  = model.targetStd;
            end
            if isfield(model, 'featureLogMask')
                scale.featureLogMask = model.featureLogMask;
            end
            if isfield(model, 'targetLogMask')
                scale.targetLogMask = model.targetLogMask;
            end
            db.Model.Scale = scale;
        end

        % Performance
        if isfield(model, 'performance')
            perf = model.performance;
            dbPerf = struct();
            if isfield(perf, 'test') && isfield(perf.test, 'rmse')
                dbPerf.rmse = perf.test.rmse;
            elseif isfield(perf, 'rmse')
                dbPerf.rmse = perf.rmse;
            end
            if isfield(perf, 'test') && isfield(perf.test, 'rmseLog')
                dbPerf.rmseLog = perf.test.rmseLog;
            end
            dbPerf.testCount = summary.testCount;
            db.Model.Performance = dbPerf;
        end

        % Training splits (indices)
        if isfield(dataset, 'trainIdx')
            db.Model.Splits = struct( ...
                'trainIdx', dataset.trainIdx, ...
                'valIdx', dataset.valIdx, ...
                'testIdx', dataset.testIdx);
        end

        save(dbFile, "db", "-v7.3"); %#ok<NASGU>
        reporter.complete("PackDB", sprintf("Saved db.Model to %s", dbFile));
    end

    %% Assemble results
    results = struct();
    results.model        = model;
    results.dataset      = dataset;
    results.summary      = summary;
    results.cfg          = cfg;
    results.elapsedTotal = toc(totalTimer);

    reporter.info(sprintf("Training workflow complete in %.1f s.", results.elapsedTotal));
end

%% ========================================================================
%  LOCAL HELPERS
%  ========================================================================

function value = localCfgField(cfg, name, defaultValue)
    %localCfgField Read an optional cfg field (cfg structs built before the
    %   v2 schema options existed may lack them).
    value = defaultValue;
    if isfield(cfg, name) && ~isempty(cfg.(name))
        value = cfg.(name);
    end
end

function legacyCfg = buildLegacyConfig(cfg)
    %buildLegacyConfig Translate orchestration cfg to legacy struct shape
    %   expected by validatePipelineConfig.
    legacyCfg = struct();
    legacyCfg.workDir          = cfg.workDir;
    legacyCfg.rawDataFiles     = cfg.rawDataFiles;
    legacyCfg.riCsvFile        = cfg.riCsvFile;
    legacyCfg.outputModelFile  = cfg.outputModelFile;
    legacyCfg.ratioLimit       = cfg.ratioLimit;
    legacyCfg.metricsToTrain   = cellstr(cfg.metricsToTrain);
    legacyCfg.training.MaxEpochs     = cfg.maxEpochs;
    legacyCfg.training.MiniBatchSize = cfg.miniBatchSize;
    legacyCfg.training.LearningRate  = cfg.learningRate;
    legacyCfg.training.Verbose       = cfg.verbose;
    legacyCfg.dataSplit.Holdout  = cfg.holdout;
    legacyCfg.dataSplit.ValSplit = cfg.valSplit;
end

function allData = loadAndMergeDataFiles(cfg, reporter)
    %loadAndMergeDataFiles Load and concatenate multiple SoA MAT files.
    rawFiles = cellstr(cfg.rawDataFiles(:)');
    allData = struct();
    for fIdx = 1:numel(rawFiles)
        candidate = rawFiles{fIdx};
        if ~isfile(candidate)
            candidate = fullfile(cfg.workDir, candidate);
        end
        if ~isfile(candidate)
            error("runTrainingWorkflow:MissingMat", "File not found: %s", rawFiles{fIdx});
        end
        S = load(candidate, "allData");
        if ~isfield(S, "allData")
            error("runTrainingWorkflow:MissingAllData", "Variable allData missing in %s", candidate);
        end
        fileData = S.allData;
        nRows = structRowCount(fileData);
        if nRows == 0
            reporter.warn("LoadData", sprintf("Empty file: %s — skipping.", candidate));
            continue
        end
        reporter.progress("LoadData", fIdx / numel(rawFiles), ...
            sprintf("Loaded %s (%d entries)", rawFiles{fIdx}, nRows));

        if isempty(fieldnames(allData))
            allData = fileData;
        else
            allData = mergeStructFields(allData, fileData);
        end
    end
    if isempty(fieldnames(allData)) || structRowCount(allData) == 0
        error("runTrainingWorkflow:NoData", "No valid data entries were loaded.");
    end
end

function [net, message] = loadPretrainedNetwork(modelFile)
    %loadPretrainedNetwork Load a pretrained network or checkpoint from supported formats.
    message = "";
    net = [];
    if ~isfile(modelFile)
        message = "File does not exist: " + string(modelFile);
        return;
    end
    S = load(modelFile);

    % Extract checkpoint info if available
    cpInfoStr = "";
    if isfield(S, "info") && isstruct(S.info)
        if isfield(S.info, "Epoch") && isfield(S.info, "Iteration")
            cpInfoStr = sprintf(" (checkpoint epoch %d, iteration %d)", S.info.Epoch, S.info.Iteration);
        elseif isfield(S.info, "Epoch")
            cpInfoStr = sprintf(" (checkpoint epoch %d)", S.info.Epoch);
        end
    end

    if isfield(S, "model") && isfield(S.model, "net")
        net = S.model.net;
        message = "Pretrained network loaded from model.net" + cpInfoStr + ".";
        return
    end
    if isfield(S, "Model") && isfield(S.Model, "Net")
        net = S.Model.Net;
        message = "Pretrained network loaded from Model.Net" + cpInfoStr + ".";
        return
    end
    if isfield(S, "Model") && isfield(S.Model, "net")
        net = S.Model.net;
        message = "Pretrained network loaded from Model.net" + cpInfoStr + ".";
        return
    end
    if isfield(S, "net")
        net = S.net;
        message = "Pretrained network loaded from checkpoint/root net" + cpInfoStr + ".";
        return
    end
    if isfield(S, "Net")
        net = S.Net;
        message = "Pretrained network loaded from checkpoint/root Net" + cpInfoStr + ".";
        return
    end

    % Scan fields for any network object
    flds = fieldnames(S);
    for k = 1:numel(flds)
        val = S.(flds{k});
        if isa(val, "dlnetwork") || isa(val, "nnet.cnn.LayerGraph") || isa(val, "SeriesNetwork") || isa(val, "DAGNetwork")
            net = val;
            message = sprintf("Pretrained network loaded from field '%s'%s.", flds{k}, cpInfoStr);
            return;
        end
    end
end

function merged = mergeStructFields(A, B)
    %mergeStructFields Concatenate SoA structs with trailing-dimension padding.
    flds = fieldnames(B);
    for k = 1:numel(flds)
        fn = flds{k};
        if ~isfield(A, fn)
            A.(fn) = B.(fn);
            continue
        end
        valA = A.(fn);
        valB = B.(fn);
        if (isnumeric(valA) || islogical(valA)) && (isnumeric(valB) || islogical(valB))
            szA = size(valA);
            szB = size(valB);
            trailA = szA(2:end);
            trailB = szB(2:end);
            if ~isequal(trailA, trailB)
                maxTrail = max([trailA; trailB], [], 1);
                valA = padTrailing(valA, maxTrail);
                valB = padTrailing(valB, maxTrail);
            end
            A.(fn) = cat(1, valA, valB);
        elseif iscell(valA) && iscell(valB)
            A.(fn) = cat(1, valA, valB);
        elseif isstring(valA) && isstring(valB)
            A.(fn) = cat(1, valA, valB);
        end
    end
    merged = A;
end

function out = padTrailing(data, targetTrail)
    %padTrailing Pad numeric array along trailing dimensions with NaN.
    szNow = size(data);
    trailNow = szNow(2:end);
    if isequal(trailNow, targetTrail)
        out = data;
        return
    end
    needPad = targetTrail - trailNow;
    if any(needPad < 0)
        error("padTrailing:Shrink", "Cannot shrink dimensions.");
    end
    padSize = [0, needPad];
    out = padarray(data, padSize, NaN, "post");
end

function summary = buildTrainingSummary(model, dataset, cfg)
    %buildTrainingSummary Assemble a summary struct for reporting.
    summary = struct();
    summary.targetNames = cellstr(string(model.targetNames));
    summary.trainCount  = dataset.counts.train;
    summary.valCount    = dataset.counts.validation;
    summary.testCount   = dataset.counts.test;
    summary.maxEpochs   = cfg.maxEpochs;
    summary.learningRate = cfg.learningRate;

    % Collect RMSE per split
    perf = model.performance;
    if isfield(perf, "validation") && isstruct(perf.validation) && isfield(perf.validation, "rmse")
        summary.valRMSE = perf.validation.rmse;
    else
        summary.valRMSE = NaN;
    end
    if isfield(perf, "test") && isstruct(perf.test) && isfield(perf.test, "rmse")
        summary.testRMSE = perf.test.rmse;
    elseif isfield(perf, "rmse")
        summary.testRMSE = perf.rmse;
    else
        summary.testRMSE = NaN;
    end
end

function s = formatRMSE(model)
    %formatRMSE Human-readable RMSE string from model performance.
    names = cellstr(string(model.targetNames));
    perf = model.performance;
    rmseVec = [];
    if isfield(perf, "test") && isstruct(perf.test) && isfield(perf.test, "rmse")
        rmseVec = perf.test.rmse;
    elseif isfield(perf, "rmse")
        rmseVec = perf.rmse;
    end
    if isempty(rmseVec)
        s = "N/A";
        return
    end
    parts = strings(1, min(numel(names), numel(rmseVec)));
    for k = 1:numel(parts)
        parts(k) = sprintf("%s=%.4g", names{k}, rmseVec(k));
    end
    s = strjoin(parts, ", ");
end
