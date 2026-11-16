%% test_surrogate_evaluation_metrics.m
% Unit tests for computeSurrogateEvaluationMetrics and target-specific transforms

setup_project;
fprintf("=== Starting test_surrogate_evaluation_metrics ===\n");

%% 1. Synthesize mock data
N = 300;
targets = ["Absorptance", "EF_vol", "EF_surf"];
yTrue = zeros(N, 3);
yTrue(:, 1) = rand(N, 1) * 0.9 + 0.05;         % Absorptance: [0, 1]
yTrue(:, 2) = 10.^(rand(N, 1) * 4);            % EF_vol: [1, 10^4]
yTrue(:, 3) = 10.^(rand(N, 1) * 8);            % EF_surf: [1, 10^8]

% Add 5% multiplicative noise
yPred = yTrue .* (1 + 0.05 * randn(N, 3));
yPred(:, 1) = max(min(yPred(:, 1), 1), 0);
yPred(:, 2:3) = max(yPred(:, 2:3), 0);

% Coordinates (period in [400, 1400], diameter in [100, 1300])
P = 400 + 1000 * rand(N, 1);
D = 100 + 0.8 * P .* rand(N, 1);
X = [P, D/2];

% Mock Optima table
optima = table([650; 800; 1100], [300; 500; 700], [150; 250; 350], ...
    'VariableNames', {'period', 'diameter', 'radius'});

%% 2. Run computeSurrogateEvaluationMetrics
fprintf("Running computeSurrogateEvaluationMetrics...\n");
dsTest = struct("XTest", X, "YTest", yTrue, "YPred", yPred, "targetNames", targets);
report = computeSurrogateEvaluationMetrics([], dsTest, optima);

% Assertions
assert(isstruct(report), "Report must be a struct");
assert(isfield(report, 'globalBiased') && istable(report.globalBiased), "Report must have globalBiased table");
assert(isfield(report, 'globalUnbiased') && istable(report.globalUnbiased), "Report must have globalUnbiased table");
assert(isfield(report, 'roiOptima') && istable(report.roiOptima), "Report must have roiOptima table");
assert(isfield(report, 'roiCombined') && istable(report.roiCombined), "Report must have roiCombined table");
assert(isfield(report, 'latexSummary') && strlength(report.latexSummary) > 0, "Report must contain latexSummary");
assert(isfield(report, 'summaryText') && strlength(report.summaryText) > 0, "Report must contain summaryText");

fprintf("  ✓ All tiers (globalBiased, globalUnbiased, roiOptima, roiCombined) generated.\n");

%% 3. Verify target denormalization (channel-specific masks)
fprintf("Testing denormalizeModelTargets...\n");
% Case A: struct format
tt = struct();
tt.targetLogTransform = [false, true, true];
tt.targetLogBase = [10, 10, 10];
tt.Mean = [0.5, 2.0, 4.0];
tt.Std  = [0.2, 1.0, 2.0];

zStd = zeros(10, 3); % mean predictions
yRecovered = denormalizeModelTargets(zStd, tt);
assert(size(yRecovered, 1) == 10 && size(yRecovered, 2) == 3, "Size mismatch in recovered targets");
assert(abs(yRecovered(1, 1) - 0.5) < 1e-10, "Absorptance denormalization incorrect");
assert(abs(yRecovered(1, 2) - (10^2.0 - 1)) < 1e-8, "EF_vol base-10 denormalization incorrect");
assert(abs(yRecovered(1, 3) - (10^4.0 - 1)) < 1e-6, "EF_surf base-10 denormalization incorrect");

% Case B: Legacy base e
ttLegacy = struct();
ttLegacy.targetLogTransform = true; % scalar boolean
ttLegacy.targetLogBase = exp(1);
ttLegacy.Mean = [1.0, 2.0, 3.0];
ttLegacy.Std  = [1.0, 1.0, 1.0];
yLegacy = denormalizeModelTargets(zeros(5, 3), ttLegacy);
assert(abs(yLegacy(1, 1) - (exp(1.0) - 1)) < 1e-10, "Legacy expm1 denormalization failed");

fprintf("  ✓ Target-specific and legacy denormalization verified.\n");

%% 4. Tier 3 de-duplication and Tier 4 (FEM-verified optima) integration
fprintf("Testing Tier 3 de-duplication and Tier 4 FEM verification...\n");
rng(7);
Nt = 400;
Pt = 600 + 600 * rand(Nt, 1);
Rt = 0.1 * Pt + 0.3 * Pt .* rand(Nt, 1);
lamT = 0.80 + 0.3 * rand(Nt, 1);                      % um
XT = [Pt * 1e-3, Rt * 1e-3, lamT];
yT4 = [50 + 40 * rand(Nt, 1), 10.^(2 + 3 * rand(Nt, 1)), 10.^(1 + 2 * rand(Nt, 1)), 10.^(2 + 2 * rand(Nt, 1))];
yP4 = yT4 .* (1 + 0.03 * randn(Nt, 4));
names4 = ["Abs", "EF_max", "EE_V", "EE_S"];

% Three basins x two metrics; the EE_V_broad and EE_V_analyte optima of basin A share a geometry
basins = ["A"; "A"; "B"; "B"; "C"; "C"];
metrics = ["EE_V_broad"; "EE_V_analyte"; "EE_V_broad"; "EE_V_analyte"; "EE_V_broad"; "EE_V_analyte"];
optP4 = [800; 800; 1000; 1005; 1150; 1150];
optR4 = [200; 200; 300; 310; 400; 405];
laserWl = 785;
shifts = linspace(0, 4200, 61);
lam61 = 1 ./ (1 / (laserWl * 1e-7) - shifts) * 1e7;   % nm
nOpt = numel(optP4);
x = (lam61 - 900) / 80;
amp = [3; 3; 2; 2.1; 1; 1.05];                          % FEM ranking A > B > C
femSim = struct("Source", "Simulation.FEM.COMSOL.OptimaVerification", "LaserWl", laserWl, ...
    "StokesWindow", [100, 4200], "period", optP4, "radius", optR4, ...
    "lambda", repmat(lam61, nOpt, 1), "isVerified", ones(nOpt, 1), ...
    "basinTag", basins, "optimizedMetric", metrics);
femSim.Abs    = 60 + 10 * amp .* exp(-x.^2);
femSim.EF_max = 1e3 * amp .* (1 + exp(-x.^2));
femSim.EE_V   = 100 * amp .* (1 + exp(-(x - 0.5).^2));
femSim.EE_S   = 500 * amp .* (1 + exp(-(x + 0.5).^2));
dbOpt4 = struct("period", optP4, "radius", optR4, "basinTag", basins, "optimizedMetric", metrics, "Sim", femSim);

% Surrogate: +2% everywhere, but it over-rates basin C so that it would pick C for EE_V_analyte
pred4 = struct();
for fn = names4
    pred4.(fn) = femSim.(fn) * 1.02;
end
pred4.EE_V(6, :) = femSim.EE_V(6, :) * 4;

trainLam = lam61(1:2:end)' * 1e-3;                     % every second wavelength was "trained"
ds4 = struct("XTest", XT, "YTest", yT4, "YPred", yP4, "targetNames", names4, ...
    "XTrain", [repmat([0.9, 0.2], numel(trainLam), 1), trainLam], ...
    "XValidation", zeros(0, 3));
rep4 = computeSurrogateEvaluationMetrics([], ds4, dbOpt4, OptimaPredictedSoA=pred4, Verbose=false);

assert(rep4.numRoiOptima == 5, "Tier 3 must evaluate 5 unique optimum geometries (A shared).");
assert(isfield(rep4, "optimaFem") && rep4.optimaFem.available, "Tier 4 must be available.");
of = rep4.optimaFem;
assert(of.numVerified == 6 && of.numUniqueGeometries == 5, "6 optima on 5 geometries expected.");
assert(any(of.spectral.Subset == "unseen"), "Unseen wavelength subset expected.");
eeRow = of.spectralSummary(of.spectralSummary.Target == "Abs", :);
assert(eeRow.R2_All > 0.9, "Abs spectra with a 2%% bias must keep R^2 > 0.9.");
rk = of.basinRanking;
broad = rk(rk.OptimizedMetric == "EE_V_broad", :);
analyte = rk(rk.OptimizedMetric == "EE_V_analyte", :);
assert(broad.TopBasinAgree && broad.FemBestBasin == "A", "EE_V_broad: surrogate and FEM agree on basin A.");
assert(~analyte.TopBasinAgree && analyte.SurrogateBestBasin == "C", "EE_V_analyte: surrogate wrongly prefers C.");
assert(analyte.RegretPct > 50, "Choosing basin C instead of A must cost > 50%% of FEM EE_V_analyte.");
assert(contains(rep4.latexSummary, "Tier 4") && strlength(rep4.latexOptimaSummary) > 0, ...
    "LaTeX summaries must include Tier 4.");
assert(~contains(rep4.latexSummary, "tentatively"), "Tentative Tier 3 footnote must be replaced.");
fprintf("  ✓ Tier 3 de-duplication, Tier 4 spectral/scalar fidelity and basin regret verified.\n");

% Without db.Optima.Sim, Tier 4 is reported as unavailable (no error)
rep5 = computeSurrogateEvaluationMetrics([], ds4, rmfield(dbOpt4, "Sim"), Verbose=false);
assert(~rep5.optimaFem.available && contains(rep5.latexSummary, "three-tier"), ...
    "Without db.Optima.Sim the report must stay three-tier.");
fprintf("  ✓ Tier 4 skipped cleanly without db.Optima.Sim.\n");

%% 4b. Structured DB persistence (db.Model.Evaluation & db.Optima.Verification) + Shift Window Auto-Detect
fprintf("Testing storeEvaluationResultsInDb and resolveDbShiftWindow...\n");
dbEval = struct("Optima", dbOpt4);
dbEval = storeEvaluationResultsInDb(dbEval, rep4);
assert(isfield(dbEval.Model, "Evaluation") && isfield(dbEval.Model, "PerformanceReport"), ...
    "db.Model.Evaluation and PerformanceReport must both be populated.");
assert(isfield(dbEval.Optima, "Verification"), "db.Optima.Verification must be populated for Tier 4.");

tmpMat = fullfile(tempdir, "test_eval_persist_" + string(randi(1e6)) + ".mat");
cTmp = onCleanup(@() delete(tmpMat)); %#ok<NASGU>
db = dbEval;
save(tmpMat, "db", "-v7");
loadedEval = load(tmpMat, "db");
ev = loadedEval.db.Model.Evaluation;
ver = loadedEval.db.Optima.Verification;
assert(ev.tier4_optimaFem.available && ev.tier4_optimaFem.numVerified == 6, ...
    "Reloaded db.Model.Evaluation must preserve Tier 4 counts.");
assert(strlength(ev.latex.combined) > 0 && contains(ev.latex.combined, "tab:optima-fem-verification"), ...
    "Reloaded db.Model.Evaluation.latex.combined must contain both LaTeX tables.");
assert(ver.basinRanking.data.RegretPct(1) > 50 || ver.basinRanking.data.RegretPct(2) > 50, ...
    "Reloaded db.Optima.Verification.basinRanking.data must be directly indexable.");

cfgDef = importSweepConfig();
assert(isequal(cfgDef.ramanWindow, [100, 4200]) && cfgDef.detectShiftWindow, ...
    "importSweepConfig defaults must be [100, 4200] and DetectShiftWindow=true.");
[winDet, srcDet] = resolveDbShiftWindow(struct("Sim", femSim), "model", 785, [100, 4200]);
assert(isequal(winDet, [100, 4200]) && srcDet == "db.Sim.StokesWindow", ...
    "resolveDbShiftWindow must detect StokesWindow from db.Sim.");
fprintf("  ✓ Structured DB evaluation persistence & shift-window auto-detection verified.\n");

%% 5. Print Summary Table preview
disp(report.globalBiased);

fprintf("=== ALL EVALUATION METRIC TESTS PASSED! ===\n");
