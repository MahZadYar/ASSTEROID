function cfg = importSweepConfig(options)
%importSweepConfig Build configuration for sweep import workflow.
%
%   cfg = importSweepConfig() returns a struct with default parameters
%   suitable for the import/DB-build orchestration workflow.
%
%   cfg = importSweepConfig(Name=Value) customizes any parameter.
%
%   The returned struct is consumed by runImportSweepWorkflow and is
%   compatible with the src/io/ and src/data/ library functions.
%
%   Name-Value Arguments:
%     --- Paths ---
%       WorkDir              (1,1) string  — Working directory (default: pwd)
%       InputFile            (1,1) string  — Path to sweep data file
%       OutputFile           (1,1) string  — Optional path to legacy output SoA .mat file (default: "")
%       AnalyteSpectrumFile  (1,1) string  — Raman spectrum of analyte
%       ExistingData         (:,:) struct  — In-memory SoA struct to merge into
%
%     --- Column Schema ---
%       ColumnSchema         (1,:) struct  — Dynamic column definitions from
%           the import preview. Each element has fields:
%             .name  (string)  – column name in the data file
%             .role  (string)  – "input" | "spectral" | "metric" | "ignore"
%           When empty, auto-detection infers roles from column names.
%
%     --- Physical Parameters ---
%       LaserWavelength      (1,1) double  — Excitation wavelength in nm
%       RamanWindow          (1,2) double  — Stokes shift window [min, max] cm^-1
%       DetectShiftWindow    (1,1) logical — Auto-detect shift window from data
%       InterpResolution     (1,1) double  — Dense interpolation resolution (1/cm)
%       SpectralInterpMethod (1,1) string  — "makima" | "pchip" | "linear" | "spline"
%       WavelengthTolerance  (1,1) double  — Spectral wavelength match tolerance in nm (default: 1e-4)
%
%     --- Database ---
%       DatabaseFile         (1,1) string  — Master unified database file (default: "database.mat")
%
%     --- Import Behaviour ---
%       Mode                 (1,1) string  — "merge" | "rebuild"
%       ReplaceExisting      (1,1) logical — Replace matching (p, r, lambda) points for imported metrics (default: false)
%       RecalculateExisting  (1,1) logical — Legacy merge alias
%
%   Output:
%       cfg — struct with all configuration fields
%
%   Example:
%       cfg = importSweepConfig( ...
%           WorkDir="D:\data", ...
%           InputFile="SweepPropeTable.dat", ...
%           LaserWavelength=785);
%       results = runImportSweepWorkflow(cfg, ProgressReporter.console());
%
%   See also: runImportSweepWorkflow, visualizeImportSummary,
%             readSweepTable, ProgressReporter

arguments
    %% Paths
    options.WorkDir             (1,1) string  = string(pwd)
    options.InputFile           (1,1) string  = "SweepPropeTable.dat"
    options.OutputFile          (1,1) string  = ""
    options.AnalyteSpectrumFile (1,1) string  = ""
    options.ExistingData        (:,:) struct  = struct([])

    %% Column Schema (dynamic column definitions from preview)
    options.ColumnSchema        (:,:)         = struct([])

    %% Physical parameters
    options.LaserWavelength     (1,1) double {mustBePositive} = 785
    options.RamanWindow         (1,2) double = [100, 3600]
    options.DetectShiftWindow   (1,1) logical = false
    options.InterpResolution    (1,1) double {mustBePositive} = 1
    options.SpectralInterpMethod (1,1) string {mustBeMember(options.SpectralInterpMethod, ...
                                    ["makima", "pchip", "linear", "spline"])} = "makima"
    options.WavelengthTolerance (1,1) double {mustBePositive} = 1e-4

    %% Database
    options.DatabaseFile        (1,1) string  = "database.mat"

    %% Import behaviour
    options.Mode                (1,1) string {mustBeMember(options.Mode, ...
                                    ["merge", "rebuild"])} = "merge"
    options.ReplaceExisting     (1,1) logical = false
    options.RecalculateExisting (1,1) logical = false

    %% Metric variant selection
    % Struct with boolean fields controlling which scalar variants to compute.
    % Each field follows the pattern <BaseMetric>_<variant> e.g. EF_vol_laser.
    % Missing fields default to true (compute all). An empty struct = compute all.
    options.MetricVariants      (1,1) struct  = struct()
end

    %% Build config struct
    cfg = struct();

    % Paths
    cfg.workDir             = options.WorkDir;
    cfg.inputFile           = options.InputFile;
    cfg.outputFile          = options.OutputFile;
    cfg.analyteSpectrumFile = options.AnalyteSpectrumFile;
    cfg.existingData        = options.ExistingData;

    % Column schema
    cfg.columnSchema        = options.ColumnSchema;

    % Physical parameters
    cfg.laserWavelength     = options.LaserWavelength;
    cfg.ramanWindow         = options.RamanWindow;
    cfg.detectShiftWindow   = options.DetectShiftWindow;
    cfg.interpResolution    = options.InterpResolution;
    cfg.spectralInterpMethod = options.SpectralInterpMethod;
    cfg.wavelengthTolerance = options.WavelengthTolerance;

    % Database
    cfg.databaseFile        = options.DatabaseFile;

    % Import behaviour
    cfg.mode                = options.Mode;
    cfg.replaceExisting     = options.ReplaceExisting;
    cfg.recalculateExisting = options.RecalculateExisting;

    % Metric variant selection
    cfg.metricVariants      = options.MetricVariants;

end
