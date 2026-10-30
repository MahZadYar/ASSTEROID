function cfg = networkConfigFromUI(d)
%networkConfigFromUI Build the surrogate NetworkConfig from a UI payload.
%   cfg = networkConfigFromUI(d) converts the training-tab JSON payload
%   (struct d) into the NetworkConfig struct consumed by
%   train_surrogate_dnn / buildSurrogateNetwork. Missing fields fall back
%   to the v6.3 defaults (architecture "gs_tensor").
%
%   Shared by TrainingController and the legacy assteroid_app callback so
%   both code paths expose identical architecture options and sizes.
%
%   See also: buildSurrogateNetwork, parseNumberList

if nargin < 1 || ~isstruct(d)
    d = struct();
end

arch = lower(localStr(d, "architecture", "gs_tensor"));
isLegacy = ismember(arch, ["resnet", "tensor_resnet"]);
if isLegacy
    headDefault = 512;
else
    headDefault = 128;
end

cfg = struct( ...
    "architecture", arch, ...
    "useMultiHead", localBool(d, "useMultiHead", true), ...
    "headHiddenSizes", parseNumberList(localStr(d, "headHiddenSizes", string(headDefault)), headDefault), ...
    ... % gs_tensor / lean_resnet (v6.4 defaults: Option A, 473,987 learnables)
    "modelWidth", localNum(d, "modelWidth", 256), ...
    "specWidths", parseNumberList(localStr(d, "specWidths", localStr(d, "stemWidths", "128,256")), [128, 256]), ...
    "specFeatures", lower(localStr(d, "specFeatures", localStr(d, "stemFeatures", "all"))), ...
    "geoWidths", parseNumberList(localStr(d, "geoWidths", "64,128"), [64, 128]), ...
    "geoWidth", localNum(d, "geoWidth", 128), ...
    "geoDepth", localNum(d, "geoDepth", 2), ...
    "numBlocks", localNum(d, "numBlocks", 2), ...
    "boundedHeads", localBool(d, "boundedHeads", true), ...
    "hiddenActivation", lower(localStr(d, "hiddenActivation", "gelu")), ...
    "zeroInitResidualOut", localBool(d, "zeroInitResidualOut", true), ...
    ... % legacy resnet / tensor_resnet
    "tensorRank", localNum(d, "tensorRank", 512), ...
    "fc1a", localNum(d, "fc1a", 256), ...
    "fc1b", localNum(d, "fc1b", 512), ...
    "proj1", localNum(d, "proj1", 512), ...
    "fc2a", localNum(d, "fc2a", 1024), ...
    "fc2b", localNum(d, "fc2b", 512));
cfg.stemWidths = cfg.specWidths;
cfg.stemFeatures = cfg.specFeatures;
end

function v = localStr(d, f, def)
v = string(def);
if isfield(d, f) && ~isempty(d.(f))
    v = string(d.(f));
    if numel(v) > 1
        v = strjoin(v, ",");
    end
end
end

function v = localNum(d, f, def)
v = def;
if isfield(d, f) && ~isempty(d.(f))
    x = d.(f);
    if ischar(x) || isstring(x)
        x = str2double(x);
    end
    if isnumeric(x) && isscalar(x) && isfinite(x)
        v = double(x);
    end
end
end

function v = localBool(d, f, def)
v = logical(def);
if isfield(d, f) && ~isempty(d.(f))
    x = d.(f);
    if islogical(x) || isnumeric(x)
        v = logical(x(1));
    elseif ischar(x) || isstring(x)
        v = any(strcmpi(string(x), ["true", "1", "on", "yes"]));
    end
end
end
