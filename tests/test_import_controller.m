%% test_import_controller.m
% Unit tests for ImportController (Stage 1 MVC Controller)

setup_project;
fprintf("=== Starting test_import_controller ===\n");

testDir = fullfile(tempdir, "test_import_controller");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Initialize session and controller
session = AssteroidSession(testDir);
ctl = ImportController(session, [], [], []);
assert(isvalid(ctl), "ImportController should be created.");
fprintf("  ✓ ImportController instantiated successfully.\n");

%% 2. Safe event handling for stop and refresh
ctl.handleEvent("StopProcess", struct());
ctl.handleEvent("RefreshDbState", struct());
ctl.handleEvent("UnknownEventXYZ", struct());
fprintf("  ✓ Stop and auxiliary events handled cleanly.\n");

%% 3. Test PreviewFile with existing tests/SweepPropeTable.dat
codebaseRoot = fileparts(fileparts(mfilename("fullpath")));
sampleDat = fullfile(codebaseRoot, "tests", "SweepPropeTable.dat");
if isfile(sampleDat)
    ctl.handleEvent("PreviewFile", struct("inputFile", sampleDat));
    fprintf("  ✓ PreviewFile handled cleanly with valid sweep table.\n");
else
    fprintf("  - Skipped PreviewFile (SweepPropeTable.dat not found).\n");
end

%% 4. Test RecalculateDerived with empty db fails gracefully
ctl.handleEvent("RecalculateDerived", struct());
fprintf("  ✓ RecalculateDerived on empty DB handled safely.\n");

%% 5. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL IMPORT CONTROLLER TESTS PASSED! ===\n");
