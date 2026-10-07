function cfg = predictionVisConfig(options)
%predictionVisConfig Build configuration for prediction visualisation workflow.
%
%   cfg = predictionVisConfig() returns a struct with default parameters.
%
%   cfg = predictionVisConfig(Name=Value) customizes any parameter.
%   Metric names are resolved through normalizeMetricNames for alias safety.
%
%   The returned struct is consumed by runPredictionVisWorkflow and reuses
%   shared orchestration utilities (computeDenseGridParams, loadAndValidateModel,
%   loadOrGeneratePredictions).
%
%   Example:
%       cfg = predictionVisConfig( ...
%           WorkDir="D:\data", ...
%           ModelFile="sers_dnn_model.mat", ...
%           RiCsvFile="McPeak.csv", ...
%           Metrics=["Absorptance", "EF_vol", "EF_surf"]);
%
%   See also: runPredictionVisWorkflow, computeDenseGridParams,
%             loadAndValidateModel, normalizeMetricNames, ProgressReporter

arguments
    %% Paths
    options.WorkDir        (1,1) string = pwd
    options.ModelFile      (1,1) string = ""
    options.RiCsvFile      (1,1) string = ""
    options.PredictionFile (1,1) string = ""

    %% Grid parameters
    options.LambdaLaser           (1,1) double {mustBePositive} = 785
    options.PLimits               (1,2) double = [750, 950]
    options.RLimits               (1,2) double = [50, 450]
    options.StokesShiftLimits     (1,2) double = [100, 3600]
    options.Resolution            (1,1) double {mustBePositive} = 0.75
    options.StokesShiftResolution (1,1) double {mustBePositive} = 2

    %% Metrics window (independent of spectral grid)
    options.LinkMetricsToGrid     (1,1) logical = true
    options.MetricsShiftLimits    (1,2) double  = [100, 3600]

    %% Metrics
    options.Metrics (1,:) string = ["Absorptance", "EF_vol", "EF_surf"]

    %% Prediction control
    options.RecomputePredictions (1,1) logical = false

    %% Database
    options.DatabaseFile (1,1) string = "database.mat"

    %% Analyte weighting (optional)
    options.UseAnalyteWeighting       (1,1) logical = true
    options.AnalyteRamanSpectrumFile  (1,1) string  = "AnalyteSpectrum_electrolyte.dat"

    %% Export / visualisation
    options.ExportPredictions (1,1) logical = true
    options.ExportGraphics    (1,1) logical = true
    options.ExportVideo       (1,1) logical = false
    options.VideoFrames       (1,1) double {mustBePositive, mustBeInteger} = 360
    options.VideoSize         (1,2) double {mustBePositive, mustBeInteger} = [1080, 1080]
end

    %% Compute grid parameters via shared utility
    grid = computeDenseGridParams( ...
        LambdaLaser           = options.LambdaLaser, ...
        PLimits               = options.PLimits, ...
        RLimits               = options.RLimits, ...
        StokesShiftLimits     = options.StokesShiftLimits, ...
        Resolution            = options.Resolution, ...
        StokesShiftResolution = options.StokesShiftResolution, ...
        OutputUnit            = "um");

    %% Normalise metric names
    metrics = normalizeMetricNames(options.Metrics);

    %% Auto-generate prediction file name if not supplied
    predictionFile = options.PredictionFile;
    if predictionFile == ""
        [~, modelBase, modelExt] = fileparts(options.ModelFile);
        predictionFile = fullfile(options.WorkDir, ...
            sprintf("%s%s_predictions_(%s).mat", modelBase, modelExt, strjoin(metrics, "_")));
    end

    %% Assemble config struct
    cfg = struct();

    % Paths
    cfg.workDir        = options.WorkDir;
    cfg.modelFile      = options.ModelFile;
    cfg.riCsvFile      = options.RiCsvFile;
    cfg.predictionFile = predictionFile;

    % Grid (in µm, ready for model consumption)
    cfg.pSamples      = grid.pSamples;
    cfg.rSamples      = grid.rSamples;
    cfg.lambdaSamples = grid.lambdaSamples;

    % Physical parameters (nm, for display and metadata)
    cfg.lambdaLaser           = options.LambdaLaser;
    cfg.pLimits               = options.PLimits;
    cfg.rLimits               = options.RLimits;
    cfg.stokesShiftLimits     = options.StokesShiftLimits;
    cfg.resolution            = options.Resolution;
    cfg.stokesShiftResolution = options.StokesShiftResolution;

    % Metrics window
    cfg.linkMetricsToGrid = options.LinkMetricsToGrid;
    if options.LinkMetricsToGrid
        cfg.metricsShiftLimits = options.StokesShiftLimits;
    else
        cfg.metricsShiftLimits = options.MetricsShiftLimits;
    end

    % Metrics
    cfg.metrics = metrics;

    % Prediction control
    cfg.recomputePredictions = options.RecomputePredictions;

    % Database
    cfg.databaseFile = options.DatabaseFile;

    % Analyte
    cfg.useAnalyteWeighting      = options.UseAnalyteWeighting;
    cfg.analyteRamanSpectrumFile = options.AnalyteRamanSpectrumFile;

    % Export / visualisation
    cfg.exportPredictions = options.ExportPredictions;
    cfg.exportGraphics    = options.ExportGraphics;
    cfg.exportVideo       = options.ExportVideo;
    cfg.videoFrames       = options.VideoFrames;
    cfg.videoSize         = options.VideoSize;

end
