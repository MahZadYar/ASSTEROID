function predictor = buildPredictorFromConfig(cfg, options)
    %buildPredictorFromConfig  Factory: build predictor from workflow config.
    %
    %   predictor = buildPredictorFromConfig(cfg) inspects cfg.dataSource and
    %   returns either a DNN-based or interpolation-based predictor struct.
    %
    %   For cfg.dataSource = "model":
    %       Loads model from cfg.modelFile and RI from cfg.riCsvFile, then
    %       wraps them with createModelPredictor.
    %
    %   For cfg.dataSource = "interpolation":
    %       Loads raw SoA data from cfg.dataFile, then builds makima
    %       interpolants with createDataPredictor.
    %
    %   predictor = buildPredictorFromConfig(cfg, Reporter=reporter)
    %   reports progress through a ProgressReporter.
    %
    %   Input:
    %       cfg — Config struct containing at minimum:
    %             .dataSource   "model" | "interpolation"
    %             .modelFile    (when dataSource = "model")
    %             .riCsvFile    (when dataSource = "model", can be "")
    %             .dataFile     (when dataSource = "interpolation")
    %
    %   Name-Value Arguments:
    %       Reporter — ProgressReporter instance (default: silent)
    %
    %   Output:
    %       predictor — Unified predictor struct from createModelPredictor or
    %                   createDataPredictor
    %
    %   See also: createModelPredictor, createDataPredictor,
    %             loadAndValidateModel, ProgressReporter

    arguments
        cfg (1,1) struct
        options.Reporter = ProgressReporter.silent()
    end

    reporter = options.Reporter;
    dataSource = resolveDataSource(cfg);

    switch dataSource
        case "model"
            reporter.start("BuildPredictor", "Loading DNN model predictor...");

            modelFile = "";
            if isfield(cfg, "modelFile"), modelFile = string(cfg.modelFile); end
            riCsvFile = "";
            if isfield(cfg, "riCsvFile"), riCsvFile = string(cfg.riCsvFile); end

            [model, ri] = loadAndValidateModel( ...
                ModelFile=modelFile, RiCsvFile=riCsvFile, Reporter=reporter);
            predictor = createModelPredictor(model, ri);

            reporter.complete("BuildPredictor", ...
                sprintf("Model predictor ready (%d targets).", numel(predictor.targetNames)));

        case "interpolation"
            reporter.start("BuildPredictor", "Building interpolation predictor from raw data...");

            dataFile = resolveDataFile(cfg);
            if ~isfile(dataFile)
                error("buildPredictorFromConfig:FileNotFound", ...
                    "Data file not found: %s", dataFile);
            end

            loaded = load(dataFile);
            if isfield(loaded, "allData")
                rawData = loaded.allData;
            elseif isfield(loaded, "data")
                rawData = loaded.data;
            else
                fnames = fieldnames(loaded);
                rawData = [];
                for i = 1:numel(fnames)
                    if isstruct(loaded.(fnames{i})) && isfield(loaded.(fnames{i}), "period")
                        rawData = loaded.(fnames{i});
                        break;
                    end
                end
                if isempty(rawData)
                    error("buildPredictorFromConfig:NoData", ...
                        "File %s does not contain recognizable SoA data.", dataFile);
                end
            end

            % Normalize geometry fields if needed
            rawData = normalizeGeometryFields(rawData);

            predictor = createDataPredictor(rawData);
            reporter.complete("BuildPredictor", ...
                sprintf("Interpolation predictor ready (%d targets, %dx%dx%d grid).", ...
                numel(predictor.targetNames), numel(predictor.rGrid), ...
                numel(predictor.pGrid), numel(predictor.lambdaGrid)));

        otherwise
            error("buildPredictorFromConfig:InvalidSource", ...
                "Unknown dataSource: '%s'. Use 'model' or 'interpolation'.", dataSource);
    end
end

%% ========================================================================
function ds = resolveDataSource(cfg)
    %resolveDataSource  Extract dataSource from config with backward compat.

    if isfield(cfg, "dataSource")
        ds = string(cfg.dataSource);
    elseif isfield(cfg, "fromPredictions") && cfg.fromPredictions
        ds = "interpolation";
    else
        ds = "model";
    end
end

%% ========================================================================
function df = resolveDataFile(cfg)
    %resolveDataFile  Extract data file path from config.

    df = "";
    if isfield(cfg, "dataFile") && strlength(cfg.dataFile) > 0
        df = string(cfg.dataFile);
    elseif isfield(cfg, "predictionFile") && strlength(cfg.predictionFile) > 0
        df = string(cfg.predictionFile);
    end

    if strlength(df) == 0
        error("buildPredictorFromConfig:NoDataFile", ...
            "DataSource='interpolation' requires a DataFile path.");
    end
end