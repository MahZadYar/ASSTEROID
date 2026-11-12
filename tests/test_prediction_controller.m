%% test_prediction_controller.m
% Unit tests for PredictionController (Stage 4 MVC Controller)

if exist("PredictionController", "class") ~= 8
    rootDir = fileparts(fileparts(mfilename("fullpath")));
    addpath(rootDir);
    setup_project;
end
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

cStruct = struct("periodMin", 400, "periodMax", 1400, "radiusMin", 50);
assert(PredictionController.safeNum(cStruct, "radiusMax", 700) == 700, "Default radiusMax fallback should be 700");
ctl.handleEvent("PredictInterpolate", cStruct);
fprintf("  ✓ PredictInterpolate (default radiusMax=700) handled safely.\n");

%% 5. Dynamic metric discovery for Predict UI (discoverModelTargetMetrics & DbStatus)
N = 12; L = 5;
lam = linspace(785, 1000, L);
simData = struct();
simData.period = repmat([500; 700; 900; 1100], 3, 1);
simData.radius = [100; 100; 100; 100; 180; 180; 180; 180; 260; 260; 260; 260];
simData.lambda = repmat(lam, N, 1);
simData.Abs = 15 * ones(N, L) + rand(N, L);
simData.E4_max = 1e6 * (1 + rand(N, L));
simData.EE_V = 100 * (1 + rand(N, L));
simData.EE_S = 1e4 * (1 + rand(N, L));
simData.CustomProbe = 5 * (1 + rand(N, L));

session.db.Sim = simData;
session.db.Model = struct("TargetNames", ["Abs", "E4_max", "EE_V", "EE_S"]);
st = session.getStatusStruct();
assert(isequal(string(st.modelTargetNames), ["Abs", "E4_max", "EE_V", "EE_S"]), ...
    "getStatusStruct must populate modelTargetNames dynamically from db.Model");
assert(all(ismember(["Abs", "E4_max", "EE_V", "EE_S", "CustomProbe"], string(st.simSpectralMetrics))), ...
    "getStatusStruct must expose all 2D simSpectralMetrics including E4_max and CustomProbe");
assert(isequal(discoverModelTargetMetrics(session.db, struct("targetNames", ["Abs", "CustomProbe"])), ["Abs", "CustomProbe"]), ...
    "Active model targetNames must take precedence over db.Model");
fprintf("  ✓ discoverModelTargetMetrics & AssteroidSession DbStatus verified.\n");

%% 6. deriveBaseTargetsFromSelection & selectPredictionFieldsCanonical (E4_max + custom targets)
selFields = ["E4_max", "E4_max_laser", "CustomProbe_broad", "EE_V_laser"];
bases = deriveBaseTargetsFromSelection(selFields, simData);
assert(all(ismember(["E4_max", "CustomProbe", "EE_V"], bases)), ...
    "deriveBaseTargetsFromSelection must resolve E4_max, CustomProbe, and EE_V");

basesAlias = deriveBaseTargetsFromSelection(["EF_max_laser", "Absorptance_laser"], simData);
assert(all(ismember(["E4_max", "Abs"], basesAlias)), ...
    "deriveBaseTargetsFromSelection must map EF_max -> E4_max and Absorptance -> Abs when in simData");

synthPred = simData;
synthPred.E4_max_laser = simData.E4_max(:, 1);
synthPred.Abs_laser = simData.Abs(:, 1);
synthPred.EE_V_broad = mean(simData.EE_V, 2);
synthPred.CustomProbe_broad = mean(simData.CustomProbe, 2);
[filtAlias, incAlias] = selectPredictionFieldsCanonical(synthPred, ["EF_max_laser", "CustomProbe_broad", "Abs_laser"]);
assert(all(ismember(["EF_max_laser", "CustomProbe_broad", "Abs_laser"], incAlias)), ...
    "selectPredictionFieldsCanonical must resolve E4_max_laser via EF_max_laser alias and preserve custom fields");
assert(isfield(filtAlias, "EF_max_laser") && ~isfield(filtAlias, "lambda"), ...
    "Scalar-only selection must not copy spectral lambda array");
fprintf("  ✓ deriveBaseTargetsFromSelection & selectPredictionFieldsCanonical verified.\n");

%% 7. End-to-end Interpolation PredictionController workflow with dynamic selection
ctl.handleEvent("PredictInterpolate", struct( ...
    "dataSource", "interpolation", ...
    "predictionTarget", "grid", ...
    "laserWavelength", 785, ...
    "periodMin", 600, "periodMax", 1000, ...
    "radiusMin", 120, "radiusMax", 240, ...
    "spatialResolution", 200, ...
    "stokesShiftMin", 100, "stokesShiftMax", 2000, ...
    "stokesShiftResolution", 500, ...
    "selectedFields", {{"E4_max", "E4_max_laser", "CustomProbe_broad"}}));
assert(isfield(session.db, "Interp") && isfield(session.db.Interp, "E4_max") && ...
    isfield(session.db.Interp, "E4_max_laser") && isfield(session.db.Interp, "CustomProbe_broad"), ...
    "PredictionController interpolation must compute and store E4_max, E4_max_laser, and CustomProbe_broad in db.Interp");
assert(~isfield(session.db.Interp, "EE_S"), ...
    "Unselected metrics (EE_S) should be filtered out from db.Interp");
fprintf("  ✓ PredictionController dynamic interpolation workflow verified.\n");

%% 8. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL PREDICTION CONTROLLER TESTS PASSED! ===\n");
