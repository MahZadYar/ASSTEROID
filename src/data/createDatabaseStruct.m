function db = createDatabaseStruct(options)
% createDatabaseStruct  Initialize an empty unified ASSTEROID database structure.
%
%   db = createDatabaseStruct()
%   db = createDatabaseStruct(Name=Value, ...)
%
%   Initializes the hierarchical database structure for ASSTEROID.
%   This structure unifies simulation data, interpolations, predictions,
%   optimization results, model metadata, and refractive index data into a
%   single container suitable for HDF5 export.
%
%   Name-Value Arguments:
%       ProjectName  - string (default: "ASSTEROID")
%       Authors      - string (default: "")
%       PaperDOI     - string (default: "")
%       Geometry     - string (default: "Hex-Sphr-Au")
%       Substrate    - string (default: "McPeak-HFilm")
%       Description  - string (default: "")
%
%   Output:
%       db - struct with empty branches: Global, Sim, Interp, Pred, Optima, Model, RI
%
%   See also: populateBranch, exportDatabaseToHDF5

    arguments
        options.ProjectName (1,1) string = "ASSTEROID"
        options.Authors     (1,1) string = ""
        options.PaperDOI    (1,1) string = ""
        options.Geometry    (1,1) string = "Hex-Sphr-Au"
        options.Substrate   (1,1) string = "McPeak-HFilm"
        options.Description (1,1) string = ""
    end

    % Initialize root struct
    db = struct();
    
    % 1. Global Metadata
    db.Global = struct( ...
        'SchemaVersion', 1, ...
        'DateCreated', string(datetime('now', 'Format', 'yyyy-MM-dd HH:mm:ss')), ...
        'ProjectName', options.ProjectName, ...
        'Authors', options.Authors, ...
        'PaperDOI', options.PaperDOI, ...
        'Geometry', options.Geometry, ...
        'Substrate', options.Substrate, ...
        'Description', options.Description ...
    );

    % 2. Data Branches (empty structs to be populated later)
    db.Sim = struct();
    db.Interp = struct();
    db.Pred = struct();
    
    % 3. Optimization Branch (flat appendable SoA)
    db.Optima = struct( ...
        'period',           zeros(0,1), ...
        'radius',           zeros(0,1), ...
        'basinTag',         string.empty(0,1), ...
        'optimizedMetric',  string.empty(0,1), ...
        'metricVariant',    string.empty(0,1), ...
        'metricValue',      zeros(0,1), ...
        'timestamp',        string.empty(0,1), ...
        'sourceMode',       string.empty(0,1) ...
    );
    
    % 4. Model Metadata Branch
    db.Model = struct();
    
    % 5. Refractive Index Branch
    db.RI = struct();

    % 6. Column Schema (dynamic column definitions from import)
    %    Struct array with fields: name (string), role (string)
    %    Roles: "input", "spectral", "metric", "ignore"
    db.Schema = struct('name', {}, 'role', {});
end
