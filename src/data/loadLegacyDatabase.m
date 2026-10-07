function db = loadLegacyDatabase(matFile, options)
% loadLegacyDatabase  Convert legacy allData .mat file to unified db struct.
%
%   db = loadLegacyDatabase(matFile) loads a legacy SoA .mat file containing
%   an 'allData' variable and converts it into the unified hierarchical
%   database structure as the Sim branch.
%
%   db = loadLegacyDatabase(matFile, LaserWl=785, StokesWindow=[100 3600])
%   attaches branch-level metadata.
%
%   Input:
%       matFile - string, path to legacy .mat file containing allData
%
%   Name-Value Arguments:
%       LaserWl      - scalar (nm), excitation wavelength (default: 785)
%       StokesWindow - [1x2] (cm^-1), Raman window (default: [100 3600])
%       BranchName   - string, target branch name (default: "Sim")
%       SourceTag    - string, provenance tag (default: "Simulation.FEM.COMSOL")
%
%   Output:
%       db - unified database struct with the specified branch populated
%
%   See also: createDatabaseStruct, populateBranch, extractBranchAsSoA

    arguments
        matFile (1,1) string {mustBeFile}
        options.LaserWl (1,1) double {mustBePositive} = 785
        options.StokesWindow (1,2) double = [100, 3600]
        options.BranchName (1,1) string = "Sim"
        options.SourceTag (1,1) string = "Simulation.FEM.COMSOL"
    end

    S = load(matFile);

    if isfield(S, "db") && isstruct(S.db)
        db = S.db;
        return
    end

    if ~isfield(S, "allData")
        error("loadLegacyDatabase:NoAllData", ...
            "File does not contain 'allData' or 'db' variable: %s", matFile);
    end

    allData = normalizeGeometryFields(S.allData);

    % Rename legacy metric fields to canonical suffix-based names
    renameMap = struct( ...
        'BEE_vol', 'EF_vol_avg', ...
        'BEE_surf', 'EF_surf_avg', ...
        'AEE_vol', 'EF_vol_analyte', ...
        'AEE_surf', 'EF_surf_analyte', ...
        'EF_vol_approx', 'EF_vol_laser', ...
        'EF_surf_approx', 'EF_surf_laser', ...
        'Abs_laser', 'Absorptance_laser', ...
        'Abs_avg', 'Absorptance_avg');

    oldNames = fieldnames(renameMap);
    for i = 1:numel(oldNames)
        oldName = oldNames{i};
        newName = renameMap.(oldName);
        if isfield(allData, oldName) && ~isfield(allData, newName)
            allData.(newName) = allData.(oldName);
            allData = rmfield(allData, oldName);
        end
    end

    db = createDatabaseStruct();
    db.(options.BranchName) = populateBranch(allData, options.SourceTag, ...
        "LaserWl", options.LaserWl, ...
        "StokesWindow", options.StokesWindow);
end
