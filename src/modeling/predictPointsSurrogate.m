function allDataRaw = predictPointsSurrogate(options)
%predictPointsSurrogate Evaluate surrogate model at explicit (P, R) coordinate points.
%   allDataRaw = predictPointsSurrogate(Name=Value)
%
%   Name-Value Arguments:
%       Model               - Trained surrogate neural network model struct
%       Ri                  - Refractive index struct with nFunc/kFunc
%       P                   - [N × 1] Period coordinates (nm)
%       R                   - [N × 1] Radius coordinates (nm)
%       LambdaSamples       - Wavelength samples (nm or µm)
%       LambdaLaser         - Laser wavelength in nm (default: 785)
%       StokesShiftLimits   - [min, max] Stokes shift in cm⁻¹ (default: [100, 3600])
%       InterpResolution    - Stokes shift resolution in cm⁻¹ (default: 5)
%       AnalyteSpectrum     - Analyte spectrum struct (optional)
%       BatchSize           - Batch evaluation size (default: 1000)
%       Reporter            - ProgressReporter instance (optional)
%       MetricsWindow       - Optional [min, max] cm⁻¹ for derived metrics
%       ExecutionEnvironment - "cpu" or "gpu" (default: "cpu")
%
%   See also: createModelPredictor, buildPointPredictionSoA

    arguments
        options.Model
        options.Ri
        options.P double
        options.R double
        options.LambdaSamples double
        options.LambdaLaser double = 785
        options.StokesShiftLimits double = [100, 3600]
        options.InterpResolution double = 5
        options.AnalyteSpectrum struct = struct()
        options.BatchSize double = 1000
        options.Reporter = []
        options.MetricsWindow double = []
        options.ExecutionEnvironment string = "cpu"
    end

    predictor = createModelPredictor(options.Model, options.Ri, ...
        "ExecutionEnvironment", options.ExecutionEnvironment);

    allDataRaw = buildPointPredictionSoA( ...
        predictor, options.P, options.R, options.LambdaSamples, ...
        options.LambdaLaser, options.StokesShiftLimits, options.InterpResolution, ...
        options.AnalyteSpectrum, options.Reporter, "PredictInterpolate", options.MetricsWindow);
end
