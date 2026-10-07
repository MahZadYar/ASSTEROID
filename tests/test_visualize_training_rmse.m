% test_visualize_training_rmse.m - Test logarithmic RMSE scaling in visualizeTrainingResults
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(rootDir);
setup_project;

fprintf("=== Starting Test for Logarithmic RMSE Scaling ===\n");

% 1. Construct synthetic results with multi-scale targets
results = struct();
results.summary = struct("maxEpochs", 100, "learningRate", 0.001);
results.model = struct();
results.model.targetNames = {'Absorptance', 'EF_vol', 'EF_surf'};

% Absorptance is ~0.01, EF_vol is ~45000, EF_surf is ~1.5e6
valRmse = [0.012; 45000; 1500000];
testRmse = [0.015; 48000; 1600000];
valLoss = [0.0004; 0.002; 0.003];
testLoss = [0.0005; 0.0025; 0.0035];

results.model.performance = struct();
results.model.performance.validation = struct("rmse", valRmse, "loss", valLoss, "count", 100);
results.model.performance.test = struct("rmse", testRmse, "loss", testLoss, "count", 100);

%% Test 1: Render in standalone figure
f = figure("Visible", "off");
cleanupF = onCleanup(@() delete(f));
visualizeTrainingResults(results, Parent=f);

% Check tiledlayout and axes
allAxes = findall(f, "Type", "axes");
assert(numel(allAxes) >= 2, "Must contain at least 2 axes (Loss and RMSE).");

% Identify RMSE axes by title or ylabel
axRmse = [];
axLoss = [];
for k = 1:numel(allAxes)
    if contains(string(allAxes(k).YLabel.String), "RMSE")
        axRmse = allAxes(k);
    elseif contains(string(allAxes(k).YLabel.String), "MSE")
        axLoss = allAxes(k);
    end
end

assert(~isempty(axRmse), "RMSE axes must be present.");
assert(~isempty(axLoss), "Loss axes must be present.");

% Verify log scale on RMSE axes
assert(string(axRmse.YScale) == "log", "axRmse.YScale must be 'log'.");
fprintf("axRmse YLim: [%.2e, %.2e]\n", axRmse.YLim(1), axRmse.YLim(2));
assert(axRmse.YLim(1) <= 0.01, "YLim lower bound must accommodate Absorptance RMSE (~0.01).");
assert(axRmse.YLim(2) >= 1e6, "YLim upper bound must accommodate EF_surf RMSE (~1.5e6).");

% Verify bar BaseValue is less than minimum data point (0.012)
allBars = findobj(axRmse, "Type", "bar");
assert(~isempty(allBars), "Bar objects must exist.");
for b = 1:numel(allBars)
    assert(allBars(b).BaseValue < 0.012, "BaseValue must be below minimum RMSE so bars are visible.");
end

fprintf("  ✓ Passed Test 1: Standalone figure renders logarithmic RMSE spanning %.2e to %.2e.\n", ...
    axRmse.YLim(1), axRmse.YLim(2));

%% Test 2: Render in dark uipanel (ASSTEROID UI theme)
uf = uifigure("Visible", "off");
cleanupUF = onCleanup(@() delete(uf));
p = uipanel(uf, "BackgroundColor", [0.06 0.08 0.10]);
visualizeTrainingResults(results, Parent=p);

allDarkAxes = findall(p, "Type", "axes");
assert(numel(allDarkAxes) >= 2, "Dark panel must contain 2 axes.");

for k = 1:numel(allDarkAxes)
    ax = allDarkAxes(k);
    if contains(string(ax.YLabel.String), "RMSE")
        assert(string(ax.YScale) == "log", "Dark panel RMSE axes must have YScale = 'log'.");
        assert(all(ax.Color == [0.06 0.10 0.16]), "Dark theme axes color must match app theme.");
    end
end

fprintf("  ✓ Passed Test 2: Dark theme panel successfully styled with log-scale RMSE.\n");

fprintf("=== ALL VISUALIZE TRAINING RMSE TESTS PASSED SUCCESSFULLY! ===\n");
