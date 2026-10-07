function cfg = trainingConfig(options)
%trainingConfig Build a validated configuration struct for DNN training.
%
%   cfg = trainingConfig(Name=Value) creates a configuration struct
%   consumed by runTrainingWorkflow. All parameters use MATLAB
%   arguments-block validation.
%
%   Name-Value Arguments:
%       WorkDir             – Working directory (string, default pwd)
%       RawDataFiles        – SoA MAT file names (string array, required)
%       RICsvFile           – Gold refractive index CSV (string, default "" uses hardcoded McPeak)
%       OutputModelFile     – Where to save model + dataset (string)
%       PreTrainedModelFile – Existing model for fine-tuning (string, "")
%       ContinueTraining    – Fine-tune flag (logical, false)
%       RatioLimit          – [min, max] r/p filter (1×2, [0 0.49])
%       MetricsToTrain      – Target spectral fields (string array)
%       MaxEpochs           – Training epochs (positive int, 50000)
%       MiniBatchSize       – Mini-batch size (positive int, 1024)
%       LearningRate        – Initial learning rate (positive, 1e-4)
%       Verbose             – Console progress (logical, true)
%       Holdout             – Fraction for val+test (0-1, 0.2)
%       ValSplit            – Validation share of holdout (0-1, 0.5)
%       FeatureSchema       – "v2_physics" (default) | "v1_legacy"
%       SplitMode           – "geometry" (default, no (P,r) leakage) | "row"
%       IncludeVerticalGap  – v2 only: add h_gap/lambda feature (logical, false)
%       GapHeightUm         – v2 only: vertical gap height in µm (0.005)
%       SaveArtifacts       – Persist model & dataset to disk (logical, true)
%       NetworkConfig       – Struct of layer width overrides (struct)
%       TargetLossWeights   – Per-target loss weights (double vector)
%       FeatureLogTransform – Log-transform p, r, lambda (logical)
%       IncludeRatios       – Include p/lambda, r/lambda, p/r (logical)
%       TargetLogTransform  – Log1p-transform targets (logical)
%       Optimizer           – Training optimizer (string)
%       LossFunction        – Loss function (string)
%       LearnRateSchedule   – Learning rate schedule (string)
%       LearnRateDropFactor – Drop factor for piecewise schedule
%       LearnRateDropPeriod – Drop period for piecewise schedule
%       GradientThreshold   – Gradient clipping threshold
%       GradientThresholdMethod – Gradient clipping method
%       L2Regularization    – L2 weight decay
%       Momentum            – SGDM momentum
%       GradientDecayFactor – Adam/RMSProp gradient decay
%       SquaredGradientDecayFactor – Adam/RMSProp squared gradient decay
%       Epsilon             – Adam/RMSProp epsilon
%       Shuffle             – Shuffle policy
%       ValidationFrequency – Validation frequency
%       ValidationPatience  – Early stopping patience
%       VerboseFrequency    – Verbose output frequency
%       Plots               – Training plot display
%       ObjectiveMetricName – Metric used for early stopping
%       OutputNetwork       – Output network selection
%       ExecutionEnvironment – Hardware selection
%       PreprocessingEnvironment – Preprocessing environment
%       Acceleration        – Acceleration mode
%       CheckpointPath      – Checkpoint output path
%       CheckpointFrequency – Checkpoint frequency
%       CheckpointFrequencyUnit – Checkpoint unit
%       ResetInputNormalization – Reset input normalization
%       BatchNormalizationStatistics – Batch norm statistics mode
%       SequenceLength      – Sequence length handling
%       SequencePaddingDirection – Sequence padding direction
%       SequencePaddingValue – Sequence padding value
%       InputDataFormats    – Input data formats
%       TargetDataFormats   – Target data formats
%       CategoricalInputEncoding – Categorical input encoding
%       CategoricalTargetEncoding – Categorical target encoding
%       ExtraTrainingOptions – Additional trainingOptions name-value pairs
%
%   Example:
%       cfg = trainingConfig( ...
%           WorkDir = "D:\data", ...
%           RawDataFiles = "prl_sweep_785.mat", ...
%           RICsvFile = "D:\data\McPeak.csv");
%       results = runTrainingWorkflow(cfg, ProgressReporter.console());
%
%   See also: runTrainingWorkflow, visualizeTrainingResults,
%             validatePipelineConfig, normalizeMetricNames

arguments
    options.WorkDir             (1,1) string  = string(pwd)
    options.RawDataFiles        (1,:) string  = "prl_sweep_sphere_785_new.mat"
    options.RICsvFile           (1,1) string  = ""  % Empty = use default hardcoded McPeak
    options.OutputModelFile     (1,1) string  = ""
    options.PreTrainedModelFile (1,1) string  = ""
    options.ContinueTraining    (1,1) logical = false
    options.RatioLimit          (1,2) double  = [0, 0.49]
    options.MetricsToTrain      (1,:) string  = ["Absorptance", "EF_vol", "EF_surf"]
    options.MaxEpochs           (1,1) double  {mustBePositive, mustBeInteger} = 200
    options.MiniBatchSize       (1,1) double  {mustBePositive, mustBeInteger} = 1024
    options.LearningRate        (1,1) double  {mustBePositive} = 1e-4
    options.Verbose             (1,1) logical = true
    options.Holdout             (1,1) double  {mustBeBetween(options.Holdout,0,1)} = 0.2
    options.ValSplit            (1,1) double  {mustBeBetween(options.ValSplit,0,1)} = 0.5
    options.FeatureSchema       (1,1) string  {mustBeMember(options.FeatureSchema, ["v2_physics", "v1_legacy"])} = "v2_physics"
    options.SplitMode           (1,1) string  {mustBeMember(options.SplitMode, ["geometry", "row"])} = "geometry"
    options.IncludeVerticalGap  (1,1) logical = false
    options.GapHeightUm         (1,1) double  {mustBePositive} = 0.005
    options.SaveArtifacts       (1,1) logical = true
    options.DatabaseFile        (1,1) string  = "database.mat"
    options.NetworkConfig       (1,1) struct  = struct()
    options.TargetLossWeights   (1,:) double = []
    options.FeatureLogTransform (1,1) logical = true
    options.IncludeRatios       (1,1) logical = true
    options.TargetLogTransform  (1,1) logical = true
    options.Optimizer            (1,1) string = "adam"
    options.LossFunction         (1,1) string = "mse"
    options.LearnRateSchedule    (1,1) string = "piecewise"
    options.LearnRateDropFactor  (1,1) double = 0.85
    options.LearnRateDropPeriod  (1,1) double {mustBePositive, mustBeInteger} = 5
    options.GradientThreshold    (1,1) double = inf
    options.GradientThresholdMethod (1,1) string = "l2norm"
    options.L2Regularization     (1,1) double {mustBeNonnegative} = 0.0001
    options.Momentum              (1,1) double = 0.9
    options.GradientDecayFactor   (1,1) double = 0.9
    options.SquaredGradientDecayFactor (1,1) double = 0.999
    options.Epsilon               (1,1) double = 1e-8
    options.Shuffle               (1,1) string = "every-epoch"
    options.ValidationFrequency   (1,1) double = NaN
    options.ValidationPatience    (1,1) double = NaN
    options.VerboseFrequency      (1,1) double = NaN
    options.Plots                 (1,1) string = "training-progress"
    options.ObjectiveMetricName   (1,1) string = "loss"
    options.OutputNetwork         (1,1) string = "auto"
    options.ExecutionEnvironment  (1,1) string = "auto"
    options.PreprocessingEnvironment (1,1) string = "serial"
    options.Acceleration          (1,1) string = "auto"
    options.CheckpointPath        (1,1) string = ""
    options.CheckpointFrequency   (1,1) double = NaN
    options.CheckpointFrequencyUnit (1,1) string = "epoch"
    options.ResetInputNormalization (1,1) logical = true
    options.BatchNormalizationStatistics (1,1) string = "auto"
    options.SequenceLength        (1,1) string = "longest"
    options.SequencePaddingDirection (1,1) string = "right"
    options.SequencePaddingValue  (1,1) double = 0
    options.InputDataFormats      (1,1) string = "auto"
    options.TargetDataFormats     (1,1) string = "auto"
    options.CategoricalInputEncoding (1,1) string = "integer"
    options.CategoricalTargetEncoding (1,1) string = "auto"
    options.ExtraTrainingOptions  cell = {}
end

    % Auto-generate RI path if not supplied; empty = use default
    if options.RICsvFile == ""
        % Will be handled by runTrainingWorkflow which calls getDefaultRefractiveIndex
        options.RICsvFile = "";
    end

    % Ensure raw data files have full paths (combine basenames with WorkDir if needed)
    rawDataFiles = options.RawDataFiles;
    for i = 1:numel(rawDataFiles)
        [fileDir, fileName, ext] = fileparts(rawDataFiles(i));
        if fileDir == ""  % Just a filename with no directory component
            rawDataFiles(i) = fullfile(options.WorkDir, rawDataFiles(i));
        end
    end
    options.RawDataFiles = rawDataFiles;

    % Auto-generate output model filename if empty
    if options.OutputModelFile == ""
        defaultName = "surrogate_dnn_model.mat";
        if ~isempty(options.RawDataFiles)
            [~, baseName, ~] = fileparts(options.RawDataFiles(1));
            defaultName = baseName + "_model.mat";
        end
        options.OutputModelFile = fullfile(options.WorkDir, defaultName);
    end

    % Normalise metric names to canonical form
    options.MetricsToTrain = normalizeMetricNames(options.MetricsToTrain);

    % Assemble output struct
    cfg = struct();
    cfg.workDir             = options.WorkDir;
    cfg.rawDataFiles        = options.RawDataFiles;
    cfg.riCsvFile           = options.RICsvFile;
    cfg.outputModelFile     = options.OutputModelFile;
    cfg.preTrainedModelFile = options.PreTrainedModelFile;
    cfg.continueTraining    = options.ContinueTraining;
    cfg.ratioLimit          = options.RatioLimit;
    cfg.metricsToTrain      = options.MetricsToTrain;
    cfg.maxEpochs           = options.MaxEpochs;
    cfg.miniBatchSize       = options.MiniBatchSize;
    cfg.learningRate        = options.LearningRate;
    cfg.verbose             = options.Verbose;
    cfg.holdout             = options.Holdout;
    cfg.valSplit            = options.ValSplit;
    cfg.featureSchema       = options.FeatureSchema;
    cfg.splitMode           = options.SplitMode;
    cfg.includeVerticalGap  = options.IncludeVerticalGap;
    cfg.gapHeightUm         = options.GapHeightUm;
    cfg.saveArtifacts       = options.SaveArtifacts;
    cfg.databaseFile        = options.DatabaseFile;
    cfg.networkConfig       = options.NetworkConfig;
    cfg.targetLossWeights   = options.TargetLossWeights;
    cfg.featureLogTransform = options.FeatureLogTransform;
    cfg.includeRatios       = options.IncludeRatios;
    cfg.targetLogTransform  = options.TargetLogTransform;
    cfg.optimizer           = options.Optimizer;
    cfg.lossFunction        = options.LossFunction;
    cfg.learnRateSchedule   = options.LearnRateSchedule;
    cfg.learnRateDropFactor = options.LearnRateDropFactor;
    cfg.learnRateDropPeriod = options.LearnRateDropPeriod;
    cfg.gradientThreshold   = options.GradientThreshold;
    cfg.gradientThresholdMethod = options.GradientThresholdMethod;
    cfg.l2Regularization    = options.L2Regularization;
    cfg.momentum             = options.Momentum;
    cfg.gradientDecayFactor  = options.GradientDecayFactor;
    cfg.squaredGradientDecayFactor = options.SquaredGradientDecayFactor;
    cfg.epsilon              = options.Epsilon;
    cfg.shuffle              = options.Shuffle;
    cfg.validationFrequency  = options.ValidationFrequency;
    cfg.validationPatience   = options.ValidationPatience;
    cfg.verboseFrequency     = options.VerboseFrequency;
    cfg.plots                = options.Plots;
    cfg.objectiveMetricName  = options.ObjectiveMetricName;
    cfg.outputNetwork        = options.OutputNetwork;
    cfg.executionEnvironment = options.ExecutionEnvironment;
    cfg.preprocessingEnvironment = options.PreprocessingEnvironment;
    cfg.acceleration         = options.Acceleration;
    cfg.checkpointPath       = options.CheckpointPath;
    cfg.checkpointFrequency  = options.CheckpointFrequency;
    cfg.checkpointFrequencyUnit = options.CheckpointFrequencyUnit;
    cfg.resetInputNormalization = options.ResetInputNormalization;
    cfg.batchNormalizationStatistics = options.BatchNormalizationStatistics;
    cfg.sequenceLength       = options.SequenceLength;
    cfg.sequencePaddingDirection = options.SequencePaddingDirection;
    cfg.sequencePaddingValue = options.SequencePaddingValue;
    cfg.inputDataFormats     = options.InputDataFormats;
    cfg.targetDataFormats    = options.TargetDataFormats;
    cfg.categoricalInputEncoding = options.CategoricalInputEncoding;
    cfg.categoricalTargetEncoding = options.CategoricalTargetEncoding;
    cfg.extraTrainingOptions = options.ExtraTrainingOptions;
end
