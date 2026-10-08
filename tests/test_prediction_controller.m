%% test_prediction_controller.m
% Unit tests for PredictionController (Stage 4 MVC Controller)

setup_project;
fprintf("=== Starting test_prediction_controller ===\n");

testDir = fullfile(tempdir, "test_pred_controller");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Initialize session and controller
session = AssteroidSession(testDir);
ctl = PredictionController(session, [], []);
assert(isvalid(ctl), "PredictionController should be created.");
fprintf("  ✓ PredictionController instantiated successfully.\n");

%% 2. Safe event handling for stop and refresh
ctl.handleEvent("StopProcess", struct());
ctl.handleEvent("StopPrediction", struct());
fprintf("  ✓ Stop events handled cleanly.\n");

ctl.handleEvent("RefreshDbState", struct());
ctl.handleEvent("UnknownEventXYZ", struct());
fprintf("  ✓ Auxiliary events handled without exception.\n");

%% 3. OpenInVisualize without figure should not throw
ctl.handleEvent("OpenInVisualize", struct("branch", "Pred"));
fprintf("  ✓ OpenInVisualize handled cleanly.\n");

%% 4. PredictInterpolate with missing model/data fails gracefully
% Calling PredictInterpolate when no model/data is loaded should notify error
% via HTML bridge callback without throwing an uncaught exception
ctl.handleEvent("PredictInterpolate", struct( ...
    "dataSource", "model", ...
    "predictionTarget", "grid", ...
    "periodMin", 400, "periodMax", 1400, ...
    "radiusMin", 50, "radiusMax", 450));
fprintf("  ✓ PredictInterpolate (model) handled safely with missing model.\n");

ctl.handleEvent("PredictInterpolate", struct( ...
    "dataSource", "data", ...
    "predictionTarget", "grid", ...
    "periodMin", 400, "periodMax", 1400, ...
    "radiusMin", 50, "radiusMax", 450));
fprintf("  ✓ PredictInterpolate (data) handled safely with empty db.Sim.\n");

%% 5. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL PREDICTION CONTROLLER TESTS PASSED! ===\n");
