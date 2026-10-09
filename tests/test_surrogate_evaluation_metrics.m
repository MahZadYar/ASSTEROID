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

%% 4. Print Summary Table preview
disp(report.globalBiased);

fprintf("=== ALL EVALUATION METRIC TESTS PASSED! ===\n");
