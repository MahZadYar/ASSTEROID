function rawFiles = resolveSimDataPath(db)
%resolveSimDataPath Return simulation data file path(s) for training.
%
%   rawFiles = resolveSimDataPath(db)
%
%   Input:
%       db - Unified database struct.
%
%   Output:
%       rawFiles - String array of file paths (may contain temp file path).

    arguments
        db struct
    end

    rawFiles = string.empty;

    if isfield(db, "Global") && isfield(db.Global, "SimFile") ...
            && strlength(string(db.Global.SimFile)) > 0 && isfile(string(db.Global.SimFile))
        rawFiles = string(db.Global.SimFile);
    elseif isfield(db, "Sim") && isstruct(db.Sim) && structRowCount(db.Sim) > 0
        tmpSim = fullfile(tempdir, "db_sim_data_temp.mat");
        allData = db.Sim; %#ok<NASGU>
        save(tmpSim, "allData", "-v7.3");
        rawFiles = string(tmpSim);
    end
end
