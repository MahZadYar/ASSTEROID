% test_database_controller.m — Unit tests for DatabaseController & AssteroidSession
setup_project;
fprintf("=== Starting test_database_controller ===\n");

testDir = fullfile(tempdir, "test_db_controller");
if ~isfolder(testDir), mkdir(testDir); end
testDbPath = fullfile(testDir, "session_test.mat");

%% 1. Initialize session
session = AssteroidSession(testDir);
assert(session.workDir == string(testDir), "Session workDir mismatch.");
assert(isstruct(session.db), "Session db should be a struct.");
assert(~session.dbDirty, "Session should not start dirty.");

%% 2. Create mock HTML component and controller
eventLog = struct('name', {}, 'data', {});
mockHtml = struct(); % We can test controller methods directly

ctl = DatabaseController(session, [], []);

%% 3. Test NewDatabase event
ctl.handleEvent("NewDatabase", struct());
assert(session.dbDirty, "Session should be dirty after NewDatabase.");
assert(isfield(session.db, "Global"), "NewDatabase should populate Global.");
fprintf("[1] NewDatabase event handling PASSED\n");

%% 4. Test UpdateMetadata event
metaData = struct( ...
    "projectName", "HyperSERS", ...
    "authors", "DeepMind Pair", ...
    "description", "Plasmonic surrogate inverse design", ...
    "paperDOI", "10.1038/s41586-026-0001");
ctl.handleEvent("UpdateMetadata", metaData);
assert(session.db.Global.ProjectName == "HyperSERS", "ProjectName mismatch.");
assert(session.db.Global.Authors == "DeepMind Pair", "Authors mismatch.");
fprintf("[2] UpdateMetadata event handling PASSED\n");

%% 5. Test SaveDatabase event
ctl.handleEvent("SaveDatabase", struct("path", testDbPath));
assert(isfile(testDbPath), "File should be saved.");
assert(~session.dbDirty, "Session should be clean after SaveDatabase.");
fprintf("[3] SaveDatabase event handling PASSED\n");

%% 6. Test LoadDatabase event
session2 = AssteroidSession(tempdir);
ctl2 = DatabaseController(session2, [], []);
ctl2.handleEvent("LoadDatabase", struct("path", testDbPath));
assert(session2.db.Global.ProjectName == "HyperSERS", "Loaded ProjectName mismatch.");
assert(~session2.dbDirty, "Loaded session should be clean.");
fprintf("[4] LoadDatabase event handling PASSED\n");

%% 7. Test serializeToTree
treeNode = DatabaseController.serializeToTree(session.db, "db", 3);
assert(isstruct(treeNode), "Tree node should be a struct.");
assert(treeNode.name == "db", "Root node name should be 'db'.");
assert(~isempty(treeNode.children), "Root should have children branches.");
fprintf("[5] serializeToTree PASSED\n");

fprintf("=== test_database_controller COMPLETED SUCCESSFULLY! ===\n");
