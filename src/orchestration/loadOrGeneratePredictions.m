function allData = loadOrGeneratePredictions(options)
    % loadOrGeneratePredictions  Load cached predictions or regenerate from model.
    %
    %   allData = loadOrGeneratePredictions(Name=Value) either loads cached SoA
    %   predictions from a .mat file or generates new ones using a trained model.
    %   Handles both SoA (allData) and legacy (predictions) formats with automatic
    %   conversion.
    %
    %   This centralises the prediction loading/generation pattern found across
    %   run_locate_maxima, run_prediction_vis, and run_prediction_vis_app.
    %
    %   Name-Value Arguments:
    %       Recompute       (1,1) logical — Force regeneration (default: false)
    %       PredictionFile  (1,1) string  — Path to cached prediction .mat file
    %       Model           — Trained model struct (required if Recompute=true)
    %       Ri              — Refractive index struct (required if Recompute=true)
    %       PSamples        (1,:) double  — Period sample vector in µm
    %       RSamples        (1,:) double  — Radius sample vector in µm
    %       LambdaSamples   (1,:) double  — Wavelength sample vector in µm
    %       LambdaLaser     (1,1) double  — Laser wavelength in nm (default: 785)
    %       StokesShiftLimits (1,2) double — Raman window limits in cm^-1
    %       AnalyteSpectrum struct         — Optional analyte spectrum for weighting
    %       InterpResolution (1,1) double — Spectral interpolation resolution (cm^-1)
    %       SaveAfterGeneration (1,1) logical — Save generated predictions (default: true)
    %       Reporter        — Optional ProgressReporter for status feedback
    %
    %   Output:
    %       allData — SoA struct with dense predictions
    %
    %   See also: predict_dense_spectrum, convertGridToSoA, ProgressReporter

    arguments
        options.Recompute (1,1) logical = false
        options.PredictionFile (1,1) string = ""
        options.Model = []
        options.Ri = []
        options.PSamples (1,:) double = []
        options.RSamples (1,:) double = []
        options.LambdaSamples (1,:) double = []
        options.LambdaLaser (1,1) double = 785
        options.StokesShiftLimits (1,2) double = [100, 3600]
        options.MetricsShiftLimits double = []
        options.AnalyteSpectrum struct = struct()
        options.InterpResolution (1,1) double = 2
        options.BatchSize (1,1) double = 1000
        options.SaveAfterGeneration (1,1) logical = true
        options.Reporter = []
        options.ExecutionEnvironment (1,1) string {mustBeMember(options.ExecutionEnvironment, ["auto", "gpu", "cpu"])} = "auto"
        options.MiniBatchSize (1,1) double = 32768
    end

    reporter = options.Reporter;
    hasReporter = ~isempty(reporter) && isa(reporter, "ProgressReporter");

    %% Generate predictions if requested
    if options.Recompute
        if isempty(options.Model)
            error("loadOrGeneratePredictions:MissingModel", ...
                "Model required when Recompute=true.");
        end
        if isempty(options.Ri)
            try
                options.Ri = getDefaultRefractiveIndex(WavelengthUnit="um");
            catch
                error("loadOrGeneratePredictions:MissingRI", ...
                    "Refractive index struct required when Recompute=true.");
            end
        elseif isstruct(options.Ri) && (~isfield(options.Ri, "nFunc") || ~isfield(options.Ri, "kFunc")) ...
                && isfield(options.Ri, "lambda") && isfield(options.Ri, "n") && isfield(options.Ri, "k")
            try
                Fn = griddedInterpolant(double(options.Ri.lambda(:)), double(options.Ri.n(:)), 'linear', 'nearest');
                Fk = griddedInterpolant(double(options.Ri.lambda(:)), double(options.Ri.k(:)), 'linear', 'nearest');
                isNm = (max(options.Ri.lambda(:)) > 50);
                options.Ri.nFunc = @(lq) localEvalRI(Fn, double(lq), isNm);
                options.Ri.kFunc = @(lq) localEvalRI(Fk, double(lq), isNm);
            catch
                % pass
            end
        end
        if isempty(options.PSamples) || isempty(options.RSamples) || isempty(options.LambdaSamples)
            error("loadOrGeneratePredictions:MissingGrid", ...
                "PSamples, RSamples, and LambdaSamples required when Recompute=true.");
        end

        if hasReporter
            reporter.start("GeneratePredictions", "Generating dense predictions (SoA format)...");
        end

        % Build argument list for predict_dense_spectrum
        predArgs = { ...
            "LaserWavelength", options.LambdaLaser, ...
            "RamanWindow", options.StokesShiftLimits, ...
            "BatchSize", options.BatchSize, ...
            "ExecutionEnvironment", options.ExecutionEnvironment, ...
            "MiniBatchSize", options.MiniBatchSize ...
        };

        % Wire progress reporting
        if hasReporter
            predArgs = [predArgs, {"ProgressFcn", ...
                @(frac, msg) reporter.progress("GeneratePredictions", frac, msg)}];
        end

        % Add optional analyte spectrum
        if ~isempty(fieldnames(options.AnalyteSpectrum))
            predArgs = [predArgs, {"AnalyteSpectrum", options.AnalyteSpectrum}];
        end

        % Add optional interpolation resolution
        if options.InterpResolution > 0
            predArgs = [predArgs, {"InterpResolution", options.InterpResolution}];
        end

        % Add optional separate metrics window
        if ~isempty(options.MetricsShiftLimits)
            predArgs = [predArgs, {"MetricsRamanWindow", options.MetricsShiftLimits}];
        end

        allData = predict_dense_spectrum(options.Model, ...
            options.PSamples, options.RSamples, options.LambdaSamples, options.Ri, ...
            predArgs{:});

        allData = localNormalizePredictionFieldNames(allData);

        % Save if requested
        if options.SaveAfterGeneration && strlength(options.PredictionFile) > 0
            save(options.PredictionFile, "allData");
            if hasReporter
                reporter.info(sprintf("Saved predictions to %s", options.PredictionFile));
            end
        end

        if hasReporter
            reporter.complete("GeneratePredictions", sprintf( ...
                "Generated %d geometries × %d wavelengths.", ...
                size(allData.lambda, 1), size(allData.lambda, 2)));
        end
        return;
    end

    %% Load from file
    if strlength(options.PredictionFile) == 0
        error("loadOrGeneratePredictions:NoSource", ...
            "Either set Recompute=true or provide a PredictionFile path.");
    end

    if ~isfile(options.PredictionFile)
        error("loadOrGeneratePredictions:MissingFile", ...
            "Prediction file not found: %s. Set Recompute=true to regenerate.", ...
            options.PredictionFile);
    end

    if hasReporter
        reporter.start("LoadPredictions", sprintf( ...
            "Loading predictions from %s...", options.PredictionFile));
    end

    loadedPred = load(options.PredictionFile);

    % Support both SoA (allData) and legacy (predictions) format
    if isfield(loadedPred, "allData")
        allData = localNormalizePredictionFieldNames(loadedPred.allData);
        if hasReporter
            reporter.complete("LoadPredictions", "Loaded predictions (SoA format).");
        end

    elseif isfield(loadedPred, "predictions")
        if hasReporter
            reporter.warn("LoadPredictions", "Converting legacy grid format to SoA...");
        end
        allData = convertGridToSoA(loadedPred.predictions, ...
            "LaserWavelength", options.LambdaLaser, ...
            "RamanWindow", options.StokesShiftLimits);
        allData = localNormalizePredictionFieldNames(allData);
        if hasReporter
            reporter.complete("LoadPredictions", "Converted legacy predictions to SoA format.");
        end

    else
        error("loadOrGeneratePredictions:InvalidFile", ...
            "File %s does not contain 'allData' or 'predictions' variable.", ...
            options.PredictionFile);
    end
end

function allData = localNormalizePredictionFieldNames(allData)
%localNormalizePredictionFieldNames Ensure canonical derived metric fields exist.
    if ~isstruct(allData)
        return;
    end

    % Legacy -> canonical aliases
    aliasMap = struct( ...
        "Abs_laser", "Absorptance_laser", ...
        "Abs_avg", "Absorptance_avg", ...
        "BEE_vol", "EF_vol_avg", ...
        "BEE_surf", "EF_surf_avg", ...
        "AEE_vol", "EF_vol_analyte", ...
        "AEE_surf", "EF_surf_analyte", ...
        "EF_vol_approx", "EF_vol_laser", ...
        "EF_surf_approx", "EF_surf_laser");

    oldNames = fieldnames(aliasMap);
    for i = 1:numel(oldNames)
        oldName = oldNames{i};
        newName = aliasMap.(oldName);
        if isfield(allData, oldName) && ~isfield(allData, newName)
            allData.(newName) = allData.(oldName);
        end
    end

    % Defensive synthesis for key laser fields if missing.
    % Use RamanShift (nearest to shift=0) when available; fall back to column 1.
    laserCol = 1;
    if isfield(allData, "RamanShift") && isnumeric(allData.RamanShift) && ~isempty(allData.RamanShift)
        shRow = allData.RamanShift;
        if ismatrix(shRow) && size(shRow, 1) > 1
            shRow = shRow(1, :);  % shared lambda grid — use first row
        end
        [~, laserCol] = min(abs(shRow));
    end

    laserFields = {"Absorptance", "EF_vol", "EF_surf"};
    for k = 1:numel(laserFields)
        baseName = laserFields{k};
        laserName = baseName + "_laser";
        if ~isfield(allData, laserName) && isfield(allData, baseName)
            v = allData.(baseName);
            if isnumeric(v)
                if ismatrix(v) && size(v, 2) >= laserCol
                    allData.(laserName) = v(:, laserCol);
                elseif isvector(v)
                    allData.(laserName) = v(:);
                end
            end
        end
    end
end

function vals = localEvalRI(interpolant, lq, isInternalNm)
    lq = double(lq);
    if isempty(lq)
        vals = zeros(size(lq));
        return;
    end
    if isInternalNm
        scaleMask = (lq < 10);
        if any(scaleMask(:))
            lq(scaleMask) = lq(scaleMask) * 1000;
        end
    else
        scaleMask = (lq >= 10);
        if any(scaleMask(:))
            lq(scaleMask) = lq(scaleMask) * 1e-3;
        end
    end
    vals = interpolant(lq);
end
