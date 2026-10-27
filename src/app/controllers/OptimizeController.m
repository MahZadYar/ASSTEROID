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
        localOptimizeState = struct()
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
                    case "MergeBasins"
                        obj.mergeBasins(eventData);
                    case "ImportSeedsCsv"
                        obj.importSeedsCsv(eventData);
                    case "ExportResults"
                        obj.exportResults(eventData);
                    case "GeneratePredictions"
                        obj.generateDensePredictions(eventData);
                    case "SaveOptimaToDb"
                        obj.saveOptimaToDb(eventData);
                    case "SaveBasinsToDb"
                        obj.saveBasinsToDb(eventData);
                    case "LoadBasinsFromDb"
                        obj.loadBasinsFromDb(eventData);
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
                    case "GetPredictionBounds"
                        obj.sendPredictionBounds();
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
            rMax = obj.safeNum(d, "radiusMax", 700);

            if (dataSource == "predictions" || (isfield(obj.session.db, "Pred") && structRowCount(obj.session.db.Pred) > 0))
                predSoA = extractBranchAsSoA(obj.session.db, "Pred");
                if isstruct(predSoA) && isfield(predSoA, "period") && isfield(predSoA, "radius") && ~isempty(predSoA.period)
                    pDataMin = min(predSoA.period); pDataMax = max(predSoA.period);
                    rDataMin = min(predSoA.radius); rDataMax = max(predSoA.radius);
                    if dataSource == "predictions"
                        pMin = pDataMin; pMax = pDataMax;
                        rMin = rDataMin; rMax = rDataMax;
                    end
                end
            end
            sMin = obj.safeNum(d, "stokesShiftMin", 100);
            sMax = obj.safeNum(d, "stokesShiftMax", 3600);
            sRes = obj.safeNum(d, "fineTuneSpectralResolution", obj.safeNum(d, "stokesShiftResolution", 5));
            if metricVariant == "laser"
                sMin = 0;
                sMax = 0;
            end
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

            % Handle pre-computed predictions preview without generating new predictions
            if dataSource == "predictions"
                obj.previewPrecomputedPredictions(d, baseMetric, metricVariant, rep);
                return;
            end

            results = runLocalizationWorkflow(cfg, rep);

            % Update session/app state
            obj.updateOptimizeState("previewResults", results);
            obj.updateOptimizeState("lastResults", results);
            obj.updateOptimizeState("config", d);
            obj.updateOptimizeState("basinMap", []);

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
            rMax = obj.safeNum(d, "radiusMax", 700);

            if (obj.safeStr(d, "dataSource", "model") == "predictions" || (isfield(obj.session.db, "Pred") && structRowCount(obj.session.db.Pred) > 0))
                predSoA = extractBranchAsSoA(obj.session.db, "Pred");
                if isstruct(predSoA) && isfield(predSoA, "period") && isfield(predSoA, "radius") && ~isempty(predSoA.period)
                    pDataMin = min(predSoA.period); pDataMax = max(predSoA.period);
                    rDataMin = min(predSoA.radius); rDataMax = max(predSoA.radius);
                    if obj.safeStr(d, "dataSource", "model") == "predictions"
                        pMin = pDataMin; pMax = pDataMax;
                        rMin = rDataMin; rMax = rDataMax;
                    end
                end
            end
            sMin = obj.safeNum(d, "stokesShiftMin", 100);
            sMax = obj.safeNum(d, "stokesShiftMax", 3600);
            sRes = obj.safeNum(d, "fineTuneSpectralResolution", obj.safeNum(d, "stokesShiftResolution", 5));
            if metricVariant == "laser"
                sMin = 0;
                sMax = 0;
            end
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
            useBasins = obj.safeBool(d, "useWatershedBasins", true);
            basinSens = max(0, obj.safeNum(d, "basinSensitivity", 0.5)) / 100;   % UI: % of range

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
                NumLocalMaxima   = obj.safeNum(d, "candidateTopN", 15), ...
                MultiStartPoints = obj.safeNum(d, "numStartPoints", 15), ...
                MultiStartUseParallel = obj.safeBool(d, "multiStartUseParallel", true) && ~forceTraceMode, ...
                ShowIterationPaths = forceTraceMode, ...
                MultiStartDisplay = multiStartDisplayMode, ...
                FunctionTolerance = obj.safeNum(d, "functionTolerance", 1e-6), ...
                StepTolerance = obj.safeNum(d, "stepTolerance", 1e-5), ...
                MaxIterations = round(obj.safeNum(d, "maxIterations", 300)), ...
                FminconAlgorithm = obj.safeStr(d, "fminconAlgorithm", "interior-point"), ...
                MaxFunctionEvaluations = round(obj.safeNum(d, "maxFunctionEvaluations", 1000)), ...
                ConstraintTolerance = obj.safeNum(d, "constraintTolerance", 1e-5), ...
                OptimalityTolerance = obj.safeNum(d, "optimalityTolerance", 1e-4), ...
                BasinRetryCount = round(obj.safeNum(d, "basinRetryCount", 2)), ...
                BasinRetryShrinkFactor = obj.safeNum(d, "basinRetryShrinkFactor", 0.5), ...
                KeepRejectedSeeds = obj.safeBool(d, "keepRejectedSeeds", true), ...
                UseAnalyticalGradients = obj.safeBool(d, "useAnalyticalGradients", true), ...
                UseGradientSeedInit = obj.safeBool(d, "useGradientSeedInit", true), ...
                GradientSeedCount = round(obj.safeNum(d, "gradientSeedCount", 0)), ...
                GradientSeedGridSize = round(obj.safeNum(d, "gradientSeedGridSize", 20)), ...
                TuningRadius     = tuningRadiusNm * 1e-3, ...
                UseWatershedBasins = useBasins, ...
                BasinSensitivity = basinSens, ...
                InBasinStarts    = max(1, round(obj.safeNum(d, "inBasinStarts", 5))), ...
                BasinValueThreshold = max(0, min(100, obj.safeNum(d, "basinValueThreshold", 50))));

            cfg.metricVariant = metricVariant;

            % Sync db.Pred from fig.UserData if needed
            if (~isfield(obj.session.db, "Pred") || structRowCount(obj.session.db.Pred) == 0) && ...
               (~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "db") && ...
                isfield(obj.fig.UserData.db, "Pred") && structRowCount(obj.fig.UserData.db.Pred) > 0)
                obj.session.db.Pred = obj.fig.UserData.db.Pred;
            end

            % If still missing, check predictionFile on disk
            if (~isfield(obj.session.db, "Pred") || structRowCount(obj.session.db.Pred) == 0)
                [~, ~, ~, predictionFile] = obj.resolvePaths();
                if strlength(predictionFile) > 0 && isfile(predictionFile)
                    loaded = load(predictionFile);
                    if isfield(loaded, "allData"), obj.session.db.Pred = loaded.allData;
                    elseif isfield(loaded, "predictions"), obj.session.db.Pred = loaded.predictions;
                    elseif isfield(loaded, "db") && isfield(loaded.db, "Pred"), obj.session.db.Pred = loaded.db.Pred;
                    else, obj.session.db.Pred = loaded;
                    end
                    if ~isempty(obj.fig) && isvalid(obj.fig)
                        obj.fig.UserData.db.Pred = obj.session.db.Pred;
                    end
                end
            end

            % Re-use cached predictions when available
            if isfield(obj.session.db, "Pred") && structRowCount(obj.session.db.Pred) > 0
                predData = extractBranchAsSoA(obj.session.db, "Pred");
                predData = obj.ensureDerivedMetricSlice(predData, baseMetric, metricVariant, laserWl);
                cfg.cachedAllData = predData;
                if cfg.dataSource == "predictions"
                    cfg.recomputePredictions = false;
                end
            end

            if mode == "refine" && isfield(d, "seeds") && ~isempty(d.seeds)
                cfg.initialCandidates = buildSeedTable(d.seeds);
                cfg.skipGridGeneration = true;
                % Refine every seed the user kept (Top-N only limits detection).
                cfg.numLocalMaxima = max(1, height(cfg.initialCandidates));

                if useBasins
                    % Reuse the partition shown at seed initialisation when it
                    % matches the current metric and sensitivity; otherwise
                    % runLocalizationWorkflow rebuilds it from cached predictions.
                    cfg.basinMap = obj.storedBasinMap(baseMetric, metricVariant, basinSens, [pMin pMax], [rMin rMax]);
                end

                % Ensure process-based parallel pool is ready (radius-box mode only;
                % in-basin refinement runs serially)
                if ~useBasins && ~forceTraceMode && cfg.multiStartUseParallel
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
            basinMap = [];
            if isfield(results, "metrics") && ~isempty(results.metrics) && isstruct(results.metrics{1}) ...
                    && isfield(results.metrics{1}, "basinMap") && isstruct(results.metrics{1}.basinMap)
                basinMap = results.metrics{1}.basinMap;
                obj.updateOptimizeState("basinMap", basinMap);
                obj.updateOptimizeState("basinMapMeta", struct("metric", string(baseMetric), ...
                    "variant", string(metricVariant), "sensitivity", basinSens, ...
                    "pLimits", [pMin pMax], "rLimits", [rMin rMax]));
            elseif mode == "detect"
                obj.updateOptimizeState("basinMap", []);
            end

            if mode == "detect"
                candidates = extractCandidatesFromResults(results, ...
                    obj.safeNum(d, "candidateTopN", 15), ...
                    obj.safeNum(d, "prominenceThreshold", 0));

                if ~isempty(ax) && isvalid(ax)
                    try
                        delete(allchild(ax));
                        plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, [], candidates, [], false, basinMap);
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
                        originalSeeds, refinedSeeds, attemptTrajectories, forceTraceMode, basinMap);
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
        % UPDATESEEDS Re-plot heatmap with updated seed coordinates and annotations.
            seeds = [];
            if isfield(d, "seeds"), seeds = d.seeds; end
            if isempty(seeds), return; end

            seedsNorm = normalizeSeedInput(seeds);

            ax = obj.getAxes();
            lastRes = obj.getOptimizeState("lastResults");
            if isempty(lastRes)
                lastRes = obj.getOptimizeState("previewResults");
            end

            baseMetric = obj.getOptimizeState("baseMetric");
            if isempty(baseMetric), baseMetric = "EF_vol"; end
            metricVariant = obj.getOptimizeState("metricVariant");
            if isempty(metricVariant), metricVariant = "avg"; end

            % Re-evaluate metric values for updated seeds if results exist
            if ~isempty(lastRes)
                try
                    if ~isfield(lastRes, "cfg") || ~isstruct(lastRes.cfg)
                        lastRes.cfg = struct();
                    end
                    lastRes.cfg.metricVariant = metricVariant;
                    vals = evaluateMetricAtPoints(lastRes, baseMetric, seedsNorm);
                    for i = 1:numel(seedsNorm)
                        if i <= numel(vals) && isfinite(vals(i))
                            seedsNorm(i).Value = vals(i);
                        end
                    end
                catch ME_eval
                    fprintf("[OptimizeController] Re-evaluate seeds warning: %s\n", ME_eval.message);
                end
            end

            obj.updateOptimizeState("currentSeeds", seedsNorm);

            if ~isempty(lastRes) && ~isempty(ax) && isvalid(ax)
                try
                    delete(allchild(ax));
                    plotOptimizeHeatmap(lastRes, baseMetric, metricVariant, ax, [], seedsNorm, [], false, ...
                        obj.getOptimizeState("basinMap"));
                catch ME
                    fprintf("[OptimizeController] Update plot warning: %s\n", ME.message);
                end
            end

            obj.sendToHTML("SeedsUpdated", struct("seeds", seedsNorm));
        end

        function mergeBasins(obj, d)
        % MERGEBASINS Merge multiple selected basins into one, updating territories and seeds.
            targetBasinId = obj.safeNum(d, "targetBasinId", NaN);
            mergedBasinIds = [];
            if isfield(d, "mergedBasinIds") && ~isempty(d.mergedBasinIds)
                mergedBasinIds = double(d.mergedBasinIds(:)');
            end
            seeds = [];
            if isfield(d, "seeds"), seeds = d.seeds; end
            if isempty(seeds), return; end

            seedsNorm = normalizeSeedInput(seeds);

            basinMap = obj.getOptimizeState("basinMap");
            if isempty(basinMap) || ~isstruct(basinMap) || ~isfield(basinMap, "labels")
                % No basin map active; just update seeds
                obj.updateSeeds(struct("seeds", seedsNorm));
                return;
            end

            % Identify target basin ID if not specified
            if isnan(targetBasinId) || targetBasinId <= 0
                if ~isempty(mergedBasinIds)
                    targetBasinId = mergedBasinIds(1);
                elseif isfield(seedsNorm(1), "BasinId") && isfinite(seedsNorm(1).BasinId)
                    targetBasinId = seedsNorm(1).BasinId;
                end
            end

            if ~isempty(mergedBasinIds) && isfinite(targetBasinId) && targetBasinId > 0
                % 1. Relabel cells in basinMap.labels
                mask = ismember(basinMap.labels, mergedBasinIds);
                basinMap.labels(mask) = uint32(targetBasinId);

                % 2. Recompute boundary polygon for targetBasinId
                otherIds = setdiff(mergedBasinIds, targetBasinId);
                bw = basinMap.labels == targetBasinId;
                B = bwboundaries(bw, 8, "noholes");
                px = []; py = [];
                if ~isempty(B)
                    [~, longest] = max(cellfun(@(b) size(b, 1), B));
                    b = B{longest};
                    px = double(basinMap.pAxis_nm(b(:, 2))); px = px(:);
                    py = double(basinMap.rAxis_nm(b(:, 1))); py = py(:);
                end

                % 3. Update basinMap.polygons
                if isfield(basinMap, "polygons") && ~isempty(basinMap.polygons)
                    kTarget = find([basinMap.polygons.BasinId] == targetBasinId, 1);
                    if isempty(kTarget)
                        basinMap.polygons(end + 1) = struct("BasinId", targetBasinId, "P_nm", px, "R_nm", py);
                    else
                        basinMap.polygons(kTarget).P_nm = px;
                        basinMap.polygons(kTarget).R_nm = py;
                    end
                    keepPoly = ~ismember([basinMap.polygons.BasinId], otherIds);
                    basinMap.polygons = basinMap.polygons(keepPoly);
                end

                % 4. Update basinMap.basinIds, peakValue, saddle
                if isfield(basinMap, "basinIds") && ~isempty(basinMap.basinIds)
                    keepB = ~ismember(basinMap.basinIds, otherIds);
                    basinMap.basinIds = basinMap.basinIds(keepB);
                    if isfield(basinMap, "peakValue") && numel(basinMap.peakValue) == numel(keepB)
                        basinMap.peakValue = basinMap.peakValue(keepB);
                    end
                    if isfield(basinMap, "saddle") && numel(basinMap.saddle) == numel(keepB)
                        basinMap.saddle = basinMap.saddle(keepB);
                    end
                end

                % 5. Mark as user-merged in basinMapMeta
                meta = obj.getOptimizeState("basinMapMeta");
                if isstruct(meta)
                    meta.isUserMerged = true;
                    obj.updateOptimizeState("basinMapMeta", meta);
                end

                obj.updateOptimizeState("basinMap", basinMap);

                % Update lastResults / previewResults if present
                lastRes = obj.getOptimizeState("lastResults");
                if ~isempty(lastRes) && isfield(lastRes, "metrics") && ~isempty(lastRes.metrics) && isstruct(lastRes.metrics{1})
                    lastRes.metrics{1}.basinMap = basinMap;
                    obj.updateOptimizeState("lastResults", lastRes);
                end
                prevRes = obj.getOptimizeState("previewResults");
                if ~isempty(prevRes) && isfield(prevRes, "metrics") && ~isempty(prevRes.metrics) && isstruct(prevRes.metrics{1})
                    prevRes.metrics{1}.basinMap = basinMap;
                    obj.updateOptimizeState("previewResults", prevRes);
                end
            end

            % 6. Ensure winner seed in seedsNorm has BasinId = targetBasinId
            for i = 1:numel(seedsNorm)
                if isfield(seedsNorm(i), "BasinId") && ismember(seedsNorm(i).BasinId, mergedBasinIds)
                    seedsNorm(i).BasinId = targetBasinId;
                end
            end

            obj.updateOptimizeState("currentSeeds", seedsNorm);

            % 7. Re-draw heatmap
            ax = obj.getAxes();
            resToPlot = obj.getOptimizeState("lastResults");
            if isempty(resToPlot)
                resToPlot = obj.getOptimizeState("previewResults");
            end

            if ~isempty(resToPlot) && ~isempty(ax) && isvalid(ax)
                baseMetric = obj.getOptimizeState("baseMetric");
                if isempty(baseMetric), baseMetric = "EF_vol"; end
                metricVariant = obj.getOptimizeState("metricVariant");
                if isempty(metricVariant), metricVariant = "avg"; end
                try
                    delete(allchild(ax));
                    plotOptimizeHeatmap(resToPlot, baseMetric, metricVariant, ax, [], seedsNorm, [], false, basinMap);
                catch ME
                    fprintf("[OptimizeController] MergeBasins plot warning: %s\n", ME.message);
                end
            end

            % 8. Notify UI
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

        function saveBasinsToDb(obj, d)
        % SAVEBASINSTODB Save currently detected/curated basin territories to session.db.Basins.
            basinMap = obj.getOptimizeState("basinMap");
            if isempty(basinMap) || ~isstruct(basinMap) || ~isfield(basinMap, "basinIds") || isempty(basinMap.basinIds)
                obj.sendError("No basins to save. Run Detect Basins first.");
                return;
            end

            seeds = [];
            if isstruct(d) && isfield(d, "seeds") && ~isempty(d.seeds)
                seeds = normalizeSeedInput(d.seeds);
            else
                currentSeeds = obj.getOptimizeState("currentSeeds");
                if ~isempty(currentSeeds)
                    seeds = currentSeeds;
                end
            end

            bIds = double(basinMap.basinIds(:));
            nB = numel(bIds);
            
            baseMetric = obj.getOptimizeState("baseMetric");
            if isempty(baseMetric), baseMetric = "EF_vol"; end
            metricVariant = obj.getOptimizeState("metricVariant");
            if isempty(metricVariant), metricVariant = "avg"; end
            masterMetric = canonicalMetricName(baseMetric, metricVariant);

            % Pre-allocate SoA columns matching createDatabaseStruct
            bIdCol    = zeros(nB, 1, 'uint32');
            tagCol    = strings(nB, 1);
            pCol      = zeros(nB, 1);
            rCol      = zeros(nB, 1);
            gridValCol= zeros(nB, 1);
            areaCol   = zeros(nB, 1);
            saddleCol = zeros(nB, 1);
            depthCol  = zeros(nB, 1);
            pMinCol   = zeros(nB, 1);
            pMaxCol   = zeros(nB, 1);
            rMinCol   = zeros(nB, 1);
            rMaxCol   = zeros(nB, 1);
            metricCol = repmat(masterMetric, nB, 1);

            pAx_nm = double(basinMap.pAxis_nm(:)');
            rAx_nm = double(basinMap.rAxis_nm(:)');
            labels = double(basinMap.labels);

            for i = 1:nB
                thisId = bIds(i);
                bIdCol(i) = uint32(thisId);

                % Match seed by BasinId or by index
                matchedSeed = [];
                for sIdx = 1:numel(seeds)
                    if isfield(seeds(sIdx), "BasinId") && seeds(sIdx).BasinId == thisId
                        matchedSeed = seeds(sIdx);
                        break;
                    end
                end
                if isempty(matchedSeed) && i <= numel(seeds)
                    matchedSeed = seeds(i);
                end

                if ~isempty(matchedSeed)
                    if isfield(matchedSeed, "Tag") && strlength(string(matchedSeed.Tag)) > 0
                        tagCol(i) = string(matchedSeed.Tag);
                    else
                        tagCol(i) = sprintf("Seed #%d", i);
                    end
                    pCol(i)       = double(matchedSeed.P);
                    rCol(i)       = double(matchedSeed.R);
                    gridValCol(i) = double(matchedSeed.Value);
                    if isfield(matchedSeed, "Area"),  areaCol(i)  = double(matchedSeed.Area); end
                    if isfield(matchedSeed, "Saddle"),saddleCol(i)= double(matchedSeed.Saddle); end
                    if isfield(matchedSeed, "Depth"), depthCol(i) = double(matchedSeed.Depth); end
                else
                    tagCol(i) = sprintf("Seed #%d", i);
                end

                % Compute territorial bounds from labels mask
                mask = labels == thisId;
                if any(mask, 'all')
                    [rIdxs, pIdxs] = find(mask);
                    pMinCol(i) = min(pAx_nm(pIdxs));
                    pMaxCol(i) = max(pAx_nm(pIdxs));
                    rMinCol(i) = min(rAx_nm(rIdxs));
                    rMaxCol(i) = max(rAx_nm(rIdxs));
                    if areaCol(i) == 0
                        areaCol(i) = numel(rIdxs);
                    end
                end
            end

            % Ensure polygons struct matches expected schema
            polygons = struct('BasinId', {}, 'P_nm', {}, 'R_nm', {});
            if isfield(basinMap, "polygons") && ~isempty(basinMap.polygons)
                polygons = basinMap.polygons;
            end

            basinsStruct = struct( ...
                'basinId',      bIdCol, ...
                'tag',          tagCol, ...
                'period',       pCol, ...
                'radius',       rCol, ...
                'gridValue',    gridValCol, ...
                'area',         areaCol, ...
                'saddle',       saddleCol, ...
                'depth',        depthCol, ...
                'pMin',         pMinCol, ...
                'pMax',         pMaxCol, ...
                'rMin',         rMinCol, ...
                'rMax',         rMaxCol, ...
                'masterMetric', metricCol, ...
                'polygons',     polygons, ...
                'labels',       uint32(labels), ...
                'pAxis_nm',     pAx_nm, ...
                'rAxis_nm',     rAx_nm ...
            );

            obj.session.db.Basins = basinsStruct;
            obj.session.dbDirty = true;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.db = obj.session.db;
                obj.fig.UserData.dbDirty = true;
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                    obj.fig.UserData.app.markDbDirty();
                end
            end

            obj.sendToHTML("BasinsSaved", struct( ...
                "count", nB, ...
                "masterMetric", masterMetric, ...
                "message", sprintf("%d basins saved to database (master metric: %s).", nB, masterMetric)));
            obj.refreshDbState();
        end

        function loadBasinsFromDb(obj, ~)
        % LOADBASINSFROMDB Load saved modal basins from session.db.Basins into controller and UI.
            db_ = obj.session.db;
            if (~isfield(db_, "Basins") || ~isstruct(db_.Basins) || ~isfield(db_.Basins, "basinId") || isempty(db_.Basins.basinId)) && ...
               (~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "db") && ...
                isfield(obj.fig.UserData.db, "Basins") && isfield(obj.fig.UserData.db.Basins, "basinId") && ...
                ~isempty(obj.fig.UserData.db.Basins.basinId))
                obj.session.db.Basins = obj.fig.UserData.db.Basins;
                db_ = obj.session.db;
            end

            % Check disk candidate files if still empty
            if ~isfield(db_, "Basins") || ~isstruct(db_.Basins) || ~isfield(db_.Basins, "basinId") || isempty(db_.Basins.basinId)
                candidates = [
                    string(obj.session.dbFile), ...
                    string(fullfile(obj.session.workDir, "database.mat")), ...
                    string(fullfile(obj.session.workDir, "Data", "Data Analysis", "database.mat")), ...
                    string(fullfile(obj.session.workDir, "..", "Data", "Data Analysis", "database.mat")), ...
                    string(fullfile(fileparts(obj.session.workDir), "Data", "Data Analysis", "database.mat"))
                ];
                for k = 1:numel(candidates)
                    cf = candidates(k);
                    if strlength(cf) > 0 && isfile(cf)
                        try
                            loaded = load(cf, "db");
                            if isfield(loaded, "db") && isfield(loaded.db, "Basins") && ...
                               isfield(loaded.db.Basins, "basinId") && ~isempty(loaded.db.Basins.basinId)
                                obj.session.db.Basins = loaded.db.Basins;
                                db_ = obj.session.db;
                                break;
                            end
                        catch
                        end
                    end
                end
            end

            if ~isfield(db_, "Basins") || ~isstruct(db_.Basins) || ~isfield(db_.Basins, "basinId") || isempty(db_.Basins.basinId)
                obj.sendError("No saved basins found in database. Detect and Save Basins first.");
                return;
            end

            bStruct = db_.Basins;
            bIds = double(bStruct.basinId(:));
            nB = numel(bIds);

            % Rebuild basinMap struct
            basinMap = struct();
            basinMap.basinIds = bIds;
            basinMap.labels = double(bStruct.labels);
            basinMap.pAxis_nm = double(bStruct.pAxis_nm(:)');
            basinMap.rAxis_nm = double(bStruct.rAxis_nm(:)');
            basinMap.pAxis = basinMap.pAxis_nm * 1e-3; % um
            basinMap.rAxis = basinMap.rAxis_nm * 1e-3; % um
            basinMap.polygons = bStruct.polygons;
            basinMap.values = [];
            if isfield(bStruct, "gridValue"), basinMap.peakValue = double(bStruct.gridValue); end
            if isfield(bStruct, "saddle"),    basinMap.saddle = double(bStruct.saddle); end
            if isfield(bStruct, "depth"),     basinMap.depth = double(bStruct.depth); end

            % Build seed objects for the HTML table
            seeds = cell(nB, 1);
            for i = 1:nB
                tStr = "Seed #" + i;
                if isfield(bStruct, "tag") && numel(bStruct.tag) >= i && strlength(string(bStruct.tag(i))) > 0
                    tStr = string(bStruct.tag(i));
                end
                s = struct( ...
                    "Index", i, ...
                    "Tag", tStr, ...
                    "P", double(bStruct.period(i)), ...
                    "R", double(bStruct.radius(i)), ...
                    "Value", double(bStruct.gridValue(i)), ...
                    "Area", double(bStruct.area(i)), ...
                    "Depth", double(bStruct.depth(i)), ...
                    "Saddle", double(bStruct.saddle(i)), ...
                    "BasinId", double(bIds(i)), ...
                    "Status", "saved");
                seeds{i} = s;
            end
            seedsVec = [seeds{:}];

            baseMetric = obj.getOptimizeState("baseMetric");
            if isempty(baseMetric), baseMetric = "EF_vol"; end
            metricVariant = obj.getOptimizeState("metricVariant");
            if isempty(metricVariant), metricVariant = "avg"; end

            lastRes = obj.getOptimizeState("lastResults");
            if isempty(lastRes)
                lastRes = obj.getOptimizeState("previewResults");
            end
            if ~isempty(lastRes) && isfield(lastRes, "metrics") && ~isempty(lastRes.metrics) && isstruct(lastRes.metrics{1})
                try
                    lastRes.metrics{1}.basinMap = basinMap;
                    obj.updateOptimizeState("lastResults", lastRes);
                catch
                end
            end

            masterMetric = "unknown";
            if isfield(bStruct, "masterMetric") && ~isempty(bStruct.masterMetric)
                masterMetric = string(bStruct.masterMetric(1));
            end

            % Update controller state with persistent flag so storedBasinMap allows metric decoupling
            obj.updateOptimizeState("basinMap", basinMap);
            obj.updateOptimizeState("basinMapMeta", struct( ...
                "metric", masterMetric, ...
                "variant", "avg", ...
                "sensitivity", NaN, ...
                "pLimits", [min(basinMap.pAxis_nm) max(basinMap.pAxis_nm)], ...
                "rLimits", [min(basinMap.rAxis_nm) max(basinMap.rAxis_nm)], ...
                "isFromDbBasins", true, ...
                "isUserMerged", true));
            obj.updateOptimizeState("currentSeeds", seedsVec);

            % Re-plot heatmap if axes and results are present
            ax = obj.getAxes();
            if ~isempty(lastRes) && ~isempty(ax) && isvalid(ax)
                try
                    delete(allchild(ax));
                    plotOptimizeHeatmap(lastRes, baseMetric, metricVariant, ax, [], seedsVec, [], false, basinMap);
                catch ME_plot
                    fprintf("[OptimizeController] Re-plot loaded basins warning: %s\n", ME_plot.message);
                end
            end

            obj.sendToHTML("SeedsFound", seedsVec);
            obj.sendToHTML("BasinsLoaded", struct( ...
                "count", nB, ...
                "masterMetric", masterMetric, ...
                "message", sprintf("Loaded %d basins from database (defined under metric: %s).", nB, masterMetric)));
        end

        function sendDbOptimaToPanel(obj)
        % SENDDBOPTIMATOPANEL Stream DB optima list to HTML table.
            db_ = obj.session.db;

            % 1. Sync from fig.UserData.db if session.db is empty
            if (~isfield(db_, "Optima") || ~isstruct(db_.Optima) || ~isfield(db_.Optima, "period") || isempty(db_.Optima.period)) && ...
               (~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "db") && ...
                isfield(obj.fig.UserData.db, "Optima") && isfield(obj.fig.UserData.db.Optima, "period") && ...
                ~isempty(obj.fig.UserData.db.Optima.period))
                obj.session.db.Optima = obj.fig.UserData.db.Optima;
                db_ = obj.session.db;
            end

            % 2. Auto-load from disk candidates if still empty
            if ~isfield(db_, "Optima") || ~isstruct(db_.Optima) || ~isfield(db_.Optima, "period") || isempty(db_.Optima.period)
                candidates = [
                    string(obj.session.dbFile), ...
                    string(fullfile(obj.session.workDir, "database.mat")), ...
                    string(fullfile(obj.session.workDir, "Data", "Data Analysis", "database.mat")), ...
                    string(fullfile(obj.session.workDir, "..", "Data", "Data Analysis", "database.mat")), ...
                    string(fullfile(fileparts(obj.session.workDir), "Data", "Data Analysis", "database.mat"))
                ];
                if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "workDir")
                    candidates(end+1) = string(fullfile(obj.fig.UserData.workDir, "database.mat")); %#ok<AGROW>
                    candidates(end+1) = string(fullfile(obj.fig.UserData.workDir, "Data", "Data Analysis", "database.mat")); %#ok<AGROW>
                    candidates(end+1) = string(fullfile(obj.fig.UserData.workDir, "..", "Data", "Data Analysis", "database.mat")); %#ok<AGROW>
                end
                for k = 1:numel(candidates)
                    cf = candidates(k);
                    if strlength(cf) > 0 && isfile(cf)
                        try
                            loaded = load(cf, "db");
                            if isfield(loaded, "db") && isfield(loaded.db, "Optima") && ...
                               isfield(loaded.db.Optima, "period") && ~isempty(loaded.db.Optima.period)
                                obj.session.db.Optima = loaded.db.Optima;
                                if strlength(obj.session.dbFile) == 0
                                    obj.session.dbFile = cf;
                                end
                                if ~isempty(obj.fig) && isvalid(obj.fig)
                                    obj.fig.UserData.db.Optima = loaded.db.Optima;
                                    if isfield(obj.fig.UserData, "dbFile") && strlength(obj.fig.UserData.dbFile) == 0
                                        obj.fig.UserData.dbFile = cf;
                                    end
                                end
                                db_ = obj.session.db;
                                break;
                            end
                        catch
                        end
                    end
                end
            end

            if ~isfield(db_, "Optima") || ~isstruct(db_.Optima) || ~isfield(db_.Optima, "period") || isempty(db_.Optima.period)
                obj.sendToHTML("DbOptimaData", struct("optima", {cell(0, 1)}));
                return;
            end

            n = numel(db_.Optima.period);
            optimaList = cell(n, 1);
            for i = 1:n
                tagVal = "";
                if isfield(db_.Optima, "basinTag") && numel(db_.Optima.basinTag) >= i
                    tagVal = string(db_.Optima.basinTag(i));
                end
                metricVal = "";
                if isfield(db_.Optima, "optimizedMetric") && numel(db_.Optima.optimizedMetric) >= i
                    metricVal = string(db_.Optima.optimizedMetric(i));
                end
                optimaList{i} = struct( ...
                    "index", i, ...
                    "tag", tagVal, ...
                    "basinTag", tagVal, ...
                    "metric", metricVal, ...
                    "optimizedMetric", metricVal, ...
                    "p", double(db_.Optima.period(i)), ...
                    "period", double(db_.Optima.period(i)), ...
                    "r", double(db_.Optima.radius(i)), ...
                    "radius", double(db_.Optima.radius(i)));
            end

            obj.sendToHTML("DbOptimaData", struct("optima", {optimaList}));
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

            fns = fieldnames(db_.Optima);
            for f = 1:numel(fns)
                if numel(db_.Optima.(fns{f})) == numel(keep)
                    db_.Optima.(fns{f}) = db_.Optima.(fns{f})(keep);
                end
            end

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
                tagVal = "";
                if isfield(db_.Optima, "basinTag") && numel(db_.Optima.basinTag) >= i
                    tagVal = string(db_.Optima.basinTag(i));
                end
                seeds{k} = struct( ...
                    "Tag", tagVal, ...
                    "P", double(db_.Optima.period(i)), ...
                    "R", double(db_.Optima.radius(i)), ...
                    "Value", NaN);
            end

            obj.sendToHTML("SeedsUpdated", struct("seeds", {seeds}));
            obj.updateSeeds(struct("seeds", {seeds}));
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
        % EXPORTRESULTS Export optima list and values to MAT or CSV.
            seeds = [];
            if isfield(d, "seeds") && ~isempty(d.seeds)
                seeds = d.seeds;
            end
            if isempty(seeds)
                seeds = obj.getOptimizeState("currentSeeds");
            end
            if isempty(seeds)
                seeds = obj.getOptimizeState("refinedOptima");
            end

            lastRes = obj.getOptimizeState("lastResults");
            if isempty(lastRes)
                lastRes = obj.getOptimizeState("previewResults");
            end

            if isempty(seeds) && ~isempty(lastRes) && isfield(lastRes, "optima") && ~isempty(lastRes.optima)
                seeds = lastRes.optima;
            end

            if isempty(seeds)
                obj.sendError("No optima available to export. Initialize or fine-tune seeds first.");
                obj.sendToHTML("ExportCanceled", struct());
                return;
            end

            seedsNorm = normalizeSeedInput(seeds);
            if isempty(seedsNorm)
                obj.sendError("No valid optima found to export.");
                obj.sendToHTML("ExportCanceled", struct());
                return;
            end

            baseMetric = obj.safeStr(d, "metric", "");
            if baseMetric == "", baseMetric = obj.getOptimizeState("baseMetric"); end
            if isempty(baseMetric) || baseMetric == "", baseMetric = "EF_vol"; end

            metricVariant = obj.safeStr(d, "metricVariant", "");
            if metricVariant == "", metricVariant = obj.getOptimizeState("metricVariant"); end
            if isempty(metricVariant) || metricVariant == "", metricVariant = "avg"; end

            laserWl = obj.safeNum(d, "laserWavelength", 785);

            % Re-evaluate metric values if missing
            needsEval = any(arrayfun(@(s) ~isfield(s, "Value") || ~isfinite(s.Value), seedsNorm));
            if needsEval && ~isempty(lastRes)
                try
                    if ~isfield(lastRes, "cfg") || ~isstruct(lastRes.cfg)
                        lastRes.cfg = struct();
                    end
                    lastRes.cfg.metricVariant = metricVariant;
                    vals = evaluateMetricAtPoints(lastRes, baseMetric, seedsNorm);
                    for i = 1:numel(seedsNorm)
                        if (~isfield(seedsNorm(i), "Value") || ~isfinite(seedsNorm(i).Value)) && ...
                                i <= numel(vals) && isfinite(vals(i))
                            seedsNorm(i).Value = vals(i);
                        end
                    end
                catch
                end
            end

            % Resolve export format: support both exportFormat (UI) and format (API/tests)
            exportFmt = "";
            if isfield(d, "exportFormat"), exportFmt = lower(string(d.exportFormat)); end
            if exportFmt == "" && isfield(d, "format"), exportFmt = lower(string(d.format)); end
            if exportFmt == "", exportFmt = "mat"; end

            exportPath = "";
            if isfield(d, "path") && strlength(string(d.path)) > 0
                exportPath = string(d.path);
            else
                defaultName = "optima_results." + exportFmt;
                filterStr = "*." + exportFmt;
                [file, path] = uiputfile(filterStr, "Export Optima Results", ...
                    fullfile(obj.session.workDir, defaultName));
                if isequal(file, 0) || isequal(path, 0)
                    obj.sendToHTML("ExportCanceled", struct());
                    return;
                end
                exportPath = string(fullfile(path, file));
            end

            if exportPath == ""
                obj.sendToHTML("ExportCanceled", struct());
                return;
            end

            % Construct clean optima table
            nRows = numel(seedsNorm);
            Tag = strings(nRows, 1);
            Period_nm = zeros(nRows, 1);
            Radius_nm = zeros(nRows, 1);
            MetricName = repmat(string(baseMetric), nRows, 1);
            MetricVariant = repmat(string(metricVariant), nRows, 1);
            MetricValue = NaN(nRows, 1);
            LaserWavelength_nm = repmat(double(laserWl), nRows, 1);

            for i = 1:nRows
                s = seedsNorm(i);
                if isfield(s, "Tag") && strlength(string(s.Tag)) > 0
                    Tag(i) = string(s.Tag);
                else
                    Tag(i) = "Optimum " + string(i);
                end
                Period_nm(i) = double(s.P);
                Radius_nm(i) = double(s.R);
                if isfield(s, "Value") && isfinite(s.Value)
                    MetricValue(i) = double(s.Value);
                end
            end

            optimaTable = table(Tag, Period_nm, Radius_nm, MetricName, MetricVariant, ...
                MetricValue, LaserWavelength_nm);

            if exportFmt == "csv"
                writetable(optimaTable, exportPath);
            else
                optima = table2struct(optimaTable);
                save(exportPath, "optima", "optimaTable");
            end

            obj.sendToHTML("ExportComplete", struct("path", exportPath, "count", nRows));
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
            rMax = obj.safeNum(d, "radiusMax", 700);
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

        function updateOptimizeState(obj, key, val)
        % UPDATEOPTIMIZESTATE Store state value in local state and fig.UserData.
            obj.localOptimizeState.(key) = val;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if ~isfield(obj.fig.UserData, "optimize")
                    obj.fig.UserData.optimize = struct();
                end
                obj.fig.UserData.optimize.(key) = val;
            end
        end

        function val = getOptimizeState(obj, key)
        % GETOPTIMIZESTATE Retrieve state value from fig.UserData or local state.
            val = [];
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "optimize")
                if isfield(obj.fig.UserData.optimize, key)
                    val = obj.fig.UserData.optimize.(key);
                    return;
                end
            end
            if isfield(obj.localOptimizeState, key)
                val = obj.localOptimizeState.(key);
            end
        end

        function bm = storedBasinMap(obj, baseMetric, metricVariant, sensitivity, pLimits, rLimits)
        % STOREDBASINMAP Basin map from seed initialisation if it matches the
        % current metric, variant, sensitivity and bounds; [] otherwise.
            bm = struct([]);
            stored = obj.getOptimizeState("basinMap");
            meta = obj.getOptimizeState("basinMapMeta");
            if isempty(stored) || ~isstruct(stored) || isempty(meta) || ~isstruct(meta)
                return;
            end
            % If basin map was loaded from db.Basins, allow cross-metric optimization reuse
            if isfield(meta, "isFromDbBasins") && meta.isFromDbBasins
                bm = stored;
                return;
            end
            same = meta.metric == string(baseMetric) && meta.variant == string(metricVariant) ...
                && (abs(meta.sensitivity - sensitivity) < 1e-12 || (isfield(meta, "isUserMerged") && meta.isUserMerged)) ...
                && isequal(meta.pLimits, pLimits) && isequal(meta.rLimits, rLimits);
            if same
                bm = stored;
            end
        end

        function sendPredictionBounds(obj)
        % SENDPREDICTIONBOUNDS Send period and radius bounds from db.Pred to HTML.
            predData = [];
            if isfield(obj.session.db, "Pred") && isstruct(obj.session.db.Pred) && structRowCount(obj.session.db.Pred) > 0
                predData = obj.session.db.Pred;
            elseif ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "db") ...
                    && isfield(obj.fig.UserData.db, "Pred") && structRowCount(obj.fig.UserData.db.Pred) > 0
                predData = obj.fig.UserData.db.Pred;
            end
            if isempty(predData)
                [~, ~, ~, predFile] = obj.resolvePaths();
                if strlength(predFile) > 0 && isfile(predFile)
                    loaded = load(predFile);
                    if isfield(loaded, "allData"), predData = loaded.allData;
                    elseif isfield(loaded, "predictions"), predData = loaded.predictions;
                    elseif isfield(loaded, "db") && isfield(loaded.db, "Pred"), predData = loaded.db.Pred;
                    end
                end
            end
            if isstruct(predData) && isfield(predData, "period") && isfield(predData, "radius") && ~isempty(predData.period)
                obj.sendToHTML("DataBounds", struct( ...
                    "periodMin", min(predData.period), "periodMax", max(predData.period), ...
                    "radiusMin", min(predData.radius), "radiusMax", max(predData.radius)));
            end
        end
    end

    %% Internal Helpers
    methods (Access = private)
        function previewPrecomputedPredictions(obj, d, baseMetric, metricVariant, rep)
        % PREVIEWPRECOMPUTEDPREDICTIONS Fast preview of existing db.Pred without new predictions.
            rep.info("Loading pre-computed predictions from db.Pred...");

            % Sync db.Pred from fig.UserData if needed
            if (~isfield(obj.session.db, "Pred") || structRowCount(obj.session.db.Pred) == 0) && ...
               (~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "db") && ...
                isfield(obj.fig.UserData.db, "Pred") && structRowCount(obj.fig.UserData.db.Pred) > 0)
                obj.session.db.Pred = obj.fig.UserData.db.Pred;
            end

            % If still missing, check predictionFile on disk
            if ~isfield(obj.session.db, "Pred") || structRowCount(obj.session.db.Pred) == 0
                [~, ~, ~, predictionFile] = obj.resolvePaths();
                if strlength(predictionFile) > 0 && isfile(predictionFile)
                    loaded = load(predictionFile);
                    if isfield(loaded, "allData"), obj.session.db.Pred = loaded.allData;
                    elseif isfield(loaded, "predictions"), obj.session.db.Pred = loaded.predictions;
                    elseif isfield(loaded, "db") && isfield(loaded.db, "Pred"), obj.session.db.Pred = loaded.db.Pred;
                    else, obj.session.db.Pred = loaded;
                    end
                    if ~isempty(obj.fig) && isvalid(obj.fig)
                        obj.fig.UserData.db.Pred = obj.session.db.Pred;
                    end
                end
            end

            if ~isfield(obj.session.db, "Pred") || structRowCount(obj.session.db.Pred) == 0
                obj.sendError("No pre-computed predictions found in database (db.Pred). Please generate or load predictions first.");
                return;
            end

            allData = extractBranchAsSoA(obj.session.db, "Pred");

            laserWl = obj.safeNum(d, "laserWavelength", 785);
            allData = obj.ensureDerivedMetricSlice(allData, baseMetric, metricVariant, laserWl);

            if metricVariant == "weighted" || metricVariant == "analyte"
                variantForField = "analyte";
            elseif metricVariant == "laser"
                variantForField = "laser";
            elseif metricVariant == "broad" || metricVariant == "broadband"
                variantForField = "broad";
            else
                variantForField = "avg";
            end
            avgFieldName = resolveDerivedMetricField(baseMetric, variantForField, allData);

            if ~isfield(allData, avgFieldName)
                obj.sendError(sprintf("Metric '%s' (%s) not found in db.Pred.", baseMetric, metricVariant));
                return;
            end

            % Construct preview results struct
            results = struct();
            results.allData = allData;
            results.metricName = baseMetric;
            results.metricVariant = metricVariant;
            if isfield(allData, "period")
                results.pSamples = unique(allData.period(:)') * 1e-3;
            else
                results.pSamples = [];
            end
            if isfield(allData, "radius")
                results.rSamples = unique(allData.radius(:)') * 1e-3;
            else
                results.rSamples = [];
            end
            if isfield(allData, "lambda") && ~isempty(allData.lambda)
                lamVals = allData.lambda(1, :);
                if max(lamVals) > 50, lamVals = lamVals * 1e-3; end
                results.lambdaSamples = lamVals;
            else
                results.lambdaSamples = [];
            end

            previewMetricEntry = struct( ...
                "metricName", baseMetric, ...
                "candidateTable", table(), ...
                "maximaResults", table(), ...
                "lambdaSamples", results.lambdaSamples);
            results.metrics = {previewMetricEntry};

            % Update session/app state
            obj.updateOptimizeState("previewResults", results);
            obj.updateOptimizeState("lastResults", results);
            obj.updateOptimizeState("config", d);
            obj.updateOptimizeState("basinMap", []);

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

            if isfield(allData, "period") && isfield(allData, "radius") && ~isempty(allData.period)
                obj.sendToHTML("DataBounds", struct( ...
                    "periodMin", min(allData.period), "periodMax", max(allData.period), ...
                    "radiusMin", min(allData.radius), "radiusMax", max(allData.radius)));
            end

            obj.sendToHTML("PreviewComplete", struct("metric", baseMetric, "variant", metricVariant));
            rep.complete("Preview", sprintf("Loaded %d pre-computed points from db.Pred. Heatmap preview ready.", structRowCount(allData)));
        end

        function allData = ensureDerivedMetricSlice(obj, allData, baseMetric, metricVariant, laserWl)
        % ENSUREDERIVEDMETRICSLICE Derive required 2D metric slice on the fly if missing.
            if nargin < 5 || isempty(laserWl)
                laserWl = 785;
            end

            if metricVariant == "weighted" || metricVariant == "analyte"
                variantForField = "analyte";
            elseif metricVariant == "laser"
                variantForField = "laser";
            elseif metricVariant == "broad" || metricVariant == "broadband"
                variantForField = "broad";
            else
                variantForField = "avg";
            end

            avgFieldName = resolveDerivedMetricField(baseMetric, variantForField, allData);

            specField = baseMetric;
            if ~isfield(allData, specField)
                aliasMap = struct("EE_V","EF_vol", "EF_vol","EE_V", ...
                                  "EE_S","EF_surf", "EF_surf","EE_S", ...
                                  "Abs","Absorptance", "Absorptance","Abs", ...
                                  "ECC","ECCheck", "ECCheck","ECC");
                if isfield(aliasMap, char(baseMetric)) && isfield(allData, aliasMap.(char(baseMetric)))
                    specField = string(aliasMap.(char(baseMetric)));
                end
            end

            if ~isfield(allData, avgFieldName) && isfield(allData, specField)
                specMat = double(allData.(specField));
                if variantForField == "laser"
                    if isfield(allData, "LaserWl") && isscalar(allData.LaserWl)
                        laserWl = double(allData.LaserWl);
                    elseif isfield(allData, "LaserWavelength") && isscalar(allData.LaserWavelength)
                        laserWl = double(allData.LaserWavelength);
                    end
                    if isfield(allData, "lambda") && ~isempty(allData.lambda)
                        lamVec = allData.lambda(1, :);
                        if max(lamVec) < 50, lamVec = lamVec * 1e3; end % um -> nm
                        [~, lIdx] = min(abs(lamVec - laserWl));
                    else
                        lIdx = 1;
                    end
                    allData.(avgFieldName) = specMat(:, lIdx);
                elseif variantForField == "avg" || variantForField == "broad"
                    allData.(avgFieldName) = mean(specMat, 2, "omitnan");
                elseif variantForField == "analyte"
                    analyteSpec = [];
                    try
                        analyteSpec = getDefaultAnalyteSpectrum();
                    catch
                    end
                    if isstruct(analyteSpec) && isfield(analyteSpec, "shift_cm") && isfield(allData, "RamanShift")
                        shifts = allData.RamanShift(:)';
                        aw = interp1(analyteSpec.shift_cm(:), analyteSpec.intensity(:), shifts, "makima", 0);
                        aw = max(0, aw);
                        if sum(aw) > 0
                            weights = aw / sum(aw);
                            allData.(avgFieldName) = specMat * weights(:);
                        else
                            allData.(avgFieldName) = mean(specMat, 2, "omitnan");
                        end
                    else
                        allData.(avgFieldName) = mean(specMat, 2, "omitnan");
                    end
                end
            end
        end

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
                end
            end
            obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
            obj.sendToHTML("OptimizeStopped", msg);
            obj.sendToHTML("ProcessStopped", msg);
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
