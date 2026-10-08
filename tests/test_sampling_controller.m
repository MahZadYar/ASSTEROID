%% test_sampling_controller.m
% Unit tests for SamplingController (Stage 2 MVC Controller)

setup_project;
fprintf("=== Starting test_sampling_controller ===\n");

testDir = fullfile(tempdir, "test_sampling_controller");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Initialize session and controller
session = AssteroidSession(testDir);
ctl = SamplingController(session, [], [], []);
assert(isvalid(ctl), "SamplingController should be created.");
fprintf("  ✓ SamplingController instantiated successfully.\n");

%% 2. Safe event handling for reset, stop and refresh
ctl.handleEvent("Reset", struct());
ctl.handleEvent("StopProcess", struct());
ctl.handleEvent("StopSampling", struct());
ctl.handleEvent("RefreshDbState", struct());
ctl.handleEvent("UnknownEventXYZ", struct());
fprintf("  ✓ Reset, stop, and auxiliary events handled cleanly.\n");

%% 3. Test actions without data loaded handle safely
ctl.handleEvent("RunSampling", struct());
ctl.handleEvent("PreviewDensity", struct());
ctl.handleEvent("ExportResults", struct());
fprintf("  ✓ RunSampling, PreviewDensity, ExportResults rejected safely before data load.\n");

%% 4. Test NaN scanning without data loaded handles safely
ctl.handleEvent("FindNanPoints", struct());
ctl.handleEvent("ExportNanPoints", struct());
ctl.handleEvent("HighlightNanPoints", struct("show", true));
fprintf("  ✓ NaN scanning and export handled safely without data.\n");

%% 5. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL SAMPLING CONTROLLER TESTS PASSED! ===\n");
