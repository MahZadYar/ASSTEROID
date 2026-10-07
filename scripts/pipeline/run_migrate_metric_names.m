% run_migrate_metric_names  Migrate legacy metric names in a database MAT file.

clearvars;
clc;

inputFile = "database_old.mat";
outputFile = "database.mat"; % leave empty to write <input>_canonical.mat
overwrite = false;
dryRun = false;

report = renameLegacyMetricNamesInDatabase( ...
    InputFile=inputFile, ...
    OutputFile=outputFile, ...
    Overwrite=overwrite, ...
    DryRun=dryRun, ...
    Verbose=true);

disp(report);
