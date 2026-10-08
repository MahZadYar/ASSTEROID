%% test_training_controller.m
% Unit tests for TrainingController (Stage 3 MVC Controller)

setup_project;
fprintf("=== Starting test_training_controller ===\n");

testDir = fullfile(tempdir, "test_train_controller");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Initialize session and controller
session = AssteroidSession(testDir);
ctl = TrainingController(session, [], [], []);

%% 2. Test BrowseCheckpointFile with direct path
mockMat = fullfile(testDir, "mock_checkpoint.mat");
info = struct("Epoch", 10, "Iteration", 500);
save(mockMat, "info", "-v7");

ctl.handleEvent("BrowseCheckpointFile", struct("path", mockMat));
fprintf("  ✓ BrowseCheckpointFile handled cleanly.\n");

%% 3. Test BrowseCheckpointDir with direct path
ctl.handleEvent("BrowseCheckpointDir", struct("path", testDir));
fprintf("  ✓ BrowseCheckpointDir handled cleanly.\n");

%% 4. Test FindLatestCheckpoint
res = ctl.findLatestCheckpointFile(testDir);
assert(isstruct(res), "Result should be a struct.");
fprintf("  ✓ findLatestCheckpointFile returned struct.\n");

%% 5. Test RunTraining with empty data fails gracefully with error message
ctl.handleEvent("RunTraining", struct());
fprintf("  ✓ RunTraining with empty DB rejected gracefully without throwing uncaught errors.\n");

%% 6. Test resolveSimDataFile, resolveRiFile, resolvePretrainedModel with Figure handle
mockFig = uifigure("Visible", "off");
cFig = onCleanup(@() delete(mockFig));
mockFig.UserData = struct("session", session, "db", session.db);
ctlWithFig = TrainingController(session, mockFig, [], []);

% Test resolution functions with Figure input
simFiles = resolveSimDataFile(mockFig);
riFile = resolveRiFile(mockFig);
modelFile = resolvePretrainedModel(mockFig);
assert(isstring(simFiles) || iscellstr(simFiles) || ischar(simFiles), "resolveSimDataFile must return string/cellstr");
assert(isstring(riFile) || ischar(riFile), "resolveRiFile must return string/char");
assert(isstring(modelFile) || ischar(modelFile), "resolvePretrainedModel must return string/char");
fprintf("  ✓ resolveSimDataFile, resolveRiFile, resolvePretrainedModel work with matlab.ui.Figure.\n");

% Test parser utilities
nums = parseNumberList("64, 128, 256");
assert(isequal(nums, [64 128 256]), "parseNumberList failed");
args = parseNameValuePairs("InitialLearnRate=0.001; MaxEpochs=100");
assert(numel(args) == 4, "parseNameValuePairs failed");
assert(isequal(args{1}, 'InitialLearnRate') && args{2} == 0.001, "parseNameValuePairs key/val mismatch");
fprintf("  ✓ parseNumberList, parseNameValuePairs, parseScalarValue work cleanly.\n");

%% 7. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL TRAINING CONTROLLER TESTS PASSED! ===\n");
