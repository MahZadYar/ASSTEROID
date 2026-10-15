function results = runLocalizationWorkflow(cfg, reporter)
    % runLocalizationWorkflow  Orchestrate maxima localization via MultiStart.
    %
    %   results = runLocalizationWorkflow(cfg) runs the complete maxima search
    %   workflow using the configuration struct produced by localizeMaximaConfig.
    %   Supports two modes via cfg.dataSource:
    %     - "model": DNN-based prediction and continuous MultiStart refinement
    %     - "interpolation": makima interpolation from raw data with optional
    %       continuous refinement or discrete-only results
    %
    %   For each configured metric, the workflow:
    %     1. Builds a predictor (DNN or interpolation)
    %     2. Loads or generates dense predictions on the grid
    %     3. Analyses the averaged metric grid (gradient, Laplacian, divergence)
    %     4. Detects candidate maxima with configurable filtering
    %     5. Refines candidates via localised MultiStart optimisation (unless
    %        cfg.discreteOnly = true)
    %     6. Returns structured results for visualisation by the caller
    %
    %   results = runLocalizationWorkflow(cfg, reporter) uses the supplied
    %   ProgressReporter for status feedback (console, uihtml, or silent).
    %
    %   Input:
    %       cfg      — Configuration struct from localizeMaximaConfig
    %       reporter — (optional) ProgressReporter instance
    %
    %   Output:
    %       results — struct with fields:
    %           metrics     {1×M} cell of per-metric result structs, each with:
    %               .metricName      string — Canonical metric name
    %               .candidateTable  table  — Detected grid candidates
    %               .maximaResults   table  — Refined MultiStart maxima
    %               .avgMetricGrid   [Nr×Np] — Averaged metric on grid
    %               .pSamples        [1×Np] — Period vector (µm)
    %               .rSamples        [1×Nr] — Radius vector (µm)
    %               .lambdaSamples   [1×Nl] — Wavelength vector (µm)
    %               .msSolutions     — MultiStart OptimSolution array
    %               .msOutput        — MultiStart diagnostics struct
    %           allData     struct — SoA prediction data
    %           predictor   struct — Predictor used (model or interpolation)
    %           model       struct — Loaded model (empty if interpolation mode)
    %           ri          struct — Loaded refractive index (empty if interpolation mode)
    %           cfg         struct — Configuration used (for reproducibility)
    %           elapsedTotal double — Total wall-clock time (seconds)
    %
    %   Example (CLI — model mode):
    %       cfg = localizeMaximaConfig( ...
    %           ModelFile="sers_model.mat", RiCsvFile="McPeak.csv", ...
    %           PLimits=[850, 920], RLimits=[70, 430]);
    %       results = runLocalizationWorkflow(cfg, ProgressReporter.console());
    %
    %   Example (CLI — interpolation mode):
    %       cfg = localizeMaximaConfig( ...
    %           DataSource="interpolation", DataFile="prl_sweep.mat", ...
    %           PLimits=[850, 920], RLimits=[70, 430], DiscreteOnly=true);
    %       results = runLocalizationWorkflow(cfg, ProgressReporter.console());
    %
    %   See also: localizeMaximaConfig, ProgressReporter, find_local_maxima,
    %             createModelPredictor, createDataPredictor, buildPredictorFromConfig

    arguments
        cfg (1,1) struct
        reporter = ProgressReporter.silent()
    end

    totalTimer = tic;

    %% Resolve data source (backward compat: default to "model")
    dataSource = "model";
    if isfield(cfg, "dataSource")
        dataSource = string(cfg.dataSource);
    end
    discreteOnly = false;
    if isfield(cfg, "discreteOnly")
        discreteOnly = cfg.discreteOnly;
    end

    %% Resolve metric variant (laser / avg / weighted)
    metricVariant = "avg";
    if isfield(cfg, "metricVariant")
        metricVariant = string(cfg.metricVariant);
    end

    % For weighted variant: load default analyte spectrum once
    analyteSpec = struct();
    if metricVariant == "weighted"
        try
            analyteSpec = getDefaultAnalyteSpectrum();
        catch ae
            reporter.warn("AnalyteSpectrum", sprintf( ...
                "Could not load default analyte spectrum (%s). Weighted avg will use uniform weighting.", ae.message));
        end
    end

    %% Step 1: Build predictor
    if isfield(cfg, "predictor") && ~isempty(cfg.predictor)
        predictor = cfg.predictor;
        reporter.info("[runLocalizationWorkflow] Reusing existing predictor.");
    else
        predictor = buildPredictorFromConfig(cfg, Reporter=reporter);
    end

    % Extract model/ri for backward-compatible results struct
    model = [];
    ri = [];
    if isfield(predictor, "mode") && predictor.mode == "model"
        if isfield(predictor, "model"), model = predictor.model; end
        if isfield(predictor, "ri"), ri = predictor.ri; end
    end

    %% Step 2: Load or generate dense predictions
    gp = cfg.gridParams;

    % skipGridGeneration: set externally on cfg when manual seeds are provided
    % and grid generation is not needed (refine-only path). allData may be
    % supplied in cfg.cachedAllData for downstream visualisation.
    skipGrid = isfield(cfg, 'skipGridGeneration') && logical(cfg.skipGridGeneration);

    hasCandidates = isfield(cfg, 'initialCandidates') && istable(cfg.initialCandidates) ...
        && height(cfg.initialCandidates) > 0;

    if skipGrid && hasCandidates
        % Refine-only: skip grid generation entirely.
        % Use cached allData if provided, otherwise build a minimal placeholder.
        if isfield(cfg, 'cachedAllData') && isstruct(cfg.cachedAllData) ...
                && isfield(cfg.cachedAllData, 'period')
            allData = cfg.cachedAllData;
            reporter.info("[runLocalizationWorkflow] Using cached allData (no grid regeneration).");
        else
            % Minimal placeholder: two corner points so downstream code has
            % a valid SoA struct. The per-metric grid check will be skipped
            % because initialCandidates bypasses reshapeSoAToVolume.
            allData = struct();
            allData.period = cfg.pLimits(:) * 1;   % [2×1] nm
            allData.radius = cfg.rLimits(:) * 1;
            allData.lambda = gp.lambdaSamples * 1e3; % µm→nm, [1×Nl]
        end
        if isfield(cfg, "cachedAllData") && isstruct(cfg.cachedAllData) ...
                && isfield(cfg.cachedAllData, "period") && isfield(cfg.cachedAllData, "radius") && ~isempty(cfg.cachedAllData.period)
            dataP = [min(cfg.cachedAllData.period), max(cfg.cachedAllData.period)];
            dataR = [min(cfg.cachedAllData.radius), max(cfg.cachedAllData.radius)];
            if dataSource == "predictions" || dataR(2) > cfg.rLimits(2)
                cfg.pLimits = dataP;
                cfg.rLimits = dataR;
            end
        end
        pSamples  = cfg.pLimits / 1e3;   % nm → µm
        rSamples  = cfg.rLimits / 1e3;
        lambdaSamples = gp.lambdaSamples; % already in µm
        reporter.info(sprintf("[runLocalizationWorkflow] Grid skipped. Bounds: P=[%.0f,%.0f] nm, R=[%.0f,%.0f] nm.", ...
            cfg.pLimits(1), cfg.pLimits(2), cfg.rLimits(1), cfg.rLimits(2)));
    elseif isfield(cfg, "cachedAllData") && isstruct(cfg.cachedAllData) ...
            && isfield(cfg.cachedAllData, "period") && ~isempty(cfg.cachedAllData.period)
        % Use pre-computed cached allData directly (from db.Pred or preview results)
        allData = cfg.cachedAllData;
        reporter.info("[runLocalizationWorkflow] Using cached predictions (no grid recomputation).");
    elseif dataSource == "interpolation"
        % For interpolation mode: generate dense predictions via interpolant
        reporter.start("GeneratePredictions", "Generating dense predictions via interpolation...");
        interpPredArgs = {"LaserWavelength", cfg.lambdaLaser, "RamanWindow", cfg.stokesShiftLimits};
        if metricVariant == "weighted" && ~isempty(fieldnames(analyteSpec))
            interpPredArgs = [interpPredArgs, {"AnalyteSpectrum", analyteSpec}];
        end
        allData = predictor.predictGrid(gp.pSamples, gp.rSamples, gp.lambdaSamples, interpPredArgs{:});
        reporter.complete("GeneratePredictions", sprintf( ...
            "Interpolated %d geometries × %d wavelengths.", ...
            size(allData.lambda, 1), size(allData.lambda, 2)));

        % Compute derived metrics (_laser, _avg, _analyte) for interpolation mode
        metricsWindow = cfg.stokesShiftLimits;
        if isfield(cfg, 'metricsShiftLimits') && ~isempty(cfg.metricsShiftLimits)
            metricsWindow = cfg.metricsShiftLimits;
        end
        derivedCfg = importSweepConfig( ...
            LaserWavelength=cfg.lambdaLaser, ...
            RamanWindow=metricsWindow, ...
            DetectShiftWindow=false, ...
            InterpResolution=cfg.stokesShiftResolution, ...
            SpectralInterpMethod="makima");
        [allData, ~] = recomputeDerivedMetrics(allData, derivedCfg, analyteSpec, reporter);
    elseif dataSource == "predictions"
        if isfield(cfg, "predictionFile") && strlength(cfg.predictionFile) > 0 && isfile(cfg.predictionFile)
            loaded = load(cfg.predictionFile);
            if isfield(loaded, "allData"), allData = loaded.allData;
            elseif isfield(loaded, "predictions"), allData = loaded.predictions;
            else, allData = loaded;
            end
            reporter.info("[runLocalizationWorkflow] Loaded predictions from file (no grid recomputation).");
        else
            error("runLocalizationWorkflow:NoPredictions", ...
                "DataSource='predictions' requires either cfg.cachedAllData or an existing cfg.predictionFile.");
        end
    else
        % Model mode: use existing loadOrGeneratePredictions
        modelPredArgs = { ...
            "Recompute", cfg.recomputePredictions, ...
            "PredictionFile", cfg.predictionFile, ...
            "Model", model, "Ri", ri, ...
            "PSamples", gp.pSamples, "RSamples", gp.rSamples, ...
            "LambdaSamples", gp.lambdaSamples, ...
            "LambdaLaser", cfg.lambdaLaser, ...
            "StokesShiftLimits", cfg.stokesShiftLimits, ...
            "AnalyteSpectrum", analyteSpec, ...
            "Reporter", reporter};
        if isfield(cfg, 'metricsShiftLimits') && ~isempty(cfg.metricsShiftLimits)
            modelPredArgs = [modelPredArgs, {"MetricsShiftLimits", cfg.metricsShiftLimits}];
        end
        allData = loadOrGeneratePredictions(modelPredArgs{:});
    end

    if isstruct(allData) && isfield(allData, "period") && isfield(allData, "radius") && ~isempty(allData.period)
        dataP = [min(allData.period), max(allData.period)];
        dataR = [min(allData.radius), max(allData.radius)];
        if dataSource == "predictions" || (isfield(cfg, "cachedAllData") && ~isempty(cfg.cachedAllData)) || dataR(2) > cfg.rLimits(2)
            cfg.pLimits = dataP;
            cfg.rLimits = dataR;
            reporter.info(sprintf("[runLocalizationWorkflow] Adopting data bounds: P=[%.0f, %.0f] nm, R=[%.0f, %.0f] nm.", ...
                dataP(1), dataP(2), dataR(1), dataR(2)));
        end
    end

    if ~skipGrid || ~hasCandidates
        % Extract grid vectors from SoA (in µm for model)
        pSamples = unique(allData.period(:)') * 1e-3;
        rSamples = unique(allData.radius(:)') * 1e-3;
        if isfield(allData, "lambda") && ~isempty(allData.lambda)
            lambdaSamples = allData.lambda(1, :) * 1e-3;
        else
            lambdaSamples = gp.lambdaSamples;
        end
    end

    % Compute analyte weights aligned to lambdaSamples for weighted-avg objective
    analyteWeights = [];
    if metricVariant == "weighted" && ~isempty(fieldnames(analyteSpec)) && ~isempty(lambdaSamples)
        lambdaLaser_um = cfg.lambdaLaser * 1e-3;   % nm → µm
        shiftVec_cm = max(0, 1e4/lambdaLaser_um - 1e4./lambdaSamples(:));  % cm⁻¹
        wRaw = interp1(double(analyteSpec.shift_cm(:)), double(analyteSpec.intensity(:)), ...
            shiftVec_cm, 'linear', 0);
        wRaw = max(0, wRaw);
        wSum = sum(wRaw);
        if wSum > 0
            analyteWeights = wRaw / wSum;
        end
    end

    %% Step 3: Prepare common parameters
    if ~isfield(cfg, "fminconAlgorithm")
        cfg.fminconAlgorithm = "interior-point";
    end
    if ~isfield(cfg, "maxFunctionEvaluations")
        cfg.maxFunctionEvaluations = 1e4;
    end
    if ~isfield(cfg, "constraintTolerance")
        cfg.constraintTolerance = cfg.functionTolerance;
    end
    if ~isfield(cfg, "optimalityTolerance")
        cfg.optimalityTolerance = cfg.functionTolerance;
    end
    if ~isfield(cfg, "basinRetryCount")
        cfg.basinRetryCount = 4;
    end
    if ~isfield(cfg, "basinRetryShrinkFactor")
        cfg.basinRetryShrinkFactor = 0.5;
    end
    if ~isfield(cfg, "keepRejectedSeeds")
        cfg.keepRejectedSeeds = true;
    end

    ratioLowerVal = cfg.ratioLimit(1);
    ratioUpperVal = cfg.ratioLimit(2);
    if ratioUpperVal == 0
        ratioUpperVal = inf;
    end

    pBounds = [min(pSamples), max(pSamples)];
    rBounds = [min(rSamples), max(rSamples)];

    destinationPad = 0;
    if isfield(cfg, 'destinationBoundPadding') && isfinite(cfg.destinationBoundPadding)
        destinationPad = max(0, double(cfg.destinationBoundPadding));
    end
    if destinationPad > 0
        pBounds = [pBounds(1) - destinationPad, pBounds(2) + destinationPad];
        rBounds = [rBounds(1) - destinationPad, rBounds(2) + destinationPad];
    end

    %% Step 4: Process each metric
    numMetrics = numel(cfg.metricsToLocate);
    metricResults = cell(1, numMetrics);

    for metricIdx = 1:numMetrics
        primaryMetric = cfg.metricsToLocate{metricIdx};
        if metricVariant == "weighted"
            metricFieldVariant = "analyte";
        elseif metricVariant == "laser"
            metricFieldVariant = "laser";
        else
            metricFieldVariant = "avg";
        end
        primaryMetricAvgField = char(resolveDerivedMetricField(primaryMetric, metricFieldVariant, allData));
        candidateField = primaryMetricAvgField;

        % Ensure candidate field exists in allData (derive on the fly if missing)
        if ~isfield(allData, candidateField) && isfield(allData, primaryMetric)
            specMat = double(allData.(primaryMetric));
            if metricFieldVariant == "laser"
                laserWl = cfg.lambdaLaser;
                if isfield(allData, "LaserWl") && isscalar(allData.LaserWl)
                    laserWl = double(allData.LaserWl);
                elseif isfield(allData, "LaserWavelength") && isscalar(allData.LaserWavelength)
                    laserWl = double(allData.LaserWavelength);
                end
                if isfield(allData, "lambda") && ~isempty(allData.lambda)
                    lamVec = allData.lambda(1, :);
                    if max(lamVec) < 50, lamVec = lamVec * 1e3; end
                    [~, lIdx] = min(abs(lamVec - laserWl));
                else
                    lIdx = 1;
                end
                allData.(candidateField) = specMat(:, lIdx);
            elseif metricFieldVariant == "analyte"
                if isstruct(analyteSpec) && isfield(analyteSpec, "intensity") && ~isempty(analyteWeights)
                    allData.(candidateField) = specMat * analyteWeights(:);
                else
                    allData.(candidateField) = mean(specMat, 2, "omitnan");
                end
            else
                allData.(candidateField) = mean(specMat, 2, "omitnan");
            end
        end

        reporter.start("Metric_" + primaryMetric, ...
            sprintf("Processing metric %d/%d: %s", metricIdx, numMetrics, primaryMetric));

        % Convert SoA to grid for gradient analysis
        % (skipped when grid generation was bypassed — initialCandidates used directly)
        if skipGrid && hasCandidates
            avgMetricGrid = [];
            pSamplesLocal = pSamples;
            rSamplesLocal = rSamples;
        else
            [avgMetricMap, pGridVis, rGridVis, ~] = reshapeSoAToVolume( ...
                allData, candidateField, 'UnitConversion', 'none');
            avgMetricGrid = double(avgMetricMap);

            % Convert grids to µm for MultiStart
            pSamplesLocal = double(pGridVis(:)') * 1e-3;
            rSamplesLocal = double(rGridVis(:)') * 1e-3;
        end

        if ~isempty(avgMetricGrid) && ~any(isfinite(avgMetricGrid), 'all')
            reporter.warn("Metric_" + primaryMetric, ...
                sprintf("No finite samples in %s. Skipping.", candidateField));
            metricResults{metricIdx} = buildEmptyResult(primaryMetric);
            continue;
        end

        % Detect candidate maxima (or use initial set)
        useBasins = isfield(cfg, 'useWatershedBasins') && logical(cfg.useWatershedBasins);
        basinSens = 0.005;
        if isfield(cfg, 'basinSensitivity') && isfinite(cfg.basinSensitivity)
            basinSens = double(cfg.basinSensitivity);
        end
        basinMinArea = 4;
        if isfield(cfg, 'basinMinArea') && isfinite(cfg.basinMinArea)
            basinMinArea = double(cfg.basinMinArea);
        end
        basinMap = [];
        if isfield(cfg, 'initialCandidates') && ~isempty(cfg.initialCandidates)
            candidateTable = cfg.initialCandidates;
            % Verify structure
            if ~all(ismember({'P_um','R_um'}, candidateTable.Properties.VariableNames))
                 error("runLocalizationWorkflow:InvalidCandidates", ...
                     "Initial candidates must contain 'P_um' and 'R_um' columns.");
            end
             % Fill GridValue if missing (needed for sorting logic downstream)
            if ~ismember("GridValue", candidateTable.Properties.VariableNames)
                if ~isempty(avgMetricGrid)
                    candidateTable.GridValue = interp2(pSamplesLocal, rSamplesLocal, avgMetricGrid, ...
                        candidateTable.P_um, candidateTable.R_um, "nearest", NaN);
                else
                    candidateTable.GridValue = NaN(height(candidateTable), 1);
                end
            end
            % Set placeholders for fields not computed
            basePeakMask = [];
            gradMagnitude = [];
            laplacianField = [];
            divergenceField = [];

            % Basin territories for in-basin refinement: prefer the map the
            % user saw at seed initialisation; otherwise rebuild it from the
            % grid (or cached predictions in refine-only mode).
            if useBasins
                if isfield(cfg, 'basinMap') && isstruct(cfg.basinMap) && ~isempty(cfg.basinMap) ...
                        && isfield(cfg.basinMap, 'labels') && any(cfg.basinMap.labels(:) > 0)
                    basinMap = cfg.basinMap;
                    reporter.info(sprintf("  Using stored basin map (%d basins).", numel(basinMap.basinIds)));
                else
                    basinGrid = avgMetricGrid;
                    pBasin = pSamplesLocal;
                    rBasin = rSamplesLocal;
                    if isempty(basinGrid) && isfield(allData, candidateField) && numel(allData.period) > 4
                        [bMap, pGB, rGB, ~] = reshapeSoAToVolume(allData, candidateField, 'UnitConversion', 'none');
                        basinGrid = double(bMap);
                        pBasin = double(pGB(:)') * 1e-3;
                        rBasin = double(rGB(:)') * 1e-3;
                    end
                    if ~isempty(basinGrid)
                        basinGrid = localMaskToLimits(basinGrid, pBasin, rBasin, cfg);
                        wsRatio = [ratioLowerVal, ratioUpperVal];
                        if dataSource == "predictions" || (ratioLowerVal <= 0 && (isinf(ratioUpperVal) || ratioUpperVal >= 1))
                            wsRatio = [0, Inf];
                        end
                        [~, basinMap] = detect_watershed_basins(basinGrid, pBasin, rBasin, ...
                            Sensitivity=basinSens, RatioLimit=wsRatio, ...
                            MinArea=basinMinArea);
                        reporter.info(sprintf("  Rebuilt basin map from grid (%d basins, sensitivity %.2f %%).", ...
                            numel(basinMap.basinIds), 100 * basinSens));
                    else
                        reporter.warn("Metric_" + primaryMetric, ...
                            "No grid available for basin map; using radius-box refinement.");
                    end
                end
            end
        elseif useBasins
            wsRatio = [ratioLowerVal, ratioUpperVal];
            if dataSource == "predictions" || (ratioLowerVal <= 0 && (isinf(ratioUpperVal) || ratioUpperVal >= 1))
                wsRatio = [0, Inf];
            end
            [candidateTable, basinMap] = detect_watershed_basins( ...
                localMaskToLimits(avgMetricGrid, pSamplesLocal, rSamplesLocal, cfg), ...
                pSamplesLocal, rSamplesLocal, ...
                Sensitivity=basinSens, RatioLimit=wsRatio, ...
                MinArea=basinMinArea, MaxBasins=cfg.numLocalMaxima);
            basePeakMask = [];
            gradMagnitude = [];
            laplacianField = [];
            divergenceField = [];
            reporter.info(sprintf("  Watershed: %d basins (H = %.4g = %.2f %% of range, %d total in map).", ...
                height(candidateTable), basinMap.hThreshold, 100 * basinSens, ...
                numel(unique(basinMap.labels(basinMap.labels > 0)))));
        else
            [candidateTable, basePeakMask, gradMagnitude, laplacianField, divergenceField] = ...
                detect_maxima_candidates(avgMetricGrid, pSamplesLocal, rSamplesLocal, ...
                [ratioLowerVal, ratioUpperVal], cfg);
        end

        candidateCount = height(candidateTable);
        reporter.info(sprintf("  Detected %d candidate maxima from grid analysis.", candidateCount));

        %% Discrete-only mode: skip MultiStart, return top-N grid candidates
        if discreteOnly
            reporter.info(sprintf("  DiscreteOnly mode: returning top %d grid candidates.", ...
                cfg.numLocalMaxima));

            if candidateCount > 0
                numSelect = min(cfg.numLocalMaxima, candidateCount);
                maximaResults = candidateTable(1:numSelect, :);
            else
                maximaResults = table();
            end

            res = struct();
            res.metricName = primaryMetric;
            res.candidateTable = candidateTable;
            res.maximaResults = maximaResults;
            res.avgMetricGrid = avgMetricGrid;
            res.pSamples = pSamplesLocal;
            res.rSamples = rSamplesLocal;
            res.lambdaSamples = lambdaSamples;
            res.msSolutions = [];
            res.msOutput = [];
            res.gradMagnitude = gradMagnitude;
            res.laplacianField = laplacianField;
            res.divergenceField = divergenceField;
            res.basinMap = basinMap;
            metricResults{metricIdx} = res;

            reporter.complete("Metric_" + primaryMetric, ...
                sprintf("Returned %d discrete maxima for %s.", height(maximaResults), primaryMetric));
            continue;
        end

        %% Continuous refinement via MultiStart (with predictor)
        if candidateCount == 0
            reporter.warn("Metric_" + primaryMetric, ...
                "No candidates; falling back to global MultiStart.");
            [maximaResults, msSolutions, msOutput] = runGlobalMultiStart( ...
                model, ri, lambdaSamples, primaryMetric, cfg, pBounds, rBounds, ...
                ratioLowerVal, ratioUpperVal, predictor, analyteWeights);
            attemptTrajectories = table();
        elseif useBasins && ~isempty(basinMap)
            if isempty(avgMetricGrid) && isfield(allData, candidateField) && numel(allData.period) > 4
                try
                    [bMap, ~, ~, ~] = reshapeSoAToVolume(allData, candidateField, 'UnitConversion', 'none');
                    if isequal(size(bMap), size(basinMap.labels))
                        avgMetricGrid = double(bMap);
                    end
                catch
                end
            end
            [maximaResults, msSolutions, msOutput, attemptTrajectories] = runBasinMultiStart( ...
                model, ri, lambdaSamples, primaryMetric, primaryMetricAvgField, ...
                cfg, candidateTable, basinMap, pBounds, rBounds, ...
                ratioLowerVal, ratioUpperVal, reporter, predictor, analyteWeights, avgMetricGrid);
        else
            [maximaResults, msSolutions, msOutput, attemptTrajectories] = runLocalMultiStart( ...
                model, ri, lambdaSamples, primaryMetric, primaryMetricAvgField, ...
                cfg, candidateTable, pBounds, rBounds, pSamplesLocal, rSamplesLocal, ...
                ratioLowerVal, ratioUpperVal, reporter, predictor, analyteWeights);
        end

        if ~isempty(maximaResults) && height(maximaResults) > 0
            reporter.complete("Metric_" + primaryMetric, ...
                sprintf("Found %d refined maxima for %s.", height(maximaResults), primaryMetric));
        else
            reporter.warn("Metric_" + primaryMetric, ...
                sprintf("No maxima found for %s.", primaryMetric));
        end

        % Store per-metric results
        res = struct();
        res.metricName = primaryMetric;
        res.candidateTable = candidateTable;
        res.maximaResults = maximaResults;
        res.avgMetricGrid = avgMetricGrid;
        res.pSamples = pSamplesLocal;
        res.rSamples = rSamplesLocal;
        res.lambdaSamples = lambdaSamples;
        res.msSolutions = msSolutions;
        res.msOutput = msOutput;
        res.attemptTrajectories = attemptTrajectories;
        res.gradMagnitude = gradMagnitude;
        res.laplacianField = laplacianField;
        res.divergenceField = divergenceField;
        res.basinMap = basinMap;
        metricResults{metricIdx} = res;
    end

    %% Build output struct
    results = struct();
    results.metrics = metricResults;
    results.allData = allData;
    results.predictor = predictor;
    results.model = model;
    results.ri = ri;
    results.cfg = cfg;
    results.elapsedTotal = toc(totalTimer);

    reporter.complete("Workflow", ...
        sprintf("Localization complete. Total time: %.1fs", results.elapsedTotal));
end

%% ========================================================================
%  INTERNAL HELPERS
%  ========================================================================

function [maximaResults, msSolutions, msOutput] = runGlobalMultiStart( ...
        model, ri, lambdaSamples, primaryMetric, cfg, pBounds, rBounds, ...
        ratioLowerVal, ratioUpperVal, predictor, analyteWeights)
    % runGlobalMultiStart  Fallback global MultiStart when no candidates detected.

    showIterationPaths = false;
    if isfield(cfg, "showIterationPaths")
        showIterationPaths = logical(cfg.showIterationPaths);
    end

    args = { ...
        'MetricName', primaryMetric, ...
        'InitialPoints', cfg.initialPoints, ...
        'FunctionTolerance', cfg.functionTolerance, ...
        'StepTolerance', cfg.stepTolerance, ...
        'MaxIterations', cfg.maxIterations, ...
        'FminconAlgorithm', cfg.fminconAlgorithm, ...
        'MaxFunctionEvaluations', cfg.maxFunctionEvaluations, ...
        'ConstraintTolerance', cfg.constraintTolerance, ...
        'OptimalityTolerance', cfg.optimalityTolerance, ...
        'NumMaxima', cfg.numLocalMaxima, ...
        'NumStartPoints', cfg.multiStartPoints, ...
        'PBounds', pBounds, ...
        'RBounds', rBounds, ...
        'RatioLower', ratioLowerVal, ...
        'RatioUpper', ratioUpperVal, ...
        'UseParallel', cfg.multiStartUseParallel, ...
        'Display', char(cfg.multiStartDisplay), ...
        'ShowIterationPaths', showIterationPaths};

    if nargin >= 10 && ~isempty(predictor)
        args = [args, {'Predictor', predictor}];
    end
    if nargin >= 11 && ~isempty(analyteWeights)
        args = [args, {'AnalyteWeights', analyteWeights}];
    end

    [maximaResults, msSolutions, msOutput] = find_local_maxima( ...
        model, ri, lambdaSamples, args{:}, 'Reporter', reporter);
end

function [maximaResults, msSolutions, msOutput, attemptTrajectories] = runLocalMultiStart( ...
        model, ri, lambdaSamples, primaryMetric, primaryMetricAvgField, ...
    cfg, candidateTable, pBounds, rBounds, pSamples, rSamples, ...
        ratioLowerVal, ratioUpperVal, reporter, predictor, analyteWeights)
    % runLocalMultiStart  Refine detected candidates via localised MultiStart runs.

    showIterationPaths = false;
    if isfield(cfg, "showIterationPaths")
        showIterationPaths = logical(cfg.showIterationPaths);
    end

    maxSeeds = min(cfg.numLocalMaxima, height(candidateTable));

    pS = double(pSamples(:)');
    if numel(pS) < 2
        dpSpacing = cfg.minLocalWindow;
    else
        dpSpacing = median(abs(diff(pS)));
    end

    rS = double(rSamples(:)');
    if numel(rS) < 2
        drSpacing = cfg.minLocalWindow;
    else
        drSpacing = median(abs(diff(rS)));
    end

    if isfield(cfg, 'tuningRadius') && isfinite(cfg.tuningRadius) && cfg.tuningRadius > 0
        localPadP = cfg.tuningRadius;
        localPadR = cfg.tuningRadius;
    else
        localPadP = max(cfg.localWindowRadiusSteps * dpSpacing, cfg.minLocalWindow);
        localPadR = max(cfg.localWindowRadiusSteps * drSpacing, cfg.minLocalWindow);
    end
    
    localStartPoints = max(20, ceil(cfg.multiStartPoints / max(1, maxSeeds)));

    % Lambda subsampling safeguard DISABLED — passing full spectrum to optimizer.
    subsampledLambda = lambdaSamples;
    useParallelLocal = logical(cfg.multiStartUseParallel);

    maximaBlocks = cell(0, 1);
    msSolutions = [];
    msOutput = [];
    attemptRows = table();

    % Build args with predictor if available
    extraArgs = {};
    if nargin >= 16 && ~isempty(predictor)
        extraArgs = {'Predictor', predictor};
    end
    if nargin >= 17 && ~isempty(analyteWeights)
        extraArgs = [extraArgs, {'AnalyteWeights', analyteWeights}];
    end

    maxRetryCount = max(1, round(cfg.basinRetryCount));
    retryShrink = cfg.basinRetryShrinkFactor;
    if ~isfinite(retryShrink) || retryShrink <= 0
        retryShrink = 0.5;
    elseif retryShrink > 1
        retryShrink = 1;
    end

    for seedIdx = 1:maxSeeds
        if isobject(reporter) && ismethod(reporter, "isStopRequested") && reporter.isStopRequested()
            error("Process:Terminated", "Optimization terminated by user.");
        end

        % Reset parallel execution mode to user's configured option for each new seed
        useParallelLocal = logical(cfg.multiStartUseParallel);
        if useParallelLocal
            try
                pool = gcp('nocreate');
                if isempty(pool) || ~isvalid(pool) || ~pool.Connected
                    parpool("Processes");
                end
            catch
                % Fall back to serial for this seed if pool creation fails
                useParallelLocal = false;
            end
        end

        pSeed = candidateTable.P_um(seedIdx);
        rSeed = candidateTable.R_um(seedIdx);
        if ismember('Tag', candidateTable.Properties.VariableNames)
            seedLabel = char(candidateTable.Tag(seedIdx));
        else
            seedLabel = sprintf("Seed #%d", seedIdx);
        end
        accepted = false;
        basinRejectCounts = zeros(maxSeeds, 1);
        pCenter = pSeed;
        rCenter = rSeed;
        shrinkCount = 0;

        for attempt = 1:maxRetryCount
            if isobject(reporter) && ismethod(reporter, "isStopRequested") && reporter.isStopRequested()
                error("Process:Terminated", "Optimization terminated by user.");
            end
            shrinkScale = retryShrink^shrinkCount;
            attemptPadP = max(cfg.minLocalWindow, localPadP * shrinkScale);
            attemptPadR = max(cfg.minLocalWindow, localPadR * shrinkScale);

            pStartLocal = [max(pBounds(1), pCenter - attemptPadP), min(pBounds(2), pCenter + attemptPadP)];
            rStartLocal = [max(rBounds(1), rCenter - attemptPadR), min(rBounds(2), rCenter + attemptPadR)];

            rStartLocal(1) = max(rStartLocal(1), ratioLowerVal * pStartLocal(1));
            if isfinite(ratioUpperVal)
                rStartLocal(2) = min(rStartLocal(2), ratioUpperVal * pStartLocal(2));
            end
            if pStartLocal(1) >= pStartLocal(2)
                pStartLocal = pBounds;
            end
            if rStartLocal(1) >= rStartLocal(2)
                rStartLocal = rBounds;
            end

            reporter.progress("Metric_" + primaryMetric, seedIdx / maxSeeds, ...
                sprintf("Refining %s (%d/%d) at [p=%.4f, r=%.4f] with local starts + global destination (attempt %d/%d)", ...
                seedLabel, seedIdx, maxSeeds, pCenter, rCenter, attempt, maxRetryCount));
            reporter.info(sprintf(...
                "[Metric_%s] %s attempt %d bounds: start p=[%.4f, %.4f], r=[%.4f, %.4f] | destination p=[%.4f, %.4f], r=[%.4f, %.4f]", ...
                primaryMetric, seedLabel, attempt, pStartLocal(1), pStartLocal(2), rStartLocal(1), rStartLocal(2), ...
                pBounds(1), pBounds(2), rBounds(1), rBounds(2)));

            try
                [localMax, localSolutions, localMsOutput, localAllRuns] = find_local_maxima(model, ri, subsampledLambda, ...
                    'MetricName', primaryMetric, ...
                    'InitialPoints', [pCenter, rCenter], ...
                    'FunctionTolerance', cfg.functionTolerance, ...
                    'StepTolerance', cfg.stepTolerance, ...
                    'MaxIterations', cfg.maxIterations, ...
                    'FminconAlgorithm', cfg.fminconAlgorithm, ...
                    'MaxFunctionEvaluations', cfg.maxFunctionEvaluations, ...
                    'ConstraintTolerance', cfg.constraintTolerance, ...
                    'OptimalityTolerance', cfg.optimalityTolerance, ...
                    'NumMaxima', 1, ...
                    'NumStartPoints', localStartPoints, ...
                    'PBounds', pStartLocal, ...
                    'RBounds', rStartLocal, ...
                    'RatioLower', ratioLowerVal, ...
                    'RatioUpper', ratioUpperVal, ...
                    'UseParallel', useParallelLocal, ...
                    'CaptureAllLocalRuns', ~useParallelLocal, ...
                    'UseGradientSeedInit', false, ...
                    'Display', char(cfg.multiStartDisplay), ...
                    'ShowIterationPaths', showIterationPaths, ...
                    'Reporter', reporter, ...
                    extraArgs{:});
            catch err
                isOomErr = contains(err.message, 'Out of Memory', 'IgnoreCase', true) || ...
                            contains(err.message, 'deserializ',   'IgnoreCase', true) || ...
                            contains(err.message, 'serializ',     'IgnoreCase', true);
                if isOomErr && useParallelLocal
                    % Parallel workers OOM on large payloads — retry this same
                    % attempt immediately in serial mode.
                    reporter.warn("Metric_" + primaryMetric, sprintf( ...
                        "%s attempt %d: OOM/serialization error in parallel mode; retrying in serial.", ...
                        seedLabel, attempt));
                    useParallelLocal = false;  % serial for remainder of this seed
                    try
                        [localMax, localSolutions, localMsOutput, localAllRuns] = find_local_maxima(model, ri, subsampledLambda, ...
                            'MetricName', primaryMetric, ...
                            'InitialPoints', [pCenter, rCenter], ...
                            'FunctionTolerance', cfg.functionTolerance, ...
                            'StepTolerance', cfg.stepTolerance, ...
                            'MaxIterations', cfg.maxIterations, ...
                            'FminconAlgorithm', cfg.fminconAlgorithm, ...
                            'MaxFunctionEvaluations', cfg.maxFunctionEvaluations, ...
                            'ConstraintTolerance', cfg.constraintTolerance, ...
                            'OptimalityTolerance', cfg.optimalityTolerance, ...
                            'NumMaxima', 1, ...
                            'NumStartPoints', localStartPoints, ...
                            'PBounds', pStartLocal, ...
                            'RBounds', rStartLocal, ...
                            'RatioLower', ratioLowerVal, ...
                            'RatioUpper', ratioUpperVal, ...
                            'UseParallel', false, ...
                            'CaptureAllLocalRuns', true, ...
                            'UseGradientSeedInit', false, ...
                            'Display', char(cfg.multiStartDisplay), ...
                            'ShowIterationPaths', showIterationPaths, ...
                            'Reporter', reporter, ...
                            extraArgs{:});
                    catch err2
                        stackStr = "";
                        for si_ = 1:numel(err2.stack)
                            stackStr = stackStr + sprintf("\n  [%d] %s line %d", si_, err2.stack(si_).name, err2.stack(si_).line);
                        end
                        reporter.warn("Metric_" + primaryMetric, ...
                            sprintf("%s attempt %d serial-retry failed: %s%s", seedLabel, attempt, err2.message, stackStr));
                        continue;
                    end
                else
                    stackStr = "";
                    for si_ = 1:numel(err.stack)
                        stackStr = stackStr + sprintf("\n  [%d] %s line %d", si_, err.stack(si_).name, err.stack(si_).line);
                    end
                    reporter.warn("Metric_" + primaryMetric, ...
                        sprintf("%s attempt %d failed: %s%s", seedLabel, attempt, err.message, stackStr));
                    continue;
                end
            end

            if isempty(localMax)
                reporter.warn("Metric_" + primaryMetric, ...
                    sprintf("%s attempt %d produced empty result.", seedLabel, attempt));
                try
                    % Use the full 14-column schema matching successful-run rows so
                    % vertcat of attemptRows never fails due to variable-name mismatch.
                    attemptRow = table(seedIdx, attempt, pSeed, rSeed, NaN, NaN, NaN, NaN, false, NaN, NaN, NaN, NaN, {[]}, ...
                        'VariableNames', {'SeedIndex','Attempt','StartP_um','StartR_um', ...
                        'EndP_um','EndR_um','ExitFlag','MetricValue','Accepted','ConstrViol','Iterations','FirstOrderOpt','DistFromSeed_um','IterPath'});
                catch tableErr
                    localLogTableBuildInputs(reporter, ...
                        sprintf("attemptRow-emptyLocalMax [seed=%d attempt=%d]", seedIdx, attempt), ...
                        {'SeedIndex','Attempt','StartP_um','StartR_um','EndP_um','EndR_um','ExitFlag','MetricValue','Accepted','ConstrViol','Iterations','FirstOrderOpt','DistFromSeed_um','IterPath'}, ...
                        {seedIdx, attempt, pSeed, rSeed, NaN, NaN, NaN, NaN, false, NaN, NaN, NaN, NaN, {[]}});
                    rethrow(tableErr);
                end
                attemptRows = [attemptRows; attemptRow]; %#ok<AGROW>
                continue;
            end

            % Ensure canonical metric field exists on localMax table so
            % downstream diagnostics, fallback merge, and sortrows are consistent
            % across variants (_avg/_analyte/_laser).
            baseAvgField = matlab.lang.makeValidName([char(primaryMetric), '_avg']);
            if ~any(strcmp(localMax.Properties.VariableNames, primaryMetricAvgField))
                if any(strcmp(localMax.Properties.VariableNames, baseAvgField))
                    localMax.(primaryMetricAvgField) = localMax.(baseAvgField);
                else
                    localMax.(primaryMetricAvgField) = NaN(height(localMax), 1);
                end
            end
            % If the variant column differs from the raw _avg column (laser/weighted
            % modes), remove the original _avg column from localMax. This ensures
            % all maximaBlocks entries have identical variable sets so vertcat works.
            if ~strcmp(primaryMetricAvgField, baseAvgField) && ...
                    any(strcmp(localMax.Properties.VariableNames, baseAvgField))
                localMax = removevars(localMax, baseAvgField);
            end

            % Diagnostic: log seed vs refined coordinates
            if height(localMax) > 0
                pRefined = localMax.P_um(1);
                rRefined = localMax.R_um(1);
                exitFlag = localMax.ExitFlag(1);
                refinedValue = localMax.(primaryMetricAvgField)(1);
                deltaP = abs(pRefined - pSeed);
                deltaR = abs(rRefined - rSeed);
                reporter.info(sprintf(...
                    "[Metric_%s] %s attempt %d: [%.4f, %.4f] → [%.4f, %.4f] (Δp=%.2e, Δr=%.2e, exit=%d, val=%.3e)", ...
                    primaryMetric, seedLabel, attempt, pSeed, rSeed, pRefined, rRefined, ...
                    deltaP, deltaR, exitFlag, refinedValue));
            end

            localMax.SeedIndex = repmat(seedIdx, height(localMax), 1);
            localMax.SeedP_um = repmat(pSeed, height(localMax), 1);
            localMax.SeedR_um = repmat(rSeed, height(localMax), 1);
            if ismember('GridValue', candidateTable.Properties.VariableNames)
                localMax.SeedValue = repmat(candidateTable.GridValue(seedIdx), height(localMax), 1);
            else
                localMax.SeedValue = NaN(height(localMax), 1);
            end

            if height(localMax) > 0 && maxSeeds > 1
                validRows = true(height(localMax), 1);
                allSeedP = candidateTable.P_um(1:maxSeeds);
                allSeedR = candidateTable.R_um(1:maxSeeds);

                for rowIdx = 1:height(localMax)
                    pRefined = localMax.P_um(rowIdx);
                    rRefined = localMax.R_um(rowIdx);
                    distances = sqrt((allSeedP - pRefined).^2 + (allSeedR - rRefined).^2);
                    [minDist, closestSeedIdx] = min(distances);
                    ownDist = distances(seedIdx);

                    if ownDist > (minDist + cfg.neighborTolerance)
                        validRows(rowIdx) = false;
                        basinRejectCounts(closestSeedIdx) = basinRejectCounts(closestSeedIdx) + 1;
                        if ismember('Tag', candidateTable.Properties.VariableNames)
                            otherLabel = char(candidateTable.Tag(closestSeedIdx));
                        else
                            otherLabel = sprintf("Seed #%d", closestSeedIdx);
                        end
                        reporter.info(sprintf(...
                            "[Metric_%s] %s: Rejected solution [p=%.4f, r=%.4f] (jumped to %s basin)", ...
                            primaryMetric, seedLabel, pRefined, rRefined, otherLabel));
                    end
                end

                localMax = localMax(validRows, :);
            end

            % Border rejection: solution at the local window edge would have escaped
            % further if not bounded — discard as non-converged interior optimum
            wasBorderRejected = false;
            borderDriftP = pCenter;
            borderDriftR = rCenter;
            if ~isempty(localMax) && isfield(cfg, 'borderRejectFraction') && cfg.borderRejectFraction > 0
                borderFrac = cfg.borderRejectFraction;
                windowWidthP = pStartLocal(2) - pStartLocal(1);
                windowWidthR = rStartLocal(2) - rStartLocal(1);
                borderTolP = borderFrac * windowWidthP;
                borderTolR = borderFrac * windowWidthR;
                validBorder = true(height(localMax), 1);
                for rowIdx = 1:height(localMax)
                    pR = localMax.P_um(rowIdx);
                    rR = localMax.R_um(rowIdx);
                    atBorderP = (pStartLocal(1) > pBounds(1) + 1e-6 && pR <= pStartLocal(1) + borderTolP) || ...
                                (pStartLocal(2) < pBounds(2) - 1e-6 && pR >= pStartLocal(2) - borderTolP);
                    atBorderR = (rStartLocal(1) > rBounds(1) + 1e-6 && rR <= rStartLocal(1) + borderTolR) || ...
                                (rStartLocal(2) < rBounds(2) - 1e-6 && rR >= rStartLocal(2) - borderTolR);
                    atBorder = atBorderP || atBorderR;
                    if atBorder
                        validBorder(rowIdx) = false;
                        wasBorderRejected = true;
                        borderDriftP = pR;
                        borderDriftR = rR;
                        reporter.info(sprintf( ...
                            "[Metric_%s] %s attempt %d: Rejected at-border solution [p=%.4f, r=%.4f]" + ...
                            " (window p=[%.4f, %.4f] r=[%.4f, %.4f], tol=%.1f%%)", ...
                            primaryMetric, seedLabel, attempt, pR, rR, ...
                            pStartLocal(1), pStartLocal(2), rStartLocal(1), rStartLocal(2), borderFrac * 100));
                    end
                end
                localMax = localMax(validBorder, :);
            end

            if ~isempty(localMax)
                % Extract ALL MultiStart start→end pairs from solutions
                if ~isempty(localAllRuns)
                    extractedRunCount = 0;
                    allSeedP = double(candidateTable.P_um(1:maxSeeds));
                    allSeedR = double(candidateTable.R_um(1:maxSeeds));
                    hasIterPath = ismember("IterPath", localAllRuns.Properties.VariableNames);
                    for riIdx = 1:height(localAllRuns)
                        sp = [double(localAllRuns.StartP_um(riIdx)), double(localAllRuns.StartR_um(riIdx))];
                        endPt = [double(localAllRuns.EndP_um(riIdx)), double(localAllRuns.EndR_um(riIdx))];
                        if any(~isfinite(endPt))
                            continue;
                        end
                        if any(~isfinite(sp))
                            continue;
                        end
                        distances = hypot(allSeedP - endPt(1), allSeedR - endPt(2));
                        ownDist = hypot(endPt(1) - pSeed, endPt(2) - rSeed);
                        minDist = min(distances);
                        acceptedFlag = ownDist <= (minDist + cfg.neighborTolerance);
                        extractedRunCount = extractedRunCount + 1;

                        metVal = double(localAllRuns.MetricValue(riIdx));
                        exitF = double(localAllRuns.ExitFlag(riIdx));
                        constrViol = NaN;
                        if any(strcmp(localAllRuns.Properties.VariableNames, 'ConstrViol'))
                            constrViol = double(localAllRuns.ConstrViol(riIdx));
                        end
                        iterationsVal = NaN;
                        if any(strcmp(localAllRuns.Properties.VariableNames, 'Iterations'))
                            iterationsVal = double(localAllRuns.Iterations(riIdx));
                        end
                        firstOrderOptVal = NaN;
                        if any(strcmp(localAllRuns.Properties.VariableNames, 'FirstOrderOpt'))
                            firstOrderOptVal = double(localAllRuns.FirstOrderOpt(riIdx));
                        end
                        distanceFromSeed = hypot(endPt(1) - pSeed, endPt(2) - rSeed);

                        % Extract iteration path if available.
                        % Use () indexing — returns 1×1 cell already; do NOT
                        % wrap in {} again or the path gets double-nested.
                        if hasIterPath
                            iterPathCell = localAllRuns.IterPath(riIdx, :);
                        else
                            iterPathCell = {[]};
                        end

                        try
                            newRow = table(seedIdx, attempt, sp(1), sp(2), endPt(1), endPt(2), ...
                                exitF, metVal, acceptedFlag, constrViol, iterationsVal, firstOrderOptVal, distanceFromSeed, iterPathCell, ...
                                'VariableNames', {'SeedIndex','Attempt','StartP_um','StartR_um', ...
                                'EndP_um','EndR_um','ExitFlag','MetricValue','Accepted','ConstrViol','Iterations','FirstOrderOpt','DistFromSeed_um','IterPath'});
                        catch tableErr
                            localLogTableBuildInputs(reporter, ...
                                sprintf("newRow-localAllRuns [seed=%d attempt=%d riIdx=%d]", seedIdx, attempt, riIdx), ...
                                {'SeedIndex','Attempt','StartP_um','StartR_um','EndP_um','EndR_um','ExitFlag','MetricValue','Accepted','ConstrViol','Iterations','FirstOrderOpt','DistFromSeed_um','IterPath'}, ...
                                {seedIdx, attempt, sp(1), sp(2), endPt(1), endPt(2), exitF, metVal, acceptedFlag, constrViol, iterationsVal, firstOrderOptVal, distanceFromSeed, iterPathCell});
                            rethrow(tableErr);
                        end
                        attemptRows = [attemptRows; newRow]; %#ok<AGROW>
                    end

                    if isstruct(localMsOutput) && isfield(localMsOutput, 'localSolverTotal')
                        totalRuns = double(localMsOutput.localSolverTotal);
                        missingRuns = max(0, totalRuns - extractedRunCount);
                        if missingRuns > 0
                            reporter.info(sprintf(...
                                "[Metric_%s] %s attempt %d: %d/%d local runs still missing after localSolTable capture.", ...
                                primaryMetric, seedLabel, attempt, missingRuns, totalRuns));
                        end
                    end
                elseif ~isempty(localSolutions)
                    allSeedP = double(candidateTable.P_um(1:maxSeeds));
                    allSeedR = double(candidateTable.R_um(1:maxSeeds));
                    extractedRunCount = 0;
                    for si = 1:numel(localSolutions)
                        sol = localSolutions(si);
                        endPt = sol.X(:)';
                        if numel(endPt) < 2 || any(~isfinite(endPt(1:2)))
                            continue;
                        end
                        distances = hypot(allSeedP - endPt(1), allSeedR - endPt(2));
                        metVal = -sol.Fval;
                        exitF = double(sol.Exitflag);
                        % Extract fmincon diagnostics from Output
                        constrViol = NaN;
                        iterations = NaN;
                        firstOrderOpt = NaN;
                        if isstruct(sol.Output)
                            if isfield(sol.Output, 'constrviolation')
                                constrViol = double(sol.Output.constrviolation);
                            end
                            if isfield(sol.Output, 'iterations')
                                iterations = double(sol.Output.iterations);
                            end
                            if isfield(sol.Output, 'firstorderopt')
                                firstOrderOpt = double(sol.Output.firstorderopt);
                            end
                        end
                        x0s = sol.X0;
                        if iscell(x0s)
                            for ki = 1:numel(x0s)
                                sp = x0s{ki}(:)';
                                if numel(sp) < 2 || any(~isfinite(sp(1:2)))
                                    continue;
                                end
                                extractedRunCount = extractedRunCount + 1;
                                % Compute distance from seed to converged point
                                distanceFromSeed = hypot(endPt(1) - pSeed, endPt(2) - rSeed);
                                ownDist = hypot(endPt(1) - pSeed, endPt(2) - rSeed);
                                minDist = min(distances);
                                acceptedFlag = ownDist <= (minDist + cfg.neighborTolerance);
                                try
                                    newRow = table(seedIdx, attempt, sp(1), sp(2), endPt(1), endPt(2), ...
                                        exitF, metVal, acceptedFlag, constrViol, iterations, firstOrderOpt, distanceFromSeed, {[]}, ...
                                        'VariableNames', {'SeedIndex','Attempt','StartP_um','StartR_um', ...
                                        'EndP_um','EndR_um','ExitFlag','MetricValue','Accepted','ConstrViol','Iterations','FirstOrderOpt','DistFromSeed_um','IterPath'});
                                catch tableErr
                                    localLogTableBuildInputs(reporter, ...
                                        sprintf("newRow-localSolutions [seed=%d attempt=%d si=%d ki=%d]", seedIdx, attempt, si, ki), ...
                                        {'SeedIndex','Attempt','StartP_um','StartR_um','EndP_um','EndR_um','ExitFlag','MetricValue','Accepted','ConstrViol','Iterations','FirstOrderOpt','DistFromSeed_um','IterPath'}, ...
                                        {seedIdx, attempt, sp(1), sp(2), endPt(1), endPt(2), exitF, metVal, acceptedFlag, constrViol, iterations, firstOrderOpt, distanceFromSeed, {[]}});
                                    rethrow(tableErr);
                                end
                                attemptRows = [attemptRows; newRow]; %#ok<AGROW>
                            end
                        end
                    end

                    if isstruct(localMsOutput) && isfield(localMsOutput, 'localSolverTotal')
                        totalRuns = double(localMsOutput.localSolverTotal);
                        missingRuns = max(0, totalRuns - extractedRunCount);
                        if missingRuns > 0
                            reporter.info(sprintf(...
                                "[Metric_%s] %s attempt %d: %d/%d local runs omitted from trajectories (nonpositive local exit flags are not returned in solutions).", ...
                                primaryMetric, seedLabel, attempt, missingRuns, totalRuns));
                        end
                    end
                end

                localMax.IsFallback = false(height(localMax), 1);
                localMax.RetryCount = repmat(attempt, height(localMax), 1);
                maximaBlocks{end+1} = localMax; %#ok<AGROW>
                accepted = true;
                break;
            end

            if attempt < maxRetryCount
                if wasBorderRejected
                    % Optimum hit local window boundary while remaining in basin:
                    % Recenter search window around drifted point to follow gradient ridge
                    pCenter = borderDriftP;
                    rCenter = borderDriftR;
                    reporter.info(sprintf(...
                        "[Metric_%s] %s: Recentering search window around drifted point [p=%.4f, r=%.4f] for attempt %d/%d.", ...
                        primaryMetric, seedLabel, pCenter, rCenter, attempt + 1, maxRetryCount));
                else
                    % Non-border rejection (e.g. hopped to neighbor basin or solver failure):
                    % Revert center to initial seed and shrink window to keep search localized
                    pCenter = pSeed;
                    rCenter = rSeed;
                    shrinkCount = shrinkCount + 1;
                    reporter.warn("Metric_" + primaryMetric, sprintf(...
                        "%s produced no in-basin maxima at attempt %d/%d; shrinking start window by %.2f and retrying.", ...
                        seedLabel, attempt, maxRetryCount, retryShrink));
                end
            end
        end

        if ~accepted
            [jumpCount, jumpSeedIdx] = max(basinRejectCounts);
            if jumpCount > 0
                if ismember('Tag', candidateTable.Properties.VariableNames)
                    jumpLabel = char(candidateTable.Tag(jumpSeedIdx));
                else
                    jumpLabel = sprintf("Seed #%d", jumpSeedIdx);
                end
                reporter.warn("Metric_" + primaryMetric, sprintf(...
                    "%s: all %d retry attempts converged outside basin (dominant jump: %s).", ...
                    seedLabel, maxRetryCount, jumpLabel));
            else
                reporter.warn("Metric_" + primaryMetric, sprintf(...
                    "%s: no valid refined optimum found after %d attempts.", ...
                    seedLabel, maxRetryCount));
            end

            if cfg.keepRejectedSeeds
                % Prefer GridValue from candidate table; if missing or NaN, evaluate
                % the seed position directly via the predictor (exact DNN value).
                seedMetric = NaN;
                if ismember('GridValue', candidateTable.Properties.VariableNames)
                    seedMetric = double(candidateTable.GridValue(seedIdx));
                end
                if isnan(seedMetric) && nargin >= 10 && ~isempty(predictor) && ~isempty(lambdaSamples)
                    try
                        if isfield(cfg, 'metricVariant') && string(cfg.metricVariant) == "weighted"
                            metricFieldVariant = "analyte";
                        elseif isfield(cfg, 'metricVariant') && string(cfg.metricVariant) == "laser"
                            metricFieldVariant = "laser";
                        else
                            metricFieldVariant = "avg";
                        end
                        stokesLimits = [0, 0];
                        lambdaLaserVal = 785;
                        if isfield(cfg, 'stokesShiftLimits'), stokesLimits  = cfg.stokesShiftLimits; end
                        if isfield(cfg, 'lambdaLaser'),       lambdaLaserVal = cfg.lambdaLaser;       end
                        soaFb = predictor.predictGrid(pSeed, rSeed, lambdaSamples, ...
                            "LaserWavelength", lambdaLaserVal, "RamanWindow", stokesLimits);
                        avgFieldName = char(resolveDerivedMetricField(primaryMetric, metricFieldVariant, soaFb));
                        if isfield(soaFb, avgFieldName)
                            seedMetric = double(soaFb.(avgFieldName)(1));
                        end
                    catch
                        seedMetric = NaN;
                    end
                end

                try
                    fallbackTbl = table(pSeed, rSeed, rSeed / pSeed, seedMetric, -999, ...
                        seedIdx, pSeed, rSeed, seedMetric, true, maxRetryCount, ...
                        'VariableNames', {'P_um','R_um','Ratio',primaryMetricAvgField, ...
                        'ExitFlag','SeedIndex','SeedP_um','SeedR_um','SeedValue','IsFallback','RetryCount'});
                catch tableErr
                    localLogTableBuildInputs(reporter, ...
                        sprintf("fallbackTbl [seed=%d]", seedIdx), ...
                        {'P_um','R_um','Ratio',primaryMetricAvgField,'ExitFlag','SeedIndex','SeedP_um','SeedR_um','SeedValue','IsFallback','RetryCount'}, ...
                        {pSeed, rSeed, rSeed/pSeed, seedMetric, -999, seedIdx, pSeed, rSeed, seedMetric, true, maxRetryCount});
                    rethrow(tableErr);
                end
                maximaBlocks{end+1} = fallbackTbl; %#ok<AGROW>
            end
        end
    end

    if isempty(maximaBlocks)
        maximaResults = table();
    else
        maximaResults = vertcat(maximaBlocks{:});
        maximaResults = sortrows(maximaResults, ...
            {'SeedIndex', primaryMetricAvgField}, {'ascend', 'descend'});
    end

    if isempty(attemptRows)
        attemptTrajectories = table();
    else
        attemptTrajectories = sortrows(attemptRows, {'SeedIndex','Attempt'}, {'ascend','ascend'});
    end
end

function [maximaResults, msSolutions, msOutput, attemptTrajectories] = runBasinMultiStart( ...
        model, ri, lambdaSamples, primaryMetric, primaryMetricAvgField, ...
        cfg, candidateTable, basinMap, pBounds, rBounds, ...
        ratioLowerVal, ratioUpperVal, reporter, predictor, analyteWeights, avgMetricGrid)
    % runBasinMultiStart  Refine each seed inside its watershed basin.
    %
    %   For every seed the owning basin is looked up in basinMap. Starts are
    %   the seed itself plus (InBasinStarts - 1) farthest-point samples from
    %   the basin core (cells in the upper 75 % of the basin depth). Each
    %   start runs one bounded fmincon (serial) on the model objective,
    %   boxed to the basin's bounding box plus a two-cell margin. A run is
    %   accepted when its endpoint lies in (or within one cell of) the same
    %   basin. The best accepted run is reported, and the spread of the
    %   accepted endpoints classifies the basin top:
    %       "peak"   all accepted endpoints within 1 nm
    %       "ridge"  endpoints spread > 1 nm but values within 0.2 % of best
    %       "multi"  endpoints spread with distinct values (sub-peaks)
    %       "single" only one accepted run
    %   Seeds with no accepted run fall back to the seed (IsFallback=true).

    msSolutions = [];
    msOutput = [];
    nStarts = 5;
    if isfield(cfg, "inBasinStarts") && isfinite(cfg.inBasinStarts) && cfg.inBasinStarts >= 1
        nStarts = round(cfg.inBasinStarts);
    end
    showIterationPaths = isfield(cfg, "showIterationPaths") && logical(cfg.showIterationPaths);

    extraArgs = {};
    if ~isempty(predictor)
        extraArgs = {'Predictor', predictor};
    end
    if ~isempty(analyteWeights)
        extraArgs = [extraArgs, {'AnalyteWeights', analyteWeights}];
    end

    pAx = double(basinMap.pAxis(:)');      % µm
    rAx = double(basinMap.rAxis(:)');
    labels = double(basinMap.labels);
    if nargin >= 16 && ~isempty(avgMetricGrid) && isequal(size(avgMetricGrid), size(labels))
        vals = double(avgMetricGrid);
    elseif isfield(basinMap, "values") && ~isempty(basinMap.values) && isequal(size(basinMap.values), size(labels))
        vals = double(basinMap.values);
    else
        vals = zeros(size(labels));
    end
    dpCell = median(abs(diff(pAx)));
    drCell = median(abs(diff(rAx)));
    [pMesh, rMesh] = meshgrid(pAx, rAx);

    maxSeeds = min(cfg.numLocalMaxima, height(candidateTable));
    seedIds = assignSeedsToBasins(basinMap, candidateTable.P_um(1:maxSeeds) * 1e3, ...
        candidateTable.R_um(1:maxSeeds) * 1e3);
    if ismember('BasinId', candidateTable.Properties.VariableNames)
        fromTable = double(candidateTable.BasinId(1:maxSeeds));
        useTable = seedIds == 0 & isfinite(fromTable) & fromTable > 0;
        seedIds(useTable) = fromTable(useTable);
    end
    [uIds, ~, grp] = unique(seedIds(seedIds > 0));
    dupCounts = accumarray(grp, 1);
    for k = find(dupCounts > 1)'
        reporter.warn("Metric_" + primaryMetric, sprintf( ...
            "%d seeds share basin %d; they will refine to the same optimum.", dupCounts(k), uIds(k)));
    end

    trajNames = {'SeedIndex','Attempt','StartP_um','StartR_um','EndP_um','EndR_um','ExitFlag', ...
        'MetricValue','Accepted','ConstrViol','Iterations','FirstOrderOpt','DistFromSeed_um','IterPath'};
    maximaBlocks = cell(maxSeeds, 1);
    trajBlocks = cell(maxSeeds, 1);
    tAll = tic;

    for seedIdx = 1:maxSeeds
        if isobject(reporter) && ismethod(reporter, "isStopRequested") && reporter.isStopRequested()
            error("Process:Terminated", "Optimization terminated by user.");
        end
        tSeed = tic;
        pSeed = double(candidateTable.P_um(seedIdx));
        rSeed = double(candidateTable.R_um(seedIdx));
        if ismember('Tag', candidateTable.Properties.VariableNames)
            seedLabel = char(string(candidateTable.Tag(seedIdx)));
        else
            seedLabel = sprintf('Seed #%d', seedIdx);
        end
        seedValue = NaN;
        if ismember('GridValue', candidateTable.Properties.VariableNames)
            seedValue = double(candidateTable.GridValue(seedIdx));
        end
        bid = seedIds(seedIdx);

        %% Start set and bounds
        if bid > 0
            terr = labels == bid;
            pIn = pMesh(terr);  rIn = rMesh(terr);  vIn = vals(terr);
            pBox = [max(pBounds(1), min(pIn) - 2*dpCell), min(pBounds(2), max(pIn) + 2*dpCell)];
            rBox = [max(rBounds(1), min(rIn) - 2*drCell), min(rBounds(2), max(rIn) + 2*drCell)];
            vMin = min(vIn);
            vMax = max(vIn);
            vRange = vMax - vMin;
            threshPct = 50;
            if isfield(cfg, "basinValueThreshold") && isfinite(cfg.basinValueThreshold)
                threshPct = max(0, min(100, double(cfg.basinValueThreshold)));
            end
            if vRange > 0
                vCutoff = vMin + (threshPct / 100) * vRange;
                core = vIn >= vCutoff;
            else
                core = true(size(vIn));
            end
            if nnz(core) < nStarts
                [~, sortIdx] = sort(vIn, 'descend');
                core = false(size(vIn));
                core(sortIdx(1:min(numel(sortIdx), max(nStarts, 1)))) = true;
            end
            starts = localFarthestPointStarts([pSeed, rSeed], [pIn(core), rIn(core)], ...
                nStarts, [dpCell, drCell]);
            boxStr = "basin";
        else
            pad = cfg.tuningRadius;
            pBox = [max(pBounds(1), pSeed - pad), min(pBounds(2), pSeed + pad)];
            rBox = [max(rBounds(1), rSeed - pad), min(rBounds(2), rSeed + pad)];
            starts = [pSeed, rSeed];
            boxStr = "radius box (seed outside basin map)";
        end
        if pBox(1) >= pBox(2), pBox = pBounds; end
        if rBox(1) >= rBox(2), rBox = rBounds; end

        reporter.progress("Metric_" + primaryMetric, seedIdx / maxSeeds, sprintf( ...
            "Refining %s (%d/%d) in basin %d: %d starts", seedLabel, seedIdx, maxSeeds, bid, size(starts, 1)));
        reporter.info(sprintf("[Metric_%s] %s %s box p=[%.1f, %.1f] r=[%.1f, %.1f] nm, %d starts", ...
            primaryMetric, seedLabel, boxStr, pBox * 1e3, rBox * 1e3, size(starts, 1)));

        %% Run fmincon from every start (serial: no worker payload overhead)
        sols = [];
        allRuns = table();
        try
            [~, sols, ~, allRuns] = find_local_maxima(model, ri, lambdaSamples, ...
                'MetricName', primaryMetric, ...
                'InitialPoints', starts, ...
                'StartPointsOnly', true, ...
                'NumMaxima', size(starts, 1), ...
                'PBounds', pBox, 'RBounds', rBox, ...
                'RatioLower', ratioLowerVal, 'RatioUpper', ratioUpperVal, ...
                'FunctionTolerance', cfg.functionTolerance, ...
                'StepTolerance', cfg.stepTolerance, ...
                'OptimalityTolerance', cfg.optimalityTolerance, ...
                'ConstraintTolerance', cfg.constraintTolerance, ...
                'MaxIterations', cfg.maxIterations, ...
                'MaxFunctionEvaluations', cfg.maxFunctionEvaluations, ...
                'FminconAlgorithm', cfg.fminconAlgorithm, ...
                'UseParallel', false, ...
                'UseGradientSeedInit', false, ...
                'CaptureAllLocalRuns', showIterationPaths, ...
                'ShowIterationPaths', showIterationPaths, ...
                'Display', char(cfg.multiStartDisplay), ...
                'Reporter', reporter, ...
                extraArgs{:});
        catch err
            if strcmp(err.identifier, "Process:Terminated")
                rethrow(err);
            end
            reporter.warn("Metric_" + primaryMetric, sprintf("%s: fmincon failed: %s", seedLabel, err.message));
        end

        %% Classify runs
        nRun = numel(sols);
        endPts = NaN(nRun, 2);  startPts = NaN(nRun, 2);
        runVal = NaN(nRun, 1);  runExit = NaN(nRun, 1);
        runIter = NaN(nRun, 1); runFoo = NaN(nRun, 1); runCv = NaN(nRun, 1);
        acceptedRun = false(nRun, 1);
        for k = 1:nRun
            endPts(k, :) = sols(k).X(:)';
            x0 = sols(k).X0;
            if iscell(x0), x0 = x0{1}; end
            startPts(k, :) = x0(:)';
            runVal(k) = -sols(k).Fval;
            runExit(k) = double(sols(k).Exitflag);
            if isstruct(sols(k).Output)
                if isfield(sols(k).Output, 'iterations'), runIter(k) = sols(k).Output.iterations; end
                if isfield(sols(k).Output, 'firstorderopt'), runFoo(k) = sols(k).Output.firstorderopt; end
                if isfield(sols(k).Output, 'constrviolation'), runCv(k) = sols(k).Output.constrviolation; end
            end
            if bid > 0
                acceptedRun(k) = localInBasin(labels, pAx, rAx, endPts(k, :), bid);
            else
                acceptedRun(k) = all(isfinite(endPts(k, :)));
            end
            acceptedRun(k) = acceptedRun(k) && isfinite(runVal(k)) && runExit(k) >= 0;

            % Retry jumped starts: contract 50% toward discrete summit and re-run fmincon
            if bid > 0 && ~acceptedRun(k) && all(isfinite(startPts(k, :)))
                retryStart = 0.5 * startPts(k, :) + 0.5 * [pSeed, rSeed];
                if ~localInBasin(labels, pAx, rAx, retryStart, bid)
                    retryStart = 0.25 * startPts(k, :) + 0.75 * [pSeed, rSeed];
                end
                try
                    [~, retrySol] = find_local_maxima(model, ri, lambdaSamples, ...
                        'MetricName', primaryMetric, ...
                        'InitialPoints', retryStart, ...
                        'StartPointsOnly', true, ...
                        'NumMaxima', 1, ...
                        'PBounds', pBox, 'RBounds', rBox, ...
                        'RatioLower', ratioLowerVal, 'RatioUpper', ratioUpperVal, ...
                        'FunctionTolerance', cfg.functionTolerance, ...
                        'StepTolerance', cfg.stepTolerance, ...
                        'OptimalityTolerance', cfg.optimalityTolerance, ...
                        'ConstraintTolerance', cfg.constraintTolerance, ...
                        'MaxIterations', cfg.maxIterations, ...
                        'MaxFunctionEvaluations', cfg.maxFunctionEvaluations, ...
                        'FminconAlgorithm', cfg.fminconAlgorithm, ...
                        'UseParallel', false, ...
                        'UseGradientSeedInit', false, ...
                        'Display', 'off', ...
                        extraArgs{:});
                    if ~isempty(retrySol) && numel(retrySol) >= 1
                        rEnd = retrySol(1).X(:)';
                        rVal = -retrySol(1).Fval;
                        rExit = double(retrySol(1).Exitflag);
                        if localInBasin(labels, pAx, rAx, rEnd, bid) && isfinite(rVal) && rExit >= 0
                            reporter.info(sprintf( ...
                                "[Metric_%s] %s: Start #%d jumped out; contracted start [%.1f, %.1f] nm converged in basin %d (val=%.4g, exit=%d)", ...
                                primaryMetric, seedLabel, k, retryStart*1e3, bid, rVal, rExit));
                            endPts(k, :) = rEnd;
                            startPts(k, :) = retryStart;
                            runVal(k) = rVal;
                            runExit(k) = rExit;
                            acceptedRun(k) = true;
                            if isstruct(retrySol(1).Output)
                                if isfield(retrySol(1).Output, 'iterations'), runIter(k) = retrySol(1).Output.iterations; end
                                if isfield(retrySol(1).Output, 'firstorderopt'), runFoo(k) = retrySol(1).Output.firstorderopt; end
                                if isfield(retrySol(1).Output, 'constrviolation'), runCv(k) = retrySol(1).Output.constrviolation; end
                            end
                        end
                    end
                catch
                    % Retry failure is non-fatal; run remains unaccepted
                end
            end
        end

        % Trajectory rows (start → end per run), with iteration paths if captured
        trajRows = cell(nRun, 1);
        for k = 1:nRun
            iterPathCell = {[]};
            if ~isempty(allRuns) && ismember("IterPath", allRuns.Properties.VariableNames)
                d = hypot(allRuns.StartP_um - startPts(k, 1), allRuns.StartR_um - startPts(k, 2));
                [dMin, j] = min(d);
                if dMin < 1e-6
                    iterPathCell = allRuns.IterPath(j, :);
                end
            end
            trajRows{k} = table(seedIdx, k, startPts(k, 1), startPts(k, 2), endPts(k, 1), endPts(k, 2), ...
                runExit(k), runVal(k), acceptedRun(k), runCv(k), runIter(k), runFoo(k), ...
                hypot(endPts(k, 1) - pSeed, endPts(k, 2) - rSeed), iterPathCell, 'VariableNames', trajNames);
        end
        if nRun > 0
            trajBlocks{seedIdx} = vertcat(trajRows{:});
        end

        %% Best accepted run + coalescence diagnostic
        nAcc = nnz(acceptedRun);
        if nAcc > 0
            accIdx = find(acceptedRun);
            [bestVal, b] = max(runVal(accIdx));
            best = accIdx(b);
            accPts_nm = endPts(accIdx, :) * 1e3;
            spread = 0;
            if nAcc > 1
                pairD = hypot(accPts_nm(:, 1) - accPts_nm(:, 1)', accPts_nm(:, 2) - accPts_nm(:, 2)');
                spread = max(pairD(:));
            end
            relGap = (bestVal - min(runVal(accIdx))) / max(abs(bestVal), eps);
            if nAcc == 1
                status = "single";
            elseif spread <= 1
                status = "peak";
            elseif relGap < 2e-3
                status = "ridge";
            else
                status = "multi";
            end
            pBest = endPts(best, 1);  rBest = endPts(best, 2);
            isFallback = false;
            exitBest = runExit(best);
            reporter.info(sprintf( ...
                "[Metric_%s] %s: [%.1f, %.1f] → [%.2f, %.2f] nm, val=%.4g (seed grid %.4g), %d/%d in basin, spread=%.2f nm, %s, %.1fs", ...
                primaryMetric, seedLabel, pSeed*1e3, rSeed*1e3, pBest*1e3, rBest*1e3, bestVal, seedValue, ...
                nAcc, nRun, spread, status, toc(tSeed)));
            if isfinite(seedValue) && bestVal < seedValue * (1 - 1e-3)
                reporter.warn("Metric_" + primaryMetric, sprintf( ...
                    "%s: refined value %.4g is below the seed grid value %.4g (grid and model may differ).", ...
                    seedLabel, bestVal, seedValue));
            end
        else
            status = "fallback";
            spread = NaN;
            pBest = pSeed;  rBest = rSeed;
            bestVal = seedValue;
            isFallback = true;
            exitBest = -999;
            reporter.warn("Metric_" + primaryMetric, sprintf( ...
                "%s: no run ended inside basin %d (%d runs); keeping the seed.", seedLabel, bid, nRun));
            if ~cfg.keepRejectedSeeds
                continue;
            end
        end

        maximaBlocks{seedIdx} = table(pBest, rBest, rBest / pBest, bestVal, exitBest, ...
            seedIdx, pSeed, rSeed, seedValue, isFallback, 1, bid, status, spread, nAcc, nRun, ...
            'VariableNames', {'P_um','R_um','Ratio',primaryMetricAvgField,'ExitFlag', ...
            'SeedIndex','SeedP_um','SeedR_um','SeedValue','IsFallback','RetryCount', ...
            'BasinId','Status','Spread_nm','NumAccepted','NumStarts'});
    end

    reporter.info(sprintf("[Metric_%s] In-basin refinement of %d seeds finished in %.1fs.", ...
        primaryMetric, maxSeeds, toc(tAll)));

    maximaBlocks = maximaBlocks(~cellfun(@isempty, maximaBlocks));
    if isempty(maximaBlocks)
        maximaResults = table();
    else
        maximaResults = vertcat(maximaBlocks{:});
        maximaResults = localFlagDuplicateOptima(maximaResults, candidateTable, primaryMetricAvgField, reporter, primaryMetric);
    end
    trajBlocks = trajBlocks(~cellfun(@isempty, trajBlocks));
    if isempty(trajBlocks)
        attemptTrajectories = table();
    else
        attemptTrajectories = vertcat(trajBlocks{:});
    end
end

function grid = localMaskToLimits(grid, pS, rS, cfg)
    % Set cells outside cfg.pLimits × cfg.rLimits (nm) to NaN so watershed
    % basins never extend beyond the refinement search domain.
    if isempty(grid) || ~isfield(cfg, 'pLimits') || ~isfield(cfg, 'rLimits')
        return;
    end
    % When using precomputed predictions data, follow data without artificial limits
    if isfield(cfg, 'dataSource') && cfg.dataSource == "predictions"
        return;
    end
    tol = 1e-9;
    pIn = pS(:)' >= cfg.pLimits(1) * 1e-3 - tol & pS(:)' <= cfg.pLimits(2) * 1e-3 + tol;
    rIn = rS(:) >= cfg.rLimits(1) * 1e-3 - tol & rS(:) <= cfg.rLimits(2) * 1e-3 + tol;
    grid(~(rIn & pIn)) = NaN;
end

function tbl = localFlagDuplicateOptima(tbl, candidateTable, valueField, reporter, primaryMetric)
    % Seeds from different grid basins that refine to the same continuous
    % optimum (≤ 1 nm apart) are one peak split by grid discretisation. The
    % lower-valued seed (ties: later seed) is marked "duplicate of <Tag>".
    if height(tbl) < 2 || ~ismember('Status', tbl.Properties.VariableNames)
        return;
    end
    hasTag = ismember('Tag', candidateTable.Properties.VariableNames);
    live = find(~tbl.IsFallback);
    [~, ord] = sort(tbl.(valueField)(live), 'descend');
    live = live(ord);
    for a = 1:numel(live)
        i = live(a);
        if startsWith(tbl.Status(i), "duplicate")
            continue;
        end
        for b = a+1:numel(live)
            j = live(b);
            if startsWith(tbl.Status(j), "duplicate")
                continue;
            end
            d_nm = 1e3 * hypot(tbl.P_um(i) - tbl.P_um(j), tbl.R_um(i) - tbl.R_um(j));
            if d_nm <= 1
                if hasTag
                    keepTag = string(candidateTable.Tag(tbl.SeedIndex(i)));
                    dupTag = string(candidateTable.Tag(tbl.SeedIndex(j)));
                else
                    keepTag = "#" + tbl.SeedIndex(i);
                    dupTag = "#" + tbl.SeedIndex(j);
                end
                tbl.Status(j) = "duplicate of " + keepTag;
                reporter.info(sprintf("[Metric_%s] %s refined to the same optimum as %s (%.2f nm apart).", ...
                    primaryMetric, dupTag, keepTag, d_nm));
            end
        end
    end
end

function starts = localFarthestPointStarts(seedPt, pool, nStarts, cellSize)
    % Greedy farthest-point sampling (in grid-cell units) seeded at seedPt.
    starts = seedPt;
    if nStarts <= 1 || isempty(pool)
        return;
    end
    scaledPool = pool ./ cellSize;
    dMin = hypot(scaledPool(:, 1) - seedPt(1) / cellSize(1), scaledPool(:, 2) - seedPt(2) / cellSize(2));
    for k = 2:nStarts
        [dBest, j] = max(dMin);
        if dBest < 1   % pool exhausted (all within one cell of a start)
            break;
        end
        starts(end + 1, :) = pool(j, :); %#ok<AGROW>
        dMin = min(dMin, hypot(scaledPool(:, 1) - scaledPool(j, 1), scaledPool(:, 2) - scaledPool(j, 2)));
    end
end

function tf = localInBasin(labels, pAx, rAx, pt, bid)
    % True when the grid cell nearest pt, or any of its 8 neighbours, is in basin bid.
    tf = false;
    if any(~isfinite(pt))
        return;
    end
    [dp, ip] = min(abs(pAx - pt(1)));
    [dr, ir] = min(abs(rAx - pt(2)));
    if numel(pAx) > 1 && dp > 1.5 * median(abs(diff(pAx))), return; end
    if numel(rAx) > 1 && dr > 1.5 * median(abs(diff(rAx))), return; end
    nb = labels(max(ir-1, 1):min(ir+1, size(labels, 1)), max(ip-1, 1):min(ip+1, size(labels, 2)));
    tf = labels(ir, ip) == bid || any(nb(:) == bid);
end

function localLogTableBuildInputs(reporter, contextLabel, varNames, varValues)
    try
        if isempty(reporter)
            return;
        end
        reporter.warn("TableBuildDebug", "[TableDebug] " + string(contextLabel));
        for vi = 1:numel(varNames)
            v = varValues{vi};
            sz = size(v);
            szStr = sprintf("%dx%d", sz(1), sz(2));
            cls = class(v);
            nEl = numel(v);
            msg = sprintf("[TableDebug] %s: class=%s size=%s numel=%d", varNames{vi}, cls, szStr, nEl);
            if iscell(v) && ~isempty(v)
                inner = v{1};
                msg = sprintf("%s innerClass=%s innerNumel=%d", msg, class(inner), numel(inner));
            end
            reporter.info(msg);
        end
    catch
        % Never let debug logging affect optimization flow.
    end
end

function res = buildEmptyResult(metricName)
    % buildEmptyResult  Return a placeholder result struct for skipped metrics.
    res = struct();
    res.metricName = metricName;
    res.candidateTable = table();
    res.maximaResults = table();
    res.avgMetricGrid = [];
    res.pSamples = [];
    res.rSamples = [];
    res.lambdaSamples = [];
    res.msSolutions = [];
    res.msOutput = [];
    res.attemptTrajectories = table();
    res.basinMap = [];
    res.gradMagnitude = [];
    res.laplacianField = [];
    res.divergenceField = [];
end
