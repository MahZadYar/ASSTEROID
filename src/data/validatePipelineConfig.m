function isValid = validatePipelineConfig(config)
% validatePipelineConfig  Validate pipeline configuration struct.
%
% isValid = validatePipelineConfig(config) checks config struct for required
% fields, correct data types, and reasonable value ranges. Returns true if
% valid; throws error otherwise.
%
% Example:
%   config = struct();
%   config.workDir = pwd;
%   config.rawDataFiles = ["data.mat"];
%   config.riCsvFile = "McPeak.csv";
%   isValid = validatePipelineConfig(config); % Returns true or throws

arguments
    config struct {mustBeNonmissing(config)}
end

isValid = false;
errors = {};

% Check required path fields
requiredPaths = {'workDir', 'rawDataFiles', 'riCsvFile', 'outputModelFile'};
for k = 1:numel(requiredPaths)
    field = requiredPaths{k};
    if ~isfield(config, field)
        errors{end+1} = sprintf('Missing required field: config.%s', field); %#ok<AGROW>
    end
end

% Validate path existence
if isfield(config, 'workDir') && ~isstring(config.workDir) && ~ischar(config.workDir)
    errors{end+1} = 'config.workDir must be a string or char array'; %#ok<AGROW>
end

if isfield(config, 'rawDataFiles')
    rawFiles = string(config.rawDataFiles);
    if isempty(rawFiles)
        errors{end+1} = 'config.rawDataFiles cannot be empty'; %#ok<AGROW>
    end
    for fIdx = 1:numel(rawFiles)
        fpath = rawFiles(fIdx);
        % If file not found as-is, try prepending workDir (for relative paths)
        if ~isfile(fpath)
            fpath = fullfile(string(config.workDir), rawFiles(fIdx));
        end
        if ~isfile(fpath)
            errors{end+1} = sprintf('Raw data file not found: %s', fpath); %#ok<AGROW>
        end
    end
end

if isfield(config, 'riCsvFile')
    riPath = string(config.riCsvFile);
    if riPath ~= "" && ~isfile(riPath)
        errors{end+1} = sprintf('Refractive index CSV not found: %s', riPath); %#ok<AGROW>
    end
end

% Validate training parameters
if isfield(config, 'training') && isstruct(config.training)
    train = config.training;
    
    if isfield(train, 'MaxEpochs')
        if ~isnumeric(train.MaxEpochs) || train.MaxEpochs < 1
            errors{end+1} = 'config.training.MaxEpochs must be a positive integer'; %#ok<AGROW>
        end
    end
    
    if isfield(train, 'MiniBatchSize')
        if ~isnumeric(train.MiniBatchSize) || train.MiniBatchSize < 1
            errors{end+1} = 'config.training.MiniBatchSize must be a positive integer'; %#ok<AGROW>
        end
    end
    
    if isfield(train, 'LearningRate')
        if ~isnumeric(train.LearningRate) || train.LearningRate <= 0
            errors{end+1} = 'config.training.LearningRate must be positive'; %#ok<AGROW>
        end
    end
    
    if isfield(train, 'Verbose') && ~islogical(train.Verbose)
        errors{end+1} = 'config.training.Verbose must be logical'; %#ok<AGROW>
    end
end

% Validate data split parameters
if isfield(config, 'dataSplit') && isstruct(config.dataSplit)
    ds = config.dataSplit;
    
    if isfield(ds, 'Holdout')
        if ~isnumeric(ds.Holdout) || ds.Holdout < 0 || ds.Holdout > 1
            errors{end+1} = 'config.dataSplit.Holdout must be in [0, 1]'; %#ok<AGROW>
        end
    end
    
    if isfield(ds, 'ValSplit')
        if ~isnumeric(ds.ValSplit) || ds.ValSplit < 0 || ds.ValSplit > 1
            errors{end+1} = 'config.dataSplit.ValSplit must be in [0, 1]'; %#ok<AGROW>
        end
    end
end

% Validate ratio limit
if isfield(config, 'ratioLimit')
    rl = config.ratioLimit;
    if ~isempty(rl)
        if ~isnumeric(rl) || numel(rl) ~= 2 || rl(1) > rl(2)
            errors{end+1} = 'config.ratioLimit must be [min, max] with min <= max'; %#ok<AGROW>
        end
        if rl(1) < 0 || rl(2) > 1
            errors{end+1} = 'config.ratioLimit values should be in [0, 1]'; %#ok<AGROW>
        end
    end
end

% Validate metrics
if isfield(config, 'metricsToTrain')
    validMetrics = {'Absorptance', 'M_vol', 'M_surf', 'EF_vol', 'EF_surf'};
    metrics = string(config.metricsToTrain);
    if isempty(metrics)
        errors{end+1} = 'config.metricsToTrain cannot be empty'; %#ok<AGROW>
    end
    for mIdx = 1:numel(metrics)
        m = metrics(mIdx);
        if ~ismember(m, validMetrics)
            errors{end+1} = sprintf('Invalid metric: %s (valid: %s)', m, strjoin(validMetrics, ', ')); %#ok<AGROW>
        end
    end
end

% Report errors
if ~isempty(errors)
    errorMsg = sprintf('Configuration validation failed:\n');
    for eIdx = 1:numel(errors)
        errorMsg = sprintf('%s  - %s\n', errorMsg, errors{eIdx});
    end
    throwAsCaller(MException('validatePipelineConfig:Invalid', errorMsg));
end

isValid = true;
end
