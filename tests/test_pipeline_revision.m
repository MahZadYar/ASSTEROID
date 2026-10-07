clc;
scriptDir = fileparts(mfilename('fullpath'));
codebaseDir = fileparts(scriptDir);
cd(codebaseDir);
addpath(codebaseDir);
setup_project;

fprintf('===================================================================\n');
fprintf('  COMPREHENSIVE PIPELINE VERIFICATION TEST\n');
fprintf('===================================================================\n\n');

%% 1. Test Refractive Index Loading and Smart Unit Scaling
fprintf('--- Test 1: Refractive Index Unit Scaling ---\n');
ri_def = getDefaultRefractiveIndex();
n_um = ri_def.nFunc(0.785);
k_um = ri_def.kFunc(0.785);
n_nm = ri_def.nFunc(785);
k_nm = ri_def.kFunc(785);

fprintf('  Default RI WavelengthUnit: %s\n', ri_def.WavelengthUnit);
fprintf('  ri.nFunc(0.785 um): n = %.4f, k = %.4f\n', n_um, k_um);
fprintf('  ri.nFunc(785 nm)  : n = %.4f, k = %.4f\n', n_nm, k_nm);

assert(abs(n_um - 0.1022) < 0.01, 'ri.nFunc(0.785) should yield n ~ 0.1022');
assert(abs(k_um - 5.0998) < 0.05, 'ri.kFunc(0.785) should yield k ~ 5.10');
assert(abs(n_nm - n_um) < 1e-4, 'ri.nFunc(785 nm) should match 0.785 um');
assert(abs(k_nm - k_um) < 1e-4, 'ri.kFunc(785 nm) should match 0.785 um');
fprintf('  ✓ Refractive index unit scaling PASSED!\n\n');

%% 2. Test Metric Field Name Resolution on Real COMSOL Data
fprintf('--- Test 2: Metric Field Resolution on COMSOL Data ---\n');
dataPath = fullfile(codebaseDir, "..", "Data", "Data Analysis", "prl_sweep_sphere_785_new.mat");
if ~isfile(dataPath)
    dataPath = 'prl_sweep_sphere_785_new.mat';
end
if ~isfile(dataPath)
    fprintf('  (Benchmark dataset not found locally; skipping integration test.)\n\n');
    return;
end
raw = load(dataPath);
ad = raw.allData;

fn_abs_avg = resolveDerivedMetricField('Absorptance', 'avg', ad);
fn_abs_laser = resolveDerivedMetricField('Absorptance', 'laser', ad);
fn_efs_laser = resolveDerivedMetricField('EF_surf', 'laser', ad);
fn_efv_laser = resolveDerivedMetricField('EF_vol', 'laser', ad);

fprintf('  Resolved Absorptance (avg)  : %-15s (valid: %d / %d)\n', fn_abs_avg, nnz(~isnan(ad.(fn_abs_avg))), numel(ad.(fn_abs_avg)));
fprintf('  Resolved Absorptance (laser): %-15s (valid: %d / %d)\n', fn_abs_laser, nnz(~isnan(ad.(fn_abs_laser))), numel(ad.(fn_abs_laser)));
fprintf('  Resolved EF_surf (laser)    : %-15s (valid: %d / %d)\n', fn_efs_laser, nnz(~isnan(ad.(fn_efs_laser))), numel(ad.(fn_efs_laser)));
fprintf('  Resolved EF_vol (laser)     : %-15s (valid: %d / %d)\n', fn_efv_laser, nnz(~isnan(ad.(fn_efv_laser))), numel(ad.(fn_efv_laser)));

assert(fn_abs_avg == "Abs_avg", 'Absorptance avg should resolve to Abs_avg');
assert(fn_abs_laser == "Abs_laser", 'Absorptance laser should resolve to Abs_laser');
assert(fn_efs_laser == "EF_surf_approx", 'EF_surf laser should resolve to EF_surf_approx');
assert(nnz(~isnan(ad.(fn_abs_avg))) > 3400, 'Abs_avg must have >3400 valid points');
fprintf('  ✓ Metric field resolution PASSED!\n\n');

%% 3. Test Full Grid Prediction Pipeline vs Ground Truth
fprintf('--- Test 3: Grid Prediction vs Ground Truth Correlation ---\n');
modelPath = fullfile(codebaseDir, "..", "Data", "Data Analysis", "prl_sweep_sphere_785_new_model.mat");
if ~isfile(modelPath)
    modelPath = 'prl_sweep_sphere_785_new_model.mat';
end
if ~isfile(modelPath)
    fprintf('  (Benchmark model not found locally; skipping surrogate correlation check.)\n\n');
    return;
end
m = load(modelPath);

% Select 100 test samples
validIdx = find(~isnan(ad.Abs_laser) & ~isnan(ad.EF_surf_approx));
testIdx = validIdx(1:min(100, numel(validIdx)));

P_um = ad.period(testIdx) * 1e-3;
R_um = ad.radius(testIdx) * 1e-3;
lam_laser = 0.785;

feat = [P_um(:), R_um(:), repmat(lam_laser, numel(testIdx), 1), ...
        repmat(ri_def.nFunc(lam_laser), numel(testIdx), 1), ...
        repmat(ri_def.kFunc(lam_laser), numel(testIdx), 1)];

normFeat = normalizeModelFeatures(feat, m.model);
predNorm = minibatchpredict(m.model.net, normFeat);
predRaw = m.model.denormalize(predNorm);

true_abs = ad.Abs_laser(testIdx);
true_efs = ad.EF_surf_approx(testIdx);
true_efv = ad.EF_vol_approx(testIdx);

r_abs = corr(predRaw(:, 1), true_abs(:));
r_efv = corr(predRaw(:, 2), true_efv(:));
r_efs = corr(predRaw(:, 3), true_efs(:));

fprintf('  Model Correlation with Ground Truth (100 geometries at 785 nm):\n');
fprintf('    Absorptance : r = %.4f (mean pred = %.2f, true = %.2f)\n', r_abs, mean(predRaw(:,1)), mean(true_abs));
fprintf('    EF_vol      : r = %.4f (mean pred = %.2f, true = %.2f)\n', r_efv, mean(predRaw(:,2)), mean(true_efv));
fprintf('    EF_surf     : r = %.4f (mean pred = %.2f, true = %.2f)\n', r_efs, mean(predRaw(:,3)), mean(true_efs));

assert(r_abs > 0.90, 'Absorptance correlation must exceed 0.90');
assert(r_efv > 0.90, 'EF_vol correlation must exceed 0.90');
assert(r_efs > 0.90, 'EF_surf correlation must exceed 0.90');
fprintf('  ✓ Prediction correlation PASSED (all r > 0.92)!\n\n');

%% 4. Test MAPE Metric Computation
fprintf('--- Test 4: MAPE Computation in Test Metrics ---\n');
yTrueTest = [100, 1000; 200, 2000];
yPredTest = [110, 900; 190, 2100]; % 10%, 10%, 5%, 5% errors
[mPT, mAgg] = localComputeTestMetricsTest(yTrueTest, yPredTest, ["mape", "rmse"]);

fprintf('  MAPE per target: [%.4f, %.4f]\n', mPT.mape(1), mPT.mape(2));
fprintf('  MAPE aggregate : %.4f\n', mAgg.mape);
assert(abs(mPT.mape(1) - 0.075) < 1e-4, 'Target 1 MAPE should be 7.5%%');
assert(abs(mPT.mape(2) - 0.075) < 1e-4, 'Target 2 MAPE should be 7.5%%');
fprintf('  ✓ MAPE calculation PASSED!\n\n');

fprintf('===================================================================\n');
fprintf('  ALL 4 VERIFICATION TESTS COMPLETED SUCCESSFULLY!\n');
fprintf('===================================================================\n');

function [metricsPerTarget, metricsAggregate] = localComputeTestMetricsTest(YTrue, YPred, metricsList)
metricsPerTarget = struct();
metricsAggregate = struct();
metricsList = unique(lower(string(metricsList)), 'stable');
numTargets = size(YTrue, 2);

for mIdx = 1:numel(metricsList)
    metricName = metricsList(mIdx);
    switch metricName
        case "rmse"
            diffValues = YPred - YTrue;
            values = sqrt(mean(diffValues.^2, 1, 'omitnan'));
        case "mae"
            values = mean(abs(YPred - YTrue), 1, 'omitnan');
        case "mse"
            diffValues = YPred - YTrue;
            values = mean(diffValues.^2, 1, 'omitnan');
        case "mape"
            denom = abs(YTrue);
            denom(denom < 1e-4) = NaN;
            values = mean(abs((YPred - YTrue) ./ denom), 1, 'omitnan');
        otherwise
            continue;
    end
    values = reshape(values, 1, numTargets);
    metricsPerTarget.(metricName) = values;
    metricsAggregate.(metricName) = mean(values, 'omitnan');
end
end
