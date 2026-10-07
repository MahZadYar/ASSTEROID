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
        pSeed = candidateTable.P_um(seedIdx);
        rSeed = candidateTable.R_um(seedIdx);
        if ismember('Tag', candidateTable.Properties.VariableNames)
            seedLabel = char(candidateTable.Tag(seedIdx));
        else
            seedLabel = sprintf("Seed #%d", seedIdx);
        end
        accepted = false;
        basinRejectCounts = zeros(maxSeeds, 1);

        for attempt = 1:maxRetryCount
            shrinkScale = retryShrink^(attempt - 1);
            attemptPadP = max(cfg.minLocalWindow, localPadP * shrinkScale);
            attemptPadR = max(cfg.minLocalWindow, localPadR * shrinkScale);

            pStartLocal = [max(pBounds(1), pSeed - attemptPadP), min(pBounds(2), pSeed + attemptPadP)];
            rStartLocal = [max(rBounds(1), rSeed - attemptPadR), min(rBounds(2), rSeed + attemptPadR)];

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
                seedLabel, seedIdx, maxSeeds, pSeed, rSeed, attempt, maxRetryCount));
            reporter.info(sprintf(...
                "[Metric_%s] %s attempt %d bounds: start p=[%.4f, %.4f], r=[%.4f, %.4f] | destination p=[%.4f, %.4f], r=[%.4f, %.4f]", ...
                primaryMetric, seedLabel, attempt, pStartLocal(1), pStartLocal(2), rStartLocal(1), rStartLocal(2), ...
                pBounds(1), pBounds(2), rBounds(1), rBounds(2)));

            try
                [localMax, localSolutions, localMsOutput, localAllRuns] = find_local_maxima(model, ri, subsampledLambda, ...
                    'MetricName', primaryMetric, ...
                    'InitialPoints', [pSeed, rSeed], ...
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
                            'InitialPoints', [pSeed, rSeed], ...
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
                    atBorder = pR <= pStartLocal(1) + borderTolP || ...
                               pR >= pStartLocal(2) - borderTolP || ...
                               rR <= rStartLocal(1) + borderTolR || ...
                               rR >= rStartLocal(2) - borderTolR;
                    if atBorder
                        validBorder(rowIdx) = false;
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
                reporter.warn("Metric_" + primaryMetric, sprintf(...
                    "%s produced no in-basin maxima at attempt %d/%d; shrinking start window by %.2f and retrying.", ...
                    seedLabel, attempt, maxRetryCount, retryShrink));
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
    res.gradMagnitude = [];
    res.laplacianField = [];
    res.divergenceField = [];
end
