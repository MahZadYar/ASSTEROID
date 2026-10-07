function allData = buildPointPredictionSoA(predictor, periodNm, radiusNm, lambdaSamples, ...
    laserWl, stokesShiftLimits, stokesRes, analyteSpectrum, reporter, progressStepName, metricsRamanWindow)
%buildPointPredictionSoA Predict spectra for explicit (period, radius) coordinate pairs.
%   Builds SoA struct from per-point predictor evaluations and computes
%   derived metrics (avg, laser, analyte).
%
%   Inputs:
%       predictor        - Model or data predictor with predictSpectral method.
%       periodNm         - [N × 1] period values in nm.
%       radiusNm         - [N × 1] radius values in nm.
%       lambdaSamples    - Wavelength samples (nm or µm, auto-detected).
%       laserWl          - Laser wavelength in nm.
%       stokesShiftLimits - [min, max] Stokes shift in cm⁻¹.
%       stokesRes        - Spectral interpolation resolution (cm⁻¹ per point).
%       analyteSpectrum  - Analyte spectrum struct (or empty struct).
%       reporter         - ProgressReporter instance.
%       progressStepName - Step name for progress reporting.
%       metricsRamanWindow - Optional [min, max] cm⁻¹ for derived metrics
%                            (defaults to stokesShiftLimits when empty).

    arguments
        predictor
        periodNm double
        radiusNm double
        lambdaSamples double
        laserWl double = 785
        stokesShiftLimits double = [100, 3600]
        stokesRes double = 5
        analyteSpectrum struct = struct()
        reporter = []
        progressStepName string = "Predict"
        metricsRamanWindow double = []
    end

    numPoints = numel(periodNm);
    lambdaNm = double(lambdaSamples(:)');
    if max(lambdaNm) < 10
        lambdaNm = lambdaNm * 1e3;
    end
    numLambda = numel(lambdaNm);
    targetNames = string(predictor.targetNames);

    allData = struct();
    allData.period = periodNm(:);
    allData.radius = radiusNm(:);
    allData.lambda = lambdaNm;                          % [1×L] — shared grid
    allData.LaserWl = repmat(double(laserWl), numPoints, 1);
    allData.lambda_exc_nm = repmat(double(laserWl), numPoints, 1);
    allData.RamanWindow = double(stokesShiftLimits(:)');  % [1×2] metadata
    allData.RamanShift = (1 ./ laserWl - 1 ./ lambdaNm) * 1e7; % [1×L] — shared grid

    for t = 1:numel(targetNames)
        allData.(targetNames(t)) = nan(numPoints, numLambda);
    end

    queryLambda = lambdaNm;
    queryP = periodNm;
    queryR = radiusNm;
    if isfield(predictor, "mode") && predictor.mode == "model"
        queryLambda = lambdaNm * 1e-3;
        queryP = periodNm * 1e-3;
        queryR = radiusNm * 1e-3;
    end

    % Use batch evaluation when available (interpolation predictor with vectorised
    % DT + barycentric spatial interpolation): avoids per-point overhead.
    if isfield(predictor, "predictPointsBatch") && ~isempty(predictor.predictPointsBatch)
        numT = numel(targetNames);
        numLraw = numel(predictor.lambdaGrid);
        if ~isempty(reporter)
            reporter.progress(progressStepName, 0.35, sprintf( ...
                "Batch eval: %d pts × %d targets × %d lambda-slices...", numPoints, numT, numLraw));
        end
        % Build a per-target callback so each pass reports in the app log.
        capturedReporter   = reporter;
        capturedStepName   = progressStepName;
        capturedNumPoints  = numPoints;
        capturedTargetNames = targetNames;
        batchProgressCb = @(t, nT, nL) localBatchProgress( ...
            capturedReporter, capturedStepName, capturedNumPoints, ...
            capturedTargetNames, t, nT, nL);
        batchResult = predictor.predictPointsBatch(queryP, queryR, queryLambda, batchProgressCb);
        for t = 1:numel(targetNames)
            allData.(targetNames(t)) = batchResult(:, :, t);
        end
        if ~isempty(reporter)
            reporter.progress(progressStepName, 0.80, sprintf( ...
                "Spectral batch complete. Computing derived metrics (%d pts)...", numPoints));
        end
        drawnow limitrate;
    else
        % Per-point loop (model predictors or fallback)
        progressStep = max(1, round(numPoints / 20));
        for i = 1:numPoints
            if ~isempty(reporter) && (mod(i, progressStep) == 0 || i == numPoints)
                reporter.progress(progressStepName, i / numPoints, ...
                    sprintf("Evaluating point %d/%d", i, numPoints));
            end
            spectra = predictor.predictSpectral(queryP(i), queryR(i), queryLambda);
            for t = 1:numel(targetNames)
                allData.(targetNames(t))(i, :) = spectra(:, t)';
            end
            if mod(i, 5) == 0
                drawnow limitrate;
                if ~isempty(reporter) && ismethod(reporter, "isStopRequested") && reporter.isStopRequested()
                    error("Process:Terminated", "Prediction terminated by user.");
                end
            end
        end
    end

    derivedWindow = stokesShiftLimits;
    if ~isempty(metricsRamanWindow)
        derivedWindow = metricsRamanWindow;
    end
    derivedCfg = importSweepConfig( ...
        LaserWavelength=laserWl, ...
        RamanWindow=derivedWindow, ...
        DetectShiftWindow=false, ...
        InterpResolution=stokesRes, ...
        SpectralInterpMethod="makima");
    [allData, ~] = recomputeDerivedMetrics(allData, derivedCfg, analyteSpectrum, reporter);
end

%% ========================================================================
function localBatchProgress(reporter, stepName, numPts, targetNames, t, numT, numLraw)
%localBatchProgress  Send per-target progress message from inside batch eval.
    if isempty(reporter), return; end
    frac = 0.35 + 0.45 * t / numT;
    tname = "";
    if t <= numel(targetNames)
        tname = " (" + targetNames(t) + ")";
    end
    reporter.progress(stepName, frac, sprintf( ...
        "Target %d/%d%s: evaluating %d pts × %d lambda-slices...", ...
        t, numT, tname, numPts, numLraw));
    drawnow limitrate;
    if ismethod(reporter, "isStopRequested") && reporter.isStopRequested()
        error("Process:Terminated", "Prediction terminated by user.");
    end
end
