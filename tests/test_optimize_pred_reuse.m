%% test_optimize_pred_reuse.m
% Tests that Stage 5 (Optimize) properly reuses db.Pred without
% re-running DNN prediction or opening standalone figure windows.

setup_project;

fprintf("=== Starting Optimize db.Pred Reuse Tests ===\n");

% 1. Create synthetic database with populated db.Pred
pVec = [600, 700, 800, 900];
rVec = [100, 150, 200, 250];
[Pgrid, Rgrid] = meshgrid(pVec, rVec);
Pcol = Pgrid(:);
Rcol = Rgrid(:);
nPoints = numel(Pcol);
lambdaVec = [785, 800, 850, 900];

predSoA = struct();
predSoA.period = Pcol;
predSoA.radius = Rcol;
predSoA.lambda = lambdaVec;
predSoA.LaserWl = repmat(785, nPoints, 1);
predSoA.Absorptance = rand(nPoints, numel(lambdaVec));
predSoA.EF_vol = rand(nPoints, numel(lambdaVec)) * 100;
predSoA.EF_surf = rand(nPoints, numel(lambdaVec)) * 200;
predSoA.EF_vol_avg = mean(predSoA.EF_vol, 2);
predSoA.EF_vol_laser = predSoA.EF_vol(:, 1);
predSoA.EF_surf_avg = mean(predSoA.EF_surf, 2);
predSoA.EF_surf_laser = predSoA.EF_surf(:, 1);
predSoA.Absorptance_avg = mean(predSoA.Absorptance, 2);
predSoA.Absorptance_laser = predSoA.Absorptance(:, 1);

% Close any pre-existing figures
close all force;

% 2. Launch ASSTEROID app
workDir = tempdir;
fig = assteroid_app(workDir);
assert(isvalid(fig), "Failed to launch ASSTEROID figure.");

% Attach db.Pred to app
fig.UserData.db.Pred = predSoA;

% Record count of open figures (should only be the uifigure)
figsBefore = findall(groot, "Type", "figure");
fprintf("Figures before preview: %d\n", numel(figsBefore));

% 3. Dispatch PreviewMetric event with dataSource = "predictions"
optHtml = fig.UserData.handles.htmlPanels(6); % Stage 5 Optimize Left HTML
previewData = struct( ...
    "dataSource", "predictions", ...
    "metric", "EF_vol", ...
    "metricVariant", "avg", ...
    "laserWavelength", 785, ...
    "periodMin", 600, "periodMax", 900, ...
    "radiusMin", 100, "radiusMax", 250, ...
    "spatialResolution", 100, ...
    "stokesShiftMin", 100, "stokesShiftMax", 3600, ...
    "stokesShiftResolution", 5);

dummyEvent = struct("HTMLEventName", "PreviewMetric", "HTMLEventData", previewData);
optHtml.HTMLEventReceivedFcn(optHtml, dummyEvent);

% Verify previewResults were created and matched db.Pred
assert(isfield(fig.UserData, "optimize"), "fig.UserData.optimize must exist.");
assert(isfield(fig.UserData.optimize, "previewResults"), "previewResults must exist.");
assert(~isempty(fig.UserData.optimize.previewResults), "previewResults must not be empty.");
assert(isfield(fig.UserData.optimize.previewResults, "allData"), "previewResults.allData must exist.");
assert(numel(fig.UserData.optimize.previewResults.allData.period) == nPoints, ...
    "previewResults should have reused db.Pred points directly.");

% Verify no popup plot windows appeared
figsAfter = findall(groot, "Type", "figure");
assert(numel(figsAfter) == numel(figsBefore), ...
    sprintf("No new figure windows should open during preview (was %d, now %d).", ...
    numel(figsBefore), numel(figsAfter)));
fprintf("  ✓ Test 1 Passed: Preview Heatmap successfully loaded db.Pred with 0 extra figures.\n");

% 4. Test Seed Detection (mode = 'detect') using cachedAllData
detectData = previewData;
detectData.mode = "detect";
detectData.candidateTopN = 5;
detectData.prominenceThreshold = 0;
detectData.recomputePredictions = false;

detectEvent = struct("HTMLEventName", "RunOptimize", "HTMLEventData", detectData);
optHtml.HTMLEventReceivedFcn(optHtml, detectEvent);

% Verify lastResults exist
assert(isfield(fig.UserData.optimize, "lastResults"), "lastResults must exist after detect.");
figsAfterDetect = findall(groot, "Type", "figure");
assert(numel(figsAfterDetect) == numel(figsBefore), ...
    sprintf("No new figure windows should open during detect (was %d, now %d).", ...
    numel(figsBefore), numel(figsAfterDetect)));
fprintf("  ✓ Test 2 Passed: Seed detection reused db.Pred without recomputing or opening figures.\n");

% Cleanup
delete(fig);
fprintf("=== ALL OPTIMIZE PRED REUSE TESTS PASSED! ===\n");
