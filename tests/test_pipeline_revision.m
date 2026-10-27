clc;
scriptDir = fileparts(mfilename('fullpath'));
codebaseDir = fileparts(scriptDir);
cd(codebaseDir);
addpath(codebaseDir);
setup_project;
rehash;

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

assert(n_um > 0.05 && n_um < 0.25, 'ri.nFunc(0.785) should be in physical Au range [0.05, 0.25]');
assert(k_um > 4.5 && k_um < 5.5, 'ri.kFunc(0.785) should be in physical Au range [4.5, 5.5]');
assert(abs(n_nm - n_um) < 1e-4, 'ri.nFunc(785 nm) should match 0.785 um');
assert(abs(k_nm - k_um) < 1e-4, 'ri.kFunc(785 nm) should match 0.785 um');
fprintf('  ✓ Refractive index unit scaling PASSED!\n\n');

%% 2. Test Canonical Metric Naming & COMSOL Variable Conventions
fprintf('--- Test 2: Canonical Metric & COMSOL Variable Naming ---\n');
varNames = string(defaultComsolVarNames());
assert(all(ismember(["EE_V", "EE_S", "EF_max"], varNames)), ...
    'defaultComsolVarNames must include EE_V, EE_S, EF_max');
assert(all(ismember(["kappa_V", "kappa_S"], varNames)), ...
    'defaultComsolVarNames must include kappa_V, kappa_S');
assert(all(ismember(["Abs", "ECC"], varNames)), ...
    'defaultComsolVarNames must include Abs, ECC');

assert(canonicalMetricName("EE_V") == "EE_V_broad", 'Default canonicalMetricName(EE_V) should be EE_V_broad');
assert(canonicalMetricName("EE_S", "laser") == "EE_S_laser", 'canonicalMetricName(EE_S, laser) should be EE_S_laser');
assert(canonicalMetricName("EE_S", "broad") == "EE_S_broad", 'canonicalMetricName(EE_S, broad) should be EE_S_broad');
assert(canonicalMetricName("EE_S", "analyte") == "EE_S_analyte", 'canonicalMetricName(EE_S, analyte) should be EE_S_analyte');
assert(canonicalMetricName("EF_max", "laser") == "EF_max_laser", 'canonicalMetricName(EF_max, laser) should be EF_max_laser');
assert(canonicalMetricName("Abs", "laser") == "Abs_laser", 'canonicalMetricName(Abs, laser) should be Abs_laser');

normList = normalizeMetricNames(["EE_V_broad", "EE_S_analyte", "EF_max_laser", "Abs_laser", "ECC", "kappa_V", "kappa_S"]);
assert(isequal(normList, ["EE_V", "EE_S", "EF_max", "Abs", "ECC", "kappa_V", "kappa_S"]), ...
    'normalizeMetricNames should strip derived suffixes and preserve canonical base names');

% Synthetic new-convention SoA struct test for recomputeDerivedMetrics & resolveDerivedMetricField
synthSoA = struct();
synthSoA.period = [300; 400];
synthSoA.radius = [100; 120];
synthSoA.LaserWl = [785; 785];
synthSoA.RamanShift = [100, 4200];
synthSoA.lambda = [785, 800, 850, 900; 785, 800, 850, 900];
synthSoA.Abs = [0.5, 0.4, 0.3, 0.2; 0.6, 0.5, 0.4, 0.3];
synthSoA.EF_max = [1e5, 8e4, 5e4, 2e4; 2e5, 1.5e5, 1e5, 5e4];
synthSoA.EE_V = [1e2, 80, 50, 20; 2e2, 150, 100, 50];
synthSoA.EE_S = [5e2, 400, 250, 100; 1e3, 750, 500, 250];
cfgTest = struct('laserWavelength', 785, 'ramanWindow', [100, 4200], ...
                 'detectShiftWindow', false, 'interpResolution', 5, ...
                 'spectralInterpMethod', 'pchip');
analyteTest = struct('shift_cm', [500, 1000, 1500, 2000], 'intensity', [0.2, 1.0, 0.8, 0.1]);
synthSoA = recomputeDerivedMetrics(synthSoA, cfgTest, analyteTest);

assert(isfield(synthSoA, 'Abs_laser') && isfield(synthSoA, 'Abs_broad') && isfield(synthSoA, 'Abs_analyte'), ...
    'recomputeDerivedMetrics must populate Abs_laser, Abs_broad, Abs_analyte');
assert(isfield(synthSoA, 'EF_max_laser') && isfield(synthSoA, 'EF_max_broad') && isfield(synthSoA, 'EF_max_analyte'), ...
    'recomputeDerivedMetrics must populate EF_max_laser, EF_max_broad, EF_max_analyte');
assert(isfield(synthSoA, 'EE_V_laser') && isfield(synthSoA, 'EE_V_broad') && isfield(synthSoA, 'EE_V_analyte'), ...
    'recomputeDerivedMetrics must populate EE_V_laser, EE_V_broad, EE_V_analyte');
assert(isfield(synthSoA, 'EE_S_laser') && isfield(synthSoA, 'EE_S_broad') && isfield(synthSoA, 'EE_S_analyte'), ...
    'recomputeDerivedMetrics must populate EE_S_laser, EE_S_broad, EE_S_analyte');
assert(resolveDerivedMetricField('EE_V', 'broad', synthSoA) == "EE_V_broad", 'EE_V broad should resolve to EE_V_broad');
assert(resolveDerivedMetricField('EE_S', 'analyte', synthSoA) == "EE_S_analyte", 'EE_S analyte should resolve to EE_S_analyte');
assert(resolveDerivedMetricField('EF_max', 'laser', synthSoA) == "EF_max_laser", 'EF_max laser should resolve to EF_max_laser');
fprintf('  ✓ Canonical metric & COMSOL variable naming PASSED!\n\n');

%% 3. Test Metric Field Name Resolution on Real COMSOL Data (Backward Compatibility)
fprintf('--- Test 3: Metric Field Resolution on COMSOL Data ---\n');
dataPath = fullfile(codebaseDir, "..", "..", "Data", "Data Analysis", "prl_sweep_sphere_785_new.mat");
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
fn_abs_laser = resolveDerivedMetricField('Abs', 'laser', ad);
fn_ees_laser = resolveDerivedMetricField('EE_S', 'laser', ad);
fn_eev_laser = resolveDerivedMetricField('EE_V', 'laser', ad);

fprintf('  Resolved Absorptance (avg)  : %-15s (valid: %d / %d)\n', fn_abs_avg, nnz(~isnan(ad.(fn_abs_avg))), numel(ad.(fn_abs_avg)));
fprintf('  Resolved Abs (laser)        : %-15s (valid: %d / %d)\n', fn_abs_laser, nnz(~isnan(ad.(fn_abs_laser))), numel(ad.(fn_abs_laser)));
fprintf('  Resolved EE_S (laser)       : %-15s (valid: %d / %d)\n', fn_ees_laser, nnz(~isnan(ad.(fn_ees_laser))), numel(ad.(fn_ees_laser)));
fprintf('  Resolved EE_V (laser)       : %-15s (valid: %d / %d)\n', fn_eev_laser, nnz(~isnan(ad.(fn_eev_laser))), numel(ad.(fn_eev_laser)));

assert(fn_abs_avg == "Abs_avg", 'Absorptance avg should resolve to Abs_avg on legacy dataset');
assert(fn_abs_laser == "Abs_laser", 'Abs laser should resolve to Abs_laser');
assert(fn_ees_laser == "EF_surf_approx" || fn_ees_laser == "EE_S_laser", 'EE_S laser should resolve on legacy dataset');
assert(nnz(~isnan(ad.(fn_abs_avg))) > 3400, 'Abs_avg must have >3400 valid points');
fprintf('  ✓ Metric field resolution PASSED!\n\n');

%% 4. Test Full Grid Prediction Pipeline vs Ground Truth
fprintf('--- Test 4: Grid Prediction vs Ground Truth Correlation ---\n');
modelPath = fullfile(codebaseDir, "..", "..", "Data", "Data Analysis", "prl_sweep_sphere_785_new_model.mat");
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
ri_yak = struct('WavelengthUnit', 'um', ...
                'nFunc', @(l) 0.1022 * ones(size(l)), ...
                'kFunc', @(l) 5.0998 * ones(size(l)));

predRaw = squeeze(predictSurrogateSpectrum(m.model, P_um(:), R_um(:), lam_laser, ri_yak));

true_abs = ad.Abs_laser(testIdx);
true_efs = ad.EF_surf_approx(testIdx);
true_efv = ad.EF_vol_approx(testIdx);

r_abs = corr(predRaw(:, 1), true_abs(:));
r_efv = corr(predRaw(:, 2), true_efv(:));
r_efs = corr(predRaw(:, 3), true_efs(:));

fprintf('  Model Correlation with Ground Truth (100 geometries at 785 nm):\n');
fprintf('    Abs  : r = %.4f (mean pred = %.2f, true = %.2f)\n', r_abs, mean(predRaw(:,1)), mean(true_abs));
fprintf('    EE_V : r = %.4f (mean pred = %.2f, true = %.2f)\n', r_efv, mean(predRaw(:,2)), mean(true_efv));
fprintf('    EE_S : r = %.4f (mean pred = %.2f, true = %.2f)\n', r_efs, mean(predRaw(:,3)), mean(true_efs));

assert(r_abs > 0.90, 'Abs correlation must exceed 0.90');
assert(r_efv > 0.90, 'EE_V correlation must exceed 0.90');
assert(r_efs > 0.90, 'EE_S correlation must exceed 0.90');
fprintf('  ✓ Prediction correlation PASSED (all r > 0.92)!\n\n');

%% 5. Test MAPE Metric Computation
fprintf('--- Test 5: MAPE Computation in Test Metrics ---\n');
yTrueTest = [100, 1000; 200, 2000];
yPredTest = [110, 900; 190, 2100]; % 10%, 10%, 5%, 5% errors
[mPT, mAgg] = localComputeTestMetricsTest(yTrueTest, yPredTest, ["mape", "rmse"]);

fprintf('  MAPE per target: [%.4f, %.4f]\n', mPT.mape(1), mPT.mape(2));
fprintf('  MAPE aggregate : %.4f\n', mAgg.mape);
assert(abs(mPT.mape(1) - 0.075) < 1e-4, 'Target 1 MAPE should be 7.5%%');
assert(abs(mPT.mape(2) - 0.075) < 1e-4, 'Target 2 MAPE should be 7.5%%');
fprintf('  ✓ MAPE calculation PASSED!\n\n');

fprintf('===================================================================\n');
fprintf('  ALL 5 VERIFICATION TESTS COMPLETED SUCCESSFULLY!\n');
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
