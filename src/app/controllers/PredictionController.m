classdef PredictionController < handle
% PREDICTIONCONTROLLER Controller for Stage 4 Dense Prediction & Interpolation.
%
%   Coordinates DNN grid-based inference, raw simulation interpolation,
%   derived spectral metric evaluations, and persistence into db.Pred
%   and db.Interp branches within AssteroidSession.
%
%   See also: AssteroidSession, DatabaseController, OptimizeController, TrainingController

    properties (SetAccess = private)
        session (1,1) AssteroidSession
        fig           = []
        htmlComponent = []
    end

    methods
        function obj = PredictionController(session, fig, htmlComponent)
        % PREDICTIONCONTROLLER Construct controller attached to session and UI.
            arguments
                session     (1,1) AssteroidSession
                fig               = []
                htmlComponent     = []
            end
            obj.session = session;
            obj.fig = fig;
            obj.htmlComponent = htmlComponent;
        end

        function handleEvent(obj, eventName, eventData)
        % HANDLEEVENT Dispatch event received from visualization_export_tab.html.
            if nargin < 3, eventData = struct(); end

            fig_ = obj.fig;

            try
                switch eventName
                    case "OpenInVisualize"
                        branch = obj.safeStr(eventData, "branch", "Pred");
                        obj.openInVisualizeTab(branch, "2d");
                    case "PredictInterpolate"
                        obj.runPredictInterpolate(eventData);
                    case "RefreshDbState"
                        if ~isempty(fig_) && isvalid(fig_) && isfield(fig_.UserData, "app") ...
                                && isfield(fig_.UserData.app, "broadcastDbStatus")
                            fig_.UserData.app.broadcastDbStatus();
                        end
                    case "SaveDatabaseRequest"
                        if ~isempty(fig_) && isvalid(fig_)
                            if isfield(fig_.UserData, "app") && isfield(fig_.UserData.app, "saveDbFile")
                                fig_.UserData.app.saveDbFile();
                            else
                                obj.session.saveDatabase();
                            end
                            if isfield(fig_.UserData, "app") && isfield(fig_.UserData.app, "broadcastDbStatus")
                                fig_.UserData.app.broadcastDbStatus();
                            end
                        else
                            obj.session.saveDatabase();
                        end
                        obj.sendToHTML("SaveComplete", "Database saved.");
                    case {"StopProcess", "StopPrediction"}
                        obj.stopPrediction();
                    case "PurgePredictions"
                        obj.purgePredictions();
                    otherwise
                        fprintf("[PredictionController] Unknown event: %s\n", eventName);
                end
            catch ME
                if obj.isStopRequested() || strcmp(ME.identifier, "Process:Terminated")
                    obj.notifyStopped("Prediction process terminated by user.");
                else
                    obj.sendToHTML("VisError", ME.message);
                end
            end
        end

        function runPredictInterpolate(obj, d)
        % RUNPREDICTINTERPOLATE Generate dense grid predictions or interpolations.
            rep = obj.makeReporter();
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            dataSource = obj.safeStr(d, "dataSource", "model");
            predictionTarget = obj.safeStr(d, "predictionTarget", "grid");
            workDir = obj.session.workDir;

            laserWl = obj.safeNum(d, "laserWavelength", 785);
            periodMin = obj.safeNum(d, "periodMin", 400);
            periodMax = obj.safeNum(d, "periodMax", 1400);
            radiusMin = obj.safeNum(d, "radiusMin", 50);
            radiusMax = obj.safeNum(d, "radiusMax", 700);
            spatialRes = obj.safeNum(d, "spatialResolution", 2);
            stokesMin = obj.safeNum(d, "stokesShiftMin", 100);
            stokesMax = obj.safeNum(d, "stokesShiftMax", 4200);
            stokesRes = obj.safeNum(d, "stokesShiftResolution", 5);
            batchSize = obj.safeNum(d, "batchSize", 1000);
            interpMethod = obj.safeStr(d, "interpMethod", "linear");
            spectralMethod = obj.safeStr(d, "spectralMethod", "makima");

            linkMetrics = true;
            if isfield(d, "linkMetricsToGrid")
                linkMetrics = logical(d.linkMetricsToGrid);
            end
            preserveExisting = obj.safeBool(d, "preserveExisting", true);
            metricsMin = obj.safeNum(d, "metricsShiftMin", stokesMin);
            metricsMax = obj.safeNum(d, "metricsShiftMax", stokesMax);

            spectralStorageMode = lower(obj.safeStr(d, "spectralStorageMode", "none"));
            if ~ismember(spectralStorageMode, ["none", "single", "log_uint16", "svd", "sidecar_h5"])
                spectralStorageMode = "none";
            end
            svdMaxRank = max(1, round(obj.safeNum(d, "svdMaxRank", 32)));
            svdMaxError = max(0, obj.safeNum(d, "svdMaxError", 0.005));
            sidecarSubtype = lower(obj.safeStr(d, "sidecarSubtype", "single"));
            if ~ismember(sidecarSubtype, ["single", "log_uint16", "double"])
                sidecarSubtype = "single";
            end

            selectedFields = string.empty;
            if isfield(d, "selectedFields")
                selectedFields = parseCellOrString(d, "selectedFields");
            end
            requestedAnalyteKeys = parseCellOrString(d, "analyteKeys");
            if ~isempty(requestedAnalyteKeys) && ~isempty(selectedFields)
                expandedFields = selectedFields;
                for fi = 1:numel(selectedFields)
                    pf = parseMetricVariantName(selectedFields(fi));
                    if pf.isDerived && ~pf.isVariantToken && pf.variant == "analyte" && strlength(pf.baseRaw) > 0
                        for ki = 1:numel(requestedAnalyteKeys)
                            ak = strtrim(string(requestedAnalyteKeys(ki)));
                            if strlength(ak) > 0
                                candField = pf.baseRaw + "_" + ak;
                                if ~ismember(candField, expandedFields)
                                    expandedFields(end+1) = candField; %#ok<AGROW>
                                end
                            end
                        end
                    end
                end
                selectedFields = expandedFields;
            end

            [modelFile, riCsvFile, dataFile, predictionFile] = obj.resolvePaths();
            analyteFile = obj.resolveAnalyteFile();
            analyteLib = obj.resolvePredictionAnalyteLibrary(d, selectedFields, analyteFile, rep);

            rep.progress("PredictInterpolate", 0.01, ...
                sprintf("Mode: %s | Target: %s", dataSource, predictionTarget));

            if spatialRes <= 0 || stokesRes <= 0
                error("runPredictInterpolate:InvalidResolution", ...
                    "Spatial and spectral resolutions must be greater than zero.");
            end
            if periodMin >= periodMax
                error("runPredictInterpolate:InvalidPeriodRange", ...
                    "Period max (%.0f nm) must be greater than period min (%.0f nm).", periodMax, periodMin);
            end
            if radiusMin >= radiusMax
                error("runPredictInterpolate:InvalidRadiusRange", ...
                    "Radius max (%.0f nm) must be greater than radius min (%.0f nm).", radiusMax, radiusMin);
            end
            if stokesMin >= stokesMax
                error("runPredictInterpolate:InvalidStokesRange", ...
                    "Stokes shift max (%.0f cm^-1) must be greater than min (%.0f cm^-1).", stokesMax, stokesMin);
            end

            pointMode = (predictionTarget == "optima");

            if dataSource == "model"
                % Ensure model and RI are loaded
                [ok, model, ri] = obj.ensureModelAndRi(rep);
                if ~ok, return; end

                needsLegacyAnalyte = isempty(selectedFields) || any(endsWith(selectedFields, "_analyte"));
                if needsLegacyAnalyte
                    analyteSpec = obj.loadAnalyteSpectrum(analyteFile, rep);
                else
                    analyteSpec = struct();
                end
                modelMetrics = discoverModelTargetMetrics(obj.session.db, model);
                if isempty(modelMetrics)
                    modelMetrics = ["Abs", "EE_V", "EE_S"];
                end

                rep.start("PredictInterpolate");

                if pointMode
                    gp = computeDenseGridParams( ...
                        LambdaLaser=laserWl, ...
                        PLimits=[periodMin, periodMax], ...
                        RLimits=[radiusMin, radiusMax], ...
                        StokesShiftLimits=[stokesMin, stokesMax], ...
                        Resolution=spatialRes, ...
                        StokesShiftResolution=stokesRes);

                    optimaPoints = obj.resolveOptimaPoints();
                    if isempty(optimaPoints) || size(optimaPoints, 1) == 0
                        obj.sendToHTML("VisError", ...
                            "No optima found in database. Run Stage 5 Optimize first, or choose 'Regular Grid'.");
                        return;
                    end

                    pList = optimaPoints(:, 1);
                    rList = optimaPoints(:, 2);
                    rep.info(sprintf("Predicting at %d optima locations from database...", numel(pList)));

                    metricsWindow = [];
                    if ~linkMetrics
                        metricsWindow = [metricsMin, metricsMax];
                    end

                    allDataRaw = predictPointsSurrogate( ...
                        Model=model, ...
                        Ri=ri, ...
                        P=pList, ...
                        R=rList, ...
                        LambdaSamples=gp.lambdaSamples, ...
                        LambdaLaser=laserWl, ...
                        StokesShiftLimits=[stokesMin, stokesMax], ...
                        InterpResolution=stokesRes, ...
                        AnalyteSpectrum=analyteSpec, ...
                        AnalyteLibrary=analyteLib, ...
                        MetricsWindow=metricsWindow, ...
                        BatchSize=batchSize, ...
                        Reporter=rep);
                else
                    cfg = predictionVisConfig( ...
                        WorkDir=workDir, ...
                        ModelFile=modelFile, ...
                        RiCsvFile=riCsvFile, ...
                        LambdaLaser=laserWl, ...
                        PLimits=[periodMin, periodMax], ...
                        RLimits=[radiusMin, radiusMax], ...
                        Resolution=spatialRes, ...
                        StokesShiftLimits=[stokesMin, stokesMax], ...
                        StokesShiftResolution=stokesRes, ...
                        LinkMetricsToGrid=linkMetrics, ...
                        MetricsShiftLimits=[metricsMin, metricsMax], ...
                        Metrics=modelMetrics, ...
                        RecomputePredictions=true, ...
                        ExportPredictions=false, ...
                        ExportGraphics=false);

                    storeSpectra = isempty(selectedFields);
                    if ~storeSpectra
                        for sfi = 1:numel(selectedFields)
                            pfSpec = parseMetricVariantName(selectedFields(sfi));
                            if ~pfSpec.isVariantToken && pfSpec.variantKind == "spectral"
                                storeSpectra = true;
                                break;
                            end
                        end
                    end

                    loadPredArgs = { ...
                        "Recompute", true, ...
                        "Model", model, ...
                        "Ri", ri, ...
                        "PSamples", cfg.pSamples, ...
                        "RSamples", cfg.rSamples, ...
                        "LambdaSamples", cfg.lambdaSamples, ...
                        "LambdaLaser", laserWl, ...
                        "StokesShiftLimits", [stokesMin, stokesMax], ...
                        "AnalyteSpectrum", analyteSpec, ...
                        "AnalyteLibrary", analyteLib, ...
                        "InterpResolution", stokesRes, ...
                        "PredictionFile", cfg.predictionFile, ...
                        "SaveAfterGeneration", false, ...
                        "BatchSize", batchSize, ...
                        "StoreSpectra", storeSpectra, ...
                        "Reporter", rep};

                    if ~linkMetrics
                        loadPredArgs = [loadPredArgs, {"MetricsShiftLimits", [metricsMin, metricsMax]}];
                    end

                    allDataRaw = loadOrGeneratePredictions(loadPredArgs{:});
                end

                [allDataFiltered, includedFields] = selectPredictionFieldsCanonical(allDataRaw, selectedFields);
                if isempty(includedFields)
                    obj.sendToHTML("VisError", "No selected metric/variant fields were found in generated predictions.");
                    return;
                end

                [allDataFiltered, encStats] = obj.encodeSpectralBranch(allDataFiltered, ...
                    dataSource, predictionTarget, spectralStorageMode, svdMaxRank, svdMaxError, sidecarSubtype, rep);

                if isstruct(allDataFiltered) && structRowCount(allDataFiltered) > 0
                    [obj.session.db, branchPath, mergeInfo] = storePredictionResults( ...
                        obj.session.db, allDataFiltered, dataSource, predictionTarget, ...
                        MergeExisting=preserveExisting);
                    storedBranch = obj.getStoredBranch(branchPath);
                    obj.session.markDirty();
                    if ~isempty(obj.fig) && isvalid(obj.fig)
                        obj.fig.UserData.db = obj.session.db;
                        obj.fig.UserData.dbDirty = true;
                        if ~isfield(obj.fig.UserData, "visExport") || ~isstruct(obj.fig.UserData.visExport)
                            obj.fig.UserData.visExport = struct();
                        end
                        obj.fig.UserData.visExport.predictionsLoaded = true;
                        obj.fig.UserData.visExport.allData = storedBranch;
                        obj.fig.UserData.visExport.ri = ri;
                        obj.fig.UserData.visExport.model = model;
                        obj.fig.UserData.visExport.modelLoaded = true;
                        if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                            obj.fig.UserData.app.markDbDirty();
                        end
                        if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "broadcastDbStatus")
                            obj.fig.UserData.app.broadcastDbStatus();
                        end
                    end

                    if mergeInfo.merged
                        rep.info(sprintf("Merged into %s: preserved %d non-conflicting field(s), wrote %d field(s).", ...
                            branchPath, numel(mergeInfo.preservedFields), numel(includedFields)));
                        if ~isempty(mergeInfo.droppedIncompatible)
                            rep.warning(sprintf("Dropped %d spectral field(s) with incompatible wavelength axis: %s", ...
                                numel(mergeInfo.droppedIncompatible), strjoin(mergeInfo.droppedIncompatible, ", ")));
                        end
                    elseif mergeInfo.mode == "replaced_mismatch"
                        rep.warning(mergeInfo.reason);
                    end

                    nPoints = structRowCount(storedBranch);
                    rep.complete("PredictInterpolate", ...
                        sprintf("Predictions complete: %d points written to %s.", nPoints, branchPath));
                    obj.sendToHTML("PredictComplete", struct( ...
                        "branch", char(branchPath), ...
                        "entries", nPoints, ...
                        "count", nPoints, ...
                        "fields", {cellstr(includedFields)}, ...
                        "mergeMode", char(mergeInfo.mode), ...
                        "preservedCount", numel(mergeInfo.preservedFields), ...
                        "spectralStorageMode", char(encStats.mode), ...
                        "spectralDetails", char(encStats.details), ...
                        "sidecarFile", char(encStats.sidecarFile), ...
                        "message", sprintf("%d points predicted and saved to %s", nPoints, branchPath)));
                else
                    obj.sendToHTML("VisError", "Prediction output was empty.");
                end

            else
                % Interpolation mode (from raw simulation data)
                simData = [];
                if isfield(obj.session.db, "Sim") && isstruct(obj.session.db.Sim) ...
                        && structRowCount(obj.session.db.Sim) > 0
                    simData = obj.session.db.Sim;
                elseif strlength(dataFile) > 0 && isfile(dataFile)
                    try
                        ld = load(dataFile);
                        if isfield(ld, "allData") && isstruct(ld.allData)
                            simData = ld.allData;
                        else
                            flds = fieldnames(ld);
                            if ~isempty(flds) && isstruct(ld.(flds{1}))
                                simData = ld.(flds{1});
                            end
                        end
                    catch
                    end
                end
                if isempty(simData) || ~isstruct(simData) || structRowCount(simData) == 0
                    obj.sendToHTML("VisError", "No simulation data in db.Sim to interpolate.");
                    return;
                end

                needsLegacyAnalyte = isempty(selectedFields) || any(endsWith(selectedFields, "_analyte"));
                if needsLegacyAnalyte
                    analyteSpec = obj.loadAnalyteSpectrum(analyteFile, rep);
                else
                    analyteSpec = struct();
                end
                baseTargets = deriveBaseTargetsFromSelection(selectedFields, simData);

                rep.start("PredictInterpolate");
                rep.info(sprintf("Interpolating simulation targets [%s]...", strjoin(baseTargets, ", ")));

                gp = computeDenseGridParams( ...
                    LambdaLaser=laserWl, ...
                    PLimits=[periodMin, periodMax], ...
                    RLimits=[radiusMin, radiusMax], ...
                    StokesShiftLimits=[stokesMin, stokesMax], ...
                    Resolution=spatialRes, ...
                    StokesShiftResolution=stokesRes);

                derivedWindow = [stokesMin, stokesMax];
                metricsWindowInterp = [];
                if ~linkMetrics
                    derivedWindow = [metricsMin, metricsMax];
                    metricsWindowInterp = derivedWindow;
                end

                if pointMode
                    optimaPoints = obj.resolveOptimaPoints();
                    if isempty(optimaPoints) || size(optimaPoints, 1) == 0
                        obj.sendToHTML("VisError", ...
                            "No saved optima in db.Optima. Run optimisation (Stage 5) first.");
                        return;
                    end
                    predictor = createDataPredictor(simData, ...
                        TargetNames=baseTargets, ...
                        InterpMethod=interpMethod, ...
                        SpectralMethod=spectralMethod, ...
                        LaserWavelength=laserWl);
                    allDataRaw = buildPointPredictionSoA( ...
                        predictor, optimaPoints(:, 1), optimaPoints(:, 2), gp.lambdaSamples, ...
                        laserWl, [stokesMin, stokesMax], stokesRes, ...
                        analyteSpec, rep, "PredictInterpolate", metricsWindowInterp, analyteLib);
                else
                    allDataRaw = interpolateRawSimulationData(simData, gp, ...
                        TargetNames=baseTargets, ...
                        SpatialMethod=interpMethod, ...
                        SpectralMethod=spectralMethod, ...
                        Reporter=rep, ...
                        BatchSize=batchSize);
                    derivedCfg = importSweepConfig( ...
                        WorkDir=workDir, ...
                        LaserWavelength=laserWl, ...
                        RamanWindow=derivedWindow, ...
                        DetectShiftWindow=true, ...
                        InterpResolution=stokesRes, ...
                        SpectralInterpMethod="makima", ...
                        AnalyteLibrary=analyteLib);
                    [allDataRaw, ~] = recomputeDerivedMetrics(allDataRaw, derivedCfg, analyteSpec, rep);
                end

                [interpDataFiltered, includedFields] = selectPredictionFieldsCanonical(allDataRaw, selectedFields);
                if isempty(includedFields)
                    obj.sendToHTML("VisError", "No selected metric/variant fields were found in interpolated data.");
                    return;
                end

                [interpDataFiltered, encStats] = obj.encodeSpectralBranch(interpDataFiltered, ...
                    dataSource, predictionTarget, spectralStorageMode, svdMaxRank, svdMaxError, sidecarSubtype, rep);

                if isstruct(interpDataFiltered) && structRowCount(interpDataFiltered) > 0
                    [obj.session.db, branchPath, mergeInfo] = storePredictionResults( ...
                        obj.session.db, interpDataFiltered, dataSource, predictionTarget, ...
                        MergeExisting=preserveExisting);
                    storedBranch = obj.getStoredBranch(branchPath);
                    obj.session.markDirty();
                    if ~isempty(obj.fig) && isvalid(obj.fig)
                        obj.fig.UserData.db = obj.session.db;
                        obj.fig.UserData.dbDirty = true;
                        if ~isfield(obj.fig.UserData, "visExport") || ~isstruct(obj.fig.UserData.visExport)
                            obj.fig.UserData.visExport = struct();
                        end
                        obj.fig.UserData.visExport.interpLoaded = true;
                        obj.fig.UserData.visExport.allData = storedBranch;
                        if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                            obj.fig.UserData.app.markDbDirty();
                        end
                        if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "broadcastDbStatus")
                            obj.fig.UserData.app.broadcastDbStatus();
                        end
                    end

                    if mergeInfo.merged
                        rep.info(sprintf("Merged into %s: preserved %d non-conflicting field(s), wrote %d field(s).", ...
                            branchPath, numel(mergeInfo.preservedFields), numel(includedFields)));
                        if ~isempty(mergeInfo.droppedIncompatible)
                            rep.warning(sprintf("Dropped %d spectral field(s) with incompatible wavelength axis: %s", ...
                                numel(mergeInfo.droppedIncompatible), strjoin(mergeInfo.droppedIncompatible, ", ")));
                        end
                    elseif mergeInfo.mode == "replaced_mismatch"
                        rep.warning(mergeInfo.reason);
                    end

                    nPoints = structRowCount(storedBranch);
                    rep.complete("PredictInterpolate", ...
                        sprintf("Interpolation complete: %d points written to %s.", nPoints, branchPath));
                    obj.sendToHTML("PredictComplete", struct( ...
                        "branch", char(branchPath), ...
                        "entries", nPoints, ...
                        "count", nPoints, ...
                        "fields", {cellstr(includedFields)}, ...
                        "mergeMode", char(mergeInfo.mode), ...
                        "preservedCount", numel(mergeInfo.preservedFields), ...
                        "spectralStorageMode", char(encStats.mode), ...
                        "spectralDetails", char(encStats.details), ...
                        "sidecarFile", char(encStats.sidecarFile), ...
                        "message", sprintf("%d points interpolated and saved to %s", nPoints, branchPath)));
                else
                    obj.sendToHTML("VisError", "Interpolation output was empty.");
                end
            end
        end

        function openInVisualizeTab(obj, branch, viewMode)
        % OPENINVISUALIZETAB Switch app tab focus to Stage 6 Visualize.
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "openInVisualizeTab")
                    obj.fig.UserData.app.openInVisualizeTab(branch, viewMode);
                end
            end
        end
    end

    %% Internal Helpers
    methods (Access = private)
        function [modelFile, riCsvFile, dataFile, predictionFile] = resolvePaths(obj)
            modelFile = ""; riCsvFile = ""; dataFile = ""; predictionFile = "";
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "app") ...
                    && isfield(obj.fig.UserData.app, "resolveDbPaths")
                [modelFile, riCsvFile, dataFile, predictionFile] = obj.fig.UserData.app.resolveDbPaths();
            elseif isfield(obj.session.db, "Global")
                g = obj.session.db.Global;
                if isfield(g, "SurrogateModelFile"), modelFile = string(g.SurrogateModelFile); end
                if isfield(g, "RefractiveIndexFile"), riCsvFile = string(g.RefractiveIndexFile); end
                if isfield(g, "SimulationDataFile"), dataFile = string(g.SimulationDataFile); end
            end
        end

        function analyteLib = resolvePredictionAnalyteLibrary(obj, d, selectedFields, analyteFile, rep)
            keys = string.empty;
            explicitKeys = parseCellOrString(d, "analyteKeys");
            for k = 1:numel(explicitKeys)
                ak = strtrim(string(explicitKeys(k)));
                if strlength(ak) > 0 && ~ismember(ak, keys)
                    keys(end+1) = ak; %#ok<AGROW>
                end
            end
            for k = 1:numel(selectedFields)
                pf = parseMetricVariantName(selectedFields(k));
                if pf.isDerived && ~pf.isVariantToken && strlength(pf.analyteKey) > 0
                    if ~ismember(pf.analyteKey, keys)
                        keys(end+1) = pf.analyteKey; %#ok<AGROW>
                    end
                end
            end
            if isempty(keys)
                analyteLib = struct([]);
                return;
            end
            analyteLib = resolveAnalyteLibrary(obj.session, Keys=keys, ...
                ExplicitFile=analyteFile, FallbackToDefault=false, Reporter=rep);
        end

        function analyteSpec = loadAnalyteSpectrum(obj, analyteFile, rep)
            [analyteSpec, resolvedPath] = resolveAnalyteSpectrum(obj.session, ...
                ExplicitFile=string(analyteFile), FallbackToDefault=true, Reporter=rep);
            if nargin >= 3 && ~isempty(rep) && strlength(string(analyteFile)) == 0 ...
                    && isstruct(analyteSpec) && isfield(analyteSpec, "shift_cm") ...
                    && ~isempty(analyteSpec.shift_cm) && strlength(resolvedPath) > 0
                [~, fname, fext] = fileparts(resolvedPath);
                rep.info(sprintf("Using built-in analyte spectrum (%s%s) for _analyte metrics.", fname, fext));
            end
        end

        function [dataOut, stats] = encodeSpectralBranch(obj, dataIn, dataSource, predictionTarget, ...
                storageMode, svdMaxRank, svdMaxError, sidecarSubtype, rep)
            branchTag = "Pred";
            if dataSource == "interpolation"
                branchTag = "Interp";
            end
            if predictionTarget == "optima"
                branchTag = "Optima_" + branchTag;
            end

            sidecarFile = "";
            if storageMode == "sidecar_h5"
                if strlength(obj.session.dbFile) > 0
                    [dbDir, dbStem] = fileparts(obj.session.dbFile);
                    if strlength(dbDir) == 0, dbDir = obj.session.workDir; end
                    if strlength(dbStem) == 0, dbStem = "ASSTEROID"; end
                else
                    dbDir = obj.session.workDir;
                    dbStem = "ASSTEROID";
                end
                sidecarFile = fullfile(dbDir, dbStem + "_" + branchTag + "_spectral.h5");
            end

            [dataOut, stats] = SpectralStorage.encodeBranch(dataIn, ...
                "Mode", storageMode, ...
                "SvdMaxRank", svdMaxRank, ...
                "SvdMaxError", svdMaxError, ...
                "SidecarFile", sidecarFile, ...
                "SidecarGroup", "/" + branchTag, ...
                "SidecarSubtype", sidecarSubtype, ...
                "Reporter", rep);

            if ~isempty(stats.encodedFields) && storageMode ~= "none" && ~isempty(rep)
                ratio = stats.rawBytes / max(1, stats.storedBytes);
                if storageMode == "sidecar_h5"
                    rep.info(sprintf("Spectral sidecar (%s): %s offloaded to %s (0 MB in DB).", ...
                        sidecarSubtype, DatabaseEngine.formatBytes(stats.rawBytes), stats.sidecarFile));
                else
                    rep.info(sprintf("Spectral compression (%s): %s -> %s in RAM (%.1fx). %s", ...
                        storageMode, DatabaseEngine.formatBytes(stats.rawBytes), ...
                        DatabaseEngine.formatBytes(stats.storedBytes), ratio, stats.details));
                end
            end
        end

        function analyteFile = resolveAnalyteFile(obj)
            analyteFile = "";
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "app") ...
                    && isfield(obj.fig.UserData.app, "resolveAnalyteFile")
                analyteFile = obj.fig.UserData.app.resolveAnalyteFile();
            elseif isfield(obj.session.db, "Global") && isfield(obj.session.db.Global, "AnalyteSpectrumFile")
                analyteFile = string(obj.session.db.Global.AnalyteSpectrumFile);
            end
        end

        function [ok, model, ri] = ensureModelAndRi(obj, rep)
            model = obj.session.model;
            ri = obj.session.ri;
            if ~isempty(model) && ~isempty(ri)
                ok = true;
                return;
            end

            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "app") ...
                    && isfield(obj.fig.UserData.app, "ensureVisExportModelAndRi")
                [ok, model, ri] = obj.fig.UserData.app.ensureVisExportModelAndRi(obj.htmlComponent, rep);
                if ok
                    obj.session.model = model;
                    obj.session.modelLoaded = true;
                    obj.session.ri = ri;
                    obj.session.riLoaded = true;
                end
            else
                ok = ~isempty(model) && ~isempty(ri);
            end
        end

        function pts = resolveOptimaPoints(obj)
            pts = zeros(0, 2);
            db_ = obj.session.db;
            if isfield(db_, "Optima") && isstruct(db_.Optima) && isfield(db_.Optima, "period") ...
                    && ~isempty(db_.Optima.period)
                p = db_.Optima.period(:);
                r = db_.Optima.radius(:);
                valid = isfinite(p) & isfinite(r);
                pts = [p(valid), r(valid)];
            end
        end

        function sendToHTML(obj, eventName, payload)
            if ~isempty(obj.htmlComponent) && isvalid(obj.htmlComponent)
                try
                    sendEventToHTMLSource(obj.htmlComponent, eventName, payload);
                catch
                end
            end
            if ~isempty(obj.fig) && isvalid(obj.fig) && isstruct(obj.fig.UserData) && isfield(obj.fig.UserData, "app")
                if strcmp(eventName, "Progress") && isstruct(payload)
                    pct = 0;
                    if isfield(payload, "fraction") && ~isempty(payload.fraction), pct = payload.fraction * 100;
                    elseif isfield(payload, "percent") && ~isempty(payload.percent), pct = payload.percent; end
                    msg = ""; if isfield(payload, "message"), msg = payload.message; end
                    try obj.fig.UserData.app.updateProgress(pct, msg, "Stage 4 — Predict"); catch; end
                elseif (strcmp(eventName, "Error") || strcmp(eventName, "Warning") || strcmp(eventName, "PredictComplete"))
                    lvl = "info";
                    if strcmp(eventName, "Error"), lvl = "error";
                    elseif strcmp(eventName, "PredictComplete"), lvl = "success";
                    else, lvl = "warning"; end
                    try obj.fig.UserData.app.logMessage(string(payload), lvl, "Stage 4 — Predict"); catch; end
                end
            end
        end

        function rep = makeReporter(obj)
            rep = ProgressReporter.fromCallback( ...
                @(type, step, data) obj.sendToHTML("Progress", data));
            rep.StopCheckFcn = @() obj.isStopRequested();
        end

        function setRunning(obj, isRunning)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "setProcessRunning")
                    obj.fig.UserData.app.setProcessRunning(isRunning, "Prediction");
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.isRunning = logical(isRunning);
                end
            end
            obj.session.setProcessRunning(isRunning, "Prediction");
        end

        function stopReq = isStopRequested(obj)
            stopReq = false;
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "isProcessStopRequested")
                    stopReq = obj.fig.UserData.app.isProcessStopRequested();
                elseif isfield(obj.fig.UserData, "process") && isfield(obj.fig.UserData.process, "stopRequested")
                    stopReq = logical(obj.fig.UserData.process.stopRequested);
                end
            end
            if ~stopReq
                stopReq = obj.session.isStopRequested();
            end
        end

        function purgePredictions(obj)
        % PURGEPREDICTIONS Remove db.Pred from session database and update UI.
            if ~isstruct(obj.session.db) || ~isfield(obj.session.db, "Pred")
                obj.sendToHTML("VisStatus", "No predictions (db.Pred) found in database.");
                return;
            end
            SpectralStorage.deleteSidecars(obj.session.db.Pred);
            obj.session.db = rmfield(obj.session.db, "Pred");
            obj.session.markDirty();
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.db = obj.session.db;
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "broadcastDbStatus")
                    obj.fig.UserData.app.broadcastDbStatus();
                end
            end
            obj.sendToHTML("VisStatus", "Purged predictions (db.Pred) from database.");
        end

        function stopPrediction(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "requestProcessStop")
                    obj.fig.UserData.app.requestProcessStop();
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.stopRequested = true;
                end
            end
            obj.session.requestStop();
        end

        function notifyStopped(obj, msg)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "notifyProcessStopped")
                    obj.fig.UserData.app.notifyProcessStopped("Prediction", msg);
                else
                    obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
                end
            else
                obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
            end
        end

        function branch = getStoredBranch(obj, branchPath)
            branch = struct();
            if ~isstruct(obj.session.db)
                return;
            end
            parts = split(string(branchPath), ".");
            cur = obj.session.db;
            for i = 1:numel(parts)
                p = char(parts(i));
                if p == "db", continue; end
                if isstruct(cur) && isfield(cur, p)
                    cur = cur.(p);
                else
                    return;
                end
            end
            if isstruct(cur)
                branch = cur;
            end
        end
    end

    %% Static Helpers
    methods (Static)
        function v = safeNum(s, f, d)
            v = d;
            if isfield(s, f) && ~isempty(s.(f))
                val = double(s.(f));
                if isfinite(val), v = val; end
            end
        end

        function v = safeStr(s, f, d)
            v = string(d);
            if isfield(s, f) && ~isempty(s.(f))
                v = string(s.(f));
            end
        end

        function v = safeBool(s, f, d)
            v = logical(d);
            if isfield(s, f) && ~isempty(s.(f))
                v = logical(s.(f));
            end
        end
    end
end
