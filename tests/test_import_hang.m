% test_import_hang.m — Verify schema-driven import workflow
setup_project;
testDir = fileparts(mfilename('fullpath'));
cfg = importSweepConfig( ...
    WorkDir = testDir, ...
    InputFile = "SweepPropeTable.dat", ...
    OutputFile = fullfile(tempdir, "test_output.mat"), ...
    LaserWavelength = 785, ...
    Mode = "rebuild");
results = runImportSweepWorkflow(cfg, ProgressReporter.console());

% Verify schema was created
assert(~isempty(results.schema), "Schema should not be empty");
fprintf("\n=== Schema ===\n");
for k = 1:numel(results.schema)
    fprintf("  %-20s  role=%s\n", results.schema(k).name, results.schema(k).role);
end

% Verify db.Schema was populated
assert(~isempty(results.db.Schema), "db.Schema should not be empty");
fprintf("\ndb.Schema has %d entries\n", numel(results.db.Schema));

% Verify allData has the expected fields
fnames = fieldnames(results.allData);
fprintf("\nallData fields: %s\n", strjoin(string(fnames), ", "));

fprintf("\nFinished!\n");
