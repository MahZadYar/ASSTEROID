function cfg = localizeMaximaConfig(options)
    % localizeMaximaConfig  Build configuration struct for maxima localization.
    %
    %   cfg = localizeMaximaConfig(Name=Value) creates a validated configuration
    %   struct for runLocalizationWorkflow. All parameters have sensible defaults
    %   and can be overridden individually. This config builder enables both CLI
    %   scripts and uihtml apps to construct workflow configurations consistently.
    %
    %   Name-Value Arguments:
    %     --- Data Source ---
    %       DataSource          (1,1) string  — "model" | "interpolation" (default: "model")
    %       DataFile            (1,1) string  — Path to raw SoA data .mat (for interpolation)
    %       DiscreteOnly        (1,1) logical — Skip MultiStart, report best grid points only
    %
    %     --- File Paths ---
    %       WorkDir             (1,1) string  — Working directory (default: pwd)
    %       ModelFile           (1,1) string  — Path to trained model .mat
    %       RiCsvFile           (1,1) string  — Path to McPeak.csv
    %       PredictionFile      (1,1) string  — Path to cached predictions .mat
    %
    %     --- Grid Parameters ---
    %       LambdaLaser         (1,1) double  — Laser wavelength in nm (default: 785)
    %       PLimits             (1,2) double  — [min, max] period in nm
    %       RLimits             (1,2) double  — [min, max] radius in nm
    %       StokesShiftLimits   (1,2) double  — [min, max] Stokes shift in cm^-1
    %       Resolution          (1,1) double  — Spatial resolution in nm
    %       StokesShiftResolution (1,1) double — Spectral resolution in cm^-1
    %
    %     --- Metrics ---
    %       MetricsToLocate     (1,:) string  — Metric names to optimise
    %       RatioLimit          (1,2) double  — [min, max] r/p ratio constraint
    %
    %     --- Prediction Control ---
    %       RecomputePredictions (1,1) logical — Regenerate predictions
    %
    %     --- MultiStart Parameters ---
    %       NumLocalMaxima      (1,1) double  — Number of maxima to report
    %       MultiStartPoints    (1,1) double  — Random start count
    %       MultiStartUseParallel (1,1) logical — Use parallel pool (default: true)
    %       ShowIterationPaths  (1,1) logical — Show fmincon iteration trajectories (overrides UseParallel→false, Display→iter)
    %       MultiStartDisplay   (1,1) string  — Verbosity: "off"|"final"|"iter"
    %       FunctionTolerance   (1,1) double  — Optimisation function tolerance
    %       StepTolerance       (1,1) double  — Optimisation step tolerance
    %       MaxIterations       (1,1) double  — Maximum fmincon iterations
    %       InitialPoints       (:,2) double  — Custom [p, r] seed points
    %       InitialCandidates   (table)       — Table of pre-detected candidate seeds
    %
    %     --- Candidate Detection ---
    %       GradientPercentile     (1,1) double — Gradient percentile threshold
    %       LaplacianFactor        (1,1) double — Fraction of negative Laplacian retained
    %       NeighborSuppressionRadius (1,1) double — Grid cells suppressed around seeds
    %       LocalWindowRadiusSteps (1,1) double — Half-width in grid steps for local bounds
    %       MinLocalWindow         (1,1) double — Minimum local bounds half-width (µm)
    %       TuningRadius           (1,1) double — Refinement radius (µm)
    %       NeighborTolerance      (1,1) double — Tolerance for plateau detection
    %
    %   Output:
    %       cfg — struct with all configuration fields, ready for runLocalizationWorkflow
    %
    %   Example:
    %       % Model-based (default):
    %       cfg = localizeMaximaConfig( ...
    %           ModelFile="sers_model.mat", RiCsvFile="McPeak.csv", ...
    %           PLimits=[850, 920], RLimits=[70, 430]);
    %
    %       % Interpolation from raw data:
    %       cfg = localizeMaximaConfig( ...
    %           DataSource="interpolation", DataFile="prl_sweep.mat", ...
    %           PLimits=[850, 920], RLimits=[70, 430], DiscreteOnly=true);
    %
    %   See also: runLocalizationWorkflow, computeDenseGridParams, ProgressReporter

    arguments
        options.DataSource (1,1) string {mustBeMember(options.DataSource, ["model", "interpolation"])} = "model"
        options.DataFile (1,1) string = ""
        options.DiscreteOnly (1,1) logical = false
        options.WorkDir (1,1) string = string(pwd)
        options.ModelFile (1,1) string = ""
        options.RiCsvFile (1,1) string = ""
        options.PredictionFile (1,1) string = ""
        options.LambdaLaser (1,1) double {mustBePositive} = 785
        options.PLimits (1,2) double {mustBePositive} = [750, 950]
        options.RLimits (1,2) double {mustBePositive} = [50, 450]
        options.StokesShiftLimits (1,2) double = [0, 0]
        options.Resolution (1,1) double {mustBePositive} = 0.7
        options.StokesShiftResolution (1,1) double {mustBePositive} = 1
        options.LinkMetricsToGrid (1,1) logical = true
        options.MetricsShiftLimits (1,2) double = [100, 3600]
        options.MetricsToLocate (1,:) string = ["Absorptance", "EF_vol", "EF_surf"]
        options.RatioLimit (1,2) double = [0, 0.49]
        options.RecomputePredictions (1,1) logical = true
        options.NumLocalMaxima (1,1) double {mustBePositive, mustBeInteger} = 15
        options.MultiStartPoints (1,1) double {mustBePositive, mustBeInteger} = 1000
        options.MultiStartUseParallel (1,1) logical = true
        options.ShowIterationPaths (1,1) logical = false
        options.MultiStartDisplay (1,1) string {mustBeMember(options.MultiStartDisplay, ["off", "final", "iter", "diagnose"])} = "off"
        options.FunctionTolerance (1,1) double {mustBePositive} = 1e-9
        options.StepTolerance (1,1) double {mustBePositive} = 1e-9
        options.MaxIterations (1,1) double {mustBePositive, mustBeInteger} = 1e4
        options.FminconAlgorithm (1,1) string {mustBeMember(options.FminconAlgorithm, ["interior-point", "sqp", "active-set", "sqp-legacy"])} = "interior-point"
        options.MaxFunctionEvaluations (1,1) double {mustBePositive, mustBeInteger} = 1e4
        options.ConstraintTolerance (1,1) double {mustBePositive} = 1e-9
        options.OptimalityTolerance (1,1) double {mustBePositive} = 1e-9
        options.UseAnalyticalGradients (1,1) logical = true
        options.UseGradientSeedInit (1,1) logical = true
        options.GradientSeedCount (1,1) double = 0
        options.GradientSeedGridSize (1,1) double {mustBePositive, mustBeInteger} = 20
        options.InitialPoints (:,2) double = zeros(0, 2)
        options.InitialCandidates table = table()
        options.GradientPercentile (1,1) double {mustBeNonnegative} = 1
        options.LaplacianFactor (1,1) double {mustBeNonnegative} = 0.5
        options.NeighborSuppressionRadius (1,1) double {mustBeNonnegative, mustBeInteger} = 3
        options.LocalWindowRadiusSteps (1,1) double {mustBePositive, mustBeInteger} = 6
        options.MinLocalWindow (1,1) double {mustBePositive} = 0.001
        options.TuningRadius (1,1) double {mustBePositive} = 0.02
        options.NeighborTolerance (1,1) double {mustBeNonnegative} = 1e-9
        options.BasinRetryCount (1,1) double {mustBePositive, mustBeInteger} = 4
        options.BasinRetryShrinkFactor (1,1) double {mustBePositive} = 1.0
        options.DestinationBoundPadding (1,1) double {mustBeNonnegative} = 0
        options.KeepRejectedSeeds (1,1) logical = true
        options.BorderRejectFraction (1,1) double {mustBeNonnegative} = 0.02
        options.MetricVariant (1,1) string {mustBeMember(options.MetricVariant, ["laser","avg","weighted"])} = "avg"
    end

    %% Normalise metrics using centralised alias resolver
    metricsNormalized = normalizeMetricNames(options.MetricsToLocate);
    if isempty(metricsNormalized)
        error("localizeMaximaConfig:NoMetrics", ...
            "MetricsToLocate must contain at least one valid metric.");
    end

    %% Validate data source requirements
    if options.DataSource == "model" && strlength(options.ModelFile) == 0
        % ModelFile will be resolved at workflow time; just warn if empty
    end
    if options.DataSource == "interpolation" && strlength(options.DataFile) == 0
        warning("localizeMaximaConfig:NoDataFile", ...
            "DataSource='interpolation' but DataFile is empty. " + ...
            "Provide a DataFile path before running the workflow.");
    end

    %% Compute dense grid parameters
    gridParams = computeDenseGridParams( ...
        LambdaLaser=options.LambdaLaser, ...
        PLimits=options.PLimits, ...
        RLimits=options.RLimits, ...
        StokesShiftLimits=options.StokesShiftLimits, ...
        Resolution=options.Resolution, ...
        StokesShiftResolution=options.StokesShiftResolution, ...
        OutputUnit="um");

    %% Build config struct
    cfg = struct();

    % Data source
    cfg.dataSource = options.DataSource;
    cfg.dataFile = options.DataFile;
    cfg.discreteOnly = options.DiscreteOnly;

    % File paths
    cfg.workDir = options.WorkDir;
    cfg.modelFile = options.ModelFile;
    cfg.riCsvFile = options.RiCsvFile;
    cfg.predictionFile = options.PredictionFile;

    % Grid (pre-computed, in µm for model consumption)
    cfg.gridParams = gridParams;
    cfg.lambdaLaser = options.LambdaLaser;
    cfg.pLimits = options.PLimits;
    cfg.rLimits = options.RLimits;
    cfg.stokesShiftLimits = options.StokesShiftLimits;
    cfg.resolution = options.Resolution;
    cfg.stokesShiftResolution = options.StokesShiftResolution;

    % Metrics window
    cfg.linkMetricsToGrid = options.LinkMetricsToGrid;
    if options.LinkMetricsToGrid
        cfg.metricsShiftLimits = options.StokesShiftLimits;
    else
        cfg.metricsShiftLimits = options.MetricsShiftLimits;
    end

    % Metrics
    cfg.metricsToLocate = metricsNormalized;
    cfg.ratioLimit = options.RatioLimit;

    % Prediction control
    cfg.recomputePredictions = options.RecomputePredictions;

    % MultiStart
    cfg.numLocalMaxima = options.NumLocalMaxima;
    cfg.multiStartPoints = options.MultiStartPoints;
    cfg.multiStartUseParallel = options.MultiStartUseParallel;
    cfg.showIterationPaths = options.ShowIterationPaths;
    cfg.multiStartDisplay = options.MultiStartDisplay;
    cfg.functionTolerance = options.FunctionTolerance;
    cfg.stepTolerance = options.StepTolerance;
    cfg.maxIterations = options.MaxIterations;
    cfg.fminconAlgorithm = options.FminconAlgorithm;
    cfg.maxFunctionEvaluations = options.MaxFunctionEvaluations;
    cfg.constraintTolerance = options.ConstraintTolerance;
    cfg.optimalityTolerance = options.OptimalityTolerance;
    cfg.useAnalyticalGradients = options.UseAnalyticalGradients;
    cfg.useGradientSeedInit = options.UseGradientSeedInit;
    cfg.gradientSeedCount = options.GradientSeedCount;
    cfg.gradientSeedGridSize = options.GradientSeedGridSize;
    cfg.initialPoints = options.InitialPoints;
    cfg.initialCandidates = options.InitialCandidates;

    % Candidate detection
    cfg.gradientPercentile = options.GradientPercentile;
    cfg.laplacianFactor = options.LaplacianFactor;
    cfg.neighborSuppressionRadius = options.NeighborSuppressionRadius;
    cfg.localWindowRadiusSteps = options.LocalWindowRadiusSteps;
    cfg.minLocalWindow = options.MinLocalWindow;
    cfg.tuningRadius = options.TuningRadius;
    cfg.neighborTolerance = options.NeighborTolerance;
    cfg.basinRetryCount = options.BasinRetryCount;
    cfg.basinRetryShrinkFactor = options.BasinRetryShrinkFactor;
    cfg.destinationBoundPadding = options.DestinationBoundPadding;
    cfg.keepRejectedSeeds = options.KeepRejectedSeeds;
    cfg.borderRejectFraction = options.BorderRejectFraction;
    cfg.metricVariant = options.MetricVariant;
end