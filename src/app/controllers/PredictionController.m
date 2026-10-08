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
            radiusMax = obj.safeNum(d, "radiusMax", 450);
            spatialRes = obj.safeNum(d, "spatialResolution", 2);
            stokesMin = obj.safeNum(d, "stokesShiftMin", 100);
            stokesMax = obj.safeNum(d, "stokesShiftMax", 3600);
            stokesRes = obj.safeNum(d, "stokesShiftResolution", 5);
            batchSize = obj.safeNum(d, "batchSize", 1000);
            interpMethod = obj.safeStr(d, "interpMethod", "linear");
            spectralMethod = obj.safeStr(d, "spectralMethod", "makima");

            linkMetrics = true;
            if isfield(d, "linkMetricsToGrid")
                linkMetrics = logical(d.linkMetricsToGrid);
            end
            metricsMin = obj.safeNum(d, "metricsShiftMin", stokesMin);
            metricsMax = obj.safeNum(d, "metricsShiftMax", stokesMax);

            selectedFields = string.empty;
            if isfield(d, "selectedFields")
                selectedFields = parseCellOrString(d, "selectedFields");
            end

            [modelFile, riCsvFile, dataFile, predictionFile] = obj.resolvePaths();
            analyteFile = obj.resolveAnalyteFile();

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

                analyteSpec = struct();
                if strlength(analyteFile) > 0 && isfile(analyteFile)
                    try
                        analyteSpec = loadAndNormalizeAnalyteSpectrum(analyteFile);
                    catch
                        analyteSpec = struct();
                    end
                end

                rep.start("PredictInterpolate");

                if pointMode
                    gp = computeDenseGridParams( ...
                        LambdaLaser=laserWl, ...
                        PLimits=[periodMin, periodMax], ...
                        RLimits=[radiusMin, radiusMax], ...
                        StokesShiftLimits=[stokesMin, stokesMax], ...
                        SpatialResolution=spatialRes, ...
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
                        RecomputePredictions=true, ...
                        ExportPredictions=false, ...
                        ExportGraphics=false);

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
                        "InterpResolution", stokesRes, ...
                        "PredictionFile", cfg.predictionFile, ...
                        "SaveAfterGeneration", false, ...
                        "BatchSize", batchSize, ...
                        "Reporter", rep};

                    if ~linkMetrics
                        loadPredArgs = [loadPredArgs, {"MetricsShiftLimits", [metricsMin, metricsMax]}];
                    end

                    allDataRaw = loadOrGeneratePredictions(loadPredArgs{:});
                end

                if isstruct(allDataRaw) && structRowCount(allDataRaw) > 0
                    obj.session.db.Pred = allDataRaw;
                    obj.session.markDirty();
                    if ~isempty(obj.fig) && isvalid(obj.fig)
                        obj.fig.UserData.db = obj.session.db;
                        obj.fig.UserData.dbDirty = true;
                        if ~isfield(obj.fig.UserData, "visExport") || ~isstruct(obj.fig.UserData.visExport)
                            obj.fig.UserData.visExport = struct();
                        end
                        obj.fig.UserData.visExport.predictionsLoaded = true;
                        obj.fig.UserData.visExport.allData = allDataRaw;
                        obj.fig.UserData.visExport.ri = ri;
                        obj.fig.UserData.visExport.model = model;
                        obj.fig.UserData.visExport.modelLoaded = true;
                        if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                            obj.fig.UserData.app.markDbDirty();
                        end
                    end

                    nPoints = structRowCount(allDataRaw);
                    rep.complete("PredictInterpolate", ...
                        sprintf("Predictions complete: %d points written to db.Pred.", nPoints));
                    obj.sendToHTML("PredictComplete", struct( ...
                        "branch", "Pred", ...
                        "count", nPoints, ...
                        "message", sprintf("%d points predicted and saved to db.Pred", nPoints)));
                else
                    obj.sendToHTML("VisError", "Prediction output was empty.");
                end

            else
                % Interpolation mode (from raw simulation data)
                simData = obj.session.db.Sim;
                if isempty(simData) || structRowCount(simData) == 0
                    obj.sendToHTML("VisError", "No simulation data in db.Sim to interpolate.");
                    return;
                end

                rep.start("PredictInterpolate");
                rep.info("Interpolating raw simulation data to dense grid...");

                % Execute gridded interpolation
                gp = computeDenseGridParams( ...
                    LambdaLaser=laserWl, ...
                    PLimits=[periodMin, periodMax], ...
                    RLimits=[radiusMin, radiusMax], ...
                    StokesShiftLimits=[stokesMin, stokesMax], ...
                    SpatialResolution=spatialRes, ...
                    StokesShiftResolution=stokesRes);

                interpData = interpolateRawSimulationData(simData, gp, ...
                    SpatialMethod=interpMethod, ...
                    SpectralMethod=spectralMethod, ...
                    Reporter=rep);

                if isstruct(interpData) && structRowCount(interpData) > 0
                    obj.session.db.Interp = interpData;
                    obj.session.markDirty();
                    if ~isempty(obj.fig) && isvalid(obj.fig)
                        obj.fig.UserData.db = obj.session.db;
                        obj.fig.UserData.dbDirty = true;
                        if ~isfield(obj.fig.UserData, "visExport") || ~isstruct(obj.fig.UserData.visExport)
                            obj.fig.UserData.visExport = struct();
                        end
                        obj.fig.UserData.visExport.interpLoaded = true;
                        obj.fig.UserData.visExport.allData = interpData;
                        if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                            obj.fig.UserData.app.markDbDirty();
                        end
                    end

                    nPoints = structRowCount(interpData);
                    rep.complete("PredictInterpolate", ...
                        sprintf("Interpolation complete: %d points written to db.Interp.", nPoints));
                    obj.sendToHTML("PredictComplete", struct( ...
                        "branch", "Interp", ...
                        "count", nPoints, ...
                        "message", sprintf("%d points interpolated and saved to db.Interp", nPoints)));
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

        function v = safeNum(~, s, f, d)
            v = d;
            if isfield(s, f) && ~isempty(s.(f))
                val = double(s.(f));
                if isfinite(val), v = val; end
            end
        end

        function v = safeStr(~, s, f, d)
            v = string(d);
            if isfield(s, f) && ~isempty(s.(f))
                v = string(s.(f));
            end
        end

        function v = safeBool(~, s, f, d)
            v = logical(d);
            if isfield(s, f) && ~isempty(s.(f))
                v = logical(s.(f));
            end
        end
    end
end
