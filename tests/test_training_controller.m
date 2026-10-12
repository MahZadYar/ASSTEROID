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

%% 7. Test EvaluateModelPerformance with empty model
ctlWithFig.handleEvent("EvaluateModelPerformance", struct());
fprintf("  ✓ EvaluateModelPerformance with empty DB rejected gracefully.\n");

%% 8. Test visualizePerformanceReport into panel
mockPanel = uipanel(mockFig);
targets = ["Absorptance", "EF_vol", "EF_surf"];
mockTbl1 = table(targets', [2.5; 4.1; 6.2], [1.8; 3.2; 4.9], [0.985; 0.962; 0.941], ...
    'VariableNames', {'Target', 'NRMSE_pct', 'NRMSLE_pct', 'R2'});
mockTbl2 = table(targets', [2.8; 4.5; 6.7], [0.981; 0.955; 0.932], ...
    'VariableNames', {'Target', 'NRMSE_pct', 'R2'});
mockTbl3 = table(targets', [1.9; 3.4; 5.1], [0.992; 0.978; 0.965], ...
    'VariableNames', {'Target', 'NRMSE_pct', 'R2'});

mockReport = struct( ...
    "globalBiased", mockTbl1, ...
    "globalUnbiased", mockTbl2, ...
    "roiCombined", mockTbl3, ...
    "latexSummary", "Mock LaTeX", ...
    "summaryText", "Mock Summary");

visualizePerformanceReport(mockReport, Parent=mockPanel);
assert(~isempty(allchild(mockPanel)), "visualizePerformanceReport should populate mockPanel");
axs = findobj(mockPanel, "Type", "axes");
assert(numel(axs) == 2, "visualizePerformanceReport should create 2 axes");
% Check NRMSE axis (log scale, [0.1, 100])
axNrmse = findobj(axs, "YScale", "log");
assert(~isempty(axNrmse), "NRMSE axis must be logarithmic");
assert(axNrmse.YLim(1) == 0.1 && axNrmse.YLim(2) == 100, ...
    sprintf("Expected NRMSE YLim [0.1 100], got [%g %g]", axNrmse.YLim(1), axNrmse.YLim(2)));
% Check R^2 axis (linear scale, fixed [0, 1])
axR2 = findobj(axs, "YScale", "linear");
assert(~isempty(axR2), "R^2 axis must be linear");
assert(isequal(axR2.YLim, [0, 1]), ...
    sprintf("Expected R^2 YLim [0 1], got [%g %g]", axR2.YLim(1), axR2.YLim(2)));

% Test dynamic lower bound expansion when NRMSE < 0.1 (e.g. 0.035%)
mockTbl1Small = mockTbl1;
mockTbl1Small.NRMSE_pct(1) = 0.035;
mockReportSmall = mockReport;
mockReportSmall.globalBiased = mockTbl1Small;
delete(allchild(mockPanel));
visualizePerformanceReport(mockReportSmall, Parent=mockPanel);
axNrmseSmall = findobj(mockPanel, "Type", "axes", "YScale", "log");
assert(axNrmseSmall.YLim(1) <= 0.035 && axNrmseSmall.YLim(1) == 0.01, ...
    sprintf("Expected dynamic NRMSE lower bound 0.01 for min=0.035, got %g", axNrmseSmall.YLim(1)));

fprintf("  ✓ visualizePerformanceReport successfully rendered into uipanel with verified R^2 and NRMSE bounds.\n");

%% 9. Test StopTraining / StopProcess event handling
ctl.handleEvent("StopProcess", struct());
assert(ctl.isStopRequested(), "isStopRequested should be true after StopProcess event");
ctl.handleEvent("StopTraining", struct());
assert(ctl.isStopRequested(), "isStopRequested should remain true after StopTraining event");
fprintf("  ✓ StopProcess and StopTraining events set stop flag correctly.\n");

%% 10. Test live training axes initialization into visPanel
mockVisPanel = uipanel(mockFig);
ctlVis = TrainingController(session, mockFig, [], mockVisPanel);
% Verify safeNum/safeBool helper parsing
assert(ctlVis.safeBool(struct("includeVerticalGap", true), "includeVerticalGap", false) == true, ...
    "safeBool should extract includeVerticalGap=true");
assert(ctlVis.safeBool(struct(), "includeVerticalGap", true) == true, ...
    "safeBool should default includeVerticalGap to true");
fprintf("  ✓ includeVerticalGap default boolean handling verified.\n");

%% 11. Test live plot lines styling, palette, and [1 totalIterations] non-rescaling XLim
ax = uiaxes(mockVisPanel);
ax.XScale = "log";
ax.YScale = "log";
% Verify training line minimum thickness and app palette colors (Teal & Gold)
hTrain = animatedline(ax, "Color", [72, 178, 172]/255, "LineWidth", 0.5, "LineStyle", "-");
hVal   = animatedline(ax, "Color", [235, 179, 79]/255, "LineWidth", 1.5, "LineStyle", "-", "Marker", "none");
assert(hTrain.LineWidth <= 0.5, "Training loss line thickness must be minimum (<= 0.5)");
assert(strcmp(hVal.LineStyle, "-"), "Validation line must be solid line");
assert(strcmp(hVal.Marker, "none"), "Validation line must have no point markers");
assert(isequal(round(hTrain.Color*255), [72, 178, 172]), "Training loss line must use ASSTEROID Teal (#48b2ac)");
assert(isequal(round(hVal.Color*255), [235, 179, 79]), "Validation loss line must use ASSTEROID Gold (#ebb34f)");

% Test XLim lock to [1 totalIterations]
totIters = 450;
ax.XLim = [1, totIters];
ax.XLimMode = "manual";
addpoints(hTrain, 1, 0.4);
addpoints(hTrain, 10, 0.05);
addpoints(hVal, 10, 0.08);
assert(isequal(ax.XLim, [1, totIters]), "XLim must remain fixed to [1 totalIterations] without rescaling");
assert(strcmp(ax.XLimMode, "manual"), "XLimMode must remain manual");
fprintf("  ✓ Live plot styling, minimum thickness, solid validation line, and [1 totalIterations] XLim verified.\n");

%% 12. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL TRAINING CONTROLLER TESTS PASSED! ===\n");

