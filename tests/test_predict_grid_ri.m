% test_predict_grid_ri.m - Test grid prediction when RI is loaded in db.
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(rootDir);
setup_project;

fprintf("=== Starting Predict Grid with DB RI Tests ===\n");

% 1. Create dummy network and model struct
layers = [
    featureInputLayer(5, "Name", "input")
    fullyConnectedLayer(10, "Name", "fc1")
    reluLayer("Name", "relu1")
    fullyConnectedLayer(3, "Name", "out")
];
net = dlnetwork(layerGraph(layers));

dummyModel = struct();
dummyModel.net = net;
dummyModel.targetNames = {'Absorptance', 'EF_vol', 'EF_surf'};
dummyModel.FeatureLogTransform = true;
dummyModel.TargetLogTransform = true;
dummyModel.normalize = @(x) x;
dummyModel.denormalize = @(y) y;

% 2. Create in-memory RI struct (similar to user loading RI into DB)
defaultRi = getDefaultRefractiveIndex();
inMemoryRi = struct();
inMemoryRi.lambda = defaultRi.lambda;
inMemoryRi.n = defaultRi.n;
inMemoryRi.k = defaultRi.k;
% Intentionally omit nFunc/kFunc to test auto-construction

%% Test 1: loadOrGeneratePredictions with empty Ri (fallback to default)
fprintf("Test 1: loadOrGeneratePredictions with empty Ri...\n");
pVec = [0.8, 0.85];
rVec = [0.1, 0.15];
lamVec = [0.8, 0.82];
predData1 = loadOrGeneratePredictions( ...
    "Recompute", true, ...
    "Model", dummyModel, ...
    "Ri", [], ...
    "PSamples", pVec, ...
    "RSamples", rVec, ...
    "LambdaSamples", lamVec, ...
    "SaveAfterGeneration", false);
assert(isstruct(predData1), "Predictions must be a struct.");
assert(isfield(predData1, "Absorptance"), "Predictions must contain targets.");
fprintf("  ✓ Passed Test 1: Fallback to default RI succeeded.\n");

%% Test 2: loadOrGeneratePredictions with in-memory Ri (lacking nFunc/kFunc)
fprintf("Test 2: loadOrGeneratePredictions with in-memory Ri...\n");
predData2 = loadOrGeneratePredictions( ...
    "Recompute", true, ...
    "Model", dummyModel, ...
    "Ri", inMemoryRi, ...
    "PSamples", pVec, ...
    "RSamples", rVec, ...
    "LambdaSamples", lamVec, ...
    "SaveAfterGeneration", false);
assert(isstruct(predData2), "Predictions must be a struct.");
assert(isfield(predData2, "EF_vol"), "Predictions must contain EF_vol.");
fprintf("  ✓ Passed Test 2: In-memory RI auto-constructed interpolants.\n");

%% Test 3: resolveDbBranchPaths with in-memory RI generates temp CSV
fprintf("Test 3: resolveDbBranchPaths with in-memory RI...\n");
db3 = struct();
db3.RI = inMemoryRi;
[~, riCsvFile3, ~, ~] = resolveDbBranchPaths(db3);
assert(strlength(riCsvFile3) > 0 && isfile(riCsvFile3), "Temp RI CSV file must be created.");
fprintf("  ✓ Passed Test 3: Materialized in-memory RI to CSV: %s\n", riCsvFile3);

%% Test 4: loadAndValidateModel with in-memory Ri option
fprintf("Test 4: loadAndValidateModel with Ri option...\n");
tmpModelFile = fullfile(tempdir, "test_model_for_ri.mat");
model = dummyModel; %#ok<NASGU>
save(tmpModelFile, "model", "-v7.3");
[loadedM, loadedRi] = loadAndValidateModel(ModelFile=tmpModelFile, Ri=inMemoryRi);
assert(isfield(loadedRi, "nFunc") && isa(loadedRi.nFunc, "function_handle"), "Loaded RI must have nFunc.");
fprintf("  ✓ Passed Test 4: loadAndValidateModel accepted in-memory RI.\n");

%% Test 5: Full ASSTEROID GUI integration test for Predict/Interpolate on grid
fprintf("Test 5: Full ASSTEROID Predict tab grid target execution...\n");
close all force;
assteroid_app(tempdir);
drawnow;
fig = findall(0, '-depth', 1, 'Type', 'figure', 'Name', "ASSTEROID — Optimal Inverse Design Platform");
assert(~isempty(fig), "Failed to find ASSTEROID figure window.");
fig = fig(1);
cleanupObj = onCleanup(@() delete(fig));

% Populate db.Model and db.RI in the running app
fig.UserData.db.Model = struct("Model", dummyModel);
fig.UserData.db.RI = inMemoryRi;
% ModelLoaded may already be set in visExport while ri was empty
fig.UserData.visExport.modelLoaded = true;
fig.UserData.visExport.model = dummyModel;
fig.UserData.visExport.ri = []; % specifically simulate the exact state that caused the user's error

% Find Predict HTML component
h = fig.UserData.handles;
htmlPredict = h.htmlPanels(5); % stage 4 predict tab (h4 is index 5: [h0, h1, h2, h3, h4, ...])

% Dispatch PredictInterpolate event with coarse grid params
predictCfg = struct( ...
    "dataSource", "model", ...
    "predictionTarget", "grid", ...
    "laserWavelength", 785, ...
    "periodMin", 750, ...
    "periodMax", 800, ...
    "radiusMin", 100, ...
    "radiusMax", 150, ...
    "spatialResolution", 50, ...
    "stokesShiftMin", 200, ...
    "stokesShiftMax", 600, ...
    "stokesShiftResolution", 200, ...
    "batchSize", 500, ...
    "linkMetricsToGrid", true, ...
    "selectedFields", {{"Absorptance", "EF_vol", "EF_surf"}});

% Trigger the event via the UI component's callback handle
ev = struct('HTMLEventName', "PredictInterpolate", 'HTMLEventData', predictCfg);
htmlPredict.HTMLEventReceivedFcn(htmlPredict, ev);

% Verify results
ve = fig.UserData.visExport;
assert(ve.predictionsLoaded == true, "visExport.predictionsLoaded should be true.");
assert(~isempty(ve.allData), "visExport.allData should not be empty.");
assert(~isempty(ve.ri), "visExport.ri must be populated.");
assert(isfield(ve.ri, "nFunc"), "visExport.ri must have nFunc.");
assert(isfield(fig.UserData.db, "Pred") && structRowCount(fig.UserData.db.Pred) > 0, ...
    "fig.UserData.db.Pred must contain predicted rows.");

close(fig);
fprintf("  ✓ Passed Test 5: Predict tab successfully populated db.Pred on grid target!\n");

fprintf("=== ALL PREDICT GRID RI TESTS PASSED SUCCESSFULLY! ===\n");
