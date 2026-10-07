function results = runAdaptiveSamplingWorkflow(cfg, reporter)
%runAdaptiveSamplingWorkflow Orchestrate the full adaptive sampling pipeline.
%
%   results = runAdaptiveSamplingWorkflow(cfg) executes the complete adaptive
%   sampling workflow: load data → build density → sample → query predictor
%   for new points → (visualise) → export.
%
%   The cfg.dataSource field controls how new sample points are evaluated:
%     "interpolation" — makima interpolation from raw COMSOL data
%     "model"         — DNN inference from a trained model
%
%   results = runAdaptiveSamplingWorkflow(cfg, reporter) reports progress
%   through a ProgressReporter instance (console, silent, or callback).
%
%   Inputs:
%       cfg      – struct from adaptiveSamplingConfig (or createSamplingConfig
%                  augmented with workDir, dataSource, modelFile, etc.).
%       reporter – (optional) ProgressReporter object. Defaults to silent.
%
%   Outputs:
%       results  – struct with fields:
%           .samples       – struct from loadSamplingData
%           .density       – struct from buildSamplingDensity
%           .samplingResult – struct from runAdaptiveSampling (.points, .count, ...)
%           .predictedMetrics – struct with metric predictions at new points
%           .predictor     – predictor struct used for inference
%           .cfg           – copy of the config used
%           .elapsedTotal  – total wall-clock time (seconds)
%
%   Example (CLI — interpolation):
%       cfg = adaptiveSamplingConfig(WorkDir="D:\data", DataFile="sweep.mat");
%       results = runAdaptiveSamplingWorkflow(cfg, ProgressReporter.console());
%
%   Example (CLI — model):
%       cfg = adaptiveSamplingConfig(DataSource="model", ...
%           ModelFile="model.mat", DataFile="sweep.mat");
%       results = runAdaptiveSamplingWorkflow(cfg, ProgressReporter.console());
%
%   See also: adaptiveSamplingConfig, createSamplingConfig,
%             loadSamplingData, buildSamplingDensity, runAdaptiveSampling,
%             buildPredictorFromConfig, ProgressReporter

arguments
    cfg      (1,1) struct
    reporter       = ProgressReporter.silent()
end

    totalTimer = tic;

    %% 0. Change working directory if specified
    if isfield(cfg, "workDir") && cfg.workDir ~= "" && cfg.workDir ~= string(pwd)
        cd(cfg.workDir);
        reporter.info("WorkDir", "Working directory: " + cfg.workDir);
    end

    %% 1. Load data
    reporter.start("LoadData");
    try
        samples = loadSamplingData(cfg);
        reporter.complete("LoadData", ...
            sprintf("Loaded %d data points with %d metrics.", ...
            samples.numPoints, numel(cfg.metricNames)));
    catch ME
        reporter.fail("LoadData", ME.message);
        rethrow(ME);
    end

    %% 2. Build density model
    reporter.start("BuildDensity");
    try
        density = buildSamplingDensity(cfg, samples);
        if cfg.uniformSampling
            reporter.complete("BuildDensity", "Using uniform density.");
        else
            reporter.complete("BuildDensity", ...
                sprintf("Density built (max=%.4g).", density.maxValue));
        end
    catch ME
        reporter.fail("BuildDensity", ME.message);
        rethrow(ME);
    end

    %% 3. Run rejection sampling
    reporter.start("RunSampling");
    reporter.progress("RunSampling", 0, sprintf("Generating %d points...", cfg.numPoints));
    try
        samplingResult = runAdaptiveSampling(cfg, samples, density);
        reporter.progress("RunSampling", 1, ...
            sprintf("Generated %d/%d points (%.1f%% acceptance).", ...
            samplingResult.count, cfg.numPoints, samplingResult.acceptanceRate * 100));
        reporter.complete("RunSampling", ...
            sprintf("%d points in %d attempts.", samplingResult.count, samplingResult.attempts));
    catch ME
        reporter.fail("RunSampling", ME.message);
        rethrow(ME);
    end

    %% 3b. Query predictor for metric values at new points
    predictedMetrics = struct();
    predictor = [];
    try
        reporter.start("QueryPredictor", "Evaluating metrics at new sample points...");
        predictor = buildPredictorFromConfig(cfg, Reporter=reporter);

        if samplingResult.count > 0
            predictedMetrics = queryPredictorAtPoints(predictor, samplingResult.points, ...
                samples, cfg, reporter);
        end
        reporter.complete("QueryPredictor", ...
            sprintf("Predicted %d targets at %d points.", ...
            numel(predictor.targetNames), samplingResult.count));
    catch ME
        reporter.warn("QueryPredictor", ...
            "Predictor evaluation failed: " + ME.message + ". Proceeding without predictions.");
    end

    %% 4. Visualise (optional)
    doVisualize = true;
    if isfield(cfg, "visualize")
        doVisualize = cfg.visualize;
    end

    if doVisualize
        reporter.start("Visualize");
        try
            colormapFile = "";
            if isfield(cfg, "colormapFile")
                colormapFile = cfg.colormapFile;
            end
            gridRes = 500;
            if isfield(cfg, "gridResolution")
                gridRes = cfg.gridResolution;
            end
            showOrig = ~isfield(cfg, "dataSource") || cfg.dataSource ~= "model";
            visualizeSamplingResults(cfg, samples, density, samplingResult, ...
                GridResolution=gridRes, ...
                ColormapFile=colormapFile, ...
                ShowOriginal=showOrig);
            reporter.complete("Visualize", "Sampling results plotted.");
        catch ME
            reporter.warn("Visualize", "Visualisation failed: " + ME.message);
        end
    end

    %% 5. Export to COMSOL
    reporter.start("Export");
    try
        origPoints = [samples.period(:), samples.radius(:)];
        precision = 6;
        if isfield(cfg, "precision")
            precision = cfg.precision;
        end

        exportToComsol(samplingResult, ...
            OutputFile=cfg.outputFile, ...
            ParamNames=cfg.paramNames, ...
            ParamUnits=cfg.paramUnits, ...
            IncludeOriginal=cfg.includeOriginal, ...
            OriginalPoints=origPoints, ...
            FilterToRange=cfg.useManualRange, ...
            PeriodRange=density.periodRange, ...
            RadiusRange=density.radiusRange, ...
            Precision=precision);
        reporter.complete("Export", "Exported to " + cfg.outputFile);
    catch ME
        reporter.fail("Export", ME.message);
        rethrow(ME);
    end

    %% Assemble results
    results = struct();
    results.samples        = samples;
    results.density        = density;
    results.samplingResult = samplingResult;
    results.predictedMetrics = predictedMetrics;
    results.predictor      = predictor;
    results.cfg            = cfg;
    results.elapsedTotal   = toc(totalTimer);

    reporter.info("Done", sprintf("Workflow completed in %.1f s.", results.elapsedTotal));

end

%% ========================================================================
function metrics = queryPredictorAtPoints(predictor, points, samples, cfg, reporter)
    %queryPredictorAtPoints  Evaluate predictor at generated sample coordinates.
    %
    %   For each new point, queries the predictor's averaged metric values.
    %   Returns a struct with .targetNames, .values [M x T], and .points [M x 2].

    numPoints = size(points, 1);
    targetNames = predictor.targetNames;
    numTargets = numel(targetNames);

    % Determine wavelength vector for spectral evaluation
    lambdaVec = [];
    if isfield(samples, "allData") && isfield(samples.allData, "lambda")
        lambdaVec = samples.allData.lambda(1, :);
    end

    % If we have spectral data, compute averaged values
    if ~isempty(lambdaVec)
        % Convert to predictor units (um for model, nm for interpolation)
        if predictor.mode == "model"
            lambdaQuery = lambdaVec * 1e-3;  % nm -> um
            pQuery = points(:, 1) * 1e-3;
            rQuery = points(:, 2) * 1e-3;
        else
            lambdaQuery = lambdaVec;
            pQuery = points(:, 1);
            rQuery = points(:, 2);
        end

        values = zeros(numPoints, numTargets);
        for i = 1:numPoints
            try
                spectral = predictor.predictSpectral(pQuery(i), rQuery(i), lambdaQuery);
                values(i, :) = mean(spectral, 1, "omitnan");
            catch
                values(i, :) = NaN;
            end

            if mod(i, max(1, floor(numPoints / 10))) == 0
                reporter.progress("QueryPredictor", i / numPoints, ...
                    sprintf("Queried %d/%d points...", i, numPoints));
            end
        end
    else
        values = NaN(numPoints, numTargets);
    end

    metrics = struct();
    metrics.targetNames = targetNames;
    metrics.values = values;
    metrics.points = points;

    % Create per-target named fields for convenience
    for t = 1:numTargets
        avgName = [targetNames{t}, '_avg'];
        metrics.(matlab.lang.makeValidName(avgName)) = values(:, t);
    end
end