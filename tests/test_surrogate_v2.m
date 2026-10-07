%% test_surrogate_v2  Verification of the v2 physics-schema surrogate pipeline.
%
% Checks (each prints PASS/FAIL; any failure raises an error at the end):
%   1. Geometry-grouped split: no (P, r) pair shared between splits.
%   2. Feature/target transforms: train-split z-scores have mean 0 / std 1;
%      dataset.denormalize inverts the target transform exactly.
%   3. Legacy (v1) model still loads and predicts (backward compatibility).
%   4. v2 smoke training (2 epochs) + save/load round trip via
%      loadAndValidateModel; handles resolve and reproduce predictions.
%   5. predict_dense_spectrum (v2) equals predictSurrogateSpectrum.
%   6. Analytical-gradient objective in find_local_maxima equals the
%      analyte-weighted inference objective; gradient matches central
%      finite differences.
%   7. Spectral smoothness diagnostic on a 0.1 nm grid (reported only).
%
% Run from the Codebase folder after setup_project:
%   matlab -batch "addpath(pwd); setup_project; run('tests/test_surrogate_v2.m')"

clearvars; clc;
here = fileparts(mfilename('fullpath'));
if isempty(here) || ~isfolder(here), here = fullfile(pwd, 'tests'); end
codebase = fileparts(here);
dataDir = fullfile(codebase, '..', 'Data', 'Data Analysis');
dataFile = fullfile(dataDir, 'prl_sweep_sphere_785_new.mat');
legacyModelFile = fullfile(dataDir, 'prl_sweep_sphere_785_new_model.mat');

failures = strings(0, 1);

fprintf('\n=== test_surrogate_v2 ===\n');
if ~isfile(dataFile)
    fprintf('  (Benchmark dataset not found locally; skipping test_surrogate_v2.)\n\n');
    return;
end
S = load(dataFile, 'allData');
ri = getDefaultRefractiveIndex(SearchDir=codebase, WavelengthUnit="um");

%% 1. Geometry split
fprintf('\n[1] Geometry-grouped split\n');
ds = prepare_training_dataset(S.allData, ri, ...
    TargetFields=["Absorptance", "EF_vol", "EF_surf"]);
gk = @(X) unique(round(X(:, 1:2) * 1e6), 'rows');
gTr = gk(ds.XTrain); gVa = gk(ds.XValidation); gTe = gk(ds.XTest);
nOverlap = size(intersect(gTr, gTe, 'rows'), 1) + size(intersect(gTr, gVa, 'rows'), 1) ...
         + size(intersect(gVa, gTe, 'rows'), 1);
failures = check(failures, nOverlap == 0, 'no geometry overlap', ...
    sprintf('(%d/%d/%d geometries)', size(gTr,1), size(gVa,1), size(gTe,1)));
fracTest = size(gTe, 1) / (size(gTr,1) + size(gVa,1) + size(gTe,1));
failures = check(failures, abs(fracTest - 0.1) < 0.01, 'test fraction ~10 %', sprintf('(%.3f)', fracTest));

%% 2. Transforms
fprintf('\n[2] Feature / target transforms\n');
F = ds.normalize(ds.XTrain);
failures = check(failures, max(abs(mean(F))) < 1e-8 && max(abs(std(F) - 1)) < 1e-8, ...
    'train features z-scored', ...
    sprintf('(max|mean|=%.1e, max|std-1|=%.1e)', max(abs(mean(F))), max(abs(std(F) - 1))));
failures = check(failures, max(abs(mean(ds.YTrain))) < 1e-8 && max(abs(std(ds.YTrain) - 1)) < 1e-8, ...
    'train targets z-scored');
tt = ds.targetTransform;
Yphys = ds.denormalize(ds.YTest);
Yref = expm1(ds.YTest .* tt.Std + tt.Mean);
relErr = max(abs(Yphys - max(Yref, 0)) ./ max(1, abs(Yref)), [], 'all');
failures = check(failures, relErr < 1e-12, 'denormalize inverts log1p + z-score', sprintf('(%.1e)', relErr));
failures = check(failures, all(Yphys(:) >= 0), 'reconstructed targets non-negative');

%% 3. Legacy model
fprintf('\n[3] Legacy (v1) model backward compatibility\n');
if isfile(legacyModelFile)
    [m1, ~] = loadAndValidateModel(ModelFile=legacyModelFile, Ri=ri);
    failures = check(failures, ~isPhysicsSchemaModel(m1), 'legacy model detected as v1');
    nG = 100;
    lamNm = double(S.allData.lambda(1:nG, :));
    names = string(m1.targetNames);
    want = intersect(["Absorptance", "EF_surf"], names, 'stable');
    yTrue = nan(nG, numel(want)); yPred = nan(nG, numel(want));
    for g = 1:nG
        [~, j] = min(abs(lamNm(g, :) - 785));
        lamUm = lamNm(g, j) * 1e-3;
        Yg = predictSurrogateSpectrum(m1, double(S.allData.period(g)) * 1e-3, ...
            double(S.allData.radius(g)) * 1e-3, lamUm, ri);
        for t = 1:numel(want)
            yPred(g, t) = Yg(1, 1, names == want(t));
            yTrue(g, t) = double(S.allData.(want(t))(g, j));
        end
    end
    for t = 1:numel(want)
        ok = isfinite(yTrue(:, t)) & isfinite(yPred(:, t));
        rr = corr(yTrue(ok, t), yPred(ok, t));
        failures = check(failures, rr > 0.9, sprintf('v1 %s correlation @785 nm', want(t)), ...
            sprintf('(r=%.3f, n=%d)', rr, nnz(ok)));
    end
else
    fprintf('  SKIP  legacy model file not found: %s\n', legacyModelFile);
end

%% 4. v2 smoke training + save/load
fprintf('\n[4] v2 smoke training and persistence\n');
m2 = train_sers_dnn(ds, MaxEpochs=2, MiniBatchSize=1024, Plots="none", Verbose=false, ...
    ValidationFrequency=50);
failures = check(failures, isPhysicsSchemaModel(m2), 'trained model carries v2 schema');
lt = arrayfun(@(L) string(class(L)), m2.net.Layers);
failures = check(failures, ~any(contains(lt, 'BatchNormalization')) && any(contains(lt, 'LayerNormalization')), ...
    'LayerNorm, no BatchNorm');
tmpFile = [tempname, '.mat'];
model = m2; save(tmpFile, 'model'); clear model;
lastwarn('');
[m2L, ~] = loadAndValidateModel(ModelFile=tmpFile, Ri=ri);
wMsg = lastwarn;
failures = check(failures, isempty(wMsg), 'reload without warnings', sprintf('(%s)', wMsg));
Xq = ds.XTest(1:500, :);
Ya = m2.denormalize(predict(m2.net, normalizeModelFeatures(Xq, m2)));
Yb = m2L.denormalize(predict(m2L.net, normalizeModelFeatures(Xq, m2L)));
failures = check(failures, max(abs(Ya - Yb), [], 'all') == 0, 'reloaded model reproduces predictions');
delete(tmpFile);

%% 5. Dense prediction path
fprintf('\n[5] predict_dense_spectrum (v2)\n');
pVec = linspace(0.76, 0.94, 7); rVec = linspace(0.06, 0.40, 6);
lamVec = (0.70:0.005:1.10)';
pd = predict_dense_spectrum(m2, pVec, rVec, lamVec, ri, 'Verbose', false, ...
    'LaserWavelength', 785, 'RamanWindow', [100 3500]);
Ydirect = predictSurrogateSpectrum(m2, pd.period * 1e-3, pd.radius * 1e-3, lamVec, ri);
dmax = 0;
for t = 1:numel(m2.targetNames)
    dmax = max(dmax, max(abs(pd.(m2.targetNames{t}) - Ydirect(:, :, t)), [], 'all'));
end
failures = check(failures, dmax == 0, 'dense grid equals predictSurrogateSpectrum', sprintf('(max diff %.1e)', dmax));
failures = check(failures, all(isfinite(pd.EF_surf(:))), 'dense predictions finite');

%% 6. Gradient path consistency (analyte-weighted)
fprintf('\n[6] find_local_maxima analytical gradient\n');
lamOpt = (0.80:0.002:0.90)';
rng(1); aw = rand(numel(lamOpt), 1) + 0.1;
pB = [0.76 0.94]; rB = [0.06 0.40];
p0 = mean(pB); r0 = (rB(1) + min(rB(2), 0.49 * p0)) / 2;
% Model predictor = the configuration used by the app (enables dlgradient path).
predictorV2 = createModelPredictor(m2, ri);
txt = evalc(['find_local_maxima(m2, ri, lamOpt, ''MetricName'', ''EF_surf'', ''NumMaxima'', 1, ', ...
    '''NumStartPoints'', 1, ''PBounds'', pB, ''RBounds'', rB, ''UseParallel'', false, ', ...
    '''MaxIterations'', 1, ''ShowIterationPaths'', true, ''UseGradientSeedInit'', false, ', ...
    '''AnalyteWeights'', aw, ''Predictor'', predictorV2);']);
tok = regexp(txt, 'f\(x0\)=([-+\d.eE]+),\s*\S+=\[([-+\d.eE]+),\s*([-+\d.eE]+)\]', 'tokens', 'once');
failures = check(failures, ~isempty(tok), 'pre-flight gradient reported');
if isempty(tok)
    disp(txt(1:min(end, 3000)));
end
if ~isempty(tok)
    fAD = str2double(tok{1}); gAD = [str2double(tok{2}), str2double(tok{3})];
    idx = find(strcmp(m2.targetNames, 'EF_surf'));
    w = aw / sum(aw);
    favg = @(p, r) localWeighted(m2, p, r, lamOpt, ri, idx, w);
    fRef = favg(p0, r0);
    h = 1e-3;
    gFD = [(favg(p0 + h, r0) - favg(p0 - h, r0)) / (2 * h), ...
           (favg(p0, r0 + h) - favg(p0, r0 - h)) / (2 * h)];
    % minibatchpredict (inference path) and dlnetwork/predict (AD path) run
    % different single-precision kernels; on the smoke model their
    % standardised outputs differ by up to ~1e-3, i.e. ~2e-3 relative in
    % EF after exp(). A logic error (wrong weights/features) would be O(1e-1).
    failures = check(failures, abs(fAD - fRef) / max(abs(fRef), eps) < 2e-3, ...
        'AD objective == analyte-weighted inference', sprintf('(%.6g vs %.6g)', fAD, fRef));
    fUni = localWeighted(m2, p0, r0, lamOpt, ri, idx, ones(numel(lamOpt), 1) / numel(lamOpt));
    failures = check(failures, abs(fAD - fRef) < 0.25 * abs(fUni - fRef), ...
        'AD objective uses analyte weights (not uniform mean)', ...
        sprintf('(|AD-weighted|=%.3g, |uniform-weighted|=%.3g)', abs(fAD - fRef), abs(fUni - fRef)));
    relG = norm(gAD - gFD) / max(norm(gFD), eps);
    failures = check(failures, relG < 0.05, 'AD gradient vs central FD', ...
        sprintf('(AD=[%.4g %.4g], FD=[%.4g %.4g], rel=%.2e)', gAD, gFD, relG));
end

%% 7. Smoothness diagnostic
fprintf('\n[7] Spectral smoothness (diagnostic only)\n');
lamFine = (0.70:0.0001:1.10)';
Yf = predictSurrogateSpectrum(m2, 0.85, 0.20, lamFine, ri);
for t = 1:numel(m2.targetNames)
    y = squeeze(Yf(1, :, t))';
    d2 = abs(diff(y, 2)); rngY = max(y) - min(y);
    fprintf('  %-12s max|d2y|/range = %.2e on 0.1 nm grid\n', m2.targetNames{t}, max(d2) / max(rngY, eps));
end

%% Summary
fprintf('\n=== %d failure(s) ===\n', numel(failures));
if ~isempty(failures)
    error('test_surrogate_v2:Failed', 'Failed checks: %s', strjoin(failures, '; '));
end

function v = localWeighted(model, p, r, lam, ri, idx, w)
Y = predictSurrogateSpectrum(model, p, r, lam, ri);
v = squeeze(Y(1, :, idx)) * w(:);
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
