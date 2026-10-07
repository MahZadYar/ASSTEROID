function [model, ri] = loadAndValidateModel(options)
    % loadAndValidateModel  Load trained model and refractive index with validation.
    %
    %   [model, ri] = loadAndValidateModel(Name=Value) loads a trained DNN model
    %   struct and gold refractive index, performing validation checks on both.
    %   This centralises the repeated model/RI loading pattern found in
    %   run_locate_maxima, run_prediction_vis, and run_prediction_vis_app.
    %
    %   Name-Value Arguments:
    %       ModelFile       (1,1) string — Path to trained model .mat file
    %       RiCsvFile       (1,1) string — Path to McPeak.csv refractive index file
    %       WavelengthUnit  (1,1) string — RI wavelength unit: "um" (default) | "nm"
    %       Reporter        ProgressReporter — Optional progress reporter
    %
    %   Output:
    %       model — Trained model struct with fields: net, targetNames,
    %               normalize, denormalize (as produced by train_sers_dnn)
    %       ri    — Refractive index struct with nFunc/kFunc interpolants
    %               (as produced by load_gold_refractive_index)
    %
    %   Example:
    %       [model, ri] = loadAndValidateModel( ...
    %           ModelFile="sers_model.mat", RiCsvFile="McPeak.csv");
    %
    %   See also: load_gold_refractive_index, train_sers_dnn, ProgressReporter

    arguments
        options.ModelFile (1,1) string {mustBeNonmissing}
        options.RiCsvFile (1,1) string = ""
        options.Ri struct = struct()
        options.WavelengthUnit (1,1) string {mustBeMember(options.WavelengthUnit, ...
            ["um", "nm"])} = "um"
        options.Reporter = []
    end

    reporter = options.Reporter;
    hasReporter = ~isempty(reporter) && isa(reporter, "ProgressReporter");

    %% Load model
    if hasReporter
        reporter.start("LoadModel", sprintf("Loading model from %s...", options.ModelFile));
    end

    if ~isfile(options.ModelFile)
        error("loadAndValidateModel:MissingModel", ...
            "Trained model not found: %s", options.ModelFile);
    end

    modelStruct = load(options.ModelFile);
    if isfield(modelStruct, "model")
        model = modelStruct.model;
        modelSource = "model";
    elseif isfield(modelStruct, "net")
        model = struct();
        model.net = modelStruct.net;
        modelSource = "net";

        if isfield(modelStruct, "targetNames")
            model.targetNames = modelStruct.targetNames;
        end
        if isfield(modelStruct, "normalize")
            model.normalize = modelStruct.normalize;
        end
        if isfield(modelStruct, "denormalize")
            model.denormalize = modelStruct.denormalize;
        end
        if isfield(modelStruct, "FeatureLogTransform")
            model.FeatureLogTransform = modelStruct.FeatureLogTransform;
        end
        if isfield(modelStruct, "IncludeRatios")
            model.IncludeRatios = modelStruct.IncludeRatios;
        end
        if isfield(modelStruct, "TargetLogTransform")
            model.TargetLogTransform = modelStruct.TargetLogTransform;
        end
        if isfield(modelStruct, "InputSize")
            model.InputSize = modelStruct.InputSize;
        end
    elseif isfield(modelStruct, "trainedModel")
        if isstruct(modelStruct.trainedModel) && isfield(modelStruct.trainedModel, "net")
            model = modelStruct.trainedModel;
            modelSource = "trainedModel.model";
        else
            model = struct();
            model.net = modelStruct.trainedModel;
            modelSource = "trainedModel";
            if isfield(modelStruct, "targetNames")
                model.targetNames = modelStruct.targetNames;
            end
        end
    elseif isfield(modelStruct, "db") && isstruct(modelStruct.db) && isfield(modelStruct.db, "Model")
        dbM = modelStruct.db.Model;
        if isfield(dbM, "Model") && isstruct(dbM.Model)
            model = dbM.Model;
            modelSource = "db.Model.Model";
        elseif isfield(dbM, "Net") && ~isempty(dbM.Net)
            if isstruct(dbM.Net) && isfield(dbM.Net, "net")
                model = dbM.Net;
                modelSource = "db.Model.Net.model";
            else
                model = struct("net", dbM.Net);
                modelSource = "db.Model.Net";
                if isfield(dbM, "TargetNames"), model.targetNames = cellstr(dbM.TargetNames); end
                if isfield(dbM, "InputSize"), model.InputSize = dbM.InputSize; end
                if isfield(dbM, "Preprocessing")
                    if isfield(dbM.Preprocessing, "FeatureLogTransform")
                        model.FeatureLogTransform = dbM.Preprocessing.FeatureLogTransform;
                    end
                    if isfield(dbM.Preprocessing, "IncludeRatios")
                        model.IncludeRatios = dbM.Preprocessing.IncludeRatios;
                    end
                    if isfield(dbM.Preprocessing, "TargetLogTransform")
                        model.TargetLogTransform = dbM.Preprocessing.TargetLogTransform;
                    end
                end
                % v2 physics schema: statistics needed to rebuild the handles.
                if isfield(dbM, "FeatureSchema") && isfield(dbM, "TargetTransform") ...
                        && ~isempty(dbM.FeatureSchema) && ~isempty(dbM.TargetTransform)
                    model.featureSchema = dbM.FeatureSchema;
                    model.targetTransform = dbM.TargetTransform;
                end
            end
        else
            error("loadAndValidateModel:InvalidDbModel", ...
                "Database file '%s' does not contain a populated Model branch.", options.ModelFile);
        end
    else
        error("loadAndValidateModel:InvalidModelFile", ...
            "File %s must contain either 'model', 'net', or 'db.Model'.", options.ModelFile);
    end

    % Default targetNames if missing
    if ~isfield(model, "targetNames") || isempty(model.targetNames)
        model.targetNames = {'Absorptance', 'EF_vol', 'EF_surf'};
    end

    % Ensure model includes preprocessing flags
    model = ensureModelFlags(model);

    % Synthesize normalize / denormalize if missing
    if (~isfield(model, "normalize") || isempty(model.normalize)) && isfield(model, "net")
        featureLogMask = [true, true, true, false, false];
        if isfield(model, "FeatureLogTransform") && ~model.FeatureLogTransform
            featureLogMask = false(1, 5);
        end
        model.normalize = @(Xraw) localNormalizeFeatures(Xraw, featureLogMask);
    end

    if (~isfield(model, "denormalize") || isempty(model.denormalize)) && isfield(model, "net")
        targetLogTransform = true;
        if isfield(model, "TargetLogTransform")
            targetLogTransform = model.TargetLogTransform;
        end
        model.denormalize = @(Ytrans) localDenormalizeTargets(Ytrans, targetLogTransform);
    end

    % Validate model structure
    requiredFields = {'net', 'targetNames', 'normalize', 'denormalize'};
    missingFields = requiredFields(~isfield(model, requiredFields));
    if ~isempty(missingFields)
        error("loadAndValidateModel:IncompleteModel", ...
            "Model missing required fields: %s", strjoin(missingFields, ', '));
    end

    if ~iscell(model.targetNames) && ~isstring(model.targetNames)
        error("loadAndValidateModel:InvalidTargetNames", ...
            "model.targetNames must be a non-empty cell array or string array.");
    end
    if isempty(model.targetNames)
        error("loadAndValidateModel:InvalidTargetNames", ...
            "model.targetNames must not be empty.");
    end
    % Ensure cellstr for downstream compatibility
    if isstring(model.targetNames)
        model.targetNames = cellstr(model.targetNames);
    end

    if hasReporter
        reporter.complete("LoadModel", sprintf( ...
            "Model loaded from %s. Targets: %s", modelSource, strjoin(cellstr(model.targetNames), ', ')));
    end

    %% Load refractive index
    if hasReporter
        if options.RiCsvFile == ""
            reporter.start("LoadRI", "Loading default refractive index...");
        else
            reporter.start("LoadRI", sprintf("Loading refractive index from %s...", options.RiCsvFile));
        end
    end

    if ~isempty(fieldnames(options.Ri))
        ri = options.Ri;
        if (~isfield(ri, "nFunc") || ~isfield(ri, "kFunc")) && isfield(ri, "lambda") && isfield(ri, "n") && isfield(ri, "k")
            Fn = griddedInterpolant(double(ri.lambda(:)), double(ri.n(:)), 'linear', 'nearest');
            Fk = griddedInterpolant(double(ri.lambda(:)), double(ri.k(:)), 'linear', 'nearest');
            ri.nFunc = @(lq) Fn(double(lq));
            ri.kFunc = @(lq) Fk(double(lq));
        end
        if hasReporter
            reporter.complete("LoadRI", "Using provided refractive index struct.");
        end
    elseif options.RiCsvFile == "" || ~isfile(options.RiCsvFile)
        ri = getDefaultRefractiveIndex(SearchDir=pwd, WavelengthUnit=options.WavelengthUnit);
        if hasReporter
            reporter.complete("LoadRI", "Loaded default gold RI from DefaultRefractiveIndices.dat.");
        end
    else
        ri = load_gold_refractive_index(options.RiCsvFile, ...
            "WavelengthUnit", options.WavelengthUnit);
        if hasReporter
            reporter.complete("LoadRI", "Refractive index loaded from file.");
        end
    end

    if ~isfield(ri, "nFunc") || ~isfield(ri, "kFunc")
        error("loadAndValidateModel:InvalidRI", ...
            "Refractive index struct missing nFunc or kFunc fields.");
    end
end

function Xnorm = localNormalizeFeatures(Xraw, featureLogMask)
%localNormalizeFeatures Natural-log transform physical features according to mask
%   (matches prepare_training_dataset/transformFeatures, which uses log()).
    if isempty(Xraw)
        Xnorm = Xraw;
        return;
    end
    Xnorm = Xraw;
    if any(featureLogMask)
        for col = 1:min(size(Xraw, 2), numel(featureLogMask))
            if featureLogMask(col) && all(Xraw(:, col) > 0)
                Xnorm(:, col) = log(Xraw(:, col));
            end
        end
    end
end

function Yraw = localDenormalizeTargets(Ytrans, targetLogTransform)
%localDenormalizeTargets Invert log1p transform applied to targets.
    if isempty(Ytrans)
        Yraw = Ytrans;
        return;
    end
    Yraw = Ytrans;
    if targetLogTransform
        Yraw = expm1(Ytrans);
    end
end
