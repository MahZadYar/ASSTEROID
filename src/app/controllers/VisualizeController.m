classdef VisualizeController < handle
% VISUALIZECONTROLLER Controller for Stage 6 Multi-mode Scientific Visualization.
%
%   Coordinates 1D spectral trace lookups, 2D continuous/scattered metric maps,
%   and 3D multi-dimensional annotated volumetric rendering across db.Sim,
%   db.Interp, and db.Pred branches. All rendering operations are transient and
%   read-only with respect to underlying database branches.
%
%   See also: AssteroidSession, plotSpectraLines, plotScatteredMap2D, renderAnnotatedVolume

    properties (SetAccess = private)
        session (1,1) AssteroidSession
        fig           = []
        htmlComponent = []
        ax1D          = []
        ax2D          = []
        viewer        = []
        traces        = struct("lambda", {}, "y", {}, "label", {}, "isDense", {})
        dataPredictor = []
        dataPredictorKey = ""
    end

    methods
        function obj = VisualizeController(session, fig, htmlComponent, ax1D, ax2D, viewer)
        % VISUALIZECONTROLLER Construct controller attached to session and UI.
            arguments
                session     (1,1) AssteroidSession
                fig               = []
                htmlComponent     = []
                ax1D              = []
                ax2D              = []
                viewer            = []
            end
            obj.session = session;
            obj.fig = fig;
            obj.htmlComponent = htmlComponent;
            obj.ax1D = ax1D;
            obj.ax2D = ax2D;
            obj.viewer = viewer;
        end

        function handleEvent(obj, eventName, eventData)
        % HANDLEEVENT Dispatch event received from visualize_tab.html.
            if nargin < 3, eventData = struct(); end

            try
                switch eventName
                    case "RequestBranchInfo"
                        obj.sendBranchInfo();
                    case "Render"
                        obj.runRender(eventData);
                    case "ClearTraces"
                        obj.clearTraces();
                    case "RefreshDbState"
                        obj.refreshDbState();
                    case "SaveDatabaseRequest"
                        obj.saveDatabase();
                    case "StopProcess"
                        obj.stopProcess();
                    otherwise
                        fprintf("[VisualizeController] Unknown event: %s\n", eventName);
                end
            catch ME
                if strcmp(ME.identifier, "Visualize:Reported")
                    return;
                elseif obj.isStopRequested() || strcmp(ME.identifier, "Process:Terminated")
                    obj.notifyStopped("Visualization terminated by user.");
                else
                    obj.sendToHTML("VisError", string(ME.message));
                end
            end
        end

        function sendBranchInfo(obj)
        % SENDBRANCHINFO Inspect session database branches and push schema to UI.
            db = obj.getDb();
            branches = struct();
            for b = ["Sim", "Interp", "Pred"]
                branches.(b) = obj.describeBranch(obj.safeStruct(db, b));
            end
            [hasModel, targets] = obj.localModelInfo(branches.Sim);
            payload = struct( ...
                "branches",     branches, ...
                "hasModel",     hasModel, ...
                "modelTargets", {cellstr(targets)}, ...
                "laserWl",      obj.localLaserWl(db));
            obj.sendToHTML("VisualizeBranchInfo", payload);
        end

        function runRender(obj, d)
        % RUNRENDER Execute 1D, 2D, or 3D visualization render.
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));
            rep = obj.makeReporter();

            obj.resizeVisPanel();

            mode = lower(obj.safeStr(d, "mode", "2d"));
            tabGroup = obj.getHandle("visualizeTabGroup");
            switch mode
                case "1d"
                    if ~isempty(tabGroup) && isvalid(tabGroup)
                        tabGroup.SelectedTab = obj.getHandle("visualizeTab1D");
                    end
                    [msg, warns] = obj.render1D(d, rep);
                case "2d"
                    if ~isempty(tabGroup) && isvalid(tabGroup)
                        tabGroup.SelectedTab = obj.getHandle("visualizeTab2D");
                    end
                    [msg, warns] = obj.render2D(d, rep);
                case "3d"
                    if ~isempty(tabGroup) && isvalid(tabGroup)
                        tabGroup.SelectedTab = obj.getHandle("visualizeTab3D");
                    end
                    drawnow;
                    [msg, warns] = obj.render3D(d, rep);
                otherwise
                    error("Visualize:UnknownMode", "Unknown visualization mode: %s", mode);
            end
            drawnow;
            rep.checkStop("Render");
            obj.sendToHTML("VisualizeComplete", ...
                struct("message", string(msg), "warnings", {cellstr(warns)}));
        end

        function clearTraces(obj)
        % CLEARTRACES Reset stored 1D spectral traces and clear 1D axes.
            obj.traces = struct("lambda", {}, "y", {}, "label", {}, "isDense", {});
            obj.syncTracesToFig();
            ax = obj.getAx1D();
            if ~isempty(ax) && isvalid(ax)
                if ~isempty(ax.Legend), delete(ax.Legend); end
                cla(ax, "reset");
                styleDarkAxes(ax, "Wavelength (nm)", "Metric value", "1D Spectra");
            end
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

        function stopProcess(obj)
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

    %% Internal Rendering Methods
    methods (Access = private)
        function [msg, warns] = render1D(obj, d, rep)
            warns = strings(1, 0);
            source = lower(obj.safeStr(d, "source", "sim"));
            if ~ismember(source, ["sim", "interp", "model"])
                error("Visualize:BadSource", "Unknown 1D source: %s", source);
            end
            p = obj.safeNum(d, "p", NaN);
            r = obj.safeNum(d, "r", NaN);
            if ~isfinite(p) || ~isfinite(r)
                error("Visualize:BadInput", "Period and radius must be finite numbers.");
            end
            metrics = reshape(parseCellOrString(d, "metrics"), 1, []);
            if isempty(metrics)
                error("Visualize:NoMetric", "Select at least one metric.");
            end
            xAxis = lower(obj.safeStr(d, "xAxis", "lambda"));
            if ~ismember(xAxis, ["lambda", "shift"]), xAxis = "lambda"; end
            smoothing = lower(obj.safeStr(d, "smoothing", "makima"));
            if ~ismember(smoothing, ["makima", "pchip", "spline", "linear", "none"]), smoothing = "makima"; end
            laserWl = obj.safeNum(d, "laserWavelength", 785);
            if ~(laserWl > 0), laserWl = 785; end

            S = obj.safeStruct(obj.getDb(), "Sim");
            rep.start("Spectra1D", "Evaluating " + source + " spectra...");
            switch source
                case "sim"
                    out = lookupSpectrum1D("sim", p, r, metrics, SimData=S);
                    obj.sendToHTML("VisualizeSnapped", struct( ...
                        "p", out.p, "r", out.r, "distance", out.distance, "index", out.simIndex));
                    srcLabel = "Sim";
                case "interp"
                    method = lower(obj.safeStr(d, "interpMethod", "natural"));
                    if ~ismember(method, ["natural", "linear", "nearest"]), method = "natural"; end
                    pred = obj.localDataPredictor(S, method, rep);
                    out = lookupSpectrum1D("interp", p, r, metrics, SimData=S, ...
                        DataPredictor=pred, InterpMethod=method);
                    if out.outsideHull
                        warns(end+1) = sprintf(['(p, r) = (%.1f, %.1f) nm lies outside the simulated ' ...
                            'convex hull; values fall back to the nearest sample.'], p, r);
                    end
                    srcLabel = "Interp";
                otherwise   % "model"
                    [ok, model, ri] = obj.ensureModelAndRi(rep);
                    if ~ok
                        error("Visualize:Reported", "Model or refractive-index data unavailable.");
                    end
                    lam = obj.localModelLambda(d, S, laserWl);
                    out = lookupSpectrum1D("model", p, r, metrics, ...
                        ModelPredictor=createModelPredictor(model, ri), LambdaGrid=lam);
                    srcLabel = "Model";
            end
            rep.checkStop("Spectra1D");
            if ~isempty(out.missing)
                warns(end+1) = "Not available from this source: " + strjoin(out.missing, ", ") + ".";
            end
            if isempty(out.metrics)
                error("Visualize:NoData", "None of the selected metrics are available from the %s source.", srcLabel);
            end

            newTraces = struct("lambda", {}, "y", {}, "label", {}, "isDense", {});
            for m = 1:numel(out.metrics)
                tr = struct( ...
                    "lambda", reshape(out.lambda, 1, []), ...
                    "y", reshape(out.values(:, m), 1, []), ...
                    "label", sprintf("%s | %s (p=%.1f, r=%.1f nm)", out.metrics(m), srcLabel, out.p, out.r), ...
                    "isDense", out.isDense);
                newTraces(end+1) = tr; %#ok<AGROW>
            end

            titleStr = sprintf("Spectra at p = %.1f nm, r = %.1f nm", out.p, out.r);
            if obj.safeBool(d, "hold", false)
                curTraces = obj.traces;
                if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "visualize") ...
                        && isfield(obj.fig.UserData.visualize, "traces")
                    curTraces = obj.fig.UserData.visualize.traces;
                end
                tracesAll = [curTraces, newTraces];
                maxTraces = 24;
                if numel(tracesAll) > maxTraces
                    tracesAll = tracesAll(end-maxTraces+1:end);
                    warns(end+1) = sprintf("Only the latest %d traces are kept.", maxTraces);
                end
                if numel(tracesAll) > numel(newTraces)
                    titleStr = "Spectral traces";
                end
            else
                tracesAll = newTraces;
            end
            obj.traces = tracesAll;
            obj.syncTracesToFig();

            ax = obj.getAx1D();
            plotSpectraLines(ax, tracesAll, XAxis=xAxis, LaserWavelength=laserWl, ...
                LogY=obj.safeBool(d, "logY", true), Smoothing=smoothing, ...
                Normalize=obj.safeBool(d, "normalize", false), Title=titleStr);
            rep.complete("Spectra1D", sprintf("%d trace(s) evaluated.", numel(newTraces)));
            msg = sprintf("1D: %d trace(s) from %s plotted (%d on axes).", numel(newTraces), srcLabel, numel(tracesAll));
        end

        function [msg, warns] = render2D(obj, d, rep)
            warns = strings(1, 0);
            [branch, S] = obj.localBranch(d);
            metric = obj.safeStr(d, "metric", "");
            if strlength(metric) == 0 || ~isfield(S, metric)
                error("Visualize:NoMetric", "Metric ""%s"" not found in db.%s.", metric, branch);
            end
            kind = lower(obj.safeStr(d, "metricKind", "scalar"));
            P = double(S.period(:));
            R = double(S.radius(:));
            rep.start("Map2D", "Rendering 2D map of " + metric + "...");
            if kind == "slice"
                shift = obj.safeNum(d, "sliceShift", 1000);
                laserWl = obj.safeNum(d, "laserWavelength", 785);
                lamT = 1 / (1 / laserWl - shift * 1e-7);
                if ~isfinite(lamT) || lamT <= 0
                    error("Visualize:BadShift", "Raman shift %.0f cm⁻¹ is not reachable from λ_L = %.1f nm.", shift, laserWl);
                end
                [v, nOut] = obj.extractSpectralSlice(S, metric, lamT);
                if nOut > 0
                    warns(end+1) = sprintf("%d of %d rows do not cover λ = %.1f nm and are left blank.", ...
                        nOut, numel(v), lamT);
                end
                titleStr = sprintf("%s @ %g cm⁻¹ (λ = %.1f nm) — db.%s", metric, shift, lamT, branch);
            else
                v = S.(metric);
                if size(v, 2) ~= 1
                    error("Visualize:NotScalar", "%s is spectral; choose a scalar variant or a spectral slice.", metric);
                end
                v = double(v(:));
                titleStr = sprintf("%s — db.%s", metric, branch);
            end
            rep.checkStop("Map2D");

            method = lower(obj.safeStr(d, "renderMethod", "triangulated"));
            if ~ismember(method, ["triangulated", "nearest"]), method = "triangulated"; end
            cmap = obj.loadColormapSafe(256, ~obj.safeBool(d, "invertColormap", false));

            sp = []; sr = [];
            showSim = obj.safeBool(d, "showSimPoints", false);
            if showSim
                simS = obj.safeStruct(obj.getDb(), "Sim");
                if isfield(simS, "period") && isfield(simS, "radius") && ~isempty(simS.period)
                    sp = double(simS.period(:));
                    sr = double(simS.radius(:));
                else
                    showSim = false;
                    warns(end+1) = "db.Sim is empty; no sample overlay drawn.";
                end
            end
            op = []; orr = [];
            if obj.safeBool(d, "showOptima", false)
                [op, orr] = obj.localOptima(obj.getDb());
                if isempty(op), warns(end+1) = "No saved optima to overlay."; end
            end

            ax = obj.getAx2D();
            info = plotScatteredMap2D(ax, P, R, v, Method=method, Colormap=cmap, ...
                LogScale=obj.safeBool(d, "logScale", false), Title=titleStr, ColorbarLabel=metric, ...
                ShowPoints=showSim, PointsP=sp, PointsR=sr, OptimaP=op, OptimaR=orr);
            rep.complete("Map2D", "2D map rendered.");
            if info.isGridded
                layout = sprintf("grid %d×%d (r × p)", info.gridSize(1), info.gridSize(2));
            else
                layout = info.method + " rendering of scattered samples";
            end
            msg = sprintf("2D: %s from db.%s, %d finite samples, %s.", metric, branch, info.nValid, layout);
        end

        function [msg, warns] = render3D(obj, d, rep)
            warns = strings(1, 0);
            [branch, S] = obj.localBranch(d);
            metric = obj.safeStr(d, "metric", "");
            [spec, ~] = obj.classifyFields(S, numel(S.period));
            if ~any(spec == metric)
                error("Visualize:NoMetric", "Spectral metric ""%s"" not found in db.%s.", metric, branch);
            end
            P = double(S.period(:));
            R = double(S.radius(:));
            rows = find(isfinite(P) & isfinite(R));
            [isGrid, pU, rU, linIdx] = detectPRGrid(P(rows), R(rows));
            if ~isGrid
                error("Visualize:NotGridded", ['db.%s holds scattered samples, which cannot be rendered ' ...
                    'as a 3D volume. Populate db.Interp via "4 Predict → Raw Data (Interpolation)" ' ...
                    'and visualise that branch instead.'], branch);
            end
            rep.start("Volume3D", "Assembling " + metric + " volume...");

            lamAll = S.lambda;
            lamRow = double(lamAll(1, :));
            if size(lamAll, 1) > 1
                chk = unique(round(linspace(1, size(lamAll, 1), min(64, size(lamAll, 1)))));
                dev = max(abs(double(lamAll(chk, :)) - lamRow), [], "all", "omitnan");
                if dev > 1e-6 * max(abs(lamRow), [], "omitnan")
                    warns(end+1) = "Rows use different λ grids; the first row's grid is used for the volume.";
                end
            end
            if max(lamRow, [], "omitnan") < 10, lamRow = lamRow * 1e3; end
            lamCols = find(isfinite(lamRow));
            [lamSorted, ord] = sort(lamRow(lamCols), "ascend");
            lamCols = lamCols(ord);

            maxS = max(16, round(obj.safeNum(d, "maxSamples", 256)));
            iR = 1:ceil(numel(rU) / maxS):numel(rU);
            iP = 1:ceil(numel(pU) / maxS):numel(pU);
            iL = 1:ceil(numel(lamSorted) / maxS):numel(lamSorted);
            nr = numel(iR); np = numel(iP); nl = numel(iL);
            if nr < numel(rU) || np < numel(pU) || nl < numel(lamSorted)
                warns(end+1) = sprintf("Volume decimated from %d×%d×%d to %d×%d×%d (r × p × λ) for display.", ...
                    numel(rU), numel(pU), numel(lamSorted), nr, np, nl);
            end
            mapR = zeros(numel(rU), 1); mapR(iR) = 1:nr;
            mapP = zeros(numel(pU), 1); mapP(iP) = 1:np;
            [irAll, ipAll] = ind2sub([numel(rU), numel(pU)], linIdx(:));
            sel = mapR(irAll) > 0 & mapP(ipAll) > 0;
            newLin = sub2ind([nr, np], mapR(irAll(sel)), mapP(ipAll(sel)));
            M = S.(metric);
            vol = NaN(nr * np, nl);
            vol(newLin, :) = double(M(rows(sel), lamCols(iL)));
            vol = reshape(vol, nr, np, nl);
            rep.checkStop("Volume3D");

            pV = pU(iP); rV = rU(iR); lV = lamSorted(iL);

            overlay = [];
            if obj.safeBool(d, "showSimColumns", false)
                simS = obj.safeStruct(obj.getDb(), "Sim");
                if isfield(simS, "period") && isfield(simS, "radius") && ~isempty(simS.period)
                    if np >= 2
                        jp = interp1(pV(:), (1:np)', double(simS.period(:)), "nearest");
                    elseif np == 1
                        jp = ones(numel(simS.period), 1);
                    else
                        jp = [];
                    end
                    if nr >= 2
                        jr = interp1(rV(:), (1:nr)', double(simS.radius(:)), "nearest");
                    elseif nr == 1
                        jr = ones(numel(simS.radius), 1);
                    else
                        jr = [];
                    end
                    ok = isfinite(jp) & isfinite(jr);
                    mask2 = false(nr, np);
                    mask2(sub2ind([nr, np], jr(ok), jp(ok))) = true;
                    overlay = repmat(mask2, 1, 1, nl);
                else
                    warns(end+1) = "db.Sim is empty; no sample columns drawn.";
                end
            end

            cmap = [];
            if obj.safeBool(d, "invertColormap", false)
                cmap = obj.loadColormapSafe(256, false);
            end
            viewerObj = obj.getViewer();
            renderAnnotatedVolume(viewerObj, vol, pV, rV, lV, ...
                Colormap=cmap, LogScale=obj.safeBool(d, "logScale", true), ...
                MetricLabel=metric, OverlayMask=overlay);
            rep.complete("Volume3D", "Volume rendered.");
            msg = sprintf("3D: %s volume %d×%d×%d (r × p × λ) from db.%s.", metric, nr, np, nl, branch);
        end

        function pred = localDataPredictor(obj, S, method, rep)
            if ~isfield(S, "period") || ~isfield(S, "lambda") || isempty(S.period)
                error("Visualize:NoSim", "db.Sim is empty; load simulation data first.");
            end
            P = double(S.period(:));
            R = double(S.radius(:));
            key = sprintf("%d|%d|%.9g|%.9g|%s", numel(P), size(S.lambda, 2), ...
                sum(P, "omitnan"), sum(R, "omitnan"), method);
            if ~isempty(obj.dataPredictor) && strcmp(obj.dataPredictorKey, key)
                pred = obj.dataPredictor;
                return;
            end
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "visualize")
                vis = obj.fig.UserData.visualize;
                if isfield(vis, "dataPredictor") && ~isempty(vis.dataPredictor) ...
                        && isfield(vis, "dataPredictorKey") && strcmp(vis.dataPredictorKey, key)
                    pred = vis.dataPredictor;
                    obj.dataPredictor = pred;
                    obj.dataPredictorKey = key;
                    return;
                end
            end

            [spec, ~] = obj.classifyFields(S, numel(P));
            if isempty(spec)
                error("Visualize:NoSpectral", "db.Sim has no spectral [N x L] metrics to interpolate.");
            end
            rep.info("Building spatial interpolant over db.Sim (cached for later queries)...");
            pred = createDataPredictor(S, TargetNames=spec, InterpMethod=method, SpectralMethod="makima");
            obj.dataPredictor = pred;
            obj.dataPredictorKey = key;
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "visualize")
                obj.fig.UserData.visualize.dataPredictor = pred;
                obj.fig.UserData.visualize.dataPredictorKey = key;
            end
        end

        function [branch, S] = localBranch(obj, d)
            branch = obj.safeStr(d, "branch", "Sim");
            if ~ismember(branch, ["Sim", "Interp", "Pred"])
                error("Visualize:BadBranch", "Unknown data branch: %s", branch);
            end
            S = obj.safeStruct(obj.getDb(), branch);
            if ~isfield(S, "period") || ~isfield(S, "radius") || isempty(S.period)
                error("Visualize:EmptyBranch", "db.%s is empty.", branch);
            end
        end

        function [v, nOut] = extractSpectralSlice(~, S, metric, lamT)
            M = S.(metric);
            N = size(M, 1);
            if size(M, 2) < 2
                error("Visualize:NotSpectral", "%s is not a spectral [N x L] metric.", metric);
            end
            lam = double(S.lambda);
            if max(lam(:), [], "omitnan") < 10, lam = lam * 1e3; end
            if size(lam, 1) ~= N
                lamRow = lam(1, :);
                [~, idx] = min(abs(lamRow - lamT));
                inRange = lamT >= min(lamRow) && lamT <= max(lamRow);
                v = double(M(:, idx));
                if ~inRange, v(:) = NaN; end
                nOut = N * double(~inRange);
            else
                [~, idx] = min(abs(lam - lamT), [], 2);
                v = double(M(sub2ind(size(M), (1:N)', idx)));
                outside = lamT < min(lam, [], 2) | lamT > max(lam, [], 2);
                v(outside) = NaN;
                nOut = nnz(outside);
            end
        end

        function [op, orr] = localOptima(~, db)
            op = []; orr = [];
            if isfield(db, "Optima") && isstruct(db.Optima) && isfield(db.Optima, "period") ...
                    && ~isempty(db.Optima.period)
                op = double(db.Optima.period(:));
                orr = double(db.Optima.radius(:));
                n = min(numel(op), numel(orr));
                op = op(1:n); orr = orr(1:n);
                if max(op, [], "omitnan") < 10
                    op = op * 1e3; orr = orr * 1e3;
                end
            end
        end

        function lam = localModelLambda(obj, d, S, laserWl)
            lamMin = obj.safeNum(d, "lambdaMin", NaN);
            lamMax = obj.safeNum(d, "lambdaMax", NaN);
            step = obj.safeNum(d, "lambdaStep", 1);
            if ~(step > 0), step = 1; end
            defRange = [laserWl, 1 / (1 / laserWl - 3600e-7)];
            if isstruct(S) && isfield(S, "lambda") && ~isempty(S.lambda)
                l = double(S.lambda(isfinite(S.lambda)));
                if ~isempty(l)
                    defRange = [min(l), max(l)];
                    if defRange(2) < 10, defRange = defRange * 1e3; end
                end
            end
            if ~isfinite(lamMin), lamMin = defRange(1); end
            if ~isfinite(lamMax), lamMax = defRange(2); end
            if lamMax <= lamMin
                error("Visualize:BadLambda", "λ max (%.1f nm) must exceed λ min (%.1f nm).", lamMax, lamMin);
            end
            nPts = floor((lamMax - lamMin) / step) + 1;
            if nPts > 20000
                error("Visualize:TooManyLambda", ...
                    "The requested grid has %d wavelengths (limit 20000); increase the step.", nPts);
            end
            lam = lamMin:step:lamMax;
            if lam(end) < lamMax, lam(end+1) = lamMax; end
        end

        function [hasModel, targets] = localModelInfo(obj, simBranch)
            hasModel = false; targets = strings(1, 0);
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "visExport")
                ve = obj.fig.UserData.visExport;
                if isfield(ve, "modelLoaded") && ve.modelLoaded && isfield(ve, "model") && ~isempty(ve.model)
                    hasModel = true;
                    if isfield(ve.model, "targetNames")
                        targets = string(ve.model.targetNames);
                    end
                end
            end
            if ~hasModel && obj.session.modelLoaded && ~isempty(obj.session.model)
                hasModel = true;
                if isfield(obj.session.model, "targetNames")
                    targets = string(obj.session.model.targetNames);
                end
            end
            if isempty(targets) && isfield(simBranch, "spectralFields")
                targets = string(simBranch.spectralFields);
            end
        end

        function lLaser = localLaserWl(obj, db)
            lLaser = 785;
            for b = ["Sim", "Interp", "Pred"]
                if isfield(db, b) && isfield(db.(b), "LaserWl") && ~isempty(db.(b).LaserWl)
                    val = double(db.(b).LaserWl(1));
                    if isfinite(val) && val > 0
                        lLaser = val;
                        return;
                    end
                end
            end
        end

        function info = describeBranch(obj, S)
            info = struct("n", 0, "isGridded", false, "gridSize", [0 0], ...
                "spectralFields", {{}}, "scalarFields", {{}}, ...
                "pRange", [NaN NaN], "rRange", [NaN NaN], "lambdaRange", [NaN NaN]);
            if ~isstruct(S) || ~isscalar(S) || ~isfield(S, "period") || ~isfield(S, "radius") ...
                    || isempty(S.period)
                return;
            end
            P = double(S.period(:));
            R = double(S.radius(:));
            n = numel(P);
            info.n = n;
            fin = isfinite(P) & isfinite(R);
            if any(fin)
                info.pRange = [min(P(fin)), max(P(fin))];
                info.rRange = [min(R(fin)), max(R(fin))];
                [isGrid, pU, rU] = detectPRGrid(P(fin), R(fin));
                info.isGridded = isGrid;
                if isGrid
                    info.gridSize = [numel(rU), numel(pU)];
                end
            end
            if isfield(S, "lambda") && isnumeric(S.lambda) && ~isempty(S.lambda)
                lam = double(S.lambda(isfinite(S.lambda)));
                if ~isempty(lam)
                    lr = [min(lam), max(lam)];
                    if lr(2) < 10, lr = lr * 1e3; end
                    info.lambdaRange = lr;
                end
            end
            [spec, scal] = obj.classifyFields(S, n);
            info.spectralFields = cellstr(spec);
            info.scalarFields = cellstr(scal);
        end

        function [spec, scal] = classifyFields(~, S, n)
            meta = ["period", "radius", "lambda", "lambda_nm", "RamanShift", ...
                    "LaserWl", "lambda_exc_nm", "RamanWindow", "RamanWindowEffective", ...
                    "p", "r", "particle_r", "f"];
            fnames = string(fieldnames(S));
            spec = strings(1, 0); scal = strings(1, 0);
            for i = 1:numel(fnames)
                fn = fnames(i);
                if ismember(fn, meta), continue; end
                v = S.(fn);
                if ~isnumeric(v), continue; end
                if size(v, 1) == n && size(v, 2) == 1
                    scal(end+1) = fn; %#ok<AGROW>
                elseif size(v, 1) == n && size(v, 2) > 1
                    spec(end+1) = fn; %#ok<AGROW>
                end
            end
            pref = contains(scal, ["_laser", "_avg", "_analyte"]) | startsWith(scal, ["BEE_", "AEE_"]);
            scal = [scal(pref), scal(~pref)];
        end

        function cmap = loadColormapSafe(~, n, doFlip)
            try
                cmap = loadColormap("AuroraAustralis.txt", n);
            catch
                cmap = parula(n);
            end
            if doFlip, cmap = flipud(cmap); end
        end

        function [ok, model, ri] = ensureModelAndRi(obj, rep)
            model = obj.session.model;
            ri = obj.session.ri;
            if ~isempty(model) && ~isempty(ri)
                ok = true; return;
            end
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "app") ...
                    && isfield(obj.fig.UserData.app, "ensureVisExportModelAndRi")
                [ok, model, ri] = obj.fig.UserData.app.ensureVisExportModelAndRi(obj.htmlComponent, rep);
            else
                ok = ~isempty(model) && ~isempty(ri);
            end
        end

        function syncTracesToFig(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if ~isfield(obj.fig.UserData, "visualize")
                    obj.fig.UserData.visualize = struct();
                end
                obj.fig.UserData.visualize.traces = obj.traces;
            end
        end

        function resizeVisPanel(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                try
                    resizeVisualizePanel(obj.fig);
                catch
                end
            end
        end

        function db = getDb(obj)
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "db") ...
                    && isstruct(obj.fig.UserData.db)
                db = obj.fig.UserData.db;
            else
                db = obj.session.db;
            end
        end

        function ax = getAx1D(obj)
            ax = obj.ax1D;
            if (isempty(ax) || ~isvalid(ax)) && ~isempty(obj.fig) && isvalid(obj.fig) ...
                    && isfield(obj.fig.UserData, "handles") && isfield(obj.fig.UserData.handles, "visualizeAx1D")
                ax = obj.fig.UserData.handles.visualizeAx1D;
            end
        end

        function ax = getAx2D(obj)
            ax = obj.ax2D;
            if (isempty(ax) || ~isvalid(ax)) && ~isempty(obj.fig) && isvalid(obj.fig) ...
                    && isfield(obj.fig.UserData, "handles") && isfield(obj.fig.UserData.handles, "visualizeAx2D")
                ax = obj.fig.UserData.handles.visualizeAx2D;
            end
        end

        function v = getViewer(obj)
            v = obj.viewer;
            if (isempty(v) || ~isvalid(v)) && ~isempty(obj.fig) && isvalid(obj.fig) ...
                    && isfield(obj.fig.UserData, "handles") && isfield(obj.fig.UserData.handles, "visualizeViewer")
                v = obj.fig.UserData.handles.visualizeViewer;
            end
        end

        function h = getHandle(obj, key)
            h = [];
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "handles") ...
                    && isfield(obj.fig.UserData.handles, key)
                h = obj.fig.UserData.handles.(key);
            end
        end

        function setRunning(obj, isRunning)
            if ~isempty(obj.fig) && isvalid(obj.fig)
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "setProcessRunning")
                    obj.fig.UserData.app.setProcessRunning(isRunning, "Visualize");
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.isRunning = logical(isRunning);
                end
            end
            obj.session.setProcessRunning(isRunning, "Visualize");
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
                    obj.fig.UserData.app.notifyProcessStopped("Visualize", msg);
                else
                    obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
                end
            else
                obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
            end
        end

        function rep = makeReporter(obj)
            rep = ProgressReporter.fromCallback( ...
                @(type, step, data) obj.sendToHTML("Progress", data));
            rep.StopCheckFcn = @() obj.isStopRequested();
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

        function s = safeStruct(~, parent, fieldName)
            s = struct();
            if isfield(parent, fieldName) && isstruct(parent.(fieldName))
                s = parent.(fieldName);
            end
        end
    end
end
