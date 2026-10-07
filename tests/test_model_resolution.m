% test_model_resolution.m - Test model resolution, temp serialization, and loadAndValidateModel
thisDir = fileparts(mfilename('fullpath'));
rootDir = fileparts(thisDir);
addpath(rootDir);
setup_project;

fprintf("=== Starting Model Resolution and Validation Tests ===\n");

% 1. Create a dummy dlnetwork
layers = [
    featureInputLayer(5, "Name", "input")
    fullyConnectedLayer(10, "Name", "fc1")
    reluLayer("Name", "relu1")
    fullyConnectedLayer(3, "Name", "out")
];
net = dlnetwork(layerGraph(layers));

% 2. Create dummy model struct
dummyModel = struct();
dummyModel.net = net;
dummyModel.targetNames = {'Absorptance', 'EF_vol', 'EF_surf'};
dummyModel.FeatureLogTransform = true;
dummyModel.TargetLogTransform = true;
dummyModel.normalize = @(x) x;
dummyModel.denormalize = @(y) y;

%% Test 1: resolveDbBranchPaths with db.Model.Model
fprintf("Test 1: resolveDbBranchPaths with db.Model.Model...\n");
db1 = struct();
db1.Model.Model = dummyModel;
[modelFile1, ~, ~, ~] = resolveDbBranchPaths(db1, pwd);
assert(isfile(modelFile1), "Model file should exist.");
[loadedModel1, ~] = loadAndValidateModel(ModelFile=modelFile1);
assert(isfield(loadedModel1, "net"), "Loaded model must have net.");
assert(isfield(loadedModel1, "normalize"), "Loaded model must have normalize.");
assert(isfield(loadedModel1, "denormalize"), "Loaded model must have denormalize.");
assert(iscell(loadedModel1.targetNames), "Loaded model must have cell targetNames.");
fprintf("  ✓ Passed Test 1\n");

%% Test 2: resolveDbBranchPaths with db.Model.Net and db.Model.TargetNames
fprintf("Test 2: resolveDbBranchPaths with db.Model.Net and db.Model.TargetNames...\n");
db2 = struct();
db2.Model.Net = net;
db2.Model.TargetNames = ["Absorptance", "EF_vol", "EF_surf"];
[modelFile2, ~, ~, ~] = resolveDbBranchPaths(db2, pwd);
assert(isfile(modelFile2), "Model file should exist.");
[loadedModel2, ~] = loadAndValidateModel(ModelFile=modelFile2);
assert(isfield(loadedModel2, "net"), "Loaded model must have net.");
assert(isfield(loadedModel2, "normalize"), "Loaded model must have synthesized normalize.");
assert(isfield(loadedModel2, "denormalize"), "Loaded model must have synthesized denormalize.");
fprintf("  ✓ Passed Test 2\n");

%% Test 3: loadAndValidateModel with legacy 'trainedModel' MAT file
fprintf("Test 3: loadAndValidateModel with legacy 'trainedModel' MAT file...\n");
tmpLegacy = fullfile(tempdir, "test_legacy_trained_model.mat");
trainedModel = dummyModel; %#ok<NASGU>
save(tmpLegacy, "trainedModel", "-v7.3");
[loadedModel3, ~] = loadAndValidateModel(ModelFile=tmpLegacy);
assert(isfield(loadedModel3, "net"), "Loaded model must have net.");
fprintf("  ✓ Passed Test 3\n");

%% Test 4: loadAndValidateModel directly on database MAT file
fprintf("Test 4: loadAndValidateModel on db.mat file...\n");
tmpDb = fullfile(tempdir, "test_db_file.mat");
dbTest = struct();
dbTest.Model.Model = dummyModel;
db = dbTest; %#ok<NASGU>
save(tmpDb, "db", "-v7.3");
[loadedModel4, ~] = loadAndValidateModel(ModelFile=tmpDb);
assert(isfield(loadedModel4, "net"), "Loaded model must have net.");
assert(isequal(loadedModel4.targetNames, dummyModel.targetNames), "Target names must match.");
fprintf("  ✓ Passed Test 4\n");

%% Test 5: createModelPredictor from loaded model
fprintf("Test 5: createModelPredictor with loaded model...\n");
ri = getDefaultRefractiveIndex();
predictor = createModelPredictor(loadedModel2, ri);
assert(isa(predictor.predictSpectral, "function_handle"), "predictSpectral must be a function handle.");
fprintf("  ✓ Passed Test 5\n");

fprintf("\n=== All Tests Passed Successfully! ===\n");
