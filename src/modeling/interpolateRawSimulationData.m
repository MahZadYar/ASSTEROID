function interpData = interpolateRawSimulationData(simData, gp, options)
%interpolateRawSimulationData Interpolate raw simulation data onto dense grid.
%   interpData = interpolateRawSimulationData(simData, gp, Name=Value)
%
%   Inputs:
%       simData - Structure containing simulation dataset (period, radius, spectra)
%       gp      - Grid parameters structure from computeDenseGridParams
%
%   Name-Value Arguments:
%       SpatialMethod  - Spatial interpolation method: "linear", "natural", "nearest"
%       SpectralMethod - Spectral interpolation method: "makima", "spline", "linear", "pchip"
%       Reporter       - ProgressReporter instance (optional)
%       BatchSize      - Evaluation batch size (default: 1000)
%       TargetNames    - String array of target names to interpolate (optional)
%
%   See also: createDataPredictor, computeDenseGridParams

    arguments
        simData struct
        gp struct
        options.SpatialMethod string = "linear"
        options.SpectralMethod string = "makima"
        options.Reporter = []
        options.BatchSize double = 1000
        options.TargetNames string = string.empty
    end

    if isempty(options.TargetNames)
        candidateTargets = ["Absorptance", "EF_vol", "EF_surf", "M_vol", "M_surf"];
        fn = string(fieldnames(simData));
        targetNames = intersect(candidateTargets, fn);
        if isempty(targetNames)
            targetNames = setdiff(fn, ["period", "radius", "lambda", "LaserWl", "lambda_exc_nm", ...
                "RamanWindow", "RamanShift", "idx", "nanFiltered", "entry_id"]);
        end
    else
        targetNames = options.TargetNames;
    end

    laserWl = 785;
    if isfield(gp, "lambdaLaser") && ~isempty(gp.lambdaLaser)
        laserWl = gp.lambdaLaser;
    end

    predictor = createDataPredictor(simData, ...
        TargetNames=targetNames, ...
        InterpMethod=options.SpatialMethod, ...
        SpectralMethod=options.SpectralMethod, ...
        LaserWavelength=laserWl);

    repFcn = [];
    if ~isempty(options.Reporter)
        repFcn = @(frac, msg) options.Reporter.progress("Interpolate", frac, msg);
    end

    interpData = predictor.predictGrid( ...
        gp.pSamples, gp.rSamples, gp.lambdaSamples, ...
        "LaserWavelength", laserWl, ...
        "RamanWindow", gp.stokesShiftLimits, ...
        "BatchSize", options.BatchSize, ...
        "ProgressFcn", repFcn);
end
