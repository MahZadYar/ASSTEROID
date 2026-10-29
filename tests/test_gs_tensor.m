%% test_gs_tensor  Verification of the v6.3 gs_tensor surrogate architecture.
%
% Self-contained (synthetic SoA data, no benchmark file required).
% Checks (each prints PASS/FAIL; any failure raises an error at the end):
%   1. v3_physics feature schema (8 columns, log_g_norm, no h_over_lambda).
%   2. Dataset bound metadata (BoundKind / LowerBound / UpperBound).
%   3. buildSurrogateNetwork: learnable counts (gs_tensor 450,435;
%      lite 254,883; legacy tensor_resnet 2,546,691 with 9 inputs),
%      allowed layer types, lambda-blind geometry encoder, physically
%      bounded outputs, lean_resnet, single-head bounded split, swish,
%      v2 feature aliasing.
%   4. Smoke training (gs_tensor): metadata, bounded physical predictions,
%      save/load reproduction, finite input gradients (dlgradient).
%   5. Fine-tuning a pretrained gs_tensor re-synchronises the fixed
%      z-scoring (scalingLayer) to the new dataset statistics.
%   6. Legacy tensor_resnet still trains (backward compatibility).
%   7. networkConfigFromUI defaults.
%
% Run from the Codebase folder:
%   matlab -batch "addpath(pwd); setup_project; run('tests/test_gs_tensor.m')"

clearvars; clc;
here = fileparts(mfilename('fullpath'));
if isempty(here) || ~isfolder(here), here = fullfile(pwd, 'tests'); end
codebase = fileparts(here);
failures = strings(0, 1);
fprintf('\n=== test_gs_tensor ===\n');

ri = getDefaultRefractiveIndex(SearchDir=codebase, WavelengthUnit="um");
allData = localSyntheticSoA(160, 12, 1);

%% 1. v3 feature schema
fprintf('\n[1] v3_physics feature schema\n');
base = [0.8 0.2 0.9 0.2 5.5; 0.6 0.294 1.0 0.25 6.5];   % 2nd row: g_norm = 0.02
[F3, n3] = buildPhysicsFeatures(base, struct('Name', "v3_physics", 'IncludeVerticalGap', true));
failures = check(failures, size(F3, 2) == 8 && n3(end) == "log_g_norm" && ~any(n3 == "h_over_lambda"), ...
    'v3 has 8 columns ending in log_g_norm (vertical gap ignored)', sprintf('[%s]', strjoin(n3, ', ')));
failures = check(failures, all(isfinite(F3(:))) && abs(F3(2, 8) - log(0.02)) < 1e-12, ...
    'log_g_norm finite at g_norm = 0.02');
[F2, n2] = buildPhysicsFeatures(base, struct('Name', "v2_physics", 'IncludeVerticalGap', true));
failures = check(failures, size(F2, 2) == 9 && n2(8) == "g_norm" && n2(9) == "h_over_lambda", ...
    'v2 schema unchanged (9 columns with gap)');
[F0, ~] = buildPhysicsFeatures(base, struct('IncludeVerticalGap', false));
failures = check(failures, isequal(F0, F2(:, 1:8)), 'schema without Name defaults to v2 (saved models)');

%% 2. Dataset bound metadata
fprintf('\n[2] Dataset bound metadata\n');
ds = prepare_training_dataset(allData, ri, TargetFields=["Absorptance", "EF_vol", "EF_surf"]);
tt = ds.targetTransform;
failures = check(failures, ds.featureSchema.Name == "v3_physics" && numel(ds.featureNames) == 8, ...
    'default dataset schema is v3_physics (8 features)');
failures = check(failures, isequal(tt.BoundKind, ["sigmoid", "softplus", "softplus"]) ...
    && tt.UpperBound(1) == 100 && all(tt.LowerBound == 0), ...
    'bounds: Abs sigmoid [0,100] (percent), EE softplus >= 0', ...
    sprintf('(%s; U=%g)', strjoin(tt.BoundKind, ','), tt.UpperBound(1)));

%% 3. Network builder
fprintf('\n[3] buildSurrogateNetwork\n');
fn8 = string(ds.featureNames);
[net, info] = buildSurrogateNetwork(8, 3, struct(), FeatureNames=fn8, TargetTransform=tt);
failures = check(failures, info.NumLearnables == 450435, 'gs_tensor default learnables', ...
    sprintf('(%d)', info.NumLearnables));
allowed = ["FeatureInputLayer", "SliceLayer", "FullyConnectedLayer", "LayerNormalizationLayer", ...
    "GELULayer", "MultiplicationLayer", "AdditionLayer", "SigmoidLayer", "SoftplusLayer", ...
    "ScalingLayer", "ConcatenationLayer"];
failures = check(failures, all(ismember(info.LayerTypes, allowed)) && numel(info.LayerTypes) == 11, ...
    'gs_tensor uses exactly the 11 built-in layer types', sprintf('[%s]', strjoin(info.LayerTypes, ', ')));
failures = check(failures, isequal(info.GeometryFeatureIdx, find(ismember(fn8, ["log_p", "log_r", "log_g_norm"]))), ...
    'geometry slice indices resolved by name');
rng(3);
X = 4 * randn(3000, 8);
X2 = X; X2(:, setdiff(1:8, info.GeometryFeatureIdx)) = randn(3000, 5);
g1 = predict(net, dlarray(single(X'), 'CB'), Outputs="geo_act2");
g2 = predict(net, dlarray(single(X2'), 'CB'), Outputs="geo_act2");
failures = check(failures, max(abs(extractdata(g1 - g2)), [], 'all') == 0, ...
    'geometry encoder is lambda-blind');
% Perturb trunk learnables so the bounds are exercised far from initialisation
netR = net;
netR.Learnables.Value = cellfun(@(v) v + 2 * randn(size(v), 'like', v), netR.Learnables.Value, ...
    'UniformOutput', false);
Z = double(extractdata(predict(netR, dlarray(single(50 * X'), 'CB'))))';
Yt = Z .* tt.Std + tt.Mean;
failures = check(failures, min(Yt(:, 1)) >= -1e-4 && max(Yt(:, 1)) <= 100 + 1e-4, ...
    'Abs head bounded to [0, 100]', sprintf('([%.3g, %.3g])', min(Yt(:, 1)), max(Yt(:, 1))));
failures = check(failures, min(Yt(:, 2:3), [], 'all') >= -1e-5, ...
    'log10(1+EE) heads non-negative', sprintf('(min %.3g)', min(Yt(:, 2:3), [], 'all')));
[~, iLite] = buildSurrogateNetwork(8, 3, struct('modelWidth', 192, 'geoWidth', 96, 'headHiddenSizes', 96), ...
    FeatureNames=fn8, TargetTransform=tt);
failures = check(failures, iLite.NumLearnables == 254883, 'gs_tensor lite learnables', ...
    sprintf('(%d)', iLite.NumLearnables));
[~, iTT] = buildSurrogateNetwork(9, 3, struct('architecture', "tensor_resnet"));
failures = check(failures, iTT.NumLearnables == 2546691, 'legacy tensor_resnet reproduced exactly (9 inputs)', ...
    sprintf('(%d)', iTT.NumLearnables));
[~, iLegacy] = buildSurrogateNetwork(9, 3, struct('fc1a', 256, 'fc2a', 1024));
failures = check(failures, iLegacy.Config.architecture == "tensor_resnet", ...
    'legacy width overrides without architecture keep tensor_resnet');
[nLean, iLean] = buildSurrogateNetwork(8, 3, struct('architecture', "lean_resnet"), TargetTransform=tt);
leanNames = string(arrayfun(@(L) L.Name, nLean.Layers, 'UniformOutput', false));
failures = check(failures, iLean.NumLearnables == 366851 && ~any(leanNames == "geo_slice"), ...
    'lean_resnet (no geometry encoder)', sprintf('(%d)', iLean.NumLearnables));
[nSH, ~] = buildSurrogateNetwork(8, 3, struct('useMultiHead', false), FeatureNames=fn8, TargetTransform=tt);
shNames = string(arrayfun(@(L) L.Name, nSH.Layers, 'UniformOutput', false));
failures = check(failures, any(shNames == "out_split") && any(shNames == "out_ch1_bound"), ...
    'single shared head is split per channel (multi-output sliceLayer) and bounded');
[~, iSw] = buildSurrogateNetwork(8, 3, struct('hiddenActivation', "swish"), FeatureNames=fn8, TargetTransform=tt);
failures = check(failures, any(iSw.LayerTypes == "SwishLayer") && ~any(iSw.LayerTypes == "GELULayer"), ...
    'hiddenActivation = swish');
fn9 = ["log_p", "log_r", "log_lambda", "eps1", "eps2", "p_over_lambda", "r_over_lambda", "g_norm", "h_over_lambda"];
warnState = warning('off', 'buildSurrogateNetwork:GeometryFeatureAlias');
[~, iAlias] = buildSurrogateNetwork(9, 3, struct(), FeatureNames=fn9, TargetTransform=tt);
warning(warnState);
failures = check(failures, isequal(iAlias.GeometryFeatureIdx, [1 2 8]), 'v2 datasets alias log_g_norm -> g_norm');

%% 4. Smoke training
fprintf('\n[4] gs_tensor smoke training\n');
m = train_surrogate_dnn(ds, MaxEpochs=3, MiniBatchSize=256, LearningRate=1e-3, Plots="none", ...
    Verbose=false, ValidationFrequency=10, LossFunction="peak_mse");
failures = check(failures, m.architecture == "gs_tensor" && m.networkInfo.BoundedHeads ...
    && m.networkInfo.NumLearnables == 450435, 'model metadata (architecture, bounded heads, learnables)');
failures = check(failures, isPhysicsSchemaModel(m) && m.flags.FeatureSchema == "v3_physics", ...
    'model carries v3_physics schema');
lamVec = (0.785:0.01:1.10)';
Ys = predictSurrogateSpectrum(m, [0.6; 0.9], [0.15; 0.3], lamVec, ri);
failures = check(failures, all(isfinite(Ys(:))) && all(Ys(:, :, 1) >= 0 & Ys(:, :, 1) <= 100, 'all') ...
    && all(Ys(:, :, 2:3) >= 0, 'all'), 'physical predictions finite and within bounds');
tmpFile = [tempname, '.mat'];
model = m; save(tmpFile, 'model'); clear model;
[mL, ~] = loadAndValidateModel(ModelFile=tmpFile, Ri=ri);
Xq = ds.XTest(1:min(200, end), :);
Ya = m.denormalize(predict(m.net, normalizeModelFeatures(Xq, m)));
Yb = mL.denormalize(predict(mL.net, normalizeModelFeatures(Xq, mL)));
failures = check(failures, max(abs(Ya - Yb), [], 'all') == 0, 'reloaded model reproduces predictions');
delete(tmpFile);
Xn = dlarray(single(normalizeModelFeatures(Xq(1:20, :), m))', 'CB');
[~, gX] = dlfeval(@localInputGradient, m.net, Xn);
failures = check(failures, all(isfinite(extractdata(gX)), 'all') && any(extractdata(gX) ~= 0, 'all'), ...
    'dlgradient through gs_tensor finite and non-zero');

%% 5. Fine-tuning re-synchronises fixed z-scoring
fprintf('\n[5] Fine-tuning a pretrained gs_tensor\n');
allData2 = localSyntheticSoA(160, 12, 7);
allData2.Absorptance = 0.6 * allData2.Absorptance;     % different statistics
ds2 = prepare_training_dataset(allData2, ri, TargetFields=["Absorptance", "EF_vol", "EF_surf"]);
m2 = train_surrogate_dnn(ds2, MaxEpochs=1, MiniBatchSize=256, Plots="none", Verbose=false, ...
    ValidationFrequency=10, Layers=m.net);
spec2 = surrogateHeadSpecs(ds2.targetTransform, 3);
zl = m2.net.Layers(arrayfun(@(L) string(L.Name) == "head_1_zscore", m2.net.Layers));
failures = check(failures, abs(zl.Scale - spec2(1).Scale) < 1e-12 && abs(zl.Offset - spec2(1).Offset) < 1e-12, ...
    'head_1_zscore synced to new dataset statistics');
failures = check(failures, m2.architecture == "gs_tensor", 'pretrained architecture inferred from layer names');

%% 6. Legacy architecture
fprintf('\n[6] Legacy tensor_resnet training\n');
ttCfg = struct('architecture', 'tensor_resnet', 'tensorRank', 32, 'fc1a', 32, 'fc1b', 64, ...
    'proj1', 64, 'fc2a', 64, 'fc2b', 64, 'headHiddenSizes', 32);
mT = train_surrogate_dnn(ds, MaxEpochs=1, MiniBatchSize=256, NetworkConfig=ttCfg, Plots="none", ...
    Verbose=false, ValidationFrequency=10);
tNames = string(arrayfun(@(L) L.Name, mT.net.Layers, 'UniformOutput', false));
failures = check(failures, mT.architecture == "tensor_resnet" && any(tNames == "tt_mult") ...
    && any(tNames == "regression") && ~mT.networkInfo.BoundedHeads, ...
    'tensor_resnet topology unchanged (tt_mult, regression identity, unbounded)');

%% 7. UI config helper
fprintf('\n[7] networkConfigFromUI\n');
c0 = networkConfigFromUI(struct());
failures = check(failures, c0.architecture == "gs_tensor" && c0.modelWidth == 256 && c0.geoWidth == 128 ...
    && c0.numBlocks == 2 && isequal(c0.headHiddenSizes, 128) && c0.boundedHeads, 'UI defaults (gs_tensor)');
c1 = networkConfigFromUI(struct('architecture', 'tensor_resnet', 'boundedHeads', false, 'modelWidth', '320'));
failures = check(failures, c1.architecture == "tensor_resnet" && isequal(c1.headHiddenSizes, 512) ...
    && ~c1.boundedHeads && c1.modelWidth == 320, 'UI legacy defaults and string parsing');

%% Summary
fprintf('\n=== %d failure(s) ===\n', numel(failures));
if ~isempty(failures)
    error('test_gs_tensor:Failed', 'Failed checks: %s', strjoin(failures, '; '));
end

function allData = localSyntheticSoA(nG, nL, seed)
rng(seed);
P = 400 + 1000 * rand(nG, 1);                       % nm
r = 50 + (0.49 * P - 50) .* rand(nG, 1);
lamL = 785;
shifts = linspace(0, 3600, nL);
lam = repmat(1e7 ./ (1e7 / lamL - shifts), nG, 1);  % nm
x = (P / 1000) ./ (lam / 1000);
y = (r / 1000) ./ (lam / 1000);
res = exp(-((x - 1.15) ./ 0.08).^2) + 0.5 * exp(-((y - 0.25) ./ 0.05).^2);
allData = struct();
allData.period = P;
allData.radius = r;
allData.lambda = lam;
allData.Absorptance = 10 + 80 * res ./ max(res, [], 'all');   % percent
allData.EF_vol = 10 .^ (1 + 2.5 * res);
allData.EF_surf = 10 .^ (2 + 4 * res);
end

function [v, g] = localInputGradient(net, X)
Y = forward(net, X);
v = sum(Y, 'all');
g = dlgradient(v, X);
end

function failures = check(failures, cond, name, detail)
if nargin < 4, detail = ''; end
if cond
    fprintf('  PASS  %s %s\n', name, detail);
else
    fprintf('  FAIL  %s %s\n', name, detail);
    failures(end+1) = string(name);
end
end
