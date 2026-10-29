function [net, info] = buildSurrogateNetwork(numFeatures, numTargets, config, options)
%buildSurrogateNetwork Construct the ASSTEROID surrogate dlnetwork.
%
%   [net, info] = buildSurrogateNetwork(numFeatures, numTargets, config)
%   [net, info] = buildSurrogateNetwork(..., FeatureNames=names, ...
%                                            TargetTransform=tt)
%
%   Architectures (config.architecture):
%     "gs_tensor"     (default, v6.3) Geometry-Spectrum Factorized Tensor
%                     Network: a lambda-blind geometry encoder G(P, r)
%                     (sliceLayer -> MLP) multiplicatively gates a
%                     spectral-geometric residual stream through
%                     geometry-conditioned bilinear residual blocks
%                         h_k = h_{k-1} + W_o [ a_k(h_{k-1}) .* s_k(G) ],
%                     with identity skips and physically bounded heads
%                     (sigmoid for absorptance, softplus for log10(1+EE)).
%     "lean_resnet"   Ablation of gs_tensor without the geometry encoder
%                     and gates (plain identity-skip residual MLP blocks).
%     "tensor_resnet" Legacy (v6.0-6.2) low-rank tensor-product ResNet.
%     "resnet"        Legacy two-block residual MLP.
%
%   Config fields (all optional):
%     Common : architecture, normalization ("layer" | "batch"),
%              useMultiHead (true), headHiddenSizes ([] -> 128 for
%              gs_tensor/lean_resnet, 512 for legacy)
%     gs/lean: modelWidth (256), geoWidth (128), geoDepth (2),
%              numBlocks (2), geometryFeatures (["log_p","log_r",
%              "log_g_norm"]), gateBiasInit (1), zeroInitResidualOut
%              (true), boundedHeads (true), hiddenActivation ("gelu" |
%              "swish" | "tanh")
%     Legacy : tensorRank (512), fc1a (256), fc1b (512), proj1 (=fc1b),
%              fc2a (1024), fc2b (=fc1b)
%
%   Name-Value:
%     FeatureNames    - names of the input feature columns (required for
%                       gs_tensor to locate the geometry columns)
%     TargetTransform - dataset.targetTransform (Mean, Std, bounds); needed
%                       for bounded heads (see surrogateHeadSpecs)
%
%   Output info struct: Config (resolved), HeadSpecs, BoundedHeads,
%   GeometryFeatureIdx, NumLearnables, LayerTypes.
%
%   All layers are MATLAB R2026b built-ins (featureInputLayer, sliceLayer,
%   fullyConnectedLayer, layerNormalizationLayer, geluLayer, sigmoidLayer,
%   softplusLayer, scalingLayer, additionLayer, multiplicationLayer,
%   concatenationLayer); no custom layer classes are required.
%
%   See also: train_surrogate_dnn, surrogateHeadSpecs, prepare_training_dataset

arguments
    numFeatures (1,1) double {mustBeInteger, mustBePositive}
    numTargets (1,1) double {mustBeInteger, mustBePositive}
    config = struct()
    options.FeatureNames (1,:) string = strings(1, 0)
    options.TargetTransform = struct()
end

if isempty(config)
    config = struct();
end
config = localResolveConfig(config, numTargets);

info = struct();
info.HeadSpecs = surrogateHeadSpecs(options.TargetTransform, numTargets);
info.BoundedHeads = false;
info.GeometryFeatureIdx = [];

switch config.architecture
    case {"gs_tensor", "lean_resnet"}
        if config.architecture == "gs_tensor"
            config.geometryFeatureIdx = localResolveGeometryIdx( ...
                config.geometryFeatures, options.FeatureNames, numFeatures);
            info.GeometryFeatureIdx = config.geometryFeatureIdx;
        end
        specs = info.HeadSpecs;
        if config.boundedHeads && ~any([specs.Kind] ~= "none")
            warning('buildSurrogateNetwork:NoBoundMetadata', ...
                ['boundedHeads requested but the target transform carries no bound ', ...
                 'metadata (Mean/Std); building unbounded heads.']);
        end
        if ~config.boundedHeads
            [specs.Kind] = deal("none");
        end
        info.HeadSpecs = specs;
        info.BoundedHeads = any([specs.Kind] ~= "none");
        net = localBuildGsTensorNetwork(numFeatures, numTargets, config, specs);
    otherwise
        [specs] = info.HeadSpecs;
        [specs.Kind] = deal("none");
        info.HeadSpecs = specs;
        net = localBuildLegacyNetwork(numFeatures, numTargets, config);
end

if ~net.Initialized
    net = initialize(net);
end

info.Config = config;
info.NumLearnables = sum(cellfun(@numel, net.Learnables.Value));
classNames = arrayfun(@(L) string(class(L)), net.Layers);
info.LayerTypes = unique(arrayfun(@(c) localLastToken(c), classNames))';
end

function s = localLastToken(c)
parts = split(c, ".");
s = parts(end);
end

%% ------------------------------------------------------------------------
%  Geometry-Spectrum Factorized Tensor Network (gs_tensor) / lean_resnet
%  ------------------------------------------------------------------------
function net = localBuildGsTensorNetwork(numFeatures, numTargets, config, specs)
W = config.modelWidth;
useGate = config.architecture == "gs_tensor";
normKind = config.normalization;
actKind = config.hiddenActivation;

net = dlnetwork;
net = addLayers(net, featureInputLayer(numFeatures, Name="input"));

% --- Spectral-geometric stem: the single full-input injection -----------
stem = [
    fullyConnectedLayer(W, Name="stem_fc")
    localNormLayer("stem_ln", normKind)
    localActLayer("stem_act", actKind)];
net = addLayers(net, stem);
net = connectLayers(net, "input", "stem_fc");

% --- Geometry encoder G(P, r): lambda-blind ------------------------------
geoOut = "";
if useGate
    geo = sliceLayer(1, config.geometryFeatureIdx, Name="geo_slice");
    for d = 1:config.geoDepth
        geo = [geo
            fullyConnectedLayer(config.geoWidth, Name=sprintf("geo_fc%d", d))
            localNormLayer(sprintf("geo_ln%d", d), normKind)
            localActLayer(sprintf("geo_act%d", d), actKind)]; %#ok<AGROW>
    end
    net = addLayers(net, geo);
    net = connectLayers(net, "input", "geo_slice");
    if config.geoDepth > 0
        geoOut = sprintf("geo_act%d", config.geoDepth);
    else
        geoOut = "geo_slice";
    end
end

% --- Geometry-conditioned bilinear residual blocks ------------------------
gateBias = config.gateBiasInit;
prev = "stem_act";
for k = 1:config.numBlocks
    tag = sprintf("b%d", k);
    spectral = [
        fullyConnectedLayer(W, Name=tag + "_fc_a")
        localNormLayer(tag + "_ln_a", normKind)
        localActLayer(tag + "_act_a", actKind)];
    net = addLayers(net, spectral);
    net = connectLayers(net, prev, tag + "_fc_a");

    if config.zeroInitResidualOut
        outFc = fullyConnectedLayer(W, Name=tag + "_fc_o", WeightsInitializer="zeros");
    else
        outFc = fullyConnectedLayer(W, Name=tag + "_fc_o");
    end

    if useGate
        % Linear (signed) geometric gate; bias initialised to gateBiasInit
        % so the block starts as an ungated residual MLP.
        gate = fullyConnectedLayer(W, Name=tag + "_gate", ...
            BiasInitializer=@(sz) gateBias * ones(sz, 'single'));
        net = addLayers(net, gate);
        net = addLayers(net, [
            multiplicationLayer(2, Name=tag + "_mult")
            outFc
            additionLayer(2, Name=tag + "_add")]);
        net = connectLayers(net, geoOut, tag + "_gate");
        net = connectLayers(net, tag + "_act_a", tag + "_mult/in1");
        net = connectLayers(net, tag + "_gate", tag + "_mult/in2");
    else
        net = addLayers(net, [outFc; additionLayer(2, Name=tag + "_add")]);
        net = connectLayers(net, tag + "_act_a", tag + "_fc_o");
    end
    net = connectLayers(net, prev, tag + "_add/in2");   % identity skip
    prev = tag + "_add";
end
trunkOut = prev;

% --- Decoupled, physically bounded readout heads --------------------------
if config.useMultiHead
    net = addLayers(net, concatenationLayer(1, numTargets, Name="concatOut"));
    for i = 1:numTargets
        headName = sprintf("head_%d", i);
        layers = localBuildHeadLayers(headName, config.headHiddenSizes, 1, normKind, ...
            actKind, "ln", "act");
        layers = [layers; localBoundLayers(headName, specs(i))]; %#ok<AGROW>
        net = addLayers(net, layers);
        net = connectLayers(net, trunkOut, headName + "_fc1");
        net = connectLayers(net, layers(end).Name, sprintf("concatOut/in%d", i));
    end
else
    layers = localBuildHeadLayers("out", config.headHiddenSizes, numTargets, normKind, ...
        actKind, "ln", "act");
    net = addLayers(net, layers);
    net = connectLayers(net, trunkOut, "out_fc1");
    if any([specs.Kind] ~= "none")
        % Split the shared multi-output head per channel (multi-output
        % sliceLayer), bound each channel, then re-concatenate.
        net = addLayers(net, sliceLayer(1, num2cell(1:numTargets), Name="out_split"));
        net = connectLayers(net, "out_out", "out_split");
        net = addLayers(net, concatenationLayer(1, numTargets, Name="concatOut"));
        for i = 1:numTargets
            chName = sprintf("out_ch%d", i);
            bl = localBoundLayers(chName, specs(i));
            if isempty(bl)
                bl = identityLayer(Name=chName + "_identity");
            end
            net = addLayers(net, bl);
            net = connectLayers(net, sprintf("out_split/out%d", i), bl(1).Name);
            net = connectLayers(net, bl(end).Name, sprintf("concatOut/in%d", i));
        end
    end
end
end

function layers = localBoundLayers(prefix, spec)
switch spec.Kind
    case "sigmoid"
        layers = [
            sigmoidLayer(Name=prefix + "_bound")
            scalingLayer(Scale=spec.Scale, Offset=spec.Offset, Name=prefix + "_zscore")];
    case "softplus"
        layers = [
            softplusLayer(Name=prefix + "_bound")
            scalingLayer(Scale=spec.Scale, Offset=spec.Offset, Name=prefix + "_zscore")];
    otherwise
        layers = [];
end
end

function idx = localResolveGeometryIdx(requested, featureNames, numFeatures)
if isempty(featureNames)
    error('buildSurrogateNetwork:FeatureNamesRequired', ...
        'gs_tensor needs FeatureNames to locate the geometry columns (%s).', ...
        strjoin(requested, ', '));
end
if numel(featureNames) ~= numFeatures
    error('buildSurrogateNetwork:FeatureNamesSize', ...
        'FeatureNames has %d entries but the network has %d input features.', ...
        numel(featureNames), numFeatures);
end
% Aliases keep v2_physics / v1_legacy datasets usable with gs_tensor.
aliases = dictionary( ...
    ["log_p", "log_r", "log_g_norm"], ...
    {["log_p", "p_um"], ["log_r", "r_um"], ["log_g_norm", "g_norm", "p_over_r"]});
idx = zeros(1, numel(requested));
for j = 1:numel(requested)
    cands = requested(j);
    if isKey(aliases, requested(j))
        cands = aliases{requested(j)};
    end
    hit = find(ismember(featureNames, cands), 1);
    if isempty(hit)
        error('buildSurrogateNetwork:MissingGeometryFeature', ...
            'Geometry feature "%s" not found among input features [%s].', ...
            requested(j), strjoin(featureNames, ', '));
    end
    if featureNames(hit) ~= requested(j)
        warning('buildSurrogateNetwork:GeometryFeatureAlias', ...
            'Geometry feature "%s" not present; using "%s" instead.', ...
            requested(j), featureNames(hit));
    end
    idx(j) = hit;
end
if numel(unique(idx)) ~= numel(idx)
    error('buildSurrogateNetwork:DuplicateGeometryFeature', ...
        'Geometry features resolve to duplicate input columns.');
end
end

%% ------------------------------------------------------------------------
%  Legacy architectures ("resnet", "tensor_resnet"), unchanged from v6.2
%  ------------------------------------------------------------------------
function netArchitecture = localBuildLegacyNetwork(numFeatures, numTargets, config)
netArchitecture = dlnetwork;
netArchitecture = addLayers(netArchitecture, featureInputLayer(numFeatures, 'Name', 'input'));

% --- Block 1 ---
block1 = [
    fullyConnectedLayer(config.fc1a, 'Name', 'fc1a')
    localNormLayer('bn1a', config.normalization)
    geluLayer('Name', 'gelu1a')
    fullyConnectedLayer(config.fc1b, 'Name', 'fc1b')
    localNormLayer('bn1b', config.normalization)
    geluLayer('Name', 'gelu1b')];
netArchitecture = addLayers(netArchitecture, block1);
netArchitecture = addLayers(netArchitecture, fullyConnectedLayer(config.proj1, 'Name', 'proj1'));
netArchitecture = addLayers(netArchitecture, additionLayer(2, 'Name', 'add1'));

netArchitecture = connectLayers(netArchitecture, 'input', 'fc1a');
netArchitecture = connectLayers(netArchitecture, 'gelu1b', 'add1/in1');
netArchitecture = connectLayers(netArchitecture, 'input', 'proj1');
netArchitecture = connectLayers(netArchitecture, 'proj1', 'add1/in2');

% --- Injection 1 (Mid): Concatenate Block 1 Output + Input Payload ---
netArchitecture = addLayers(netArchitecture, concatenationLayer(1, 2, 'Name', 'concat_mid'));
netArchitecture = connectLayers(netArchitecture, 'add1', 'concat_mid/in1');
netArchitecture = connectLayers(netArchitecture, 'input', 'concat_mid/in2');

% --- Block 2 ---
if strcmpi(config.architecture, "tensor_resnet")
    % Low-Rank Tensor-Product Residual Core (Bilinear / Tucker Contraction):
    % Contracts multi-scale latent factor U^(A) from concat_mid with direct
    % spectral/coordinate factor U^(B) from input via Hadamard tensor product
    % in rank-R latent space before projecting to fc2b.
    branchA = [
        fullyConnectedLayer(config.fc2a, 'Name', 'fc2a')
        localNormLayer('bn2a', config.normalization)
        geluLayer('Name', 'gelu2a')
        fullyConnectedLayer(config.tensorRank, 'Name', 'tt_core_a')
        localNormLayer('tt_bn_a', config.normalization)
        geluLayer('Name', 'tt_gelu_a')];
    branchB = [
        fullyConnectedLayer(config.tensorRank, 'Name', 'tt_core_b')
        localNormLayer('tt_bn_b', config.normalization)
        geluLayer('Name', 'tt_gelu_b')];
    postMult = [
        multiplicationLayer(2, 'Name', 'tt_mult')
        fullyConnectedLayer(config.fc2b, 'Name', 'fc2b')
        localNormLayer('bn2b', config.normalization)
        geluLayer('Name', 'gelu2b')];

    netArchitecture = addLayers(netArchitecture, branchA);
    netArchitecture = addLayers(netArchitecture, branchB);
    netArchitecture = addLayers(netArchitecture, postMult);
    netArchitecture = addLayers(netArchitecture, additionLayer(2, 'Name', 'add2'));
    netArchitecture = addLayers(netArchitecture, fullyConnectedLayer(config.fc2b, 'Name', 'proj2'));

    netArchitecture = connectLayers(netArchitecture, 'concat_mid', 'fc2a');
    netArchitecture = connectLayers(netArchitecture, 'input', 'tt_core_b');
    netArchitecture = connectLayers(netArchitecture, 'tt_gelu_a', 'tt_mult/in1');
    netArchitecture = connectLayers(netArchitecture, 'tt_gelu_b', 'tt_mult/in2');
    netArchitecture = connectLayers(netArchitecture, 'gelu2b', 'add2/in1');
    netArchitecture = connectLayers(netArchitecture, 'concat_mid', 'proj2');
    netArchitecture = connectLayers(netArchitecture, 'proj2', 'add2/in2');
else
    block2 = [
        fullyConnectedLayer(config.fc2a, 'Name', 'fc2a')
        localNormLayer('bn2a', config.normalization)
        geluLayer('Name', 'gelu2a')
        fullyConnectedLayer(config.fc2b, 'Name', 'fc2b')
        localNormLayer('bn2b', config.normalization)
        geluLayer('Name', 'gelu2b')];
    netArchitecture = addLayers(netArchitecture, block2);
    netArchitecture = addLayers(netArchitecture, additionLayer(2, 'Name', 'add2'));

    % Residual conn: proj2 projects concat_mid to match fc2b
    netArchitecture = addLayers(netArchitecture, fullyConnectedLayer(config.fc2b, 'Name', 'proj2'));

    netArchitecture = connectLayers(netArchitecture, 'concat_mid', 'fc2a');
    netArchitecture = connectLayers(netArchitecture, 'gelu2b', 'add2/in1');
    netArchitecture = connectLayers(netArchitecture, 'concat_mid', 'proj2');
    netArchitecture = connectLayers(netArchitecture, 'proj2', 'add2/in2');
end

% --- Injection 2 (Head): Concatenate Block 2 Output + Input Payload ---
netArchitecture = addLayers(netArchitecture, concatenationLayer(1, 2, 'Name', 'concat_head'));
netArchitecture = connectLayers(netArchitecture, 'add2', 'concat_head/in1');
netArchitecture = connectLayers(netArchitecture, 'input', 'concat_head/in2');

% --- Output Heads ---
if config.useMultiHead
    headInputNames = cell(1, numTargets);
    for i = 1:numTargets
        headName = sprintf('head_%d', i);
        headLayers = localBuildHeadLayers(headName, config.headHiddenSizes, 1, config.normalization);
        netArchitecture = addLayers(netArchitecture, headLayers);
        netArchitecture = connectLayers(netArchitecture, 'concat_head', [headName '_fc1']);
        headInputNames{i} = [headName '_out'];
    end

    netArchitecture = addLayers(netArchitecture, concatenationLayer(1, numTargets, 'Name', 'concatOut'));
    for i = 1:numTargets
        netArchitecture = connectLayers(netArchitecture, headInputNames{i}, sprintf('concatOut/in%d', i));
    end

    netArchitecture = addLayers(netArchitecture, localRegressionIdentityLayer('regression'));
    netArchitecture = connectLayers(netArchitecture, 'concatOut', 'regression');
else
    outLayers = localBuildHeadLayers('out', config.headHiddenSizes, numTargets, config.normalization);
    netArchitecture = addLayers(netArchitecture, outLayers);
    netArchitecture = connectLayers(netArchitecture, 'concat_head', 'out_fc1');
    netArchitecture = addLayers(netArchitecture, localRegressionIdentityLayer('regression'));
    netArchitecture = connectLayers(netArchitecture, 'out_out', 'regression');
end
end

%% ------------------------------------------------------------------------
%  Configuration
%  ------------------------------------------------------------------------
function config = localResolveConfig(configIn, numTargets)
legacyOnly = ["tensorRank", "fc1a", "fc1b", "proj1", "fc2a", "fc2b"];

config = struct();
config.architecture = "gs_tensor";     % "gs_tensor" (default) | "lean_resnet" | "tensor_resnet" | "resnet"
config.normalization = "layer";        % "layer" (default) | "batch" (legacy)
config.useMultiHead = true;
config.headHiddenSizes = [];           % [] -> 128 (gs_tensor/lean_resnet) or 512 (legacy)
% gs_tensor / lean_resnet
config.modelWidth = 256;
config.geoWidth = 128;
config.geoDepth = 2;
config.numBlocks = 2;
config.geometryFeatures = ["log_p", "log_r", "log_g_norm"];
config.gateBiasInit = 1;
config.zeroInitResidualOut = true;
config.boundedHeads = true;
config.hiddenActivation = "gelu";
% legacy resnet / tensor_resnet
config.tensorRank = 512;
config.fc1a = 256;
config.fc1b = 512;
config.proj1 = 512;
config.fc2a = 1024;
config.fc2b = 512;

if isstruct(configIn)
    fields = fieldnames(configIn);
    % Back-compat: legacy width overrides without an explicit architecture
    % keep meaning tensor_resnet (the pre-6.3 default).
    if ~isfield(configIn, 'architecture') && any(ismember(fields, legacyOnly))
        config.architecture = "tensor_resnet";
    end
    for k = 1:numel(fields)
        config.(fields{k}) = configIn.(fields{k});
    end
end

config.architecture = lower(string(config.architecture));
if ~ismember(config.architecture, ["gs_tensor", "lean_resnet", "resnet", "tensor_resnet"])
    error('train_sers_dnn:NetworkConfig', ...
        'Network config architecture must be "gs_tensor", "lean_resnet", "resnet" or "tensor_resnet" (got "%s").', ...
        config.architecture);
end
isLegacy = ismember(config.architecture, ["resnet", "tensor_resnet"]);

if numTargets < 1
    error('train_sers_dnn:Targets', 'Number of targets must be >= 1.');
end
config.useMultiHead = logical(config.useMultiHead);
config.normalization = lower(string(config.normalization));
if ~ismember(config.normalization, ["layer", "batch"])
    error('train_sers_dnn:NetworkConfig', ...
        'Network config normalization must be "layer" or "batch" (got "%s").', config.normalization);
end
if isempty(config.headHiddenSizes)
    if isLegacy
        config.headHiddenSizes = 512;
    else
        config.headHiddenSizes = 128;
    end
end
config.headHiddenSizes = localPosIntVec(config.headHiddenSizes, 'headHiddenSizes');

if isLegacy
    if isempty(config.tensorRank)
        config.tensorRank = 128;
    end
    config.tensorRank = localPosInt(config.tensorRank, 'tensorRank');
    config.fc1a = localPosInt(config.fc1a, 'fc1a');
    config.fc1b = localPosInt(config.fc1b, 'fc1b');
    config.proj1 = localPosInt(config.proj1, 'proj1');
    config.fc2a = localPosInt(config.fc2a, 'fc2a');
    config.fc2b = localPosInt(config.fc2b, 'fc2b');
    % Auto-enforce residual connection constraints
    % The network has two residual paths:
    % 1. input → proj1 → add1/in2  (must match fc1b → add1/in1)
    % 2. add1 → add2/in2  (must match fc2b → add2/in1)
    % Therefore: proj1 must equal fc1b, and fc2b must equal proj1 (=fc1b)
    if config.proj1 ~= config.fc1b
        warning('train_sers_dnn:ArchitectureConstraint', ...
            'proj1 (%d) auto-corrected to fc1b (%d) for residual connection.', ...
            config.proj1, config.fc1b);
        config.proj1 = config.fc1b;
    end
    if config.fc2b ~= config.fc1b
        warning('train_sers_dnn:ArchitectureConstraint', ...
            'fc2b (%d) auto-corrected to fc1b (%d) for residual connection.', ...
            config.fc2b, config.fc1b);
        config.fc2b = config.fc1b;
    end
else
    config.modelWidth = localPosInt(config.modelWidth, 'modelWidth');
    config.geoWidth = localPosInt(config.geoWidth, 'geoWidth');
    config.geoDepth = localNonNegInt(config.geoDepth, 'geoDepth');
    config.numBlocks = localNonNegInt(config.numBlocks, 'numBlocks');
    config.geometryFeatures = string(config.geometryFeatures(:)');
    if isempty(config.geometryFeatures)
        error('train_sers_dnn:NetworkConfig', 'geometryFeatures cannot be empty.');
    end
    if ~isscalar(config.gateBiasInit) || ~isfinite(config.gateBiasInit)
        error('train_sers_dnn:NetworkConfig', 'gateBiasInit must be a finite scalar.');
    end
    config.gateBiasInit = double(config.gateBiasInit);
    config.zeroInitResidualOut = logical(config.zeroInitResidualOut);
    config.boundedHeads = logical(config.boundedHeads);
    config.hiddenActivation = lower(string(config.hiddenActivation));
    if ~ismember(config.hiddenActivation, ["gelu", "swish", "tanh"])
        error('train_sers_dnn:NetworkConfig', ...
            'hiddenActivation must be "gelu", "swish" or "tanh" (got "%s").', config.hiddenActivation);
    end
end
end

function value = localPosInt(value, name)
if ~isscalar(value) || ~isfinite(value) || value < 1
    error('train_sers_dnn:NetworkConfig', 'Network config %s must be a positive integer.', name);
end
value = round(double(value));
end

function value = localNonNegInt(value, name)
if ~isscalar(value) || ~isfinite(value) || value < 0
    error('train_sers_dnn:NetworkConfig', 'Network config %s must be a non-negative integer.', name);
end
value = round(double(value));
end

function values = localPosIntVec(values, name)
if isempty(values)
    error('train_sers_dnn:NetworkConfig', 'Network config %s cannot be empty.', name);
end
values = double(values(:)');
if any(~isfinite(values)) || any(values < 1)
    error('train_sers_dnn:NetworkConfig', 'Network config %s must be positive integers.', name);
end
values = round(values);
end

%% ------------------------------------------------------------------------
%  Shared layer factories
%  ------------------------------------------------------------------------
function layer = localNormLayer(name, kind)
% Per-layer normalisation. LayerNorm normalises each sample over its
% channels, so its behaviour does not depend on mini-batch composition.
if nargin < 2 || isempty(kind)
    kind = "layer";
end
switch lower(string(kind))
    case "batch"
        layer = batchNormalizationLayer('Name', name);
    otherwise
        layer = layerNormalizationLayer('Name', name);
end
end

function layer = localActLayer(name, kind)
switch lower(string(kind))
    case "swish"
        layer = swishLayer(Name=name);
    case "tanh"
        layer = tanhLayer(Name=name);
    otherwise
        layer = geluLayer(Name=name);
end
end

function layers = localBuildHeadLayers(prefix, hiddenSizes, outSize, normKind, actKind, normTag, actTag)
% Legacy naming (head_k_bn1 / head_k_gelu1) is kept when normTag/actTag are
% omitted so pre-6.3 architectures are reproduced layer-for-layer.
if nargin < 3 || isempty(outSize), outSize = 1; end
if nargin < 4, normKind = "layer"; end
if nargin < 5, actKind = "gelu"; end
if nargin < 6, normTag = "bn"; end
if nargin < 7, actTag = "gelu"; end
prefix = string(prefix);
hiddenSizes = localPosIntVec(hiddenSizes, 'headHiddenSizes');
layers = [];
for idx = 1:numel(hiddenSizes)
    layers = [layers
        fullyConnectedLayer(hiddenSizes(idx), 'Name', sprintf('%s_fc%d', prefix, idx))
        localNormLayer(sprintf('%s_%s%d', prefix, normTag, idx), normKind)
        localActLayer(sprintf('%s_%s%d', prefix, actTag, idx), actKind)]; %#ok<AGROW>
end
layers = [layers
    fullyConnectedLayer(outSize, 'Name', sprintf('%s_out', prefix))];
end

function layer = localRegressionIdentityLayer(name)
layer = functionLayer(@(X) X, 'Name', name, 'Formattable', true);
end
