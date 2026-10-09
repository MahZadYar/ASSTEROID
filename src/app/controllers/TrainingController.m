classdef TrainingController < handle
% TRAININGCONTROLLER Controller for Stage 3 DNN Surrogate Model Training.
%
%   Coordinates training parameter collection, dataset preparation,
%   surrogate network training execution, training diagnostic plots,
%   and model persistence back into the AssteroidSession state store.
%
%   See also: AssteroidSession, DatabaseController, OptimizeController, runTrainingWorkflow

    properties (SetAccess = private)
        session (1,1) AssteroidSession
        fig           = []
        htmlComponent = []
        visPanel      = []
    end

    methods
        function obj = TrainingController(session, fig, htmlComponent, visPanel)
        % TRAININGCONTROLLER Construct controller attached to session and UI.
            arguments
                session     (1,1) AssteroidSession
                fig               = []
                htmlComponent     = []
                visPanel          = []
            end
            obj.session = session;
            obj.fig = fig;
            obj.htmlComponent = htmlComponent;
            obj.visPanel = visPanel;
        end

        function handleEvent(obj, eventName, eventData)
        % HANDLEEVENT Dispatch event received from training_tab.html.
            if nargin < 3, eventData = struct(); end

            src = obj.htmlComponent;
            fig_ = obj.fig;

            try
                switch eventName
                    case "RunTraining"
                        obj.runTrainingPipeline(eventData);
                    case {"StopTraining", "StopProcess"}
                        obj.stopTraining();
                    case "RefreshDbState"
                        if ~isempty(fig_) && isvalid(fig_) && isfield(fig_.UserData, "app") ...
                                && isfield(fig_.UserData.app, "broadcastDbStatus")
                            fig_.UserData.app.broadcastDbStatus();
                        end
                    case "SaveDatabaseRequest"
                        if ~isempty(fig_) && isvalid(fig_)
                            if isfield(fig_.UserData, "app") && isfield(fig_.UserData.app, "saveDbFile")
                                fig_.UserData.app.saveDbFile();
                            else
                                obj.session.saveDatabase();
                            end
                            if isfield(fig_.UserData, "app") && isfield(fig_.UserData.app, "broadcastDbStatus")
                                fig_.UserData.app.broadcastDbStatus();
                            end
                        else
                            obj.session.saveDatabase();
                        end
                        obj.sendToHTML("SaveComplete", "Database saved.");
                    case "BrowseCheckpointFile"
                        obj.browseCheckpointFile(eventData);
                    case "BrowseCheckpointDir"
                        obj.browseCheckpointDir(eventData);
                    case "FindLatestCheckpoint"
                        workDir = obj.session.workDir;
                        res = obj.findLatestCheckpointFile(workDir);
                        obj.sendToHTML("LatestCheckpointFound", res);
                    case "EvaluateModelPerformance"
                        obj.evaluateModelPerformance(eventData);
                    otherwise
                        fprintf("[TrainingController] Unknown event: %s\n", eventName);
                end
            catch ME
                if obj.isStopRequested() || strcmp(ME.identifier, "Process:Terminated")
                    obj.notifyStopped("Training terminated by user.");
                else
                    fprintf("[TrainingController] Error: %s\n%s\n", ME.message, getReport(ME));
                    obj.sendToHTML("TrainError", ME.message);
                end
            end
        end

        function runTrainingPipeline(obj, d)
        % RUNTRAININGPIPELINE Execute DNN training workflow.
            if obj.isProcessRunning()
                obj.sendToHTML("TrainError", ...
                    "A process is already running. Please wait for it to finish or click Stop.");
                return;
            end

            progressDisplayMode = lower(obj.safeStr(d, "progressDisplayMode", "app-panel"));
            useAppProgressPanel = strcmpi(progressDisplayMode, "app-panel");

            if useAppProgressPanel
                rep = obj.makeReporter();
                obj.sendToHTML("Progress", struct( ...
                    "message", "Progress display: App Right Panel (MATLAB monitor disabled)", ...
                    "fraction", 0));
            else
                rep = ProgressReporter.console();
                rep.StopCheckFcn = @() obj.isStopRequested();
                obj.sendToHTML("Progress", struct( ...
                    "message", "Progress display: MATLAB Default Monitor", ...
                    "fraction", 0));
            end

            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            workDir = obj.session.workDir;

            % Resolve raw simulation files from session database
            rawFiles = obj.resolveSimDataFiles();
            if isempty(rawFiles)
                obj.sendToHTML("TrainError", ...
                    "No simulation data loaded. Load data in the Database tab.");
                return;
            end

            metricsList = ["Absorptance", "EF_vol", "EF_surf"];
            if isfield(d, "metricsToTrain") && ~isempty(d.metricsToTrain)
                metricsList = string(d.metricsToTrain);
            end

            networkConfig = struct( ...
                "useMultiHead", obj.safeBool(d, "useMultiHead", true), ...
                "fc1a", obj.safeNum(d, "fc1a", 128), ...
                "fc1b", obj.safeNum(d, "fc1b", 256), ...
                "proj1", obj.safeNum(d, "proj1", 256), ...
                "fc2a", obj.safeNum(d, "fc2a", 512), ...
                "fc2b", obj.safeNum(d, "fc2b", 256), ...
                "headHiddenSizes", parseNumberList(obj.safeStr(d, "headHiddenSizes", "128"), 128));

            targetLossWeights = parseNumberList(obj.safeStr(d, "targetLossWeights", ""), []);
            extraTrainingOptions = parseNameValuePairs(obj.safeStr(d, "extraTrainingOptions", ""));

            riFile = obj.resolveRiFile();

            continueTraining = obj.safeBool(d, "continueTraining", false);
            pretrainedSource = obj.safeStr(d, "pretrainedSource", "db");
            customPretrainedFile = strtrim(obj.safeStr(d, "customPretrainedFile", ""));

            if continueTraining
                if (pretrainedSource == "file" || customPretrainedFile ~= "") && isfile(customPretrainedFile)
                    preTrainedModelFile = string(customPretrainedFile);
                else
                    preTrainedModelFile = obj.resolvePretrainedModel();
                end
                if preTrainedModelFile == "" || ~isfile(preTrainedModelFile)
                    obj.sendToHTML("TrainError", ...
                        "Continue Training is enabled, but no valid pretrained model or checkpoint file was found. Please browse for a valid .mat file or uncheck 'Continue Training'.");
                    return;
                end
            else
                preTrainedModelFile = "";
            end

            defaultModelFile = fullfile(tempdir, "sers_dnn_model.mat");
            if obj.safeBool(d, "saveArtifacts", true) && ~isempty(rawFiles)
                [~, baseName, ~] = fileparts(rawFiles(1));
                defaultModelFile = fullfile(workDir, baseName + "_model.mat");
            end

            plotsMode = obj.safeStr(d, "plots", "none");
            if useAppProgressPanel, plotsMode = "none"; end

            featureSchema = obj.safeStr(d, "featureSchema", "v2_physics");
            splitMode     = obj.safeStr(d, "splitMode", "geometry");
            incVertGap    = obj.safeBool(d, "includeVerticalGap", false);
            gapHeightUm   = obj.safeNum(d, "gapHeightUm", 0.005);

            cfg = trainingConfig( ...
                WorkDir             = workDir, ...
                RawDataFiles        = rawFiles(:)', ...
                RICsvFile           = riFile, ...
                OutputModelFile     = defaultModelFile, ...
                PreTrainedModelFile = preTrainedModelFile, ...
                ContinueTraining    = continueTraining, ...
                RatioLimit          = [obj.safeNum(d,"ratioLimitMin",0), obj.safeNum(d,"ratioLimitMax",0.49)], ...
                MetricsToTrain      = metricsList, ...
                MaxEpochs           = obj.safeNum(d, "maxEpochs", 200), ...
                MiniBatchSize       = obj.safeNum(d, "miniBatchSize", 1024), ...
                LearningRate        = obj.safeNum(d, "learningRate", 1e-4), ...
                Verbose             = obj.safeBool(d, "verbose", true), ...
                Holdout             = obj.safeNum(d, "holdout", 0.2), ...
                ValSplit            = obj.safeNum(d, "valSplit", 0.5), ...
                FeatureSchema       = featureSchema, ...
                SplitMode           = splitMode, ...
                IncludeVerticalGap  = incVertGap, ...
                GapHeightUm         = gapHeightUm, ...
                SaveArtifacts       = obj.safeBool(d, "saveArtifacts", true), ...
                FeatureLogTransform = obj.safeBool(d, "featureLogTransform", true), ...
                IncludeRatios       = obj.safeBool(d, "includeRatios", featureSchema == "v1_legacy"), ...
                TargetLogTransform  = obj.safeBool(d, "targetLogTransform", true), ...
                Optimizer           = obj.safeStr(d, "optimizer", "adam"), ...
                LossFunction        = obj.safeStr(d, "lossFunction", "mse"), ...
                LearnRateSchedule   = obj.safeStr(d, "learnRateSchedule", "piecewise"), ...
                LearnRateDropFactor = obj.safeNum(d, "learnRateDropFactor", 0.85), ...
                LearnRateDropPeriod = obj.safeNum(d, "learnRateDropPeriod", 5), ...
                GradientThreshold   = obj.safeNum(d, "gradientThreshold", inf), ...
                GradientThresholdMethod = obj.safeStr(d, "gradientThresholdMethod", "l2norm"), ...
                L2Regularization    = obj.safeNum(d, "l2Regularization", 0.0001), ...
                Momentum                = obj.safeNum(d, "momentum", 0.9), ...
                GradientDecayFactor      = obj.safeNum(d, "gradientDecayFactor", 0.9), ...
                SquaredGradientDecayFactor = obj.safeNum(d, "squaredGradientDecayFactor", 0.999), ...
                Epsilon                 = obj.safeNum(d, "epsilon", 1e-8), ...
                Shuffle                 = obj.safeStr(d, "shuffle", "every-epoch"), ...
                ValidationFrequency     = obj.safeNum(d, "validationFrequency", NaN), ...
                ValidationPatience      = obj.safeNum(d, "validationPatience", NaN), ...
                VerboseFrequency        = obj.safeNum(d, "verboseFrequency", NaN), ...
                Plots                   = plotsMode, ...
                ObjectiveMetricName     = obj.safeStr(d, "objectiveMetricName", "loss"), ...
                OutputNetwork           = obj.safeStr(d, "outputNetwork", "auto"), ...
                ExecutionEnvironment    = obj.safeStr(d, "executionEnvironment", "auto"), ...
                PreprocessingEnvironment = obj.safeStr(d, "preprocessingEnvironment", "serial"), ...
                Acceleration            = obj.safeStr(d, "acceleration", "auto"), ...
                CheckpointPath          = obj.safeStr(d, "checkpointPath", ""), ...
                CheckpointFrequency     = obj.safeNum(d, "checkpointFrequency", NaN), ...
                CheckpointFrequencyUnit = obj.safeStr(d, "checkpointFrequencyUnit", "epoch"), ...
                ResetInputNormalization = obj.safeBool(d, "resetInputNormalization", true), ...
                BatchNormalizationStatistics = obj.safeStr(d, "batchNormalizationStatistics", "auto"), ...
                SequenceLength          = obj.safeStr(d, "sequenceLength", "longest"), ...
                SequencePaddingDirection = obj.safeStr(d, "sequencePaddingDirection", "right"), ...
                SequencePaddingValue    = obj.safeNum(d, "sequencePaddingValue", 0), ...
                InputDataFormats        = obj.safeStr(d, "inputDataFormats", "auto"), ...
                TargetDataFormats       = obj.safeStr(d, "targetDataFormats", "auto"), ...
                CategoricalInputEncoding = obj.safeStr(d, "categoricalInputEncoding", "integer"), ...
                CategoricalTargetEncoding = obj.safeStr(d, "categoricalTargetEncoding", "auto"), ...
                ExtraTrainingOptions    = extraTrainingOptions, ...
                NetworkConfig       = networkConfig, ...
                TargetLossWeights   = targetLossWeights);

            cfg.stopTrainingFcn = @() obj.isStopRequested();

            results = runTrainingWorkflow(cfg, rep);

            % Render diagnostic plots
            vp = obj.visPanel;
            if ~isempty(vp) && isvalid(vp)
                try
                    delete(allchild(vp));
                    visualizeTrainingResults(results, Parent=vp);
                catch ME_vis
                    fprintf("[TrainingController] Visualization error: %s\n", ME_vis.message);
                end
            end

            % Update session state
            if isfield(results, "db") && isstruct(results.db)
                obj.session.db = results.db;
            end
            if isfield(results, "model") && isstruct(results.model)
                obj.session.model = results.model;
                obj.session.modelLoaded = true;

                if ~isfield(obj.session.db, "Model") || ~isstruct(obj.session.db.Model)
                    obj.session.db.Model = struct();
                end
                obj.session.db.Model.Model = results.model;
                if isfield(results.model, "net")
                    obj.session.db.Model.Net = results.model.net;
                end
                if isfield(results.model, "targetNames")
                    obj.session.db.Model.TargetNames = cellstr(results.model.targetNames);
                end
                if isfield(cfg, "outputModelFile") && isfile(string(cfg.outputModelFile))
                    obj.session.db.Model.NetFile = string(cfg.outputModelFile);
                end
            end

            obj.session.markDirty();

            % Dispatch three-tier performance report to UI if available
            if isfield(results, "performanceReport") && isstruct(results.performanceReport) ...
                    && ~isempty(fieldnames(results.performanceReport))
                obj.sendPerformanceReport(results.performanceReport);
            elseif isfield(obj.session.db, "Model") && isfield(obj.session.db.Model, "PerformanceReport") ...
                    && isstruct(obj.session.db.Model.PerformanceReport)
                obj.sendPerformanceReport(obj.session.db.Model.PerformanceReport);
            end

            % Sync legacy figure state for backward compatibility
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.db = obj.session.db;
                obj.fig.UserData.dbDirty = true;
                if isfield(obj.fig.UserData, "visExport")
                    ve = obj.fig.UserData.visExport;
                    ve.model = obj.session.model;
                    ve.modelLoaded = true;
                    obj.fig.UserData.visExport = ve;
                end
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                    obj.fig.UserData.app.markDbDirty();
                else
                    obj.fig.UserData.dbDirty = true;
                end
            end

            if obj.isStopRequested()
                obj.notifyStopped(sprintf("Training stopped by user and finalized in %.1f s", results.elapsedTotal));
            else
                obj.sendToHTML("TrainComplete", sprintf("Training complete in %.1f s", results.elapsedTotal));
            end
        end

        function browseCheckpointFile(obj, d)
        % BROWSECHECKPOINTFILE Browse for a checkpoint .mat file.
            startDir = obj.session.workDir;
            if isfolder("C:/tmp/DNNCheckPoints")
                startDir = "C:/tmp/DNNCheckPoints";
            end
            if isfield(d, "path") && strlength(string(d.path)) > 0
                selectedPath = string(d.path);
                [~, f, ext] = fileparts(selectedPath);
                obj.sendToHTML("CheckpointFileSelected", struct( ...
                    "filePath", selectedPath, "fileName", string(f + ext)));
                return;
            end
            [cpFile, cpPath] = uigetfile({'*.mat', 'Model & Checkpoint Files (*.mat)'; '*.*', 'All Files (*.*)'}, ...
                'Select Pretrained Model or Checkpoint File', startDir);
            if ischar(cpFile) || isstring(cpFile)
                selectedPath = fullfile(cpPath, cpFile);
                obj.sendToHTML("CheckpointFileSelected", struct( ...
                    "filePath", string(selectedPath), "fileName", string(cpFile)));
            end
        end

        function browseCheckpointDir(obj, d)
        % BROWSECHECKPOINTDIR Browse for a checkpoint save directory.
            if isfield(d, "path") && strlength(string(d.path)) > 0
                obj.sendToHTML("CheckpointDirSelected", struct("dirPath", string(d.path)));
                return;
            end
            cpDir = uigetdir(obj.session.workDir, 'Select Checkpoint Save Directory');
            if ischar(cpDir) || isstring(cpDir)
                obj.sendToHTML("CheckpointDirSelected", struct("dirPath", string(cpDir)));
            end
        end

        function res = findLatestCheckpointFile(~, workDir)
        % FINDLATESTCHECKPOINTFILE Locate newest checkpoint file in candidate folders.
            candidateDirs = [
                string(workDir), ...
                "C:/tmp/DNNCheckPoints", ...
                fullfile(workDir, "DNNCheckpoints"), ...
                "C:/tmp/DNNCheckPoints_archive"
            ];
            allFiles = [];
            for k = 1:numel(candidateDirs)
                dPath = candidateDirs(k);
                if isfolder(dPath)
                    files = dir(fullfile(dPath, "**", "*.mat"));
                    if ~isempty(files)
                        if isempty(allFiles), allFiles = files;
                        else, allFiles = [allFiles; files]; %#ok<AGROW>
                        end
                    end
                end
            end

            res = struct("found", false, "filePath", "", "fileName", "", "dateStr", "", "infoStr", "");
            if isempty(allFiles), return; end

            [~, sortIdx] = sort([allFiles.datenum], "descend");
            allFiles = allFiles(sortIdx);

            for k = 1:numel(allFiles)
                fPath = fullfile(allFiles(k).folder, allFiles(k).name);
                try
                    vars = whos('-file', fPath);
                    varNames = {vars.name};
                    if any(ismember(varNames, {'net', 'Net', 'model', 'Model'}))
                        res.found = true;
                        res.filePath = string(fPath);
                        res.fileName = string(allFiles(k).name);
                        res.dateStr = string(allFiles(k).date);
                        if ismember('info', varNames)
                            S = load(fPath, 'info');
                            if isfield(S, 'info') && isstruct(S.info)
                                if isfield(S.info, 'Epoch') && isfield(S.info, 'Iteration')
                                    res.infoStr = sprintf("Epoch %d, Iteration %d", S.info.Epoch, S.info.Iteration);
                                elseif isfield(S.info, 'Epoch')
                                    res.infoStr = sprintf("Epoch %d", S.info.Epoch);
                                end
                            end
                        end
                        return;
                    end
                catch
                    continue;
                end
            end
        end
    end

    %% Internal Helpers
    methods (Access = private)
        function db = getDb(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig) && isstruct(obj.fig.UserData) ...
                    && isfield(obj.fig.UserData, "db") && isstruct(obj.fig.UserData.db)
                db = obj.fig.UserData.db;
            else
                db = obj.session.db;
            end
        end

        function rawFiles = resolveSimDataFiles(obj)
            rawFiles = resolveSimDataFile(obj.getDb());
            if isempty(rawFiles) && ~isempty(obj.fig) && isvalid(obj.fig)
                rawFiles = resolveSimDataFile(obj.fig);
            end
        end

        function riFile = resolveRiFile(obj)
            riFile = resolveRiFile(obj.getDb());
            if riFile == "" && ~isempty(obj.fig) && isvalid(obj.fig)
                riFile = resolveRiFile(obj.fig);
            end
        end

        function modelFile = resolvePretrainedModel(obj)
            modelFile = resolvePretrainedModel(obj.getDb());
            if modelFile == "" && ~isempty(obj.fig) && isvalid(obj.fig)
                modelFile = resolvePretrainedModel(obj.fig);
            end
        end

        function sendToHTML(obj, eventName, payload)
            if ~isempty(obj.htmlComponent) && isvalid(obj.htmlComponent)
                try
                    sendEventToHTMLSource(obj.htmlComponent, eventName, payload);
                catch
                end
            end
        end

        function rep = makeReporter(obj)
            rep = ProgressReporter.fromCallback( ...
                @(type, step, data) obj.sendToHTML("Progress", data));
            rep.StopCheckFcn = @() obj.isStopRequested();
        end

        function setRunning(obj, isRunning)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "setProcessRunning")
                    obj.fig.UserData.app.setProcessRunning(isRunning, "Training");
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.isRunning = logical(isRunning);
                end
                if isfield(obj.fig.UserData, "training")
                    obj.fig.UserData.training.isRunning = isRunning;
                end
            end
            obj.session.setProcessRunning(isRunning, "Training");
        end

        function running = isProcessRunning(obj)
            running = false;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "process") && isfield(obj.fig.UserData.process, "isRunning")
                    running = logical(obj.fig.UserData.process.isRunning);
                end
            end
            if ~running
                running = obj.session.process.isRunning;
            end
        end

        function stopReq = isStopRequested(obj)
            stopReq = false;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "isProcessStopRequested")
                    stopReq = obj.fig.UserData.app.isProcessStopRequested();
                elseif isfield(obj.fig.UserData, "process") && isfield(obj.fig.UserData.process, "stopRequested")
                    stopReq = logical(obj.fig.UserData.process.stopRequested);
                end
                if ~stopReq && isfield(obj.fig.UserData, "training") && isfield(obj.fig.UserData.training, "stopRequested")
                    stopReq = logical(obj.fig.UserData.training.stopRequested);
                end
            end
            if ~stopReq
                stopReq = obj.session.isStopRequested();
            end
        end

        function stopTraining(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "requestProcessStop")
                    obj.fig.UserData.app.requestProcessStop();
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.stopRequested = true;
                end
                if isfield(obj.fig.UserData, "training")
                    obj.fig.UserData.training.stopRequested = true;
                end
            end
            obj.session.requestStop();
        end

        function notifyStopped(obj, msg)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "notifyProcessStopped")
                    obj.fig.UserData.app.notifyProcessStopped("Training", msg);
                else
                    obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
                end
            else
                obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
            end
        end

        function v = safeNum(~, s, f, d)
            v = d;
            if isfield(s, f) && ~isempty(s.(f))
                val = double(s.(f));
                if isfinite(val), v = val; end
            end
        end

        function v = safeStr(~, s, f, d)
            v = string(d);
            if isfield(s, f) && ~isempty(s.(f))
                v = string(s.(f));
            end
        end

        function v = safeBool(~, s, f, d)
            v = logical(d);
            if isfield(s, f) && ~isempty(s.(f))
                v = logical(s.(f));
            end
        end

        function sendPerformanceReport(obj, perfReport)
        % SENDPERFORMANCEREPORT Format and push three-tier metrics to HTML.
            if isempty(perfReport) || ~isstruct(perfReport) || ~isfield(perfReport, "globalBiased")
                return;
            end

            try
                tblB = perfReport.globalBiased;
                tblU = perfReport.globalUnbiased;
                tblR = [];
                if isfield(perfReport, "roiCombined") && ~isempty(perfReport.roiCombined)
                    tblR = perfReport.roiCombined;
                end

                nTargets = height(tblB);
                targetRows = cell(nTargets, 1);

                for k = 1:nTargets
                    tName = string(tblB.Target{k});
                    rowStruct = struct( ...
                        'name', tName, ...
                        'holdoutNRMSE', round(double(tblB.NRMSE_Pct(k)), 2), ...
                        'holdoutNRMSLE', round(double(tblB.N_RMSLE_Pct(k)), 2), ...
                        'holdoutR2', round(double(tblB.R2(k)), 4), ...
                        'idwNRMSE', round(double(tblU.IDW_NRMSE_Pct(k)), 2), ...
                        'idwR2', round(double(tblU.IDW_R2(k)), 4), ...
                        'roiNRMSE', NaN, ...
                        'roiR2', NaN);

                    if ~isempty(tblR) && ismember("Target", tblR.Properties.VariableNames)
                        rIdx = find(string(tblR.Target) == tName, 1);
                        if ~isempty(rIdx)
                            rowStruct.roiNRMSE = round(double(tblR.RoI_NRMSE_Pct(rIdx)), 2);
                            rowStruct.roiR2 = round(double(tblR.RoI_R2(rIdx)), 4);
                        end
                    end
                    targetRows{k} = rowStruct;
                end

                ts = "";
                if isfield(perfReport, "timestamp"), ts = string(perfReport.timestamp); end
                numTest = 0;
                if isfield(perfReport, "numTestSamples"), numTest = double(perfReport.numTestSamples); end
                numRoi = 0;
                if isfield(perfReport, "numRoiSamples"), numRoi = double(perfReport.numRoiSamples); end
                latex = "";
                if isfield(perfReport, "latexSummary"), latex = string(perfReport.latexSummary); end

                payload = struct( ...
                    'hasReport', true, ...
                    'timestamp', ts, ...
                    'numTestSamples', numTest, ...
                    'numRoiSamples', numRoi, ...
                    'latexSummary', latex, ...
                    'targets', {targetRows});

                obj.sendToHTML("TrainingPerformanceReport", payload);
            catch ME_send
                fprintf("[TrainingController] Error sending performance report: %s\n", ME_send.message);
            end
        end

        function evaluateModelPerformance(obj, ~)
        % EVALUATEMODELPERFORMANCE Evaluate three-tier metrics for currently loaded model.
            if ~obj.session.modelLoaded && (~isfield(obj.session.db, "Model") || isempty(fieldnames(obj.session.db.Model)))
                obj.sendToHTML("TrainError", "No trained model loaded in session or db.Model.");
                return;
            end

            % Check simulation data
            simData = [];
            if isfield(obj.session.db, "Sim") && isstruct(obj.session.db.Sim) && ~isempty(fieldnames(obj.session.db.Sim))
                simData = obj.session.db.Sim;
            end
            if isempty(simData)
                obj.sendToHTML("TrainError", "Simulation data required for evaluation (db.Sim is empty).");
                return;
            end

            model = obj.session.model;
            if isempty(model) && isfield(obj.session.db.Model, "Model")
                model = obj.session.db.Model.Model;
            end

            ri = getDefaultRefractiveIndex(SearchDir=obj.session.workDir, WavelengthUnit="um");
            targetFields = ["Absorptance", "EF_vol", "EF_surf"];
            if isfield(model, "targetNames") && ~isempty(model.targetNames)
                targetFields = string(model.targetNames);
            end

            ds = prepare_training_dataset(simData, ri, TargetFields=targetFields);

            dbOptima = [];
            if isfield(obj.session.db, "Optima") && isstruct(obj.session.db.Optima)
                dbOptima = obj.session.db.Optima;
            end

            perfReport = computeSurrogateEvaluationMetrics(model, ds, dbOptima, Verbose=true);

            % Update session state
            if ~isfield(obj.session.db, "Model") || ~isstruct(obj.session.db.Model)
                obj.session.db.Model = struct();
            end
            obj.session.db.Model.PerformanceReport = perfReport;
            if ~isempty(obj.session.model)
                obj.session.model.performanceReport = perfReport;
            end
            obj.session.markDirty();

            obj.sendPerformanceReport(perfReport);
            obj.sendToHTML("Progress", struct("message", "Generalization metrics evaluated successfully."));
        end
    end
end
