classdef SamplingController < handle
% SAMPLINGCONTROLLER Controller for Stage 2 Adaptive Parameter Sampling.
%
%   Coordinates metric density calculations, rejection-sampling of new
%   geometries, failed/NaN grid detection, and COMSOL parameter sweeps.
%
%   See also: AssteroidSession, adaptiveSamplingConfig, runAdaptiveSamplingWorkflow

    properties (SetAccess = private)
        session (1,1) AssteroidSession
        fig           = []
        htmlComponent = []
        ax            = []
        samplingState = struct( ...
            "config", [], ...
            "samples", [], ...
            "density", [], ...
            "result", [], ...
            "nanResult", [], ...
            "dataLoaded", false, ...
            "samplingComplete", false)
    end

    methods
        function obj = SamplingController(session, fig, htmlComponent, ax)
        % SAMPLINGCONTROLLER Construct controller attached to session and UI.
            arguments
                session     (1,1) AssteroidSession
                fig               = []
                htmlComponent     = []
                ax                = []
            end
            obj.session = session;
            obj.fig = fig;
            obj.htmlComponent = htmlComponent;
            obj.ax = ax;
        end

        function handleEvent(obj, eventName, eventData)
        % HANDLEEVENT Dispatch event received from adaptive_sampling_app.html.
            if nargin < 3, eventData = struct(); end

            try
                switch eventName
                    case "LoadData"
                        obj.loadSamplingData(eventData);
                    case "RunSampling"
                        obj.runSampling(eventData);
                    case "PreviewDensity"
                        obj.previewDensity(eventData);
                    case "ExportResults"
                        obj.exportSamplingResults(eventData);
                    case "FindNanPoints"
                        obj.findNanPoints(eventData);
                    case "ExportNanPoints"
                        obj.exportNanPoints(eventData);
                    case "HighlightNanPoints"
                        obj.highlightNanPoints(eventData);
                    case "Reset"
                        obj.resetSampling();
                    case "RefreshDbState"
                        obj.refreshDbState();
                    case "SaveDatabaseRequest"
                        obj.saveDatabase();
                    case {"StopProcess", "StopSampling"}
                        obj.stopSampling();
                    otherwise
                        fprintf("[SamplingController] Unknown event: %s\n", eventName);
                end
            catch ME
                if obj.isStopRequested() || strcmp(ME.identifier, "Process:Terminated")
                    obj.notifyStopped("Sampling process terminated by user.");
                else
                    obj.sendToHTML("Error", ME.message);
                end
            end
        end

        function loadSamplingData(obj, eventData)
        % LOADSAMPLINGDATA Load baseline dataset for adaptive sampling.
            cfg = obj.buildSamplingCfgFromEvent(eventData);
            obj.samplingState.config = cfg;

            if cfg.fromPredictions
                if isempty(cfg.predictionFile)
                    obj.sendToHTML("Error", "Select a prediction file"); return;
                end
            else
                if isempty(cfg.dataFile)
                    obj.sendToHTML("Error", "Select a data file"); return;
                end
            end

            obj.sendToHTML("StatusUpdate", "Loading data...");
            samples = loadSamplingData(cfg);
            obj.samplingState.samples = samples;
            obj.samplingState.dataLoaded = true;
            obj.syncStateToFig();

            % Detect input parameter names and ranges from schema first
            inputParams = struct('name', {}, 'min', {}, 'max', {});
            db = obj.session.db;
            if isfield(db, 'Schema') && ~isempty(db.Schema) && numel(db.Schema) > 0
                for k = 1:numel(db.Schema)
                    if string(db.Schema(k).role) == "input"
                        pName = db.Schema(k).name;
                        if isfield(samples.allData, pName)
                            vals = samples.allData.(pName);
                            vMin = min(vals, [], 'omitnan'); if isempty(vMin) || isnan(vMin), vMin = 0; end
                            vMax = max(vals, [], 'omitnan'); if isempty(vMax) || isnan(vMax), vMax = 100; end
                            inputParams(end+1) = struct('name', pName, ...
                                'min', vMin, 'max', vMax); %#ok<AGROW>
                        end
                    end
                end
            end

            % Fallback: if no schema inputs found, use period/radius
            pMin = min(samples.period, [], 'omitnan'); if isempty(pMin) || isnan(pMin), pMin = 0; end
            pMax = max(samples.period, [], 'omitnan'); if isempty(pMax) || isnan(pMax), pMax = 100; end
            rMin = min(samples.radius, [], 'omitnan'); if isempty(rMin) || isnan(rMin), rMin = 0; end
            rMax = max(samples.radius, [], 'omitnan'); if isempty(rMax) || isnan(rMax), rMax = 50; end

            if isempty(inputParams)
                inputParams(1) = struct('name', 'period', 'min', pMin, 'max', pMax);
                inputParams(2) = struct('name', 'radius', 'min', rMin, 'max', rMax);
            end

            % Detect scalar (averaged) metric fields, excluding input parameters
            inputNames = {'period','radius','p','r','lambda','f','LaserWl','Source','StokesWindow','Shifts'};
            if ~isempty(inputParams)
                inputNames = unique([inputNames, {inputParams.name}]);
            end

            fnames = fieldnames(samples.allData);
            valid = string([]);
            for i = 1:numel(fnames)
                fn = fnames{i};
                if ismember(fn, inputNames), continue; end
                v = samples.allData.(fn);
                if isnumeric(v) && numel(v) == samples.numPoints
                    valid(end+1) = string(fn); %#ok<AGROW>
                end
            end

            % Also check schema metrics
            if isfield(db, 'Schema') && ~isempty(db.Schema) && numel(db.Schema) > 0
                for k = 1:numel(db.Schema)
                    if string(db.Schema(k).role) == "metric"
                        mName = db.Schema(k).name;
                        if isfield(samples.allData, mName) && ~ismember(string(mName), valid)
                            valid(end+1) = string(mName); %#ok<AGROW>
                        end
                    end
                end
            end

            valid = unique(valid, 'stable');
            if isempty(valid)
                valid = ["EF_vol_avg", "EF_surf_avg", "Absorptance_avg"];
            end

            obj.sendToHTML("DataLoaded", struct( ...
                "numPoints", samples.numPoints, ...
                "periodMin", pMin, "periodMax", pMax, ...
                "radiusMin", rMin, "radiusMax", rMax, ...
                "inputParams", inputParams, ...
                "availableMetrics", valid));

            obj.updateSamplingViz(cfg, samples, [], []);
        end

        function runSampling(obj, eventData)
        % RUNSAMPLING Execute rejection-sampling loop based on density field.
            if ~obj.samplingState.dataLoaded
                obj.sendToHTML("Error", "Load data first"); return;
            end
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            cfg = obj.buildSamplingCfgFromEvent(eventData);
            cfg.stopFcn = @() obj.isStopRequested();
            obj.samplingState.config = cfg;

            if isempty(cfg.metricNames)
                obj.sendToHTML("Error", "Select at least one metric"); return;
            end

            obj.sendToHTML("SamplingProgress", struct("percent", 5, "message", "Building density..."));

            samples = updateSamplesMetrics_local(obj.samplingState.samples, cfg);
            obj.samplingState.samples = samples;

            density = buildSamplingDensity(cfg, samples);
            obj.samplingState.density = density;

            obj.sendToHTML("SamplingProgress", struct("percent", 15, "message", "Running rejection sampling..."));
            result = runAdaptiveSampling(cfg, samples, density);
            obj.samplingState.result = result;
            obj.samplingState.samplingComplete = true;
            obj.syncStateToFig();

            obj.sendToHTML("SamplingProgress", struct("percent", 100, "message", "Complete!"));
            obj.sendToHTML("SamplingComplete", struct( ...
                "count", result.count, ...
                "attempts", result.attempts, ...
                "acceptanceRate", result.acceptanceRate));

            obj.updateSamplingViz(cfg, samples, density, result);
        end

        function previewDensity(obj, eventData)
        % PREVIEWDENSITY Compute 2D density grid from chosen metrics and preview.
            if ~obj.samplingState.dataLoaded
                obj.sendToHTML("Error", "Load data first"); return;
            end
            cfg = obj.buildSamplingCfgFromEvent(eventData);
            if isempty(cfg.metricNames)
                obj.sendToHTML("Error", "Select at least one metric"); return;
            end
            obj.samplingState.config = cfg;
            samples = updateSamplesMetrics_local(obj.samplingState.samples, cfg);
            obj.samplingState.samples = samples;

            density = buildSamplingDensity(cfg, samples);
            obj.samplingState.density = density;
            obj.syncStateToFig();

            obj.updateSamplingViz(cfg, samples, density, obj.samplingState.result);
            obj.sendToHTML("DensityPreview", struct("success", true));
        end

        function exportSamplingResults(obj, eventData)
        % EXPORTSAMPLINGRESULTS Export generated coordinates to COMSOL format.
            if ~obj.samplingState.samplingComplete || isempty(obj.samplingState.result)
                obj.sendToHTML("Error", "Run sampling first"); return;
            end
            outFile = obj.safeStr(eventData, "outputFile", "adaptive_points.txt");
            workDir = obj.session.workDir;
            if workDir ~= ""
                defaultPath = fullfile(workDir, outFile);
            else
                defaultPath = fullfile(pwd, outFile);
            end

            [file, path] = uiputfile({'*.txt', 'Text Files (*.txt)'; '*.*', 'All Files (*.*)'}, ...
                'Save Export File As', defaultPath);

            if isequal(file, 0) || isequal(path, 0)
                obj.sendToHTML("StatusUpdate", "Export cancelled.");
                return;
            end

            outFile = fullfile(path, file);
            st = obj.samplingState;
            originalPoints = [st.samples.period(:), st.samples.radius(:)];
            exportToComsol(st.result, OutputFile=outFile, ...
                IncludeOriginal=obj.safeBool(eventData, "includeOriginal", false), ...
                OriginalPoints=originalPoints);
            obj.sendToHTML("ExportComplete", struct("filename", outFile));
        end

        function findNanPoints(obj, eventData)
        % FINDNANPOINTS Scan dataset for unconverged/NaN simulation points.
            dataSource = [];
            st = obj.samplingState;
            if isfield(st, "samples") && ~isempty(st.samples) && isfield(st.samples, "allData")
                dataSource = st.samples.allData;
            elseif isfield(obj.session.db, "Sim") && isstruct(obj.session.db.Sim) && structRowCount(obj.session.db.Sim) > 0
                dataSource = obj.session.db;
            elseif isfield(obj.session.db, "Global") && isfield(obj.session.db.Global, "SimFile") ...
                   && isfile(string(obj.session.db.Global.SimFile))
                dataSource = string(obj.session.db.Global.SimFile);
            end

            if isempty(dataSource)
                [~, ~, simDataFile, ~] = obj.resolvePaths();
                if strlength(simDataFile) > 0 && isfile(simDataFile)
                    dataSource = simDataFile;
                end
            end

            if isempty(dataSource)
                obj.sendToHTML("Error", "No dataset loaded. Load data in Database or Sampling tab first.");
                return;
            end

            obj.sendToHTML("StatusUpdate", "Scanning for NaN metrics...");

            precision = obj.safeNum(eventData, "precision", 6);
            res = findNanSamplingPoints(dataSource, Precision=precision);
            obj.samplingState.nanResult = res;
            obj.syncStateToFig();

            obj.sendToHTML("NanPointsFound", res);

            if res.hasNans
                obj.sendToHTML("StatusUpdate", ...
                    sprintf("Found %d unique geometry points with NaNs across %d entries.", res.count, res.totalRows));
            else
                obj.sendToHTML("StatusUpdate", "No NaN values detected in any metric.");
            end
        end

        function exportNanPoints(obj, eventData)
        % EXPORTNANPOINTS Save detected failed points to text/dat file.
            if ~isfield(obj.samplingState, "nanResult") || isempty(obj.samplingState.nanResult) ...
               || obj.samplingState.nanResult.count == 0
                obj.sendToHTML("Error", "Scan for NaN points first.");
                return;
            end

            nanRes = obj.samplingState.nanResult;
            defaultName = obj.safeStr(eventData, "outputFile", "comsol_failed_nan_points.txt");
            workDir = obj.session.workDir;
            if workDir ~= ""
                defaultPath = fullfile(workDir, defaultName);
            else
                defaultPath = fullfile(pwd, defaultName);
            end

            [file, path] = uiputfile({'*.txt', 'Text Files (*.txt)'; '*.dat', 'Data Files (*.dat)'; '*.*', 'All Files (*.*)'}, ...
                'Save COMSOL Re-sweep File As', defaultPath);

            if isequal(file, 0) || isequal(path, 0)
                obj.sendToHTML("StatusUpdate", "Export cancelled.");
                return;
            end

            outFile = fullfile(path, file);
            fmt = obj.safeStr(eventData, "format", "param");
            precision = obj.safeNum(eventData, "precision", 6);

            exportNanPointsToComsol(nanRes, ...
                OutputFile=outFile, ...
                Format=fmt, ...
                Precision=precision);

            obj.sendToHTML("ExportNanComplete", struct( ...
                "filename", outFile, ...
                "count", nanRes.count));
            obj.sendToHTML("StatusUpdate", ...
                sprintf("Exported %d points to COMSOL file: %s", nanRes.count, file));
        end

        function highlightNanPoints(obj, eventData)
        % HIGHLIGHTNANPOINTS Render marker overlays on axes for failed points.
            ax_ = obj.getAxes();
            if isempty(ax_) || ~isvalid(ax_), return; end

            oldH = findobj(ax_, "Tag", "NAN_HIGHLIGHT_POINTS");
            delete(oldH);

            show = obj.safeBool(eventData, "show", true);
            if ~show, return; end

            if ~isfield(obj.samplingState, "nanResult") || isempty(obj.samplingState.nanResult) ...
               || obj.samplingState.nanResult.count == 0
                return;
            end

            nanRes = obj.samplingState.nanResult;
            hold(ax_, "on");

            zVal = 2.0;
            zChildren = findobj(ax_, "Type", "surface");
            if ~isempty(zChildren)
                try
                    zdata = get(zChildren(1), "ZData");
                    zVal = max(zdata(:)) * 1.2;
                catch
                end
            end

            pts = nanRes.uniquePoints;
            hScat = scatter3(ax_, pts(:, 1), pts(:, 2), repmat(zVal, size(pts, 1), 1), ...
                60, [1 0.5 0], "^", "filled", ...
                "MarkerEdgeColor", [1 1 1], ...
                "LineWidth", 1.2, ...
                "DisplayName", sprintf("Failed/NaN Points (%d)", nanRes.count), ...
                "Tag", "NAN_HIGHLIGHT_POINTS");
            uistack(hScat, "top");
            legend(ax_, "show", "TextColor", [0.8 0.85 0.9], "Location", "northeast");
        end

        function resetSampling(obj)
        % RESETSAMPLING Clear current state and reset axes visualization.
            obj.samplingState = struct( ...
                "config", [], "samples", [], "density", [], ...
                "result", [], "nanResult", [], "dataLoaded", false, "samplingComplete", false);
            obj.syncStateToFig();

            ax_ = obj.getAxes();
            if ~isempty(ax_) && isvalid(ax_)
                cla(ax_);
                title(ax_, "Sampling Density & Generated Points", "Color", [0.9 0.92 0.95]);
            end
            obj.sendToHTML("StatusUpdate", "Reset complete");
        end

        function updateSamplingViz(obj, cfg, samples, density, result)
        % UPDATESAMPLINGVIZ Render density surface and scatter points onto axes.
            ax_ = obj.getAxes();
            if isempty(ax_) || ~isvalid(ax_), return; end

            cla(ax_); hold(ax_, "on");

            if cfg.useManualRange && ~isnan(cfg.periodRange(1))
                pR = cfg.periodRange; rR = cfg.radiusRange;
            else
                pR = [min(samples.period) max(samples.period)];
                rR = [min(samples.radius) max(samples.radius)];
            end
            maxD = 1;

            if ~isempty(density) && ~cfg.uniformSampling
                gr = cfg.gridResolution;
                pG = linspace(pR(1), pR(2), gr); rG = linspace(rR(1), rR(2), gr);
                [PG, RG] = meshgrid(pG, rG);
                D = density.func(PG(:), RG(:)); D = reshape(D, size(PG)); D(isnan(D)) = 0;
                maxD = max(D(:)) + 0.01;
                surf(ax_, PG, RG, D, "EdgeColor", "none", "FaceAlpha", 0.9);
                view(ax_, 2);
                cmap = [];
                if ~isempty(obj.fig) && isvalid(obj.fig)
                    cmap = getappdata(obj.fig, "CustomColormap");
                end
                if isempty(cmap), cmap = parula(256); end
                colormap(ax_, cmap);
                cb = colorbar(ax_); cb.Color = [0.7 0.75 0.8];
                clim(ax_, [0 1]);
            else
                view(ax_, 2);
            end

            if cfg.showOriginal && ~isempty(samples)
                scatter3(ax_, samples.period, samples.radius, ...
                    ones(size(samples.period)) * 1.1 * maxD, ...
                    cfg.pointSize, hex2rgb(cfg.originalColor), "filled", ...
                    "MarkerEdgeColor", "k", "LineWidth", 0.5, "DisplayName", "Original");
            end
            if cfg.showGenerated && ~isempty(result) && result.count > 0
                scatter3(ax_, result.points(:, 1), result.points(:, 2), ...
                    ones(result.count, 1) * 1.2 * maxD, ...
                    cfg.pointSize * 1.2, hex2rgb(cfg.generatedColor), "filled", ...
                    "MarkerEdgeColor", "w", "LineWidth", 0.5, ...
                    "DisplayName", sprintf("Generated (%d)", result.count));
            end
            hold(ax_, "off");
            xlim(ax_, pR); ylim(ax_, rR);
            xlabel(ax_, "Period (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");
            ylabel(ax_, "Radius (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");
            if ~isempty(result) && result.count > 0
                ttl = sprintf("Generated %d points (%.2f%% acceptance)", result.count, result.acceptanceRate * 100);
            else
                ttl = "Sampling Density Preview";
            end
            title(ax_, ttl, "Color", [0.9 0.92 0.95], "FontSize", 12);
            legend(ax_, "Location", "northeast", "TextColor", [0.9 0.92 0.95], ...
                "Color", [0.2 0.25 0.3], "EdgeColor", [0.4 0.45 0.5]);
            drawnow;
        end

        function cfg = buildSamplingCfgFromEvent(obj, ev)
        % BUILDSAMPLINGCFGFROMEVENT Construct adaptiveSamplingConfig value object.
            gf = @(n, d) ternaryVal(isfield(ev, n), @() ev.(n), d);
            gs = @(n, d) string(gf(n, d));
            metricNames = sanitiseMetricList(gf("metricNames", []));
            if isempty(metricNames)
                db = obj.session.db;
                if isfield(db, "Schema") && ~isempty(db.Schema)
                    for k = 1:numel(db.Schema)
                        if string(db.Schema(k).role) == "metric"
                            metricNames = string(db.Schema(k).name);
                            break;
                        end
                    end
                end
                if isempty(metricNames) && isfield(db, "Sim") && isstruct(db.Sim)
                    simFields = fieldnames(db.Sim);
                    prefList = {'EF_vol_avg', 'EF_vol', 'BEE_vol', 'EF_surf_avg', 'EF_surf', 'Absorptance_avg', 'Absorptance'};
                    prefIdx = find(ismember(simFields, prefList), 1);
                    if ~isempty(prefIdx)
                        metricNames = string(simFields{prefIdx});
                    else
                        for k = 1:numel(simFields)
                            if ~ismember(simFields{k}, {'period','radius','p','r','lambda','f','LaserWl','Source','StokesWindow','Shifts'})
                                metricNames = string(simFields{k});
                                break;
                            end
                        end
                    end
                end
                if isempty(metricNames), metricNames = "EF_vol_avg"; end
            end
            nM = max(1, numel(metricNames));

            if isfield(ev, "autoDetectRanges") && ev.autoDetectRanges
                pR = [NaN NaN]; rR = [NaN NaN];
            elseif isfield(ev, "periodMin") && isfield(ev, "periodMax")
                pR = [ev.periodMin, ev.periodMax]; rR = [ev.radiusMin, ev.radiusMax];
            else
                pR = [NaN NaN]; rR = [NaN NaN];
            end

            [dbModelFile, dbRiCsvFile, dbDataFile, dbPredFile] = obj.resolvePaths();

            xParam = gs("xAxisParam", "");
            yParam = gs("yAxisParam", "");

            cfg = adaptiveSamplingConfig( ...
                WorkDir         = obj.session.workDir, ...
                DataSource      = gs("dataSource", "interpolation"), ...
                DataFile        = dbDataFile, ...
                ModelFile       = dbModelFile, ...
                RiCsvFile       = dbRiCsvFile, ...
                PredictionFile  = dbPredFile, ...
                NumPoints       = gf("numPoints", 100), ...
                MaxAttempts     = gf("maxAttempts", 1e6), ...
                MinSeparation   = gf("minSeparation", 5), ...
                RtpThreshold    = gf("rtpThreshold", 0.49), ...
                UniformSampling = gf("uniformSampling", false), ...
                EnforceOriginalSpacing = gf("enforceOriginalSpacing", true), ...
                PeriodRange     = pR, RadiusRange = rR, ...
                MetricNames     = metricNames, ...
                MetricWeights   = padVec(gf("metricWeights", []), nM), ...
                MetricAlphas    = padVec(gf("metricAlphas", []),  nM), ...
                OverallExponent = gf("overallExponent", 1), ...
                BlurSigma       = gf("blurSigma", 0), ...
                OutputFile      = gs("outputFile", "adaptive_points.txt"), ...
                DensityThreshold = gf("densityThreshold", 0), ...
                GridResolution  = gf("gridResolution", 100), ...
                Visualize       = false, ...
                xAxisParam      = xParam, ...
                yAxisParam      = yParam);

            cfg.xAxisParam     = xParam;
            cfg.yAxisParam     = yParam;
            cfg.showOriginal   = gf("showOriginal", true);
            cfg.showGenerated  = gf("showGenerated", true);
            cfg.originalColor  = gs("originalColor", "#ef4444");
            cfg.generatedColor = gs("generatedColor", "#10b981");
            cfg.pointSize      = gf("pointSize", 30);
        end

        function refreshDbState(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "broadcastDbStatus")
                    obj.fig.UserData.app.broadcastDbStatus();
                end
            end
        end

        function saveDatabase(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "saveDbFile")
                    obj.fig.UserData.app.saveDbFile();
                    if isfield(obj.fig.UserData.app, "broadcastDbStatus")
                        obj.fig.UserData.app.broadcastDbStatus();
                    end
                end
            else
                obj.session.saveDatabase();
            end
            obj.sendToHTML("SaveComplete", "Database saved.");
        end

        function stopSampling(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "requestProcessStop")
                    obj.fig.UserData.app.requestProcessStop();
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.stopRequested = true;
                end
            end
            obj.session.requestStop();
        end
    end

    %% Internal Helpers
    methods (Access = private)
        function ax = getAxes(obj)
            ax = obj.ax;
            if (isempty(ax) || ~isvalid(ax)) && ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "handles") && isfield(obj.fig.UserData.handles, "samplingAx")
                    ax = obj.fig.UserData.handles.samplingAx;
                end
            end
        end

        function syncStateToFig(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.sampling = obj.samplingState;
            end
        end

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

        function setRunning(obj, isRunning)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "setProcessRunning")
                    obj.fig.UserData.app.setProcessRunning(isRunning, "Sampling");
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.isRunning = logical(isRunning);
                end
            end
            obj.session.setProcessRunning(isRunning, "Sampling");
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

        function notifyStopped(obj, msg)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "notifyProcessStopped")
                    obj.fig.UserData.app.notifyProcessStopped("Sampling", msg);
                else
                    obj.sendToHTML("SamplingProgress", struct("percent", 0, "message", msg));
                end
            else
                obj.sendToHTML("SamplingProgress", struct("percent", 0, "message", msg));
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
