function results = runPredictionVisWorkflow(cfg, reporter)
%runPredictionVisWorkflow Orchestrate dense prediction + visualisation.
%
%   results = runPredictionVisWorkflow(cfg) loads a trained model, produces
%   dense SoA predictions, and visualises each requested metric (spectral-
%   average maps, laser-wavelength maps, and optional 3-D volume renders).
%
%   results = runPredictionVisWorkflow(cfg, reporter) reports progress
%   through a ProgressReporter instance.
%
%   Inputs:
%       cfg      – struct from predictionVisConfig.
%       reporter – (optional) ProgressReporter. Defaults to silent.
%
%   Outputs:
%       results  – struct with fields:
%           .allData      – SoA prediction data
%           .model        – loaded DNN model struct
%           .ri           – refractive index struct
%           .cfg          – config snapshot
%           .figures      – cell array of figure handles (one per metric)
%           .elapsedTotal – wall-clock seconds
%
%   See also: predictionVisConfig, loadAndValidateModel,
%             loadOrGeneratePredictions, reshapeSoAToVolume, ProgressReporter

arguments
    cfg      (1,1) struct
    reporter       = ProgressReporter.silent()
end

    totalTimer = tic;

    %% 0. Working directory
    if cfg.workDir ~= "" && cfg.workDir ~= string(pwd)
        cd(cfg.workDir);
    end

    cmap = flipud(loadColormap("AuroraAustralis.txt", 4095));

    %% 1. Load model & RI
    reporter.start("LoadModel");
    try
        [model, ri] = loadAndValidateModel(...
            ModelFile=cfg.modelFile, RiCsvFile=cfg.riCsvFile, Reporter=reporter);
        reporter.complete("LoadModel", "Model and RI loaded.");
    catch ME
        reporter.fail("LoadModel", ME.message);
        rethrow(ME);
    end

    %% 2. Load analyte spectrum (optional)
    analyteSpectrum = struct();
    if cfg.useAnalyteWeighting && isfile(cfg.analyteRamanSpectrumFile)
        reporter.start("LoadAnalyte");
        try
            analyteSpectrum = loadAndNormalizeAnalyteSpectrum(cfg.analyteRamanSpectrumFile);
            if isfield(analyteSpectrum, "shift_cm")
                reporter.complete("LoadAnalyte", "Analyte spectrum loaded.");
            else
                reporter.warn("LoadAnalyte", "Analyte spectrum empty; analyte metrics will be NaN.");
                analyteSpectrum = struct();
            end
        catch ME
            reporter.warn("LoadAnalyte", "Failed: " + ME.message);
        end
    end

    %% 3. Generate or load predictions
    % Resolve metrics window: use separate limits if not linked to grid
    metricsShiftLimits = [];
    if isfield(cfg, 'metricsShiftLimits') && ~isequal(cfg.metricsShiftLimits, cfg.stokesShiftLimits)
        metricsShiftLimits = cfg.metricsShiftLimits;
    end

    reporter.start("Predictions");
    try
        predArgs = { ...
            "Recompute", cfg.recomputePredictions, ...
            "PredictionFile", cfg.predictionFile, ...
            "Model", model, ...
            "Ri", ri, ...
            "PSamples", cfg.pSamples, ...
            "RSamples", cfg.rSamples, ...
            "LambdaSamples", cfg.lambdaSamples, ...
            "LambdaLaser", cfg.lambdaLaser, ...
            "StokesShiftLimits", cfg.stokesShiftLimits, ...
            "AnalyteSpectrum", analyteSpectrum, ...
            "InterpResolution", cfg.stokesShiftResolution, ...
            "SaveAfterGeneration", cfg.exportPredictions, ...
            "Reporter", reporter};
        if ~isempty(metricsShiftLimits)
            predArgs = [predArgs, {"MetricsShiftLimits", metricsShiftLimits}];
        end
        allData = loadOrGeneratePredictions(predArgs{:});
        reporter.complete("Predictions", ...
            sprintf("SoA ready: %d geometries, %d wavelengths.", ...
            size(allData.lambda, 1), size(allData.lambda, 2)));
    catch ME
        reporter.fail("Predictions", ME.message);
        rethrow(ME);
    end

    %% 4. Per-metric visualisation
    numMetrics = numel(cfg.metrics);
    figures = cell(numMetrics, 1);

    for mIdx = 1:numMetrics
        metricName  = cfg.metrics(mIdx);
        metricField = char(matlab.lang.makeValidName(metricName));
        metricAvgField = char(resolveDerivedMetricField(metricName, "avg", allData));
        metricLabel = strrep(metricName, "_", "\_");

        stepName = sprintf("Vis_%s", char(metricName));
        reporter.start(stepName);

        if ~isfield(allData, metricField)
            reporter.warn(stepName, sprintf("Field %s missing; skipping.", metricField));
            continue
        end

        % Reshape SoA → volume
        [metricVolume, pGrid_nm, rGrid_nm, lambdaGrid_nm] = ...
            reshapeSoAToVolume(allData, metricField);

        % --- Laser-wavelength map ---
        [~, laserIdx] = min(abs(lambdaGrid_nm - cfg.lambdaLaser));
        laserMetricGrid = double(metricVolume(:, :, laserIdx));

        figLaser = figure;
        hP = pcolor(pGrid_nm, rGrid_nm, laserMetricGrid);
        set(hP, "EdgeColor", "none", "FaceColor", "interp");
        colormap(cmap); colorbar;
        xlabel("p (nm)"); ylabel("r (nm)");
        title(sprintf("%s at λ = %.1f nm", metricLabel, cfg.lambdaLaser));
        if cfg.exportGraphics
            saveas(figLaser, fullfile(cfg.workDir, ...
                sprintf("prediction_%s_laser.png", metricField)));
        end

        % --- Spectral-average map ---
        if isfield(allData, metricAvgField)
            [avgMap, ~, ~, ~] = reshapeSoAToVolume(allData, metricAvgField);
            avgGrid = double(avgMap);

            figAvg = figure;
            hP2 = pcolor(pGrid_nm, rGrid_nm, avgGrid);
            set(hP2, "EdgeColor", "none", "FaceColor", "interp");
            colormap(cmap); colorbar;
            xlabel("p (nm)"); ylabel("r (nm)");
            title(sprintf("Average %s across %.1f<λ<%.1f nm", ...
                metricLabel, lambdaGrid_nm(2), lambdaGrid_nm(end)));
            if cfg.exportGraphics
                saveas(figAvg, fullfile(cfg.workDir, ...
                    sprintf("prediction_%s_avg.png", metricField)));
            end
        end

        % --- 3-D volume render ---
        renderVolumeVis(metricVolume, pGrid_nm, rGrid_nm, lambdaGrid_nm, ...
            cmap, cfg, metricField);

        figures{mIdx} = struct("laser", figLaser);
        reporter.complete(stepName, sprintf("%s visualised.", char(metricName)));
    end

    %% 5. Pack into unified database
    if isfield(cfg, 'databaseFile') && strlength(cfg.databaseFile) > 0
        reporter.start("PackDB", "Packing predictions into database...");
        dbFile = cfg.databaseFile;
        if isfile(dbFile)
            db = load(dbFile, "db").db;
        else
            db = createDatabaseStruct();
        end
        db.Pred = populateBranch(allData, "Prediction.DNN", ...
            "ModelRef", "Model", ...
            "LaserWl", cfg.lambdaLaser, ...
            "StokesWindow", cfg.stokesShiftLimits, ...
            "Resolution", cfg.resolution);
        save(dbFile, "db", "-v7.3"); %#ok<NASGU>
        reporter.complete("PackDB", sprintf("Saved db.Pred to %s", dbFile));
    end

    %% Assemble output
    results = struct();
    results.allData      = allData;
    results.model        = model;
    results.ri           = ri;
    results.cfg          = cfg;
    results.figures      = figures;
    results.elapsedTotal = toc(totalTimer);

    reporter.info(sprintf("Prediction-vis workflow completed in %.1f s.", results.elapsedTotal));

end

%% ========================================================================
%  LOCAL HELPER: 3-D volume render via volshow
%  ========================================================================
function renderVolumeVis(metricVolume, pGrid_nm, rGrid_nm, lambdaGrid_nm, cmap, cfg, metricField)
    volData = double(metricVolume);
    xData = pGrid_nm;
    yData = rGrid_nm;
    zData = lambdaGrid_nm;

    volMin = min(volData(:), [], "omitnan");
    volMax = max(volData(:), [], "omitnan");
    volRange = volMax - volMin;
    if volRange > 0
        volNorm = (volData - volMin) / volRange;
    else
        volNorm = zeros(size(volData));
    end
    volNorm(~isfinite(volNorm)) = 0;

    epsilon = 1e-4;
    alphaMap = log(linspace(epsilon, 1, 4095));
    alphaMap = 1 - alphaMap / min(alphaMap);

    lx = max(xData(:)) - min(xData(:));
    ly = max(yData(:)) - min(yData(:));
    lz = min(zData(:)) - max(zData(:));
    sx = lx / size(xData, 2);
    sy = ly / size(yData, 2);
    sz = lz / size(zData, 2);
    A = [sx 0 0 0; 0 sy 0 0; 0 0 sz 0; 0 0 0 1];
    tform = affinetform3d(A);

    h = volshow(volNorm * 4095, ...
        "DisplayRangeMode", "12-bit", ...
        "RenderingStyle", "GradientOpacity", ...
        "GradientOpacityValue", 0.2, ...
        "Colormap", cmap, ...
        "Alphamap", alphaMap, ...
        "Transformation", tform, ...
        "Interpolation", "bilinear");

    viewer = h.Parent;
    hFig = viewer.Parent;
    viewer.Lighting = "on";
    viewer.LightPositionMode = "target-right";
    viewer.Box = "off";
    viewer.ScaleBar = "on";
    viewer.ScaleBarStyle = "measure";
    viewer.BackgroundColor = "black";
    viewer.BackgroundGradient = "off";
    viewer.SpatialUnits = "nm";
    viewer.RenderingQuality = "high";
    viewer.Toolbar = "off";
    viewer.OrientationAxes = "off";

    offset = [sx sy sz] / 2;
    xAxis = images.ui.graphics.roi.Line(Position=[0 0 0; lx 0 0] + [offset; offset]);
    xAxis.Label = "Lattice Period";
    yAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 ly 0] + [offset; offset]);
    yAxis.Label = "Particle Size";
    zAxis = images.ui.graphics.roi.Line(Position=[0 0 0; 0 0 lz] + [offset; offset]);
    zAxis.Label = "Wavelength";
    pOrig = images.ui.graphics.roi.Point(Position=[0 0 0] + offset);
    pOrig.Label = sprintf("P = %.0f nm\nD = %.0f nm\nλ = %.0f nm", ...
        min(xData(:)), 2 * min(yData(:)), min(zData(:)));
    pX = images.ui.graphics.roi.Point(Position=[lx 0 0] + offset);
    pX.Label = sprintf("P = %.0f nm", max(xData(:)));
    pY = images.ui.graphics.roi.Point(Position=[0 ly 0] + offset);
    pY.Label = sprintf("D = %.0f nm", 2 * max(yData(:)));
    pZ = images.ui.graphics.roi.Point(Position=[0 0 lz] + offset);
    pZ.Label = sprintf("λ = %.0f nm", max(zData(:)));
    viewer.Annotations = [xAxis yAxis zAxis pOrig pX pY pZ];

    szVol = size(volNorm);
    center = [szVol(2) szVol(1) -szVol(3)] / 2;
    dist = sqrt(szVol(1)^2 + szVol(2)^2 + szVol(3)^2);
    viewer.CameraPosition = center + [cos(3 * pi / 4), sin(3 * pi / 4), 1] * dist;
    viewer.CameraTarget = center;
    viewer.CameraUpVector = [0 1 0];

    % Video export
    if cfg.exportVideo
        numFrames = cfg.videoFrames;
        vec = linspace(0, 2 * pi, numFrames)' + 3 * pi / 4;
        hFig.Position = [10 10 cfg.videoSize(1) cfg.videoSize(2)];
        videoFile = fullfile(cfg.workDir, sprintf("prediction_%s_3Dvis.mp4", metricField));
        v = VideoWriter(videoFile, "Archival");
        v.FrameRate = 30;
        v.MJ2BitDepth = 12;
        open(v);
        for fIdx = 1:numFrames
            viewer.CameraPosition = center + [cos(vec(fIdx)), sin(vec(fIdx)), 1] * dist;
            writeVideo(v, getframe(hFig));
        end
        close(v);
    end
end
