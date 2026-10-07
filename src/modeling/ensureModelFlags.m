function model = ensureModelFlags(model)
%ensureModelFlags Ensure model includes preprocessing flags and input metadata.
%
% model = ensureModelFlags(model)
%
% Adds missing fields for legacy models and infers input size from
% feature names or network input layer when available.

arguments
    model (1,1) struct
end

% v2 physics-schema models are self-describing: rebuild handles from the
% stored statistics so they work regardless of how the model was persisted.
if isPhysicsSchemaModel(model)
    model = ensurePhysicsSchemaFlags(model);
    return;
end

inputSize = inferInputSize(model);
if ~isfield(model, "inputSize") || isempty(model.inputSize)
    model.inputSize = inputSize;
end

if ~isfield(model, "featureNames") || isempty(model.featureNames)
    model.featureNames = defaultFeatureNames(model.inputSize);
end

featureLogTransform = getFlag(model, "FeatureLogTransform", true);
includeRatios = getFlag(model, "IncludeRatios", model.inputSize > 5);
targetLogTransform = getFlag(model, "TargetLogTransform", true);
inputPreprocessing = getStringFlag(model, "inputPreprocessing", inferPreprocessingMode(model.inputSize));
normalizeIncludesRatios = strcmpi(inputPreprocessing, "normalize");

model.FeatureLogTransform = featureLogTransform;
model.IncludeRatios = includeRatios;
model.TargetLogTransform = targetLogTransform;
model.inputPreprocessing = inputPreprocessing;
model.normalizeIncludesRatios = normalizeIncludesRatios;

model.flags = struct( ...
    "FeatureLogTransform", featureLogTransform, ...
    "IncludeRatios", includeRatios, ...
    "TargetLogTransform", targetLogTransform, ...
    "InputSize", model.inputSize, ...
    "InputPreprocessing", inputPreprocessing, ...
    "NormalizeIncludesRatios", normalizeIncludesRatios, ...
    "FeatureNames", {cellstr(model.featureNames)});
end

function model = ensurePhysicsSchemaFlags(model)
schema = model.featureSchema;
tt = model.targetTransform;
model.inputSize = numel(schema.FeatureMean);
model.featureNames = cellstr(string(schema.FeatureNames));
model.FeatureLogTransform = true;
model.IncludeRatios = false;          % ratios are built inside buildPhysicsFeatures
model.TargetLogTransform = logical(tt.Log1p);
model.inputPreprocessing = "physics_v2";
model.normalizeIncludesRatios = false;
model.normalize = @(Xraw) standardizeModelFeatures(Xraw, schema);
model.denormalize = @(Z) denormalizeModelTargets(Z, logical(tt.Log1p), tt.Mean, tt.Std);
model.flags = struct( ...
    "FeatureSchema", "v2_physics", ...
    "FeatureLogTransform", true, ...
    "IncludeRatios", false, ...
    "TargetLogTransform", model.TargetLogTransform, ...
    "InputSize", model.inputSize, ...
    "InputPreprocessing", model.inputPreprocessing, ...
    "NormalizeIncludesRatios", false, ...
    "FeatureNames", {model.featureNames});
end

function inputSize = inferInputSize(model)
inputSize = NaN;
if isfield(model, "inputSize") && ~isempty(model.inputSize)
    inputSize = double(model.inputSize);
end
if isnan(inputSize) && isfield(model, "featureNames") && ~isempty(model.featureNames)
    inputSize = numel(model.featureNames);
end
if isnan(inputSize) && isfield(model, "net")
    try
        layers = model.net.Layers;
        for i = 1:numel(layers)
            if isprop(layers(i), "InputSize")
                inputSize = double(layers(i).InputSize);
                break;
            end
        end
    catch
        inputSize = NaN;
    end
end
if isnan(inputSize)
    inputSize = 5;
end
end

function names = defaultFeatureNames(inputSize)
baseNames = {"p_um", "r_um", "lambda_um", "n", "k"};
ratioNames = {"p_lambda_ratio", "r_lambda_ratio", "p_r_ratio"};
if inputSize <= numel(baseNames)
    names = baseNames(1:inputSize);
else
    names = [baseNames, ratioNames];
    names = names(1:inputSize);
end
end

function value = getFlag(model, fieldName, defaultValue)
value = defaultValue;
if isfield(model, fieldName)
    value = logical(model.(fieldName));
elseif isfield(model, "flags") && isfield(model.flags, fieldName)
    value = logical(model.flags.(fieldName));
end
end

function value = getStringFlag(model, fieldName, defaultValue)
value = defaultValue;
if isfield(model, fieldName)
    value = string(model.(fieldName));
elseif isfield(model, "flags") && isfield(model.flags, fieldName)
    value = string(model.flags.(fieldName));
end
end

function mode = inferPreprocessingMode(inputSize)
if inputSize > 5
    mode = "normalize";
else
    mode = "network";
end
end
