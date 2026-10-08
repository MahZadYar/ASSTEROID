% test_database_engine.m — Unit tests for high-capacity DatabaseEngine
setup_project;
fprintf("=== Starting test_database_engine ===\n");

testDir = fullfile(tempdir, "test_db_engine");
if ~isfolder(testDir), mkdir(testDir); end
testFile = fullfile(testDir, "test_database.mat");

%% 1. Create test database structure
db = createDatabaseStruct(ProjectName="TestProject", Authors="NanoTRAACES");
N = 100;
L = 50;
db.Sim.period = linspace(700, 900, N)';
db.Sim.radius = linspace(50, 200, N)';
db.Sim.lambda = repmat(linspace(700, 1100, L), N, 1);
db.Sim.EF_vol = rand(N, L);
db.Sim.Absorptance = rand(N, L);

%% 2. Test DatabaseEngine.saveDatabase
logs = strings(0, 1);
testReporter = @(msg, type) assignin('caller', 'logs', [logs; string(msg)]);

infoSave = DatabaseEngine.saveDatabase(db, testFile, testReporter);
assert(isfile(testFile), "Database file should exist after saving.");
assert(infoSave.fileBytes > 0, "Saved file bytes should be > 0.");
assert(infoSave.elapsed >= 0, "Elapsed save time should be recorded.");
fprintf("[1] DatabaseEngine.saveDatabase PASSED (Saved %s in %.3f s, %.1f MB/s)\n", ...
    infoSave.sizeString, infoSave.elapsed, infoSave.rateMBs);

%% 3. Test DatabaseEngine.inspectFile
infoInspect = DatabaseEngine.inspectFile(testFile);
assert(infoInspect.fileBytes == infoSave.fileBytes, "Inspect file size should match.");
assert(any(strcmp({infoInspect.variables.name}, "db")), "Variables should include 'db'.");
fprintf("[2] DatabaseEngine.inspectFile PASSED (Inspected %d variables without full load)\n", ...
    numel(infoInspect.variables));

%% 4. Test DatabaseEngine.loadDatabase
[loadedDb, infoLoad] = DatabaseEngine.loadDatabase(testFile, testReporter);
assert(isstruct(loadedDb), "Loaded DB should be a struct.");
assert(isfield(loadedDb, "Global"), "Loaded DB should have Global.");
assert(isfield(loadedDb, "Sim"), "Loaded DB should have Sim.");
assert(isequal(size(loadedDb.Sim.period), [N 1]), "Sim.period dimensions should match.");
assert(isequal(size(loadedDb.Sim.EF_vol), [N L]), "Sim.EF_vol dimensions should match.");
fprintf("[3] DatabaseEngine.loadDatabase PASSED (Loaded %s in %.3f s, %.1f MB/s)\n", ...
    infoLoad.sizeString, infoLoad.elapsed, infoLoad.rateMBs);

%% 5. Test formatBytes
assert(strcmp(DatabaseEngine.formatBytes(500), "500 B"), "formatBytes B failed");
assert(contains(DatabaseEngine.formatBytes(1500), "KB"), "formatBytes KB failed");
assert(contains(DatabaseEngine.formatBytes(5*1024^2), "MB"), "formatBytes MB failed");
assert(contains(DatabaseEngine.formatBytes(4*1024^3), "GB"), "formatBytes GB failed");
fprintf("[4] DatabaseEngine.formatBytes PASSED\n");

%% 6. Test DatabaseEngine.saveDatabaseAsync
asyncFile = fullfile(testDir, "test_async_database.mat");
[future, infoAsync] = DatabaseEngine.saveDatabaseAsync(db, asyncFile);
if ~isempty(future)
    wait(future);
    assert(isfile(asyncFile), "Async saved file should exist on disk.");
    fInfo = dir(asyncFile);
    assert(fInfo.bytes > 0, "Async saved file should have non-zero bytes.");
end
fprintf("[5] DatabaseEngine.saveDatabaseAsync PASSED\n");

fprintf("=== test_database_engine COMPLETED SUCCESSFULLY! ===\n");
