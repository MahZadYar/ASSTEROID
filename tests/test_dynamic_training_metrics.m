%% test_dynamic_training_metrics.m
% Verify dynamic spectral target discovery and DB-driven training selection.

if exist("discoverSimSpectralMetrics", "file") ~= 2
    rootDir = fileparts(fileparts(mfilename("fullpath")));
    addpath(rootDir);
    setup_project;
end
fprintf("=== Starting test_dynamic_training_metrics ===\n");

ri = getDefaultRefractiveIndex("WavelengthUnit", "um");

%% 1. discoverSimSpectralMetrics on DB without EF_max (with ECC diagnostic)
N = 20; L = 5;
lam = linspace(785, 1000, L);
simNoMax = struct();
simNoMax.period = linspace(450, 950, N)';
simNoMax.radius = linspace(80, 220, N)';
simNoMax.lambda = repmat(lam, N, 1);
simNoMax.Abs = 10 + 5 * rand(N, L);
simNoMax.EE_V = 10 .^ (1 + 2 * rand(N, L));
simNoMax.EE_S = 10 .^ (2 + 3 * rand(N, L));
simNoMax.ECC = 1e-4 * randn(N, L);
simNoMax.EE_V_laser = simNoMax.EE_V(:, 1);

[allM, defM] = discoverSimSpectralMetrics(simNoMax);
assert(isequal(allM, ["Abs", "EE_V", "EE_S", "ECC"]), ...
    sprintf("Unexpected allMetrics: [%s]", strjoin(allM, ", ")));
assert(isequal(defM, ["Abs", "EE_V", "EE_S"]), ...
    sprintf("Unexpected defaultTargets: [%s]", strjoin(defM, ", ")));
fprintf("  [1] discoverSimSpectralMetrics skipped missing EF_max & excluded ECC from defaults.\n");

%% 2. prepare_training_dataset auto-discovers available targets
ds3 = prepare_training_dataset(simNoMax, ri);
assert(isequal(string(ds3.targetNames), ["Abs", "EE_V", "EE_S"]), ...
    sprintf("Expected [Abs, EE_V, EE_S], got [%s]", strjoin(string(ds3.targetNames), ", ")));
assert(isequal(ds3.targetTransform.BoundKind, ["sigmoid", "softplus", "softplus"]), ...
    "3-target bounds mismatch");
fprintf("  [2] prepare_training_dataset omitted TargetFields trained cleanly on 3 available targets.\n");

%% 3. E4_max alias resolution and log transform
simE4 = simNoMax;
simE4.E4_max = 10 .^ (4 + 2 * rand(N, L));
dsE4 = prepare_training_dataset(simE4, ri, TargetFields=["Abs", "EF_max", "EE_V", "EE_S"]);
assert(isequal(dsE4.targetTransform.BoundKind, ["sigmoid", "softplus", "softplus", "softplus"]), ...
    "E4_max must resolve to EF_max with softplus bound");
[allE4, defE4] = discoverSimSpectralMetrics(simE4);
assert(ismember("E4_max", allE4) && ismember("E4_max", defE4), ...
    "discoverSimSpectralMetrics should include E4_max when present");
fprintf("  [3] E4_max resolved both explicitly (via EF_max alias) and dynamically.\n");

%% 4. Custom spectral target discovery and validatePipelineConfig
simCustom = struct();
simCustom.period = simNoMax.period;
simCustom.radius = simNoMax.radius;
simCustom.lambda = simNoMax.lambda;
simCustom.CustomProbe = 5 * rand(N, L);
[allC, defC] = discoverSimSpectralMetrics(simCustom);
assert(isequal(allC, "CustomProbe") && isequal(defC, "CustomProbe"), ...
    "Custom spectral target should be auto-discovered when no standard names exist");

tmpMat = fullfile(tempdir, "test_dyn_metrics_cfg.mat");
cTmp = onCleanup(@() deleteIfExists(tmpMat));
save(tmpMat, "simCustom", "-v7");
cfg = trainingConfig(WorkDir=tempdir, RawDataFiles=tmpMat, MetricsToTrain="CustomProbe");
assert(validatePipelineConfig(cfg), "validatePipelineConfig must allow dynamic custom metrics");
fprintf("  [4] Custom spectral target auto-discovered and validated.\n");

%% 5. AssteroidSession.getStatusStruct & resolveRequestedTrainMetrics
sess = AssteroidSession(tempdir);
sess.db.Sim = simNoMax;
st = sess.getStatusStruct();
assert(isequal(string(st.simSpectralMetrics), ["Abs", "EE_V", "EE_S", "ECC"]), ...
    "Session status should expose simSpectralMetrics");
assert(isequal(string(st.defaultTrainMetrics), ["Abs", "EE_V", "EE_S"]), ...
    "Session status should expose defaultTrainMetrics");

[mResolved, errResolved] = resolveRequestedTrainMetrics(struct(), sess.db);
assert(errResolved == "" && isequal(mResolved, ["Abs", "EE_V", "EE_S"]), ...
    "resolveRequestedTrainMetrics without UI selection should use DB defaults");

[~, errEmpty] = resolveRequestedTrainMetrics(struct("metricsToTrain", {{}}), sess.db);
assert(strlength(errEmpty) > 0, "Empty UI selection should produce explicit validation error");
fprintf("  [5] Session status & resolveRequestedTrainMetrics verified.\n");

fprintf("=== test_dynamic_training_metrics PASSED ===\n");

function deleteIfExists(p)
if isfile(p), delete(p); end
end
