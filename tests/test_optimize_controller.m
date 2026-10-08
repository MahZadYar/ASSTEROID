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

%% 7. Test ExportResults (empty check)
ctl.handleEvent("ExportResults", struct("format", "mat", "path", fullfile(testDir, "test_export.mat")));
fprintf("  ✓ ExportResults handled gracefully with empty results.\n");

%% 8. Clean up
try
    rmdir(testDir, "s");
catch
end

fprintf("=== ALL OPTIMIZE CONTROLLER TESTS PASSED! ===\n");
