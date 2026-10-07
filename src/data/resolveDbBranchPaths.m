function [modelFile, riCsvFile, dataFile, predictionFile] = resolveDbBranchPaths(db, workDir)
%resolveDbBranchPaths Return file paths for model, RI, sim data and predictions.
%   When data lives only in memory (loaded via the Database tab), a temp
%   .mat file is written so that downstream pipeline functions that expect
%   file paths continue to work.
%
%   [modelFile, riCsvFile, dataFile, predictionFile] = resolveDbBranchPaths(db, workDir)
%
%   Inputs:
%       db      - Unified database struct with branches Global, Model, Sim, RI, Pred.
%       workDir - (optional) Working directory string (unused currently but reserved).
%
%   Outputs:
%       modelFile      - Path to model .mat (may be a temp file).
%       riCsvFile      - Path to RI CSV or empty string for auto-detect.
%       dataFile       - Path to simulation data .mat (may be a temp file).
%       predictionFile - Path to predictions .mat (may be a temp file).

    arguments
        db struct
        workDir string = ""
    end

    % --- Model ---
    modelFile = "";
    if isfield(db, "Model") && isstruct(db.Model)
        if isfield(db.Model, "NetFile") && strlength(string(db.Model.NetFile)) > 0 ...
                && isfile(string(db.Model.NetFile))
            modelFile = string(db.Model.NetFile);
        elseif isfield(db.Model, "Model") && isstruct(db.Model.Model)
            tmpModel = fullfile(tempdir, "db_model_temp.mat");
            model = db.Model.Model; %#ok<NASGU>
            save(tmpModel, "model", "-v7.3");
            modelFile = string(tmpModel);
        elseif isfield(db.Model, "Net") && ~isempty(db.Model.Net)
            tmpModel = fullfile(tempdir, "db_model_temp.mat");
            if isstruct(db.Model.Net) && isfield(db.Model.Net, "net")
                model = db.Model.Net; %#ok<NASGU>
                save(tmpModel, "model", "-v7.3");
            else
                net = db.Model.Net; %#ok<NASGU>
                model = struct("net", net);
                if isfield(db.Model, "TargetNames") && ~isempty(db.Model.TargetNames)
                    model.targetNames = cellstr(db.Model.TargetNames);
                end
                save(tmpModel, "model", "net", "-v7.3");
            end
            modelFile = string(tmpModel);
        end
    end

    % --- RI ---
    riCsvFile = "";
    if isfield(db, "RI") && isstruct(db.RI)
        if isfield(db.RI, "SourceFile") ...
                && strlength(string(db.RI.SourceFile)) > 0 && isfile(string(db.RI.SourceFile))
            riCsvFile = string(db.RI.SourceFile);
        elseif isfield(db.RI, "lambda") && isfield(db.RI, "n") && isfield(db.RI, "k") && ~isempty(db.RI.lambda)
            tmpRi = fullfile(tempdir, "db_ri_temp.csv");
            wl = db.RI.lambda(:);
            if max(wl) < 10
                wl = wl * 1000; % convert um to nm for CSV
            end
            T = table(wl, db.RI.n(:), db.RI.k(:), 'VariableNames', {'wl', 'n', 'k'});
            writetable(T, tmpRi);
            riCsvFile = string(tmpRi);
        end
    end

    % --- Sim data ---
    dataFile = "";
    if isfield(db, "Global") && isfield(db.Global, "SimFile") ...
            && strlength(string(db.Global.SimFile)) > 0 && isfile(string(db.Global.SimFile))
        dataFile = string(db.Global.SimFile);
    elseif isfield(db, "Sim") && isstruct(db.Sim) && structRowCount(db.Sim) > 0
        tmpSim = fullfile(tempdir, "db_sim_data_temp.mat");
        allData = db.Sim; %#ok<NASGU>
        save(tmpSim, "allData", "-v7.3");
        dataFile = string(tmpSim);
    end

    % --- Predictions ---
    predictionFile = "";
    if isfield(db, "Pred") && isstruct(db.Pred) && structRowCount(db.Pred) > 0
        tmpPred = fullfile(tempdir, "db_pred_temp.mat");
        allData = db.Pred; %#ok<NASGU>
        save(tmpPred, "allData", "-v7.3");
        predictionFile = string(tmpPred);
    end
end
