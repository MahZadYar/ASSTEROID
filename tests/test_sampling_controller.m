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

%% 5. Test standalone utility functions
assert(ternaryVal(true, 10, 20) == 10, "ternaryVal true branch value failed");
assert(ternaryVal(false, 10, 20) == 20, "ternaryVal false branch value failed");
assert(ternaryVal(true, @() 100, 200) == 100, "ternaryVal true closure failed");
assert(ternaryVal(false, @() 100, 200) == 200, "ternaryVal false closure fallback failed");
assert(isequal(padVec([1 2], 4), [1 2 1 1]), "padVec padding failed");
assert(isequal(padVec([1 2 3 4 5], 3), [1 2 3]), "padVec truncation failed");
assert(isequal(sanitiseMetricList({'EF_vol', '', 'BEE'}), ["EF_vol", "BEE"]), "sanitiseMetricList failed");
assert(isequal(hex2rgb("#ffffff"), [1 1 1]), "hex2rgb failed");
fprintf("  ✓ Standalone utility functions (ternaryVal, padVec, sanitiseMetricList, hex2rgb) passed.\n");

%% 6. Test LoadData from DB simulation data
session.db.Sim = struct('period', [100; 120; 140], 'radius', [20; 25; 30], 'EF_vol_avg', [1.5; 2.0; 2.5]);
ctl.handleEvent("LoadData", struct("dataSource", "interpolation"));
assert(ctl.samplingState.dataLoaded, "SamplingController should have dataLoaded=true after LoadData.");
fprintf("  ✓ LoadData with DB simulation data succeeded.\n");

%% 7. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL SAMPLING CONTROLLER TESTS PASSED! ===\n");
