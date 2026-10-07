%% Export Unified Database for Publication
% Exports the unified SERS database to HDF5 format for Open Science,
% and optionally exports the trained DNN model to ONNX format.
%
% Prerequisites:
%   - Run the full pipeline first (import → train → predict → optimize)
%   - The unified database file (database.mat) must exist
%
% Outputs:
%   - sers_database.h5   — HDF5 file readable by Python, R, OriginPro
%   - sers_model.onnx    — ONNX model (if model .mat file exists)

setup_project;

%% Configuration
workDir      = pwd;
dbMatFile    = fullfile(workDir, "database.mat");
dbH5File     = fullfile(workDir, "sers_database.h5");
onnxFile     = fullfile(workDir, "sers_model.onnx");

%% Load database
if ~isfile(dbMatFile)
    error("Database file not found: %s\nRun the pipeline first.", dbMatFile);
end

fprintf("Loading database from %s...\n", dbMatFile);
db = load(dbMatFile, "db").db;

%% Export to HDF5
fprintf("Exporting to HDF5: %s\n", dbH5File);
exportDatabaseToHDF5(db, dbH5File);

%% Export model to ONNX (if available)
if isfield(db, "Model") && isfield(db.Model, "NetFile")
    netFile = db.Model.NetFile;
    if isfile(netFile)
        fprintf("Loading model from %s...\n", netFile);
        S = load(netFile, "model");
        if isfield(S, "model")
            try
                exportModelToOnnx(S.model, onnxFile);
            catch ME
                warning("ONNX export failed: %s", ME.message);
            end
        end
    else
        fprintf("Model file not found: %s — skipping ONNX export.\n", netFile);
    end
else
    fprintf("No Model.NetFile in database — skipping ONNX export.\n");
end

%% Summary
fprintf("\n=== Export Complete ===\n");
fprintf("  HDF5:  %s\n", dbH5File);
if isfile(onnxFile)
    fprintf("  ONNX:  %s\n", onnxFile);
end
fprintf("\nHDF5 can be opened with:\n");
fprintf("  Python:    h5py.File('sers_database.h5', 'r')\n");
fprintf("  OriginPro: File → Import → HDF5\n");
fprintf("  MATLAB:    importDatabaseFromHDF5('sers_database.h5')\n");
