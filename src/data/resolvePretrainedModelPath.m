function preTrainedModelFile = resolvePretrainedModelPath(db)
%resolvePretrainedModelPath Return model file path for continue-training.
%
%   preTrainedModelFile = resolvePretrainedModelPath(db)
%
%   Input:
%       db - Unified database struct.
%
%   Output:
%       preTrainedModelFile - String path to model file, or "".

    arguments
        db struct
    end

    preTrainedModelFile = "";
    if isfield(db, "Model") && isstruct(db.Model)
        if isfield(db.Model, "NetFile") && strlength(string(db.Model.NetFile)) > 0 ...
                && isfile(string(db.Model.NetFile))
            preTrainedModelFile = string(db.Model.NetFile);
        elseif isfield(db.Model, "Model") && isstruct(db.Model.Model)
            tmpModel = fullfile(tempdir, "db_model_temp.mat");
            model = db.Model.Model; %#ok<NASGU>
            save(tmpModel, "model", "-v7.3");
            preTrainedModelFile = string(tmpModel);
        elseif isfield(db.Model, "Net") && ~isempty(db.Model.Net)
            tmpModel = fullfile(tempdir, "db_model_temp.mat");
            if isstruct(db.Model.Net) && isfield(db.Model.Net, "net")
                model = db.Model.Net; %#ok<NASGU>
                save(tmpModel, "model", "-v7.3");
            else
                net = db.Model.Net; %#ok<NASGU>
                model = struct("net", net);
                save(tmpModel, "model", "net", "-v7.3");
            end
            preTrainedModelFile = string(tmpModel);
        end
    end
end
