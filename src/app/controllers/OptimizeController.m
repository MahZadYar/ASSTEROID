classdef OptimizeController < handle
% OPTIMIZECONTROLLER Controller for Stage 5 Local Maxima Optimization.
%
%   Coordinates metric preview heatmap generation, candidate seed detection,
%   MultiStart local maxima refinement, seed table editing, optima database
%   persistence, and results exporting between optimization_tab.html and
%   the AssteroidSession state store.
%
%   See also: AssteroidSession, DatabaseController, assteroid_app, runLocalizationWorkflow

    properties (SetAccess = private)
        session (1,1) AssteroidSession
        fig           = []
        htmlComponent = []
        axesHandle    = []
    end

    methods
        function obj = OptimizeController(session, fig, htmlComponent, axesHandle)
        % OPTIMIZECONTROLLER Construct controller attached to session and UI.
            arguments
                session     (1,1) AssteroidSession
                fig               = []
                htmlComponent     = []
                axesHandle        = []
            end
            obj.session = session;
            obj.fig = fig;
            obj.htmlComponent = htmlComponent;
            obj.axesHandle = axesHandle;
        end

        function handleEvent(obj, eventName, eventData)
        % HANDLEEVENT Dispatch event received from optimization_tab.html.
            if nargin < 3, eventData = struct(); end

            try
                switch eventName
                    case "RunOptimize"
                        obj.runOptimizePipeline(eventData);
                    case "PreviewMetric"
                        obj.previewMetric(eventData);
                    case "UpdateSeeds"
                        obj.updateSeeds(eventData);
                    case "ImportSeedsCsv"
                        obj.importSeedsCsv(eventData);
                    case "ExportResults"
                        obj.exportResults(eventData);
                    case "GeneratePredictions"
                        obj.generateDensePredictions(eventData);
                    case "SaveOptimaToDb"
                        obj.saveOptimaToDb(eventData);
                    case "GetDbOptima"
                        obj.sendDbOptimaToPanel();
                    case "DeleteDbOptima"
                        obj.deleteDbOptima(eventData);
                    case "SetSeedsFromDbOptima"
                        obj.setSeedsFromDbOptima(eventData);
                    case "RefreshDbState"
                        obj.refreshDbState();
                    case "SaveDatabaseRequest"
                        obj.saveDatabaseRequest();
                    case "MetricChanged"
                        obj.updateMetricState(eventData);
                    case {"StopProcess", "StopOptimize"}
                        obj.stopOptimization();
                    otherwise
                        fprintf("[OptimizeController] Unknown event: %s\n", eventName);
                end
            catch ME
                if obj.isStopRequested() || strcmp(ME.identifier, "Process:Terminated")
                    obj.notifyStopped("Optimization terminated by user.");
                    return;
                end
                fprintf("[OptimizeController] ERROR in handleEvent (%s):\n%s\n", ...
                    eventName, getReport(ME, "extended", "hyperlinks", "off"));
                obj.sendError(ME.message);
            end
        end

        function previewMetric(obj, d)
        % PREVIEWMETRIC Generate fast 2D metric heatmap preview.
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            rep = obj.makeReporter();
            rep.info("Generating metric preview heatmap...");

            baseMetric = obj.safeStr(d, "metric", "EF_vol");
            metricVariant = obj.safeStr(d, "metricVariant", "avg");
            dataSource = obj.safeStr(d, "dataSource", "model");

            obj.syncMetricState(baseMetric, metricVariant);

            % Resolve paths and data
            [modelFile, riCsvFile, dataFile, predictionFile] = obj.resolvePaths();
            workDir = obj.session.workDir;

            laserWl = obj.safeNum(d, "laserWavelength", 785);
            pMin = obj.safeNum(d, "periodMin", 400);
            pMax = obj.safeNum(d, "periodMax", 1400);
            rMin = obj.safeNum(d, "radiusMin", 50);
            rMax = obj.safeNum(d, "radiusMax", 450);
            sMin = obj.safeNum(d, "stokesShiftMin", 100);
            sMax = obj.safeNum(d, "stokesShiftMax", 3600);
            sRes = obj.safeNum(d, "stokesShiftResolution", 5);
            spatialRes = obj.safeNum(d, "spatialResolution", 2);

            linkMetrics = true;
            if isfield(d, "linkMetricsToGrid")
                linkMetrics = logical(d.linkMetricsToGrid);
            end
            metricsMin = obj.safeNum(d, "metricsShiftMin", sMin);
            metricsMax = obj.safeNum(d, "metricsShiftMax", sMax);

            cfg = localizeMaximaConfig( ...
                WorkDir = workDir, ...
                DataSource = dataSource, ...
                DataFile = dataFile, ...
                ModelFile = modelFile, ...
                RiCsvFile = riCsvFile, ...
                PredictionFile = predictionFile, ...
                RecomputePredictions = (dataSource ~= "predictions"), ...
                LambdaLaser = laserWl, ...
                PLimits = [pMin, pMax], ...
                RLimits = [rMin, rMax], ...
                StokesShiftLimits = [sMin, sMax], ...
                StokesShiftResolution = sRes, ...
                MetricsToLocate = string(baseMetric), ...
                LinkMetricsToGrid = linkMetrics, ...
                MetricsShiftLimits = [metricsMin, metricsMax], ...
                Resolution = spatialRes, ...
                DiscreteOnly = true, ...
                NumLocalMaxima = 1);

            cfg.metricVariant = metricVariant;

            % Re-use cached predictions from db.Pred when requested
            if isfield(obj.session.db, "Pred") && structRowCount(obj.session.db.Pred) > 0
                cfg.cachedAllData = extractBranchAsSoA(obj.session.db, "Pred");
                if dataSource == "predictions"
                    cfg.recomputePredictions = false;
                end
            end

            results = runLocalizationWorkflow(cfg, rep);

            % Update session/app state
            obj.updateOptimizeState("previewResults", results);
            obj.updateOptimizeState("lastResults", results);
            obj.updateOptimizeState("config", d);

            % Render preview to axes
            ax = obj.getAxes();
            if ~isempty(ax) && isvalid(ax)
                try
                    delete(allchild(ax));
                    plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, [], [], [], false);
                catch ME_plot
                    fprintf("[OptimizeController] Visualization warning: %s\n", ME_plot.message);
                end
            end

            obj.sendToHTML("PreviewComplete", struct("metric", baseMetric, "variant", metricVariant));
            rep.complete("Preview", "Heatmap preview ready.");
        end

        function runOptimizePipeline(obj, d)
        % RUNOPTIMIZEPIPELINE Execute detection or MultiStart refinement.
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            rep = obj.makeReporter();
            mode = obj.safeStr(d, "mode", "detect");

            baseMetric = obj.safeStr(d, "metric", "EF_vol");
            metricVariant = obj.safeStr(d, "metricVariant", "avg");
            obj.syncMetricState(baseMetric, metricVariant);

            [modelFile, riCsvFile, dataFile, predictionFile] = obj.resolvePaths();
            workDir = obj.session.workDir;

            laserWl = obj.safeNum(d, "laserWavelength", 785);
            pMin = obj.safeNum(d, "periodMin", 400);
            pMax = obj.safeNum(d, "periodMax", 1400);
            rMin = obj.safeNum(d, "radiusMin", 50);
            rMax = obj.safeNum(d, "radiusMax", 450);
            sMin = obj.safeNum(d, "stokesShiftMin", 100);
            sMax = obj.safeNum(d, "stokesShiftMax", 3600);
            sRes = obj.safeNum(d, "stokesShiftResolution", 5);
            spatialRes = obj.safeNum(d, "spatialResolution", 2);

            linkMetrics = true;
            if isfield(d, "linkMetricsToGrid")
                linkMetrics = logical(d.linkMetricsToGrid);
            end
            metricsMin = obj.safeNum(d, "metricsShiftMin", sMin);
            metricsMax = obj.safeNum(d, "metricsShiftMax", sMax);

            tuningRadiusNm = obj.safeNum(d, "refinementRadius", 10);
            forceTraceMode = obj.safeBool(d, "showMultiStartPaths", false);
            multiStartDisplayMode = obj.safeStr(d, "multiStartDisplay", "off");

            cfg = localizeMaximaConfig( ...
                WorkDir          = workDir, ...
                DataSource       = obj.safeStr(d, "dataSource", "model"), ...
                DataFile         = dataFile, ...
                DiscreteOnly     = (mode == "detect"), ...
                ModelFile        = modelFile, ...
                RiCsvFile        = riCsvFile, ...
                PredictionFile   = predictionFile, ...
                RecomputePredictions = (mode ~= "refine"), ...
                LambdaLaser      = laserWl, ...
                PLimits          = [pMin, pMax], ...
                RLimits          = [rMin, rMax], ...
                StokesShiftLimits = [sMin, sMax], ...
                StokesShiftResolution = sRes, ...
                MetricsToLocate  = string(baseMetric), ...
                LinkMetricsToGrid = linkMetrics, ...
                MetricsShiftLimits = [metricsMin, metricsMax], ...
                Resolution       = spatialRes, ...
                NumLocalMaxima   = obj.safeNum(d, "candidateTopN", 10), ...
                MultiStartPoints = obj.safeNum(d, "numStartPoints", 50), ...
                MultiStartUseParallel = obj.safeBool(d, "multiStartUseParallel", true) && ~forceTraceMode, ...
                ShowIterationPaths = forceTraceMode, ...
                MultiStartDisplay = multiStartDisplayMode, ...
                FunctionTolerance = obj.safeNum(d, "functionTolerance", 1e-9), ...
                StepTolerance = obj.safeNum(d, "stepTolerance", 1e-9), ...
                MaxIterations = round(obj.safeNum(d, "maxIterations", 10000)), ...
                FminconAlgorithm = obj.safeStr(d, "fminconAlgorithm", "interior-point"), ...
                MaxFunctionEvaluations = round(obj.safeNum(d, "maxFunctionEvaluations", 10000)), ...
                ConstraintTolerance = obj.safeNum(d, "constraintTolerance", 1e-9), ...
                OptimalityTolerance = obj.safeNum(d, "optimalityTolerance", 1e-9), ...
                BasinRetryCount = round(obj.safeNum(d, "basinRetryCount", 4)), ...
                BasinRetryShrinkFactor = obj.safeNum(d, "basinRetryShrinkFactor", 0.5), ...
                KeepRejectedSeeds = obj.safeBool(d, "keepRejectedSeeds", true), ...
                UseAnalyticalGradients = obj.safeBool(d, "useAnalyticalGradients", true), ...
                UseGradientSeedInit = obj.safeBool(d, "useGradientSeedInit", true), ...
                GradientSeedCount = round(obj.safeNum(d, "gradientSeedCount", 0)), ...
                GradientSeedGridSize = round(obj.safeNum(d, "gradientSeedGridSize", 20)), ...
                TuningRadius     = tuningRadiusNm * 1e-3);

            cfg.metricVariant = metricVariant;

            % Re-use cached predictions when available
            if isfield(obj.session.db, "Pred") && structRowCount(obj.session.db.Pred) > 0
                cfg.cachedAllData = extractBranchAsSoA(obj.session.db, "Pred");
                if cfg.DataSource == "predictions"
                    cfg.RecomputePredictions = false;
                end
            end

            if mode == "refine" && isfield(d, "seeds") && ~isempty(d.seeds)
                cfg.initialCandidates = buildSeedTable(d.seeds);
                cfg.skipGridGeneration = true;

                % Ensure process-based parallel pool is ready
                if ~forceTraceMode && cfg.MultiStartUseParallel
                    try
                        pool = gcp('nocreate');
                        if isempty(pool) || isa(pool, 'parallel.ThreadPool')
                            if ~isempty(pool), delete(pool); end
                            parpool("Processes");
                        end
                    catch ME_pool
                        fprintf("[OptimizeController] Pool initialization warning: %s\n", ME_pool.message);
                    end
                end
            end

            results = runLocalizationWorkflow(cfg, rep);

            % Update session state
            obj.updateOptimizeState("lastResults", results);
            obj.updateOptimizeState("config", d);

            ax = obj.getAxes();

            if mode == "detect"
                candidates = extractCandidatesFromResults(results, ...
                    obj.safeNum(d, "candidateTopN", 10), ...
                    obj.safeNum(d, "prominenceThreshold", 0));

                if ~isempty(ax) && isvalid(ax)
                    try
                        delete(allchild(ax));
                        plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, [], candidates, [], false);
                    catch ME_plt
                        fprintf("[OptimizeController] Visualization warning: %s\n", ME_plt.message);
                    end
                end

                obj.sendToHTML("SeedsFound", candidates);
                obj.sendToHTML("OptimizeComplete", ...
                    sprintf("Seed detection complete (%d candidates).", numel(candidates)));
                return;
            end

            % Refine mode
            originalSeeds = [];
            if isfield(d, "seeds") && ~isempty(d.seeds)
                originalSeeds = normalizeSeedInput(d.seeds);
            end

            refinedSeeds = extractRefinedSeeds(results, baseMetric, originalSeeds);
            attemptTrajectories = extractAttemptTrajectories(results, baseMetric);

            if ~isempty(ax) && isvalid(ax)
                try
                    delete(allchild(ax));
                    plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, ...
                        originalSeeds, refinedSeeds, attemptTrajectories, forceTraceMode);
                catch ME_plt2
                    fprintf("[OptimizeController] Visualization warning: %s\n", ME_plt2.message);
                end
            end

            obj.sendToHTML("SeedsRefined", struct( ...
                "seeds", refinedSeeds, ...
                "attemptTrajectories", attemptTrajectories));

            % Write-back to db.Pred
            if isfield(results, "allData") && isstruct(results.allData)
                obj.session.db.Pred = results.allData;
                obj.session.dbDirty = true;
                if ~isempty(obj.fig) && isvalid(obj.fig)
                    obj.fig.UserData.db = obj.session.db;
                    obj.fig.UserData.dbDirty = true;
                end
            end

            obj.sendToHTML("OptimizeComplete", ...
                sprintf("Found %d maxima in %.1f s.", ...
                    countMaximaResults(results), results.elapsedTotal));
        end

        function updateSeeds(obj, d)
        % UPDATESEEDS Re-plot heatmap with updated seed coordinates.
            seeds = [];
            if isfield(d, "seeds"), seeds = d.seeds; end
            if isempty(seeds), return; end

            seedsNorm = normalizeSeedInput(seeds);
            obj.updateOptimizeState("currentSeeds", seedsNorm);

            ax = obj.getAxes();
            lastRes = obj.getOptimizeState("lastResults");
            baseMetric = obj.getOptimizeState("baseMetric");
            if isempty(baseMetric), baseMetric = "EF_vol"; end
            metricVariant = obj.getOptimizeState("metricVariant");
            if isempty(metricVariant), metricVariant = "avg"; end

            if ~isempty(lastRes) && ~isempty(ax) && isvalid(ax)
                try
                    delete(allchild(ax));
                    plotOptimizeHeatmap(lastRes, baseMetric, metricVariant, ax, seedsNorm, [], [], false);
                catch ME
                    fprintf("[OptimizeController] Update plot warning: %s\n", ME.message);
                end
            end

            obj.sendToHTML("SeedsUpdated", struct("seeds", seedsNorm));
        end

        function saveOptimaToDb(obj, d)
        % SAVEOPTIMATODB Persist selected optima to session.db.Optima.
            seeds = d;
            if isstruct(d) && isfield(d, "seeds")
                seeds = d.seeds;
            end
            if isempty(seeds)
                obj.sendError("No optima to save.");
                return;
            end
            if iscell(seeds), seeds = [seeds{:}]; end

            baseMetric = obj.getOptimizeState("baseMetric");
            if isempty(baseMetric), baseMetric = "EF_vol"; end
            metricVariant = obj.getOptimizeState("metricVariant");
            if isempty(metricVariant), metricVariant = "avg"; end
            canonicalMetric = canonicalMetricName(baseMetric, metricVariant);

            db_ = obj.session.db;
            if ~isfield(db_, "Optima") || ~isstruct(db_.Optima) || ~isfield(db_.Optima, "period")
                db_.Optima = struct( ...
                    "period", zeros(0,1), "radius", zeros(0,1), ...
                    "basinTag", string.empty(0,1), "optimizedMetric", string.empty(0,1));
            end

            nSaved = 0;
            for i = 1:numel(seeds)
                s = seeds(i);
                p = NaN; r = NaN; tag = "";
                if isfield(s, "period"), p = double(s.period);
                elseif isfield(s, "P"), p = double(s.P);
                elseif isfield(s, "p"), p = double(s.p); end

                if isfield(s, "radius"), r = double(s.radius);
                elseif isfield(s, "R"), r = double(s.R);
                elseif isfield(s, "r"), r = double(s.r); end

                if isfield(s, "tag"), tag = string(s.tag);
                elseif isfield(s, "Tag"), tag = string(s.Tag); end

                if ~isfinite(p) || ~isfinite(r), continue; end

                db_.Optima.period(end+1,1) = p;
                db_.Optima.radius(end+1,1) = r;
                db_.Optima.basinTag(end+1,1) = tag;
                db_.Optima.optimizedMetric(end+1,1) = canonicalMetric;
                nSaved = nSaved + 1;
            end

            obj.session.db = db_;
            obj.session.dbDirty = true;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.db = db_;
                obj.fig.UserData.dbDirty = true;
            end

            totalOptima = numel(db_.Optima.period);
            obj.sendToHTML("OptimaSaved", struct("count", nSaved, "total", totalOptima));
            obj.sendDbOptimaToPanel();
        end

        function sendDbOptimaToPanel(obj)
        % SENDDBOPTIMATOPANEL Stream DB optima list to HTML table.
            db_ = obj.session.db;
            if ~isfield(db_, "Optima") || ~isstruct(db_.Optima) || ~isfield(db_.Optima, "period")
                obj.sendToHTML("DbOptimaData", struct("optima", []));
                return;
            end

            n = numel(db_.Optima.period);
            optimaList = cell(n, 1);
            for i = 1:n
                optimaList{i} = struct( ...
                    "index", i, ...
                    "tag", string(db_.Optima.basinTag(i)), ...
                    "metric", string(db_.Optima.optimizedMetric(i)), ...
                    "p", double(db_.Optima.period(i)), ...
                    "r", double(db_.Optima.radius(i)));
            end

            obj.sendToHTML("DbOptimaData", struct("optima", optimaList));
        end

        function deleteDbOptima(obj, d)
        % DELETEDBOPTIMA Remove rows from db.Optima by index.
            if ~isfield(d, "indices") || isempty(d.indices), return; end
            idx = double(d.indices);

            db_ = obj.session.db;
            if ~isfield(db_, "Optima") || ~isstruct(db_.Optima) || ~isfield(db_.Optima, "period")
                return;
            end

            keep = true(numel(db_.Optima.period), 1);
            idxValid = idx(idx >= 1 & idx <= numel(keep));
            keep(idxValid) = false;

            db_.Optima.period = db_.Optima.period(keep);
            db_.Optima.radius = db_.Optima.radius(keep);
            db_.Optima.basinTag = db_.Optima.basinTag(keep);
            db_.Optima.optimizedMetric = db_.Optima.optimizedMetric(keep);

            obj.session.db = db_;
            obj.session.dbDirty = true;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.db = db_;
                obj.fig.UserData.dbDirty = true;
            end

            obj.sendDbOptimaToPanel();
        end

        function setSeedsFromDbOptima(obj, d)
        % SETSEEDSFROMDBOPTIMA Load selected DB optima into current seeds table.
            if ~isfield(d, "indices") || isempty(d.indices), return; end
            idx = double(d.indices);

            db_ = obj.session.db;
            if ~isfield(db_, "Optima") || ~isstruct(db_.Optima) || ~isfield(db_.Optima, "period")
                return;
            end

            idxValid = idx(idx >= 1 & idx <= numel(db_.Optima.period));
            seeds = cell(numel(idxValid), 1);
            for k = 1:numel(idxValid)
                i = idxValid(k);
                seeds{k} = struct( ...
                    "Tag", string(db_.Optima.basinTag(i)), ...
                    "P", double(db_.Optima.period(i)), ...
                    "R", double(db_.Optima.radius(i)), ...
                    "Value", NaN);
            end

            obj.sendToHTML("SeedsUpdated", struct("seeds", seeds));
            obj.updateSeeds(struct("seeds", seeds));
        end

        function importSeedsCsv(obj, d)
        % IMPORTSEEDSCSV Load seed coordinates from external CSV file.
            csvPath = "";
            if isfield(d, "path") && strlength(string(d.path)) > 0
                csvPath = string(d.path);
            else
                [file, path] = uigetfile("*.csv", "Import Seeds CSV", obj.session.workDir);
                if file ~= 0
                    csvPath = fullfile(path, file);
                end
            end

            if csvPath == "" || ~isfile(csvPath), return; end

            T = readtable(csvPath);
            seeds = cell(height(T), 1);
            for i = 1:height(T)
                tagStr = "Seed " + i;
                if ismember("Tag", T.Properties.VariableNames)
                    tagStr = string(T.Tag{i});
                end
                pVal = NaN; rVal = NaN;
                if ismember("P", T.Properties.VariableNames), pVal = double(T.P(i));
                elseif ismember("Period", T.Properties.VariableNames), pVal = double(T.Period(i)); end
                if ismember("R", T.Properties.VariableNames), rVal = double(T.R(i));
                elseif ismember("Radius", T.Properties.VariableNames), rVal = double(T.Radius(i)); end

                seeds{i} = struct("Tag", tagStr, "P", pVal, "R", rVal, "Value", NaN);
            end

            obj.sendToHTML("SeedsUpdated", struct("seeds", seeds));
            obj.updateSeeds(struct("seeds", seeds));
        end

        function exportResults(obj, d)
        % EXPORTRESULTS Export optimization results to MAT or CSV.
            lastRes = obj.getOptimizeState("lastResults");
            if isempty(lastRes)
                obj.sendError("No optimization results available to export.");
                return;
            end

            format = obj.safeStr(d, "format", "mat");
            exportPath = "";
            if isfield(d, "path") && strlength(string(d.path)) > 0
                exportPath = string(d.path);
            else
                defaultName = "optimization_results." + format;
                [file, path] = uiputfile("*." + format, "Export Optimization Results", ...
                    fullfile(obj.session.workDir, defaultName));
                if file ~= 0
                    exportPath = fullfile(path, file);
                end
            end

            if exportPath == "", return; end

            if format == "csv"
                T = struct2table(lastRes.optimaTable);
                writetable(T, exportPath);
            else
                save(exportPath, "lastRes", "-v7.3");
            end

            obj.sendToHTML("ExportComplete", struct("path", exportPath));
        end

        function generateDensePredictions(obj, d)
        % GENERATEDENSEPREDICTIONS Precompute dense grid inference to db.Pred.
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            rep = obj.makeReporter();
            rep.info("Generating dense predictions across grid...");

            [modelFile, riCsvFile, ~, ~] = obj.resolvePaths();
            if modelFile == ""
                obj.sendError("No surrogate model file available.");
                return;
            end

            laserWl = obj.safeNum(d, "laserWavelength", 785);
            pMin = obj.safeNum(d, "periodMin", 400);
            pMax = obj.safeNum(d, "periodMax", 1400);
            rMin = obj.safeNum(d, "radiusMin", 50);
            rMax = obj.safeNum(d, "radiusMax", 450);
            sMin = obj.safeNum(d, "stokesShiftMin", 100);
            sMax = obj.safeNum(d, "stokesShiftMax", 3600);
            sRes = obj.safeNum(d, "stokesShiftResolution", 5);
            spatialRes = obj.safeNum(d, "spatialResolution", 2);

            linkMetrics = true;
            if isfield(d, "linkMetricsToGrid")
                linkMetrics = logical(d.linkMetricsToGrid);
            end
            metricsMin = obj.safeNum(d, "metricsShiftMin", sMin);
            metricsMax = obj.safeNum(d, "metricsShiftMax", sMax);

            cfg = predictionVisConfig( ...
                WorkDir             = obj.session.workDir, ...
                ModelFile           = modelFile, ...
                RiCsvFile           = riCsvFile, ...
                LambdaLaser         = laserWl, ...
                PLimits             = [pMin, pMax], ...
                RLimits             = [rMin, rMax], ...
                Resolution          = spatialRes, ...
                StokesShiftLimits   = [sMin, sMax], ...
                StokesShiftResolution = sRes, ...
                LinkMetricsToGrid   = linkMetrics, ...
                MetricsShiftLimits  = [metricsMin, metricsMax], ...
                RecomputePredictions = true, ...
                ExportPredictions   = false, ...
                ExportGraphics      = false);

            loadPredArgs = { ...
                "Recompute", true, ...
                "Model", obj.session.model, ...
                "Ri", obj.session.ri, ...
                "PSamples", cfg.pSamples, "RSamples", cfg.rSamples, ...
                "LambdaSamples", cfg.lambdaSamples, ...
                "LambdaLaser", laserWl, ...
                "StokesShiftLimits", [sMin, sMax], ...
                "AnalyteSpectrum", obj.session.analyteSpectrum, ...
                "InterpResolution", sRes, ...
                "PredictionFile", cfg.predictionFile, ...
                "SaveAfterGeneration", false, ...
                "Reporter", rep};

            if ~linkMetrics
                loadPredArgs = [loadPredArgs, {"MetricsShiftLimits", [metricsMin, metricsMax]}];
            end

            allDataRaw = loadOrGeneratePredictions(loadPredArgs{:});

            if isstruct(allDataRaw) && structRowCount(allDataRaw) > 0
                obj.session.db.Pred = allDataRaw;
                obj.session.dbDirty = true;
                if ~isempty(obj.fig) && isvalid(obj.fig)
                    obj.fig.UserData.db.Pred = allDataRaw;
                    obj.fig.UserData.dbDirty = true;
                end
                n = structRowCount(allDataRaw);
                obj.sendToHTML("PredictionsGenerated", struct("count", n));
                rep.complete("GeneratePredictions", sprintf("Dense predictions ready (%d entries).", n));
            else
                obj.sendError("Generated prediction dataset was empty.");
            end
        end

        function updateMetricState(obj, d)
        % UPDATEMETRICSTATE Update selected metric and variant.
            m = obj.safeStr(d, "metric", "EF_vol");
            v = obj.safeStr(d, "metricVariant", "avg");
            obj.syncMetricState(m, v);
        end
    end

    %% Internal Helpers
    methods (Access = private)
        function [modelFile, riCsvFile, dataFile, predictionFile] = resolvePaths(obj)
            modelFile = ""; riCsvFile = ""; dataFile = ""; predictionFile = "";
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "app") ...
                    && isfield(obj.fig.UserData.app, "resolveDbPaths")
                [modelFile, riCsvFile, dataFile, predictionFile] = obj.fig.UserData.app.resolveDbPaths();
            elseif isfield(obj.session.db, "Global")
                g = obj.session.db.Global;
                if isfield(g, "SurrogateModelFile"), modelFile = string(g.SurrogateModelFile); end
                if isfield(g, "RefractiveIndexFile"), riCsvFile = string(g.RefractiveIndexFile); end
                if isfield(g, "SimulationDataFile"), dataFile = string(g.SimulationDataFile); end
            end
        end

        function ax = getAxes(obj)
            ax = obj.axesHandle;
            if (isempty(ax) || ~isvalid(ax)) && ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "handles") && isfield(obj.fig.UserData.handles, "optimizeAx")
                    ax = obj.fig.UserData.handles.optimizeAx;
                end
            end
        end

        function syncMetricState(obj, baseMetric, metricVariant)
            obj.updateOptimizeState("baseMetric", baseMetric);
            obj.updateOptimizeState("metricVariant", metricVariant);
        end

        function updateOptimizeState(obj, key, val)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if ~isfield(obj.fig.UserData, "optimize")
                    obj.fig.UserData.optimize = struct();
                end
                obj.fig.UserData.optimize.(key) = val;
            end
        end

        function val = getOptimizeState(obj, key)
            val = [];
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "optimize")
                if isfield(obj.fig.UserData.optimize, key)
                    val = obj.fig.UserData.optimize.(key);
                end
            end
        end

        function sendToHTML(obj, eventName, payload)
            if ~isempty(obj.htmlComponent) && isvalid(obj.htmlComponent)
                try
                    sendEventToHTMLSource(obj.htmlComponent, eventName, payload);
                catch
                end
            end
            if ~isempty(obj.fig) && isvalid(obj.fig)
                try
                    sendOptimizeEvent(obj.fig, eventName, payload, obj.htmlComponent);
                catch
                end
            end
        end

        function sendError(obj, msg)
            obj.sendToHTML("OptimizeError", msg);
        end

        function rep = makeReporter(obj)
            rep = ProgressReporter.fromCallback( ...
                @(type, step, data) obj.sendToHTML("Progress", data));
            rep.StopCheckFcn = @() obj.isStopRequested();
        end

        function setRunning(obj, isRunning)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "setProcessRunning")
                    obj.fig.UserData.app.setProcessRunning(isRunning, "Optimize");
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.isRunning = logical(isRunning);
                end
            end
            obj.session.setProcessRunning(isRunning, "Optimize");
        end

        function stopReq = isStopRequested(obj)
            stopReq = false;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "isProcessStopRequested")
                    stopReq = obj.fig.UserData.app.isProcessStopRequested();
                elseif isfield(obj.fig.UserData, "process") && isfield(obj.fig.UserData.process, "stopRequested")
                    stopReq = logical(obj.fig.UserData.process.stopRequested);
                end
            end
            if ~stopReq
                stopReq = obj.session.isStopRequested();
            end
        end

        function stopOptimization(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "requestProcessStop")
                    obj.fig.UserData.app.requestProcessStop();
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.stopRequested = true;
                end
            end
            obj.session.requestStop();
        end

        function notifyStopped(obj, msg)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "notifyProcessStopped")
                    obj.fig.UserData.app.notifyProcessStopped("Optimize", msg);
                else
                    obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
                end
            else
                obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
            end
        end

        function refreshDbState(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "broadcastDbStatus")
                    obj.fig.UserData.app.broadcastDbStatus();
                end
            end
        end

        function saveDatabaseRequest(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "saveDbFile")
                    obj.fig.UserData.app.saveDbFile();
                    if isfield(obj.fig.UserData.app, "broadcastDbStatus")
                        obj.fig.UserData.app.broadcastDbStatus();
                    end
                end
            else
                obj.session.saveDatabase();
            end
            obj.sendToHTML("SaveComplete", "Database saved.");
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
    end
end
