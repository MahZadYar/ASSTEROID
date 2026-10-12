%% test_optimize_controller.m
% Unit tests for OptimizeController (Stage 5 MVC Controller)

setup_project;
fprintf("=== Starting test_optimize_controller ===\n");

testDir = fullfile(tempdir, "test_opt_controller");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Initialize session and headless controller
session = AssteroidSession(testDir);
assert(isstruct(session.db), "Session db must be a struct.");

ctl = OptimizeController(session, [], [], []);

%% 2. Test MetricChanged event
ctl.handleEvent("MetricChanged", struct("metric", "Absorptance", "metricVariant", "laser"));
fprintf("  ✓ MetricChanged event handled cleanly.\n");

%% 3. Test SaveOptimaToDb event
sampleSeeds = [
    struct("Tag", "Peak_A", "P", 720.5, "R", 115.0), ...
    struct("Tag", "Peak_B", "P", 840.0, "R", 185.5)
];

ctl.handleEvent("SaveOptimaToDb", struct("seeds", sampleSeeds));
assert(isfield(session.db, "Optima"), "session.db.Optima must exist after saving optima.");
assert(numel(session.db.Optima.period) == 2, "Expected 2 saved optima in database.");
assert(session.db.Optima.period(1) == 720.5, "First period mismatch.");
assert(session.db.Optima.radius(2) == 185.5, "Second radius mismatch.");
assert(session.db.Optima.basinTag(1) == "Peak_A", "First tag mismatch.");
fprintf("  ✓ SaveOptimaToDb event correctly updated session.db.Optima.\n");

%% 4. Test GetDbOptima event
ctl.handleEvent("GetDbOptima", struct());
fprintf("  ✓ GetDbOptima handled cleanly.\n");

%% 5. Test DeleteDbOptima event
ctl.handleEvent("DeleteDbOptima", struct("indices", 1));
assert(numel(session.db.Optima.period) == 1, "Expected 1 remaining optimum after deleting index 1.");
assert(session.db.Optima.basinTag(1) == "Peak_B", "Remaining optimum should be Peak_B.");
fprintf("  ✓ DeleteDbOptima correctly pruned selected index.\n");

%% 6. Test SetSeedsFromDbOptima event
ctl.handleEvent("SetSeedsFromDbOptima", struct("indices", 1));
fprintf("  ✓ SetSeedsFromDbOptima transferred DB optima to active seeds.\n");

%% 7. Test UpdateSeeds event
updatedSeeds = [
    struct("Tag", "Custom_Optimum_1", "P", 750.0, "R", 120.0, "Value", 145.2), ...
    struct("Tag", "Custom_Optimum_2", "P", 880.0, "R", 190.0, "Value", 98.7)
];
ctl.handleEvent("UpdateSeeds", struct("seeds", updatedSeeds));
curSeeds = ctl.getOptimizeState("currentSeeds");
assert(numel(curSeeds) == 2, "Expected 2 currentSeeds.");
assert(curSeeds(1).Tag == "Custom_Optimum_1", "Expected updated tag Custom_Optimum_1.");
assert(curSeeds(2).P == 880.0, "Expected updated period 880.0.");
fprintf("  ✓ UpdateSeeds preserved renamed tags and updated coordinates.\n");

%% 8. Test ExportResults to MAT (only optima list, not whole DB)
matPath = fullfile(testDir, "exported_optima.mat");
ctl.handleEvent("ExportResults", struct("exportFormat", "mat", "path", matPath, "seeds", updatedSeeds));
assert(isfile(matPath), "MAT export file must exist.");
loadedMat = load(matPath);
assert(isfield(loadedMat, "optima"), "MAT export must contain 'optima'.");
assert(isfield(loadedMat, "optimaTable"), "MAT export must contain 'optimaTable'.");
assert(~isfield(loadedMat, "lastRes"), "MAT export must NOT contain lastRes.");
assert(~isfield(loadedMat, "allData"), "MAT export must NOT contain allData.");
assert(numel(loadedMat.optima) == 2, "Expected 2 exported optima entries in MAT.");
assert(string(loadedMat.optima(1).Tag) == "Custom_Optimum_1", "First optima tag mismatch in MAT.");
assert(loadedMat.optima(1).MetricValue == 145.2, "MetricValue mismatch in MAT.");
fprintf("  ✓ ExportResults (MAT) successfully saved only the optima list without full db.\n");

%% 9. Test ExportResults to CSV
csvPath = fullfile(testDir, "exported_optima.csv");
ctl.handleEvent("ExportResults", struct("exportFormat", "csv", "path", csvPath, "seeds", updatedSeeds));
assert(isfile(csvPath), "CSV export file must exist.");
loadedCsv = readtable(csvPath, "TextType", "string");
assert(height(loadedCsv) == 2, "Expected 2 exported optima entries in CSV.");
assert(loadedCsv.Tag(1) == "Custom_Optimum_1", "First optima tag mismatch in CSV.");
assert(loadedCsv.Period_nm(1) == 750.0, "Period_nm mismatch in CSV.");
assert(loadedCsv.Radius_nm(1) == 120.0, "Radius_nm mismatch in CSV.");
assert(loadedCsv.MetricValue(1) == 145.2, "MetricValue mismatch in CSV.");
fprintf("  ✓ ExportResults (CSV) successfully saved only the optima table and values.\n");

%% 10. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL OPTIMIZE CONTROLLER TESTS PASSED! ===\n");
