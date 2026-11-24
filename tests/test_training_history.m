function test_training_history()
% test_training_history  Verify per-iteration training history persistence and plotting.
%
%   Verify that per-iteration training history (loss, validation loss, RMSE,
%   learning rate, elapsed time) is captured by train_surrogate_dnn, stored in
%   db.Model.TrainingHistory by runTrainingWorkflow, and plottable via
%   plotTrainingHistory.

if exist("train_surrogate_dnn", "file") ~= 2
    rootDir = fileparts(fileparts(mfilename("fullpath")));
    addpath(rootDir);
    setup_project;
end
fprintf("=== Starting test_training_history ===\n");

ri = getDefaultRefractiveIndex("WavelengthUnit", "um");
rng(42, "twister");

%% 1. Build small synthetic SoA simulation dataset
nGeom = 30;
nWl   = 5;
sim = struct();
sim.period = linspace(500, 900, nGeom)';
sim.radius = linspace(80, 200, nGeom)';
sim.lambda = repmat(linspace(785, 1050, nWl), nGeom, 1);
sim.Abs    = 10 + 20 * rand(nGeom, nWl);
sim.EE_V   = 10 .^ (1 + 2 * rand(nGeom, nWl));
sim.EE_S   = 10 .^ (2 + 2 * rand(nGeom, nWl));

ds = prepare_training_dataset(sim, ri, ...
    TargetFields=["Abs", "EE_V", "EE_S"], ...
    Holdout=0.2, ValSplit=0.5, FeatureSchema="v3_physics", SplitMode="geometry");

%% 2. Train for 4 epochs and verify model.trainingHistory
model = train_surrogate_dnn(ds, ...
    "MaxEpochs", 4, ...
    "MiniBatchSize", 16, ...
    "LearningRate", 1e-3, ...
    "ValidationFrequency", 4, ...
    "Plots", "none", ...
    "Verbose", false, ...
    "ExecutionEnvironment", "cpu", ...
    "NetworkConfig", struct("architecture", "gs_tensor", "stemHidden", 16, "stemOut", 32, "trunkWidth", 32, "numBlocks", 1, "headWidth", 16));

assert(isfield(model, "trainingHistory") && isstruct(model.trainingHistory), ...
    "model.trainingHistory struct must exist.");
h = model.trainingHistory;
nExpectedIters = 4 * floor(size(ds.XTrain, 1) / 16);
assert(numel(h.iteration) == nExpectedIters, ...
    sprintf("Expected %d iterations, got %d", nExpectedIters, numel(h.iteration)));
assert(numel(h.epoch) == nExpectedIters && numel(h.trainingLoss) == nExpectedIters && ...
       numel(h.learningRate) == nExpectedIters && numel(h.elapsedSec) == nExpectedIters, ...
    "Per-iteration vectors must share length.");
assert(all(isfinite(h.trainingLoss) & h.trainingLoss > 0), "trainingLoss must be finite and positive.");
assert(all(isfinite(h.learningRate) & h.learningRate > 0), "learningRate must be finite and positive.");
assert(all(isfinite(h.elapsedSec) & h.elapsedSec >= 0), "elapsedSec must be finite and non-negative.");
assert(~isempty(h.validationIteration) && numel(h.validationIteration) == numel(h.validationLoss), ...
    "validationIteration and validationLoss must be populated and aligned.");
assert(all(isfinite(h.validationLoss) & h.validationLoss > 0), "validationLoss must be finite and positive.");
fprintf("  [1] model.trainingHistory verified (%d train iters, %d val points).\n", ...
    numel(h.iteration), numel(h.validationIteration));

%% 3. Verify runTrainingWorkflow packs db.Model.TrainingHistory into database.mat
origPwd = pwd;
cPwd = onCleanup(@() cd(origPwd));
tmpDir = fullfile(tempdir, "test_train_history_wf");
if isfolder(tmpDir), rmdir(tmpDir, "s"); end
mkdir(tmpDir);
cTmp = onCleanup(@() rmdir(tmpDir, "s"));

allData = sim; %#ok<NASGU>
simFile = fullfile(tmpDir, "sim.mat");
dbFile  = fullfile(tmpDir, "database.mat");
save(simFile, "allData", "-v7");

cfg = trainingConfig( ...
    WorkDir=tmpDir, ...
    RawDataFiles=simFile, ...
    DatabaseFile=dbFile, ...
    SaveArtifacts=false, ...
    MaxEpochs=3, ...
    MiniBatchSize=16, ...
    LearningRate=1e-3, ...
    ValidationFrequency=4, ...
    Plots="none", ...
    Verbose=false, ...
    ExecutionEnvironment="cpu", ...
    NetworkConfig=struct("architecture", "gs_tensor", "stemHidden", 16, "stemOut", 32, "trunkWidth", 32, "numBlocks", 1, "headWidth", 16));

res = runTrainingWorkflow(cfg);
assert(isfield(res.dbModel, "TrainingHistory") && isstruct(res.dbModel.TrainingHistory), ...
    "dbModel.TrainingHistory must be populated.");

S = load(dbFile, "db");
assert(isfield(S.db, "Model") && isfield(S.db.Model, "TrainingHistory"), ...
    "db.Model.TrainingHistory must be persisted in database.mat.");
assert(isfield(S.db.Model.Model, "trainingHistory"), ...
    "db.Model.Model.trainingHistory must also be persisted.");
fprintf("  [2] db.Model.TrainingHistory persisted in database.mat (%d iters).\n", ...
    numel(S.db.Model.TrainingHistory.iteration));

%% 4. Verify plotTrainingHistory renders cleanly from saved database.mat
fig = plotTrainingHistory(dbFile, Visible="off");
cFig = onCleanup(@() delete(fig));
axs = findobj(fig, "Type", "axes");
assert(numel(axs) == 2, "plotTrainingHistory should produce 2 axes.");
fprintf("  [3] plotTrainingHistory rendered cleanly from database.mat.\n");
cd(origPwd);
fprintf("=== All test_training_history assertions PASSED ===\n");
end
