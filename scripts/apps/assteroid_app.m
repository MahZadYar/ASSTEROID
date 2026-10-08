function figOut = assteroid_app(workFolder)
%assteroid_app  Launch unified ASSTEROID application.
%
%   assteroid_app() opens a six-stage tabbed interface for ASSTEROID:
%   Adaptive Sampling, Surrogate Training, Exploration and Refinement for
%   Optimal Inverse Design.
%
%     Stage 1 — Import & Database      (Data ingest, QA)
%     Stage 2 — Adaptive Sampling      (rejection-sampling new coordinates)
%     Stage 3 — DNN Training           (prepare + train + evaluate)
%     Stage 4 — Prediction             (dense prediction / interpolation)
%     Stage 5 — Optimization           (MultiStart maxima localization)
%     Stage 6 — Visualize              (1D spectra / 2D maps / 3D volumes)
%
%   Each tab contains a control panel (uihtml) on the left and a
%   visualization area on the right. All tabs delegate to the shared
%   orchestration layer (src/orchestration/) via ProgressReporter, so
%   the same workflows run identically from CLI scripts.
%
%   Syntax:
%       assteroid_app
%       assteroid_app(workFolder)
%       fig = assteroid_app(...)
%
%   Inputs:
%       workFolder - (optional) path to the working directory. The app
%                    sets its workDir to this path and attempts to load
%                    database.mat from it on startup. Defaults to pwd.
%
%   Example:
%       assteroid_app("C:/Projects/MyExperiment")
%
%   See also: ASSTEROID, start_app, importSweepConfig, trainingConfig,
%             localizeMaximaConfig, adaptiveSamplingConfig, predictionVisConfig

    arguments
        workFolder (1,1) string = string(pwd)
    end
    workFolder = string(workFolder);

    % Sanitize path: legacy folder must never shadow src/
    codebaseRoot = fileparts(fileparts(fileparts(mfilename("fullpath"))));
    legacyDir = fullfile(codebaseRoot, "legacy");
    if contains(path, legacyDir)
        try rmpath(legacyDir); catch; end
    end

    % Singleton guard: if an instance is already running, focus it
    existing = findall(groot, "Tag", "ASSTEROID_MAIN_APP");
    if ~isempty(existing)
        existing = existing(isvalid(existing));
    end
    if isempty(existing)
        allFigs = findall(groot, "Type", "figure");
        for k = 1:numel(allFigs)
            if isvalid(allFigs(k)) && contains(string(allFigs(k).Name), "ASSTEROID")
                existing = allFigs(k);
                break;
            end
        end
    end
    if ~isempty(existing) && isvalid(existing(1))
        fig = existing(1);
        uistack(fig, "top");
        try focus(fig); catch; end
        if nargout > 0
            figOut = fig;
        end
        return;
    end

    %% Figure ----------------------------------------------------------------
    screenSize = get(0, "ScreenSize");
    figW = min(1700, screenSize(3) - 80);
    figH = min(1020, screenSize(4) - 80);

    fig = uifigure("Name", "☄️ ASSTEROID — Optimal Inverse Design Platform", ...
        "Tag", "ASSTEROID_MAIN_APP", ...
        "Position", [(screenSize(3)-figW)/2, (screenSize(4)-figH)/2, figW, figH], ...
        "Color", [6, 8, 18]/255, ...
        "Resize", "on", ...
        "CloseRequestFcn", @onAppClose);
    figOut = fig;

    %% Shared state stored on figure -----------------------------------------
    session = AssteroidSession(workFolder);
    fig.UserData = struct( ...
        "session",      session, ...
        "workDir",      workFolder, ...
        "handles",      struct(), ...
        "db",           struct(), ...
        "dbFile",       "", ...
        "dbDirty",      false, ...
        "process",      struct("isRunning", false, "stopRequested", false, "activeStage", ""));
    fig.UserData.app = struct( ...
        "broadcastDbStatus", @() broadcastDbStatus(fig), ...
        "isProcessStopRequested", @() isProcessStopRequested(fig), ...
        "setProcessRunning", @(r, s) setProcessRunning(fig, r, s), ...
        "requestProcessStop", @() requestProcessStop(fig), ...
        "notifyProcessStopped", @(s, m) notifyProcessStopped(fig, s, m), ...
        "saveDbFile", @() saveDbFile(fig), ...
        "markDbDirty", @() markDbDirty(fig), ...
        "resolveDbPaths", @() resolveDbPaths(fig), ...
        "resolveAnalyteFile", @() resolveAnalyteFile(fig), ...
        "openInVisualizeTab", @(b, m) openInVisualizeTab(fig, b, m), ...
        "ensureVisExportModelAndRi", @(h, r) ensureVisExportModelAndRi(fig, h, r));

    %% Main tab group ---------------------------------------------------------
    tabGroup = uitabgroup(fig, ...
        "Units", "normalized", ...
        "Position", [0 0 1 1], ...
        "SelectionChangedFcn", @(src, ev) handleMainTabSelection(src, ev, fig));

    tabColors = [6, 8, 18]/255;

    %% ====================================================================
    %  STAGE 0 — Database Manager
    %  ====================================================================
    tab0 = uitab(tabGroup, "Title", "💾 0 Database", "BackgroundColor", tabColors);
    fig.UserData.handles.dbTab = tab0;
    [h0, ~] = buildImportTabLayout(tab0, "database_tab.html");
    dbController = DatabaseController(session, fig, h0);
    fig.UserData.handles.dbController = dbController;
    h0.HTMLEventReceivedFcn = @(src, ev) handleDatabaseEvent(src, ev, fig);
    fig.UserData.handles.dbHtml = h0;

    %% ====================================================================
    %  STAGE 1 — Import & Database
    %  ====================================================================
    tab1 = uitab(tabGroup, "Title", "📥 1 Import", "BackgroundColor", tabColors);
    [h1, visPanel1] = buildImportTabLayout(tab1, "import_tab.html");
    importController = ImportController(session, fig, h1, visPanel1);
    fig.UserData.handles.importController = importController;
    fig.UserData.handles.importHtml = h1;
    fig.UserData.handles.importVisPanel = visPanel1;
    h1.HTMLEventReceivedFcn = @(src, ev) handleImportEvent(src, ev, fig, visPanel1);

    %% ====================================================================
    %  STAGE 2 — Adaptive Sampling
    %  ====================================================================
    tab2 = uitab(tabGroup, "Title", "🎯 2 Sampling", "BackgroundColor", tabColors);
    [h2, visPanel2] = buildTabLayout(tab2, "adaptive_sampling_app.html");

    ax2 = uiaxes(visPanel2, ...
        "Units",     "normalized", ...
        "Position",  [0.05 0.05 0.9 0.9], ...
        "Color",     [12, 16, 32]/255, ...
        "XColor",    [160, 178, 214]/255, ...
        "YColor",    [160, 178, 214]/255, ...
        "GridColor", [46, 62, 98]/255, ...
        "GridAlpha", 0.6, ...
        "Box",       "on");
    ax2.XGrid = "on"; ax2.YGrid = "on";
    xlabel(ax2, "Period (nm)", "Color", [248, 248, 248]/255, "FontWeight", "bold");
    ylabel(ax2, "Radius (nm)", "Color", [248, 248, 248]/255, "FontWeight", "bold");
    title(ax2, "Sampling Density & Generated Points", "Color", [248, 248, 248]/255);

    samplingController = SamplingController(session, fig, h2, ax2);
    fig.UserData.handles.samplingController = samplingController;
    fig.UserData.handles.samplingAx = ax2;
    fig.UserData.handles.samplingHtml = h2;
    fig.UserData.sampling = struct( ...
        "config", [], "samples", [], "density", [], ...
        "result", [], "dataLoaded", false, "samplingComplete", false);

    h2.HTMLEventReceivedFcn = @(src, ev) handleSamplingEvent(src, ev, fig);

    %% ====================================================================
    %  STAGE 3 — DNN Training
    %  ====================================================================
    tab3 = uitab(tabGroup, "Title", "🧠 3 Training", "BackgroundColor", tabColors);
    [h3, visPanel3] = buildTabLayout(tab3, "training_tab.html");
    trainController = TrainingController(session, fig, h3, visPanel3);
    fig.UserData.handles.trainingController = trainController;
    fig.UserData.handles.trainingHtml = h3;
    fig.UserData.handles.trainingVisPanel = visPanel3;
    h3.HTMLEventReceivedFcn = @(src, ev) handleTrainingEvent(src, ev, fig, visPanel3);

    %% ====================================================================
    %  STAGE 4 — Prediction
    %  ====================================================================
    tab4 = uitab(tabGroup, "Title", "🔮 4 Predict", "BackgroundColor", tabColors);
    % Full-width HTML: prediction / interpolation only. Rendering lives in
    % Stage 6 (Visualize).
    [h4, ~] = buildImportTabLayout(tab4, "visualization_export_tab.html");
    predController = PredictionController(session, fig, h4);
    fig.UserData.handles.predController = predController;
    fig.UserData.handles.visExportHtml = h4;
    fig.UserData.training = struct("isRunning", false, "stopRequested", false);

    % Initialize visualization & export state
    fig.UserData.visExport = struct( ...
        "allData", [], "predictionsLoaded", false, ...
        "model", [], "ri", [], "modelLoaded", false, ...
        "analyteSpectrum", struct());

    h4.HTMLEventReceivedFcn = @(src, ev) handleVisExportEvent(src, ev, fig);

    %% ====================================================================
    %  STAGE 5 — Optimization
    %  ====================================================================
    tab5 = uitab(tabGroup, "Title", "🔍 5 Optimize", "BackgroundColor", tabColors);
    [h5, visPanel5] = buildOptimizeTabLayout(tab5, "optimization_tab.html");

    % Create axes in visualization panel
    ax5opt = uiaxes(visPanel5, ...
        "Units",     "normalized", ...
        "Position",  [0.05 0.05 0.9 0.9], ...
        "Color",     [12, 16, 32]/255, ...
        "XColor",    [160, 178, 214]/255, ...
        "YColor",    [160, 178, 214]/255, ...
        "GridColor", [46, 62, 98]/255, ...
        "GridAlpha", 0.6, ...
        "Box",       "on");
    ax5opt.XGrid = "on"; ax5opt.YGrid = "on";
    xlabel(ax5opt, "Period (nm)", "Color", [248, 248, 248]/255, "FontWeight", "bold");
    ylabel(ax5opt, "Radius (nm)", "Color", [248, 248, 248]/255, "FontWeight", "bold");
    title(ax5opt, "Optimization Landscape", "Color", [248, 248, 248]/255);

    optController = OptimizeController(session, fig, h5, ax5opt);
    fig.UserData.handles.optimizeController = optController;
    fig.UserData.handles.optimizeAx = ax5opt;
    fig.UserData.handles.optimizeHtml = h5;
    fig.UserData.handles.optimizeLeft = h5;
    fig.UserData.handles.optimizeRight = h5;

    h5.HTMLEventReceivedFcn = @(src, ev) handleOptimizeEvent(src, ev, fig, ax5opt);

    %% ====================================================================
    %  STAGE 6 — Visualize (1D spectra / 2D maps / 3D volumes)
    %  ====================================================================
    tab6 = uitab(tabGroup, "Title", "🌌 6 Visualize", "BackgroundColor", tabColors);
    [h6, visPanel6] = buildTabLayout(tab6, "visualize_tab.html");
    visPanel6.AutoResizeChildren = "off";
    visPanel6.SizeChangedFcn = @(~, ~) resizeVisualizePanel(fig);

    % Pixel-unit tab group resized explicitly (deferred layout in uitabs)
    visTabGroup6 = uitabgroup(visPanel6, ...
        "Units", "pixels", ...
        "Position", [1, 1, max(10, round(visPanel6.Position(3))), max(10, round(visPanel6.Position(4)))]);

    tab6a = uitab(visTabGroup6, "Title", "1D Spectra", "BackgroundColor", [12, 16, 32]/255);
    ax6a = createDarkAxes(tab6a, "Wavelength (nm)", "Metric value", "1D Spectra");

    tab6b = uitab(visTabGroup6, "Title", "2D Map", "BackgroundColor", [12, 16, 32]/255);
    ax6b = createDarkAxes(tab6b, "Period (nm)", "Radius (nm)", "2D Map");

    tab6c = uitab(visTabGroup6, "Title", "3D Volume", "BackgroundColor", [12, 16, 32]/255);
    viewer6 = viewer3d(tab6c, ...
        "Units", "normalized", ...
        "Position", [0 0 1 1], ...
        "BackgroundColor", "black", "BackgroundGradient", "off");

    fig.UserData.handles.mainTabGroup      = tabGroup;
    fig.UserData.handles.visualizeHtml     = h6;
    fig.UserData.handles.visualizeTab      = tab6;
    fig.UserData.handles.visualizePanel    = visPanel6;
    fig.UserData.handles.visualizeTabGroup = visTabGroup6;
    fig.UserData.handles.visualizeTab1D    = tab6a;
    fig.UserData.handles.visualizeTab2D    = tab6b;
    fig.UserData.handles.visualizeTab3D    = tab6c;
    fig.UserData.handles.visualizeAx1D     = ax6a;
    fig.UserData.handles.visualizeAx2D     = ax6b;
    fig.UserData.handles.visualizeViewer   = viewer6;

    visController = VisualizeController(session, fig, h6, ax6a, ax6b, viewer6);
    fig.UserData.handles.visController     = visController;

    % Transient render state (never written to the database)
    fig.UserData.visualize = struct( ...
        "dataPredictor", [], "dataPredictorKey", "", ...
        "traces", emptyVisualizeTraces());

    h6.HTMLEventReceivedFcn = @(src, ev) handleVisualizeEvent(src, ev, fig);

    %% Store all HTML handles -------------------------------------------------
    fig.UserData.handles.htmlPanels = [h0, h1, h2, h3, h4, h5, h5, h6];

    %% Ensure Stage 0 Database tab is the initially selected tab --------------
    tabGroup.SelectedTab = tab0;

    %% Load colormap once for reuse -------------------------------------------
    loadCustomColormap(fig);

    %% Attempt RI auto-load ---------------------------------------------------
    loadRefractiveIndexData(fig);

    %% Attempt DB auto-load ---------------------------------------------------
    defaultDb = fullfile(workFolder, "database.mat");
    if isfile(defaultDb)
        loadDbFile(fig, defaultDb);
    end

    if nargout < 1
        clear figOut;
    end
end

%% ########################################################################
%   STAGE 0 — DATABASE MANAGER HANDLERS
%  ########################################################################
function handleDatabaseEvent(src, event, fig)
%handleDatabaseEvent  Dispatch events from the Database tab HTML panel.
    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "dbController") ...
            && ~isempty(fig.UserData.handles.dbController)
        fig.UserData.handles.dbController.handleEvent(event.HTMLEventName, event.HTMLEventData);
        return;
    end
    name = event.HTMLEventName;
    data = event.HTMLEventData;
    try
        switch name
            case "BrowseDbFile"
                [file, path] = uigetfile( ...
                    {"*.mat", "MAT Files"}, "Select Database File", fig.UserData.workDir);
                if file ~= 0
                    fullPath = fullfile(path, file);
                    sendEventToHTMLSource(src, "BrowseResult", ...
                        struct("field", "dbFile", "path", fullPath));
                end

            case "LoadDatabase"
                dbPath = "";
                if isstruct(data) && isfield(data, "path")
                    dbPath = string(data.path);
                end
                if dbPath == ""
                    sendEventToHTMLSource(src, "Error", "No file path specified.");
                    return
                end
                if ~isfile(dbPath)
                    sendEventToHTMLSource(src, "Error", "File not found: " + dbPath);
                    return
                end
                loadDbFile(fig, dbPath);
                if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "mainTabGroup") && ...
                   isfield(fig.UserData.handles, "dbTab") && isvalid(fig.UserData.handles.dbTab)
                    fig.UserData.handles.mainTabGroup.SelectedTab = fig.UserData.handles.dbTab;
                end
                sendEventToHTMLSource(src, "LoadComplete", ...
                    sprintf("Database loaded from %s", dbPath));

            case "SaveDatabase"
                if fig.UserData.dbFile == ""
                    [file, path] = uiputfile( ...
                        {"*.mat", "MAT Files"}, "Save Database As", ...
                        fullfile(fig.UserData.workDir, "database.mat"));
                    if file == 0, return; end
                    fig.UserData.dbFile = string(fullfile(path, file));
                end
                saveDbFile(fig);
                sendEventToHTMLSource(src, "SaveComplete", ...
                    sprintf("Database saved to %s", fig.UserData.dbFile));

            case "BrowseSaveAs"
                [file, path] = uiputfile( ...
                    {"*.mat", "MAT Files"}, "Save Database As", ...
                    fullfile(fig.UserData.workDir, "database.mat"));
                if file ~= 0
                    fig.UserData.dbFile = string(fullfile(path, file));
                    saveDbFile(fig);
                    sendEventToHTMLSource(src, "SaveComplete", ...
                        sprintf("Database saved to %s", fig.UserData.dbFile));
                end

            case "NewDatabase"
                fig.UserData.db = createDatabaseStruct();
                fig.UserData.dbFile = "";
                markDbDirty(fig);
                sendEventToHTMLSource(src, "LoadComplete", "New empty database created.");

            case "UpdateMetadata"
                if ~isstruct(data), return; end
                if ~isstruct(fig.UserData.db) || ~isfield(fig.UserData.db, "Global")
                    fig.UserData.db = createDatabaseStruct();
                end
                g = fig.UserData.db.Global;
                if isfield(data, "projectName"), g.ProjectName = string(data.projectName); end
                if isfield(data, "authors"),     g.Authors     = string(data.authors);     end
                if isfield(data, "description"), g.Description = string(data.description); end
                if isfield(data, "paperDOI"),    g.PaperDOI    = string(data.paperDOI);    end
                fig.UserData.db.Global = g;
                markDbDirty(fig);

            case "ExportHDF5"
                if ~isstruct(fig.UserData.db) || ~isfield(fig.UserData.db, "Global")
                    sendEventToHTMLSource(src, "Error", "No database loaded.");
                    return
                end
                outDir = fig.UserData.workDir;
                if fig.UserData.dbFile ~= ""
                    outDir = fileparts(fig.UserData.dbFile);
                end
                h5File = fullfile(outDir, "sers_database.h5");
                try
                    exportDatabaseToHDF5(fig.UserData.db, h5File);
                    sendEventToHTMLSource(src, "ExportComplete", ...
                        sprintf("HDF5 exported to %s", h5File));
                catch ME_exp
                    sendEventToHTMLSource(src, "Error", ME_exp.message);
                end

            case "ExportONNX"
                if ~isstruct(fig.UserData.db) || ~isfield(fig.UserData.db, "Model")
                    sendEventToHTMLSource(src, "Error", "No model in database.");
                    return
                end
                outDir = fig.UserData.workDir;
                if fig.UserData.dbFile ~= ""
                    outDir = fileparts(fig.UserData.dbFile);
                end
                onnxFile = fullfile(outDir, "sers_model.onnx");
                try
                    exportModelToOnnx(fig.UserData.db, onnxFile);
                    sendEventToHTMLSource(src, "ExportComplete", ...
                        sprintf("ONNX exported to %s", onnxFile));
                catch ME_exp
                    sendEventToHTMLSource(src, "Error", ME_exp.message);
                end

            case "BrowseBranchFile"
                branchName = string(data.branch);
                fieldId = string(data.field);
                filterSpec = getBranchFileFilter(branchName);
                [file, path] = uigetfile(filterSpec, ...
                    "Select file for " + branchName, fig.UserData.workDir);
                if file ~= 0
                    sendEventToHTMLSource(src, "BrowseResult", ...
                        struct("field", fieldId, "path", fullfile(path, file)));
                end

            case "LoadBranch"
                branchName = string(data.branch);
                filePath = string(data.path);
                if ~isfile(filePath)
                    sendEventToHTMLSource(src, "Error", "File not found: " + filePath);
                    return
                end
                loadBranchData(fig, branchName, filePath);
                sendEventToHTMLSource(src, "LoadComplete", ...
                    sprintf("%s branch loaded from %s", branchName, filePath));

            case "ClearBranch"
                branchName = string(data.branch);
                clearBranchData(fig, branchName);
                sendEventToHTMLSource(src, "LoadComplete", ...
                    sprintf("%s branch cleared.", branchName));

            case "BrowseWorkDir"
                selDir = uigetdir(fig.UserData.workDir, "Select Working Directory");
                if selDir ~= 0
                    fig.UserData.workDir = string(selDir);
                    if isfield(fig.UserData.db, "Global")
                        fig.UserData.db.Global.WorkDir = fig.UserData.workDir;
                    end
                    markDbDirty(fig);
                end

            case "InspectDb"
                treeData = serializeDbToTree(fig.UserData.db, "db", 3);
                sendEventToHTMLSource(src, "DbTree", treeData);

            case "StopProcess"
                requestProcessStop(fig);

            otherwise
                fprintf("[Database] Unknown event: %s\n", name);
        end
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Database", "Database operation terminated by user.");
        else
            sendEventToHTMLSource(src, "Error", ME.message);
            fprintf("[Database] Error in %s: %s\n", name, ME.message);
        end
    end
end

%% ========================================================================
%   DATABASE HELPER FUNCTIONS
%  ========================================================================
function loadDbFile(fig, dbPath)
%loadDbFile  Load a database .mat file into the app state using DatabaseEngine.
    reporter = @(msg, type) sendDbLogMessage(fig, msg, type);
    [db, info] = DatabaseEngine.loadDatabase(dbPath, reporter);

    fig.UserData.db = db;
    fig.UserData.dbFile = string(dbPath);
    fig.UserData.dbDirty = false;

    % Cache model into visExport if db has populated Model
    if isfield(fig.UserData.db, "Model") && isstruct(fig.UserData.db.Model)
        if isfield(fig.UserData.db.Model, "Model") && isstruct(fig.UserData.db.Model.Model)
            fig.UserData.visExport.model = fig.UserData.db.Model.Model;
            fig.UserData.visExport.modelLoaded = true;
        elseif isfield(fig.UserData.db.Model, "Net") && ~isempty(fig.UserData.db.Model.Net)
            fig.UserData.visExport.model = fig.UserData.db.Model;
            fig.UserData.visExport.modelLoaded = true;
        end
    end

    % Cache RI into visExport if db has populated RI
    if isfield(fig.UserData.db, "RI") && isstruct(fig.UserData.db.RI)
        fig.UserData.visExport.ri = resolveRefractiveIndexStruct(fig);
    end

    % Update workDir from db if available
    if isfield(fig.UserData.db, "Global") && isfield(fig.UserData.db.Global, "WorkDir") ...
            && strlength(string(fig.UserData.db.Global.WorkDir)) > 0
        fig.UserData.workDir = string(fig.UserData.db.Global.WorkDir);
    else
        fig.UserData.workDir = string(fileparts(dbPath));
    end

    % Sync with AssteroidSession if available
    if isfield(fig.UserData, "session") && ~isempty(fig.UserData.session) && isvalid(fig.UserData.session)
        fig.UserData.session.db = db;
        fig.UserData.session.dbFile = string(dbPath);
        fig.UserData.session.dbDirty = false;
        fig.UserData.session.workDir = fig.UserData.workDir;
        if isfield(db, "Model") && isstruct(db.Model) && ...
                ((isfield(db.Model, "Model") && ~isempty(db.Model.Model)) || ...
                 (isfield(db.Model, "Net") && ~isempty(db.Model.Net)))
            fig.UserData.session.modelLoaded = true;
        end
        if isfield(db, "RI") && isstruct(db.RI) && isfield(db.RI, "lambda") && ~isempty(db.RI.lambda)
            fig.UserData.session.riLoaded = true;
        end
    end

    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "mainTabGroup") && ...
       isfield(fig.UserData.handles, "dbTab") && isvalid(fig.UserData.handles.dbTab)
        fig.UserData.handles.mainTabGroup.SelectedTab = fig.UserData.handles.dbTab;
    end

    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "dbHtml") ...
            && isvalid(fig.UserData.handles.dbHtml)
        sendEventToHTMLSource(fig.UserData.handles.dbHtml, "LoadComplete", ...
            sprintf("Database loaded: %s (%.2f s, %s)", dbPath, info.elapsed, info.sizeString));
    end

    broadcastDbStatus(fig);
end

function saveDbFile(fig)
%saveDbFile  Persist the in-memory db struct to disk using DatabaseEngine.
    if fig.UserData.dbFile == ""
        error("saveDbFile:NoPath", "No save path set. Use Save As first.");
    end

    reporter = @(msg, type) sendDbLogMessage(fig, msg, type);
    info = DatabaseEngine.saveDatabase(fig.UserData.db, fig.UserData.dbFile, reporter);

    fig.UserData.dbDirty = false;
    if isfield(fig.UserData, "session") && ~isempty(fig.UserData.session) && isvalid(fig.UserData.session)
        fig.UserData.session.dbDirty = false;
    end

    if isfield(fig.UserData.handles, "dbHtml") && isvalid(fig.UserData.handles.dbHtml)
        sendEventToHTMLSource(fig.UserData.handles.dbHtml, "SaveComplete", ...
            sprintf("Database saved in %.2f s (Size: %s, %.1f MB/s).", ...
                info.elapsed, info.sizeString, info.rateMBs));
    end

    broadcastDbStatus(fig);
end

function sendDbLogMessage(fig, msg, ~)
%sendDbLogMessage  Forward database engine log notifications to UI panels.
    if ~isvalid(fig), return; end
    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "htmlPanels")
        panels = fig.UserData.handles.htmlPanels;
        for i = 1:numel(panels)
            if isvalid(panels(i))
                try
                    sendEventToHTMLSource(panels(i), "Progress", ...
                        struct("message", string(msg), "fraction", []));
                catch
                end
            end
        end
    end
    fprintf("[DatabaseEngine] %s\n", msg);
end

function markDbDirty(fig)
%markDbDirty  Flag the database as having unsaved changes.
    fig.UserData.dbDirty = true;
    if isfield(fig.UserData, "session") && ~isempty(fig.UserData.session) && isvalid(fig.UserData.session)
        fig.UserData.session.db = fig.UserData.db;
        fig.UserData.session.dbDirty = true;
    end
    broadcastDbStatus(fig);
end

function broadcastDbStatus(fig)
%broadcastDbStatus  Push DB status to all HTML panels.
    if ~isvalid(fig), return; end
    status = buildDbStatusStruct(fig);

    % Update the database tab itself
    if isfield(fig.UserData.handles, "dbHtml") && isvalid(fig.UserData.handles.dbHtml)
        sendEventToHTMLSource(fig.UserData.handles.dbHtml, "DbStatus", status);
    end

    % Send auto-fill data to pipeline tabs
    if isfield(fig.UserData.handles, "htmlPanels")
        autoFill = buildAutoFillStruct(fig, status);
        panels = fig.UserData.handles.htmlPanels;
        for i = 1:numel(panels)
            if isvalid(panels(i))
                if isfield(fig.UserData.handles, "dbHtml") && panels(i) == fig.UserData.handles.dbHtml
                    continue;
                end
                sendEventToHTMLSource(panels(i), "DbAutoFill", autoFill);
                sendEventToHTMLSource(panels(i), "DbStatus", status);
            end
        end
    end
end

function status = buildDbStatusStruct(fig)
%buildDbStatusStruct  Build a struct summarizing the current DB state.
    db = fig.UserData.db;
    if (isempty(db) || ~isstruct(db)) && isfield(fig.UserData, "session") ...
            && ~isempty(fig.UserData.session) && isvalid(fig.UserData.session) ...
            && ~isempty(fig.UserData.session.db) && isstruct(fig.UserData.session.db)
        db = fig.UserData.session.db;
        fig.UserData.db = db;
        fig.UserData.dbFile = fig.UserData.session.dbFile;
        fig.UserData.dbDirty = fig.UserData.session.dbDirty;
        fig.UserData.workDir = fig.UserData.session.workDir;
    end

    status = struct( ...
        "dbFile",        fig.UserData.dbFile, ...
        "dbDirty",       fig.UserData.dbDirty, ...
        "projectName",   "", ...
        "authors",       "", ...
        "description",   "", ...
        "paperDOI",      "", ...
        "hasSimData",    false, ...
        "simEntries",    0, ...
        "hasModel",      false, ...
        "modelFile",     "", ...
        "hasPredictions", false, ...
        "predEntries",   0, ...
        "hasInterp",     false, ...
        "interpEntries", 0, ...
        "hasRI",         false, ...
        "hasAnalyte",    false, ...
        "analyteFile",   "", ...
        "hasOptima",     false, ...
        "optimaCount",   0, ...
        "workDir",       fig.UserData.workDir, ...
        "simFile",       "");

    if ~isstruct(db), return; end

    % Global metadata
    if isfield(db, "Global")
        g = db.Global;
        if isfield(g, "ProjectName"), status.projectName = string(g.ProjectName); end
        if isfield(g, "Authors"),     status.authors     = string(g.Authors);     end
        if isfield(g, "Description"), status.description = string(g.Description); end
        if isfield(g, "PaperDOI"),    status.paperDOI    = string(g.PaperDOI);    end
        if isfield(g, "SimFile"),     status.simFile      = string(g.SimFile);    end
    end

    % Sim branch
    if isfield(db, "Sim") && isstruct(db.Sim)
        n = structRowCount(db.Sim);
        status.simEntries = n;
        status.hasSimData = n > 0;
    end

    % Model branch
    if isfield(db, "Model") && isstruct(db.Model)
        m = db.Model;
        hasNet = (isfield(m, "Net") && ~isempty(m.Net)) || ...
                 (isfield(m, "Model") && ~isempty(m.Model));
        hasNetFile = isfield(m, "NetFile") && strlength(string(m.NetFile)) > 0;
        status.hasModel = hasNet || hasNetFile;
        if hasNetFile
            status.modelFile = string(m.NetFile);
        end
    end

    % Predictions branch
    if isfield(db, "Pred") && isstruct(db.Pred)
        n = structRowCount(db.Pred);
        status.predEntries = n;
        status.hasPredictions = n > 0;
    end

    % Interpolation branch (gridded resample of db.Sim)
    if isfield(db, "Interp") && isstruct(db.Interp)
        n = structRowCount(db.Interp);
        status.interpEntries = n;
        status.hasInterp = n > 0;
    end

    % RI branch
    if isfield(db, "RI") && isstruct(db.RI)
        hasLambda = isfield(db.RI, "lambda") && ~isempty(db.RI.lambda);
        status.hasRI = hasLambda;
    end

    % Analyte spectrum
    if isfield(db, "Global") && isfield(db.Global, "AnalyteSpectrumFile") ...
            && strlength(string(db.Global.AnalyteSpectrumFile)) > 0
        status.hasAnalyte = true;
        status.analyteFile = string(db.Global.AnalyteSpectrumFile);
    end

    % Optima branch
    if isfield(db, "Optima") && isstruct(db.Optima) && isfield(db.Optima, "period")
        nOpt = numel(db.Optima.period);
        status.hasOptima = nOpt > 0;
        status.optimaCount = nOpt;
    end
end

function af = buildAutoFillStruct(~, status)
%buildAutoFillStruct  Build the auto-fill payload for pipeline tabs.
    af = struct( ...
        "workDir",    status.workDir, ...
        "modelFile",  status.modelFile, ...
        "simFile",    status.simFile);

    % Derive simFile basename for rawDataFiles in training tab
    if strlength(status.simFile) > 0
        [~, name, ext] = fileparts(status.simFile);
        af.simFileBasename = name + ext;
    else
        af.simFileBasename = "";
    end
end

function node = serializeDbToTree(val, name, maxDepth)
%serializeDbToTree  Recursively serialize a MATLAB value into a tree struct.
%   Returns a struct with fields: name, type, size, value, children.
%   maxDepth limits recursion depth to avoid huge payloads.
    if nargin < 3, maxDepth = 4; end
    node = struct('name', string(name), 'type', '', 'size', '', ...
                  'value', '', 'children', {{}});

    if isstruct(val) && numel(val) == 1
        % Scalar struct — show fields as children
        node.type = 'struct';
        fns = fieldnames(val);
        node.size = sprintf('1×1 struct (%d fields)', numel(fns));
        if maxDepth > 0
            for k = 1:numel(fns)
                child = serializeDbToTree(val.(fns{k}), fns{k}, maxDepth - 1);
                node.children{end+1} = child;
            end
        else
            node.value = sprintf('{%s}', strjoin(string(fns), ', '));
        end

    elseif isstruct(val) && numel(val) > 1
        % Struct array
        node.type = 'struct[]';
        node.size = sprintf('%s struct (%d fields)', mat2str(size(val)), numel(fieldnames(val)));
        if maxDepth > 0
            nShow = min(numel(val), 5);
            for k = 1:nShow
                child = serializeDbToTree(val(k), sprintf('[%d]', k), maxDepth - 1);
                node.children{end+1} = child;
            end
            if numel(val) > nShow
                node.children{end+1} = struct('name', sprintf('... +%d more', numel(val) - nShow), ...
                    'type', '', 'size', '', 'value', '', 'children', {{}});
            end
        end

    elseif isnumeric(val) || islogical(val)
        node.type = class(val);
        node.size = mat2str(size(val));
        nEl = numel(val);
        if nEl == 0
            node.value = '[]';
        elseif nEl == 1
            node.value = num2str(val, '%.6g');
        elseif nEl <= 10
            node.value = mat2str(val, 6);
        else
            % Show first/last few
            flat = val(:)';
            head = flat(1:min(4, nEl));
            tail = flat(max(1, nEl-1):nEl);
            node.value = sprintf('[%s ... %s]', ...
                strjoin(string(num2str(head', '%.4g')), ' '), ...
                strjoin(string(num2str(tail', '%.4g')), ' '));
        end

    elseif ischar(val) || isstring(val)
        node.type = 'string';
        sv = string(val);
        if strlength(sv) > 120
            node.value = extractBefore(sv, 121) + "…";
        else
            node.value = sv;
        end
        node.size = sprintf('1×%d', strlength(sv));

    elseif iscell(val)
        node.type = 'cell';
        node.size = mat2str(size(val));
        if maxDepth > 0
            nShow = min(numel(val), 8);
            for k = 1:nShow
                child = serializeDbToTree(val{k}, sprintf('{%d}', k), maxDepth - 1);
                node.children{end+1} = child;
            end
            if numel(val) > nShow
                node.children{end+1} = struct('name', sprintf('... +%d more', numel(val) - nShow), ...
                    'type', '', 'size', '', 'value', '', 'children', {{}});
            end
        else
            node.value = sprintf('{%d elements}', numel(val));
        end

    elseif isa(val, 'dlnetwork') || isa(val, 'SeriesNetwork') || isa(val, 'DAGNetwork')
        node.type = class(val);
        try
            nLayers = numel(val.Layers);
            node.size = sprintf('%d layers', nLayers);
        catch
            node.size = '?';
        end
        node.value = '<neural network>';

    elseif isobject(val)
        node.type = class(val);
        node.size = mat2str(size(val));
        node.value = '<object>';

    elseif isa(val, 'function_handle')
        node.type = 'function_handle';
        node.value = func2str(val);

    else
        node.type = class(val);
        node.size = mat2str(size(val));
        node.value = '<unsupported>';
    end
end

function filterSpec = getBranchFileFilter(branchName)
%getBranchFileFilter  Return uigetfile filter spec for a database branch.
    switch branchName
        case "Sim"
            filterSpec = {"*.mat", "MAT Files (Simulation Data)"};
        case "Model"
            filterSpec = {"*.mat", "MAT Files (Trained Model)"};
        case "RI"
            filterSpec = {"*.csv;*.mat", "CSV or MAT Files (Refractive Index)"};
        case "Pred"
            filterSpec = {"*.mat", "MAT Files (Predictions)"};
        case "Analyte"
            filterSpec = {"*.dat;*.txt;*.csv;*.mat", "Spectrum Files"};
        otherwise
            filterSpec = {"*.*", "All Files"};
    end
end

function loadBranchData(fig, branchName, filePath)
%loadBranchData  Load a file into a specific branch of the database struct.
    switch branchName
        case "Sim"
            S = load(filePath);
            if isfield(S, "allData")
                soaData = S.allData;
            elseif isfield(S, "db") && isstruct(S.db) && isfield(S.db, "Sim")
                soaData = S.db.Sim;
            else
                error("loadBranchData:InvalidSim", ...
                    "File does not contain 'allData' or 'db.Sim'.");
            end
            fig.UserData.db.Sim = soaData;
            fig.UserData.db.Global.SimFile = string(filePath);

        case "Model"
            S = load(filePath);
            if isfield(S, "model") && isstruct(S.model)
                fig.UserData.db.Model.Model = S.model;
                if isfield(S.model, "net")
                    fig.UserData.db.Model.Net = S.model.net;
                end
                if isfield(S.model, "targetNames")
                    fig.UserData.db.Model.TargetNames = cellstr(S.model.targetNames);
                end
                fig.UserData.visExport.model = S.model;
                fig.UserData.visExport.modelLoaded = true;
                fig.UserData.visExport.ri = resolveRefractiveIndexStruct(fig);
            elseif isfield(S, "trainedModel")
                if isstruct(S.trainedModel) && isfield(S.trainedModel, "net")
                    fig.UserData.db.Model.Model = S.trainedModel;
                    fig.UserData.db.Model.Net = S.trainedModel.net;
                    fig.UserData.visExport.model = S.trainedModel;
                    fig.UserData.visExport.modelLoaded = true;
                    fig.UserData.visExport.ri = resolveRefractiveIndexStruct(fig);
                else
                    fig.UserData.db.Model.Net = S.trainedModel;
                end
            elseif isfield(S, "net")
                fig.UserData.db.Model.Net = S.net;
            elseif isfield(S, "db") && isstruct(S.db) && isfield(S.db, "Model")
                fig.UserData.db.Model = S.db.Model;
                if isfield(S.db.Model, "Model") && isstruct(S.db.Model.Model)
                    fig.UserData.visExport.model = S.db.Model.Model;
                    fig.UserData.visExport.modelLoaded = true;
                    fig.UserData.visExport.ri = resolveRefractiveIndexStruct(fig);
                end
            else
                error("loadBranchData:InvalidModel", ...
                    "File does not contain a recognized model variable.");
            end
            fig.UserData.db.Model.NetFile = string(filePath);

        case "RI"
            [~, ~, ext] = fileparts(filePath);
            if strcmpi(ext, ".csv")
                ri = load_gold_refractive_index(filePath);
                fig.UserData.db.RI = ri;
            elseif strcmpi(ext, ".mat")
                S = load(filePath);
                if isfield(S, "ri")
                    fig.UserData.db.RI = S.ri;
                elseif isfield(S, "RI")
                    fig.UserData.db.RI = S.RI;
                else
                    error("loadBranchData:InvalidRI", ...
                        "MAT file does not contain 'ri' or 'RI' variable.");
                end
            end
            fig.UserData.db.RI.SourceFile = string(filePath);
            fig.UserData.visExport.ri = resolveRefractiveIndexStruct(fig, filePath);

        case "Pred"
            S = load(filePath);
            if isfield(S, "allData")
                fig.UserData.db.Pred = S.allData;
            elseif isfield(S, "predictions")
                soaData = convertGridToSoA(S.predictions);
                fig.UserData.db.Pred = soaData;
            elseif isfield(S, "db") && isstruct(S.db) && isfield(S.db, "Pred")
                fig.UserData.db.Pred = S.db.Pred;
            else
                error("loadBranchData:InvalidPred", ...
                    "File does not contain predictions in a recognized format.");
            end

        case "Analyte"
            fig.UserData.db.Global.AnalyteSpectrumFile = string(filePath);

        otherwise
            warning("loadBranchData:UnknownBranch", ...
                "Unknown branch: %s", branchName);
    end
    markDbDirty(fig);
end

function clearBranchData(fig, branchName)
%clearBranchData  Clear a specific branch of the database struct.
    switch branchName
        case "Sim"
            fig.UserData.db.Sim = struct();
            if isfield(fig.UserData.db.Global, "SimFile")
                fig.UserData.db.Global.SimFile = "";
            end
        case "Model"
            fig.UserData.db.Model = struct("Net", [], "NetFile", "");
            fig.UserData.visExport.model = [];
            fig.UserData.visExport.modelLoaded = false;
        case "RI"
            fig.UserData.db.RI = struct();
            fig.UserData.visExport.ri = [];
        case "Pred"
            fig.UserData.db.Pred = struct();
        case "Analyte"
            if isfield(fig.UserData.db.Global, "AnalyteSpectrumFile")
                fig.UserData.db.Global.AnalyteSpectrumFile = "";
            end
        otherwise
            warning("clearBranchData:UnknownBranch", ...
                "Unknown branch: %s", branchName);
    end
    markDbDirty(fig);
end

%% ========================================================================
%   DB PATH RESOLVERS — materialise in-memory branches to temp files
%  ========================================================================
function [modelFile, riCsvFile, dataFile, predictionFile] = resolveDbPaths(fig)
%resolveDbPaths  Thin delegate — see resolveDbBranchPaths.
    db = fig.UserData.db;
    if (isempty(db) || ~isstruct(db)) && isfield(fig.UserData, "session") ...
            && ~isempty(fig.UserData.session) && isvalid(fig.UserData.session) ...
            && ~isempty(fig.UserData.session.db) && isstruct(fig.UserData.session.db)
        db = fig.UserData.session.db;
        fig.UserData.db = db;
    end
    [modelFile, riCsvFile, dataFile, predictionFile] = resolveDbBranchPaths(db, fig.UserData.workDir);
end

function [ok, model, ri] = ensureVisExportModelAndRi(fig, src, reporter)
%ensureVisExportModelAndRi Ensure both trained model and RI are loaded and valid.
    ok = false;
    model = [];
    ri = [];
    if isempty(fig) || ~isvalid(fig) || ~isstruct(fig.UserData)
        return;
    end
    workDir = fig.UserData.workDir;
    [modelFile, riCsvFile, ~, ~] = resolveDbPaths(fig);
    ve = fig.UserData.visExport;

    % 1. Resolve RI
    ri = resolveRefractiveIndexStruct(fig, riCsvFile);
    ve.ri = ri;

    % 2. Resolve Model
    if isfield(ve, "model") && isstruct(ve.model) && isfield(ve.model, "net") && ~isempty(ve.model.net)
        model = ve.model;
    elseif isfield(fig.UserData.db, "Model") && isstruct(fig.UserData.db.Model) ...
            && isfield(fig.UserData.db.Model, "Model") && isstruct(fig.UserData.db.Model.Model) ...
            && isfield(fig.UserData.db.Model.Model, "net")
        model = fig.UserData.db.Model.Model;
    elseif isfield(fig.UserData.db, "Model") && isstruct(fig.UserData.db.Model) ...
            && isfield(fig.UserData.db.Model, "Net") && ~isempty(fig.UserData.db.Model.Net)
        if isstruct(fig.UserData.db.Model.Net) && isfield(fig.UserData.db.Model.Net, "net")
            model = fig.UserData.db.Model.Net;
        else
            model = struct("net", fig.UserData.db.Model.Net);
            if isfield(fig.UserData.db.Model, "TargetNames") && ~isempty(fig.UserData.db.Model.TargetNames)
                model.targetNames = cellstr(fig.UserData.db.Model.TargetNames);
            end
        end
    else
        % Try loading from file
        reporter.start("LoadModel");
        mfPath = resolvePath(modelFile, workDir);
        if ~isfile(mfPath)
            reporter.fail("LoadModel", "Model file not found: " + mfPath);
            if ~isempty(src)
                sendEventToHTMLSource(src, "VisError", "Model file not found: " + mfPath);
            end
            return;
        end
        try
            [model, loadedRi] = loadAndValidateModel( ...
                ModelFile=mfPath, RiCsvFile=riCsvFile, Ri=ri, Reporter=reporter);
            if ~isstruct(ri) || ~isfield(ri, "nFunc")
                ri = loadedRi;
                ve.ri = ri;
            end
            reporter.complete("LoadModel", "Model loaded.");
        catch ME
            reporter.fail("LoadModel", "Failed to load model: " + string(ME.message));
            if ~isempty(src)
                sendEventToHTMLSource(src, "VisError", "Failed to load model: " + string(ME.message));
            end
            return;
        end
    end

    % Validate and decorate model
    if isempty(model) || ~isfield(model, "net")
        reporter.fail("LoadModel", "No valid neural network model found in database or file.");
        if ~isempty(src)
            sendEventToHTMLSource(src, "VisError", "No valid model found in database or file. Train a model in Stage 3 or load one in Stage 0.");
        end
        return;
    end

    model = ensureModelFlags(model);
    if ~isfield(model, "targetNames") || isempty(model.targetNames)
        model.targetNames = {'Absorptance', 'EF_vol', 'EF_surf'};
    end
    if isstring(model.targetNames)
        model.targetNames = cellstr(model.targetNames);
    end

    % Normalize and denormalize fallback handles if missing
    if (~isfield(model, "normalize") || isempty(model.normalize))
        featureLogMask = [true, true, true, false, false];
        if isfield(model, "FeatureLogTransform") && ~model.FeatureLogTransform
            featureLogMask = false(1, 5);
        end
        model.normalize = @(Xraw) localNormalizeModelFeatures(Xraw, featureLogMask);
    end
    if (~isfield(model, "denormalize") || isempty(model.denormalize))
        targetLogTransform = true;
        if isfield(model, "TargetLogTransform")
            targetLogTransform = model.TargetLogTransform;
        end
        model.denormalize = @(Ytrans) localDenormalizeModelTargets(Ytrans, targetLogTransform);
    end

    % Final check on RI: if still missing nFunc, fallback to default
    if isempty(ri) || ~isstruct(ri) || ~isfield(ri, "nFunc") || ~isfield(ri, "kFunc")
        ri = getDefaultRefractiveIndex(WavelengthUnit="um");
        ve.ri = ri;
    end

    ve.model = model;
    ve.ri = ri;
    ve.modelLoaded = true;
    fig.UserData.visExport = ve;
    ok = true;
end

function Xnorm = localNormalizeModelFeatures(Xraw, featureLogMask)
    if isempty(Xraw), Xnorm = Xraw; return; end
    Xnorm = Xraw;
    if any(featureLogMask)
        for col = 1:min(size(Xraw, 2), numel(featureLogMask))
            if featureLogMask(col) && all(Xraw(:, col) > 0)
                % Natural log: prepare_training_dataset/transformFeatures uses log().
                Xnorm(:, col) = log(Xraw(:, col));
            end
        end
    end
end

function Yraw = localDenormalizeModelTargets(Ytrans, targetLogTransform)
    if isempty(Ytrans), Yraw = Ytrans; return; end
    if targetLogTransform
        Yraw = 10.^Ytrans;
    else
        Yraw = Ytrans;
    end
end

function handleMainTabSelection(~, ~, fig)
%handleMainTabSelection  Ensure deferred-layout tabs expand properly on switch.
    drawnow;
    resizeVisualizePanel(fig);
    broadcastDbStatus(fig);
end

function ax = createDarkAxes(parent, xLabel, yLabel, titleStr)
%createDarkAxes  uiaxes with the app's dark styling.
    ax = uiaxes(parent, "Units", "normalized", "Position", [0.05 0.05 0.9 0.9]);
    styleDarkAxes(ax, xLabel, yLabel, titleStr);
end

%% ========================================================================
%   TAB LAYOUT HELPER
%  ========================================================================
function [h, visPanel] = buildTabLayout(parentTab, htmlFile)
%buildTabLayout Create the standard left-HTML / right-vis split.
    grid = uigridlayout(parentTab, [1 2]);
    grid.ColumnWidth = {400, "1x"};
    grid.Padding = [0 0 0 0]; grid.ColumnSpacing = 0;
    grid.BackgroundColor = parentTab.BackgroundColor;

    % HTML control panel
    h = uihtml(grid);
    h.Layout.Column = 1;
    h.HTMLSource = fullfile(fileparts(mfilename("fullpath")), htmlFile);

    % Visualization panel
    visPanel = uipanel(grid, ...
        "BackgroundColor", [6, 8, 18]/255, ...
        "BorderType", "none");
    visPanel.Layout.Column = 2;
end

function [h, visPanel] = buildImportTabLayout(parentTab, htmlFile)
%buildImportTabLayout  Full-width HTML for the Import tab.
%   The import tab's HTML contains its own two-column flex layout
%   (control-panel on the left, data-preview on the right).
%   The visPanel is kept as a minimal column for post-import QA plots;
%   it starts hidden and can be shown/resized after import completes.
    grid = uigridlayout(parentTab, [1 1]);
    grid.ColumnWidth = {"1x"};
    grid.Padding = [0 0 0 0]; grid.ColumnSpacing = 0;
    grid.BackgroundColor = parentTab.BackgroundColor;

    % Full-width HTML component (contains its own left/right layout)
    h = uihtml(grid);
    h.Layout.Column = 1;
    h.HTMLSource = fullfile(fileparts(mfilename("fullpath")), htmlFile);

    % Create a visPanel for QA plots — hidden by default.
    % runImportPipeline can show this by adjusting grid.ColumnWidth.
    visPanel = uipanel(parentTab, ...
        "BackgroundColor", [6, 8, 18]/255, ...
        "BorderType", "none", ...
        "Visible", "off");
end

function varargout = buildOptimizeTabLayout(parentTab, htmlFile)
%buildOptimizeTabLayout Create unified left-settings/results panel and right-visualization axes.
    grid = uigridlayout(parentTab, [1 2]);
    grid.ColumnWidth = {480, "1x"};
    grid.Padding = [0 0 0 0];
    grid.ColumnSpacing = 0;
    grid.BackgroundColor = parentTab.BackgroundColor;

    htmlPath = fullfile(fileparts(mfilename("fullpath")), htmlFile);

    hUnified = uihtml(grid);
    hUnified.Layout.Column = 1;
    hUnified.HTMLSource = htmlPath;
    hUnified.Data = struct("mode", "unified");

    visPanel = uipanel(grid, ...
        "BackgroundColor", [6, 8, 18]/255, ...
        "BorderType", "none");
    visPanel.Layout.Column = 2;

    if nargout >= 3
        varargout = {hUnified, hUnified, visPanel};
    else
        varargout = {hUnified, visPanel};
    end
end

%% ========================================================================
%   PROGRESS REPORTER FACTORY
%  ========================================================================
function reporter = makeReporter(htmlComponent, fig)
%makeReporter Build a ProgressReporter that forwards to a uihtml panel.
    if nargin < 2 || isempty(fig) || ~isvalid(fig)
        fig = ancestor(htmlComponent, "figure");
    end
    reporter = ProgressReporter.fromCallback( ...
        @(type, step, data) sendEventToHTMLSource(htmlComponent, "Progress", data));
    if ~isempty(fig) && isvalid(fig)
        reporter.StopCheckFcn = @() isProcessStopRequested(fig);
    end
end

function reporter = makeOptimizeReporter(fig, src)
%makeOptimizeReporter Build ProgressReporter that broadcasts to both optimize panels.
    reporter = ProgressReporter.fromCallback( ...
        @(type, step, data) sendOptimizeEvent(fig, "Progress", data, src));
    if ~isempty(fig) && isvalid(fig)
        reporter.StopCheckFcn = @() isProcessStopRequested(fig);
    end
end



%% ========================================================================
%   GLOBAL PROCESS MANAGEMENT & STOP SYSTEM
%  ========================================================================
function onAppClose(fig, ~)
%onAppClose Safely tear down active workflows, parallel pool, and close figure.
    if isvalid(fig)
        try, requestProcessStop(fig); catch, end
        try
            pool = gcp('nocreate');
            if ~isempty(pool)
                delete(pool);
            end
        catch
        end
        delete(fig);
    end
end

function requestProcessStop(fig)
%requestProcessStop Signal immediate and indefinite termination to all stages.
    if isempty(fig) || ~isvalid(fig), return; end
    setProcessStopRequested(fig, true);
    setTrainingStopRequested(fig, true);
    activeStage = getProcessActiveStage(fig);
    msg = "Stop requested. Terminating ongoing process...";
    if activeStage ~= ""
        msg = sprintf("Stop requested. Terminating %s process...", activeStage);
    end
    broadcastProcessEvent(fig, "ProcessStopAck", struct("stage", activeStage, "message", msg));
    drawnow;
end

function notifyProcessStopped(fig, stageName, message)
%notifyProcessStopped Notify all UI panels that a process was terminated.
    if nargin < 2 || isempty(stageName), stageName = getProcessActiveStage(fig); end
    if nargin < 3 || isempty(message), message = "Process terminated by user."; end
    if isempty(fig) || ~isvalid(fig), return; end
    
    setProcessRunning(fig, false, "");
    setProcessStopRequested(fig, false);
    setTrainingStopRequested(fig, false);
    
    payload = struct("stage", string(stageName), "message", string(message), "terminated", true);
    broadcastProcessEvent(fig, "ProcessStopped", payload);
    
    % Forward stage-specific notifications for backwards compatibility
    stageStr = lower(string(stageName));
    if contains(stageStr, "train")
        broadcastProcessEvent(fig, "TrainStopped", message);
    elseif contains(stageStr, "sampl")
        broadcastProcessEvent(fig, "SamplingStopped", message);
    elseif contains(stageStr, "opt")
        broadcastProcessEvent(fig, "OptimizeStopped", message);
    elseif contains(stageStr, "import")
        broadcastProcessEvent(fig, "ImportStopped", message);
    elseif contains(stageStr, "predict") || contains(stageStr, "vis")
        broadcastProcessEvent(fig, "VisStopped", message);
    end
    drawnow;
end

function broadcastProcessEvent(fig, eventName, payload)
%broadcastProcessEvent Send event to all HTML panels in the app.
    if isempty(fig) || ~isvalid(fig), return; end
    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "htmlPanels")
        panels = fig.UserData.handles.htmlPanels;
        for i = 1:numel(panels)
            if isvalid(panels(i))
                try
                    sendEventToHTMLSource(panels(i), eventName, payload);
                catch
                end
            end
        end
    end
end

function setProcessRunning(fig, value, stageName)
    if isempty(fig) || ~isvalid(fig), return; end
    if ~isfield(fig.UserData, "process") || ~isstruct(fig.UserData.process)
        fig.UserData.process = struct("isRunning", false, "stopRequested", false, "activeStage", "");
    end
    fig.UserData.process.isRunning = logical(value);
    if nargin >= 3
        fig.UserData.process.activeStage = string(stageName);
    elseif ~value
        fig.UserData.process.activeStage = "";
    end
    if value
        fig.UserData.process.stopRequested = false;
    end
    if nargin >= 3 && contains(lower(string(stageName)), "train")
        setTrainingRunning(fig, value);
    end
end

function running = isProcessRunning(fig)
    running = false;
    if isempty(fig) || ~isvalid(fig), return; end
    if isfield(fig.UserData, "process") && isstruct(fig.UserData.process) && ...
       isfield(fig.UserData.process, "isRunning")
        running = logical(fig.UserData.process.isRunning);
    end
    if ~running && isfield(fig.UserData, "training") && isstruct(fig.UserData.training) && ...
       isfield(fig.UserData.training, "isRunning")
        running = logical(fig.UserData.training.isRunning);
    end
end

function stage = getProcessActiveStage(fig)
    stage = "";
    if isempty(fig) || ~isvalid(fig), return; end
    if isfield(fig.UserData, "process") && isstruct(fig.UserData.process) && ...
       isfield(fig.UserData.process, "activeStage")
        stage = string(fig.UserData.process.activeStage);
    end
end

function setProcessStopRequested(fig, value)
    if isempty(fig) || ~isvalid(fig), return; end
    if ~isfield(fig.UserData, "process") || ~isstruct(fig.UserData.process)
        fig.UserData.process = struct("isRunning", false, "stopRequested", false, "activeStage", "");
    end
    fig.UserData.process.stopRequested = logical(value);
end

function stopReq = isProcessStopRequested(fig)
    stopReq = false;
    if isempty(fig) || ~isvalid(fig), return; end
    if isfield(fig.UserData, "process") && isstruct(fig.UserData.process) && ...
       isfield(fig.UserData.process, "stopRequested")
        stopReq = logical(fig.UserData.process.stopRequested);
    end
    if ~stopReq && isfield(fig.UserData, "training") && isstruct(fig.UserData.training) && ...
       isfield(fig.UserData.training, "stopRequested")
        stopReq = logical(fig.UserData.training.stopRequested);
    end
end

function cleanupProcess(fig)
    if ~isempty(fig) && isvalid(fig)
        setProcessRunning(fig, false, "");
        setProcessStopRequested(fig, false);
    end
end

function cleanupTrainingProcess(fig)
    if ~isempty(fig) && isvalid(fig)
        setTrainingRunning(fig, false);
        setProcessRunning(fig, false, "");
        setProcessStopRequested(fig, false);
    end
end


%% ========================================================================
%   BROWSE FILE — shared across all tabs
%  ========================================================================
function browseAndReply(src, eventData, fig)
%browseAndReply Open OS file/folder dialog and push result back to HTML.
    fieldId = "";
    fileType = "file";
    if isstruct(eventData)
        if isfield(eventData, "field"), fieldId = string(eventData.field); end
        if isfield(eventData, "type"),  fileType = string(eventData.type); end
    end

    startDir = fig.UserData.workDir;

    if fileType == "folder"
        chosen = uigetdir(startDir, "Select Folder");
        if chosen == 0, return; end
        fig.UserData.workDir = string(chosen);
        sendEventToHTMLSource(src, "BrowseResult", struct( ...
            "field", fieldId, "path", string(chosen)));
    else
        [file, path] = uigetfile( ...
            {"*.mat;*.dat;*.csv;*.txt", "Supported Files"}, ...
            "Select File", startDir);
        if file == 0, return; end
        
        % Always update workDir from the selected file's directory
        fig.UserData.workDir = string(path);

        % For rawDataFiles, send only the filename to JS (paths corrupt in JS roundtrip)
        if fieldId == "rawDataFiles"
            % Auto-detect McPeak.csv in the same directory
            riPath = "";
            riCandidate = fullfile(path, "McPeak.csv");
            if isfile(riCandidate)
                riPath = string(riCandidate);
            end
            sendEventToHTMLSource(src, "BrowseResult", struct( ...
                "field", fieldId, ...
                "filename", string(file), ...
                "riCsvFile", riPath));
        else
            % For other fields, return full path
            sendEventToHTMLSource(src, "BrowseResult", struct( ...
                "field", fieldId, "path", string(fullfile(path, file))));
        end
    end
end

%% ########################################################################
%   STAGE 1 — IMPORT HANDLERS
%  ########################################################################
function handleImportEvent(src, event, fig, visPanel)
    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "importController") ...
            && ~isempty(fig.UserData.handles.importController)
        fig.UserData.handles.importController.handleEvent(event.HTMLEventName, event.HTMLEventData);
        return;
    end
    name = event.HTMLEventName;
    data = event.HTMLEventData;
    try
        switch name
            case "PreviewFile"
                previewImportFile(src, data, fig);
            case "RunImport"
                runImportPipeline(src, data, fig, visPanel);
            case "RecalculateDerived"
                recalculateImportDerivedMetrics(src, data, fig);
            case "BrowseFile"
                browseAndReply(src, data, fig);
            case "RefreshDbState"
                broadcastDbStatus(fig);
            case "SaveDatabaseRequest"
                saveDbFile(fig);
                broadcastDbStatus(fig);
            case "StopProcess"
                requestProcessStop(fig);
            otherwise
                fprintf("[Import] Unknown event: %s\n", name);
        end
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Import", "Import process terminated by user.");
        else
            sendEventToHTMLSource(src, "ImportError", ME.message);
        end
    end
end

function recalculateImportDerivedMetrics(src, d, fig)
%recalculateImportDerivedMetrics Recompute *_laser, *_avg, *_analyte for db.Sim.
    reporter = makeReporter(src, fig);
    setProcessRunning(fig, true, "Import");
    cleanupObj = onCleanup(@() cleanupProcess(fig));
    try
        if ~isfield(fig.UserData.db, "Sim") || ~isstruct(fig.UserData.db.Sim) || structRowCount(fig.UserData.db.Sim) == 0
            sendEventToHTMLSource(src, "ImportError", "No simulation data in database (db.Sim is empty).");
            return;
        end

        cfg = importSweepConfig( ...
            WorkDir             = fig.UserData.workDir, ...
            LaserWavelength     = safeNum(d, "laserWavelength", 785), ...
            RamanWindow         = [safeNum(d,"ramanWindowMin",100), safeNum(d,"ramanWindowMax",3600)], ...
            DetectShiftWindow   = safeBool(d, "detectShiftWindow", false), ...
            InterpResolution    = safeNum(d, "interpResolution", 1), ...
            SpectralInterpMethod = safeStr(d, "spectralInterpMethod", "makima"), ...
            MetricVariants      = safeStruct(d, "metricVariants"));

        % DB analyte first, default fallback, never flat
        analyteSpectrum = struct();
        analyteFile = resolveAnalyteFile(fig);
        if strlength(analyteFile) > 0 && isfile(analyteFile)
            try
                analyteSpectrum = loadAndNormalizeAnalyteSpectrum(analyteFile);
            catch
                analyteSpectrum = struct();
            end
        end
        if ~isstruct(analyteSpectrum) || ~isfield(analyteSpectrum, "shift_cm") || isempty(analyteSpectrum.shift_cm)
            analyteSpectrum = getDefaultAnalyteSpectrum();
        end

        % Extract clean SoA before recalculating: db.Sim has branch-level metadata
        % fields (Source, LaserWl, StokesWindow…) prepended by populateBranch.
        % Passing db.Sim directly causes structRowCount to return 1 (size of the
        % string Source field), so only row 1 would be processed and all other
        % entries' _laser fields get replaced with NaN.
        soaData = extractBranchAsSoA(fig.UserData.db, "Sim");
        [soaData, updatedCount] = recomputeDerivedMetrics(soaData, cfg, analyteSpectrum, reporter);
        % Write all updated fields back into db.Sim, preserving branch metadata.
        soaFields = fieldnames(soaData);
        for kf = 1:numel(soaFields)
            fig.UserData.db.Sim.(soaFields{kf}) = soaData.(soaFields{kf});
        end
        markDbDirty(fig);
        broadcastDbStatus(fig);

        sendEventToHTMLSource(src, "RecalculateComplete", sprintf("Updated %d geometry rows.", updatedCount));
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Import", "Recalculation terminated by user.");
            return;
        end
        sendEventToHTMLSource(src, "ImportError", "Recalculation failed: " + string(ME.message));
    end
end

function [simData, updatedCount] = localRecomputeDerivedFields(simData, cfg, analyteSpectrum, reporter)
%localRecomputeDerivedFields  Thin delegate — see recomputeDerivedMetrics.
    [simData, updatedCount] = recomputeDerivedMetrics(simData, cfg, analyteSpectrum, reporter);
end

function previewImportFile(src, d, fig)
%previewImportFile Read a sweep file and send preview data to the UI.
    inputFile = safeStr(d, "inputFile", "SweepPropeTable.dat");

    % Resolve file path
    candidates = { ...
        string(inputFile), ...
        fullfile(fig.UserData.workDir, inputFile)};
    filePath = "";
    for k = 1:numel(candidates)
        if isfile(candidates{k})
            filePath = candidates{k};
            break;
        end
    end
    if filePath == ""
        sendEventToHTMLSource(src, "ImportError", sprintf("File not found: %s", inputFile));
        return;
    end

    % Read the file
    T = readSweepTable(filePath);
    T.Properties.VariableNames = sanitizeVarNames(T.Properties.VariableNames);

    colNames = T.Properties.VariableNames;
    numCols = numel(colNames);
    numRows = height(T);

    % Auto-detect roles from column names
    inputPatterns    = ["period", "radius", "p", "r", "gap", "thickness", "angle", ...
                        "height", "pitch", "particle_r", "diameter"];
    spectralPatterns = ["lambda", "wavelength", "freq", "frequency", "omega"];

    roles = cell(1, numCols);
    for k = 1:numCols
        cn = lower(colNames{k});
        if any(strcmpi(cn, spectralPatterns))
            roles{k} = "spectral";
        elseif any(strcmpi(cn, inputPatterns))
            roles{k} = "input";
        else
            roles{k} = "metric";
        end
    end

    % Extract first N rows as cell array
    maxPreviewRows = min(numRows, 15);
    rowData = cell(maxPreviewRows, 1);
    for r = 1:maxPreviewRows
        rowVals = cell(1, numCols);
        for c = 1:numCols
            val = T{r, c};
            if isnumeric(val) || islogical(val)
                rowVals{c} = double(val);
            else
                rowVals{c} = string(val);
            end
        end
        rowData{r} = rowVals;
    end

    result = struct( ...
        "columns", {colNames}, ...
        "roles", {roles}, ...
        "rows", {rowData}, ...
        "numRows", numRows, ...
        "numCols", numCols, ...
        "filePath", filePath);

    sendEventToHTMLSource(src, "PreviewResult", result);
end

function runImportPipeline(src, d, fig, visPanel)
    reporter = makeReporter(src, fig);
    setProcessRunning(fig, true, "Import");
    cleanupObj = onCleanup(@() cleanupProcess(fig));

    analyteFile = resolveAnalyteFile(fig);
    outputFile = resolveImportOutputFile(fig);

    % Build column schema from UI event data
    columnSchema = struct([]);
    if isfield(d, "columnSchema") && ~isempty(d.columnSchema)
        cs = d.columnSchema;
        if iscell(cs)
            for k = 1:numel(cs)
                item = cs{k};
                if isstruct(item) && isfield(item, "name") && isfield(item, "role")
                    entry = struct('name', char(item.name), 'role', char(item.role));
                    if isfield(item, "originalName")
                        entry.originalName = char(item.originalName);
                    else
                        entry.originalName = char(item.name);
                    end
                    if isempty(columnSchema)
                        columnSchema = entry;
                    else
                        columnSchema(end+1) = entry; %#ok<AGROW>
                    end
                end
            end
        elseif isstruct(cs)
            for k = 1:numel(cs)
                entry = struct('name', char(cs(k).name), 'role', char(cs(k).role));
                if isfield(cs(k), "originalName")
                    entry.originalName = char(cs(k).originalName);
                else
                    entry.originalName = char(cs(k).name);
                end
                if isempty(columnSchema)
                    columnSchema = entry;
                else
                    columnSchema(end+1) = entry; %#ok<AGROW>
                end
            end
        end
    end

    cfg = importSweepConfig( ...
        WorkDir             = fig.UserData.workDir, ...
        InputFile           = safeStr(d, "inputFile", "SweepPropeTable.dat"), ...
        OutputFile          = outputFile, ...
        AnalyteSpectrumFile = analyteFile, ...
        ColumnSchema        = columnSchema, ...
        LaserWavelength     = safeNum(d, "laserWavelength", 785), ...
        RamanWindow         = [safeNum(d,"ramanWindowMin",100), safeNum(d,"ramanWindowMax",3600)], ...
        DetectShiftWindow   = safeBool(d, "detectShiftWindow", false), ...
        InterpResolution    = safeNum(d, "interpResolution", 1), ...
        SpectralInterpMethod = safeStr(d, "spectralInterpMethod", "makima"), ...
        Mode                = safeStr(d, "mode", "merge"), ...
        ReplaceExisting     = safeBool(d, "replaceExisting", false), ...
        RecalculateExisting = safeBool(d, "recalculateExisting", false), ...
        MetricVariants      = safeStruct(d, "metricVariants"));

    results = runImportSweepWorkflow(cfg, reporter);

    % Render QA plots into the right panel (if available)
    try
        visPanel.Visible = "on";
        delete(allchild(visPanel));
        visualizeImportSummary(results, Parent=visPanel);
    catch ME2
        visPanel.Visible = "off";
        fprintf("[Import] Visualization error: %s\n", ME2.message);
    end

    % Write-back to unified database
    try
        if isfield(results, "db") && isstruct(results.db)
            fig.UserData.db = results.db;
        end
        if isfield(cfg, "outputFile") && strlength(string(cfg.outputFile)) > 0
            if ~isfield(fig.UserData.db, "Global") || ~isstruct(fig.UserData.db.Global)
                fig.UserData.db.Global = struct();
            end
            outPath = string(cfg.outputFile);
            isAbsWin = ~isempty(regexp(char(outPath), '^[A-Za-z]:[\\/]', 'once'));
            isAbsUnc = startsWith(outPath, "\\");
            isAbsUnix = startsWith(outPath, "/");
            if ~(isAbsWin || isAbsUnc || isAbsUnix)
                outPath = fullfile(string(cfg.workDir), outPath);
            end
            fig.UserData.db.Global.SimFile = outPath;
        end
        markDbDirty(fig);
    catch ME_db
        fprintf("[Import] DB write-back warning: %s\n", ME_db.message);
    end

    sendEventToHTMLSource(src, "ImportComplete", ...
        sprintf("%d entries imported in %.1f s", ...
            results.summary.numEntries, results.elapsedTotal));
end

function outputFile = resolveImportOutputFile(fig)
%resolveImportOutputFile Return Sim MAT path used by import workflow.
    outputFile = "prl_sweep.mat";
    db = fig.UserData.db;
    if isfield(db, "Global") && isfield(db.Global, "SimFile")
        sf = string(db.Global.SimFile);
        if strlength(sf) > 0
            outputFile = sf;
        end
    end
end

%% ########################################################################
%   STAGE 2 — ADAPTIVE SAMPLING HANDLERS
%  ########################################################################
function handleSamplingEvent(src, event, fig)
    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "samplingController") ...
            && ~isempty(fig.UserData.handles.samplingController)
        fig.UserData.handles.samplingController.handleEvent(event.HTMLEventName, event.HTMLEventData);
        return;
    end
    name = event.HTMLEventName;
    data = event.HTMLEventData;
    try
        switch name
            case "LoadData"
                loadSamplingData_app(src, fig, data);

            case "RunSampling"
                runSampling_app(src, fig, data);

            case "PreviewDensity"
                previewDensity_app(src, fig, data);

            case "ExportResults"
                exportSamplingResults_app(src, fig, data);

            case "FindNanPoints"
                findNanPoints_app(src, fig, data);

            case "ExportNanPoints"
                exportNanPoints_app(src, fig, data);

            case "HighlightNanPoints"
                highlightNanPoints_app(src, fig, data);

            case "Reset"
                resetSampling(src, fig);
            case "RefreshDbState"
                broadcastDbStatus(fig);
            case "SaveDatabaseRequest"
                saveDbFile(fig);
                broadcastDbStatus(fig);
            case "StopProcess"
                requestProcessStop(fig);
            case "StopSampling"
                requestProcessStop(fig);
            otherwise
                fprintf("[Sampling] Unknown event: %s\n", name);
        end
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Sampling", "Sampling process terminated by user.");
        else
            sendEventToHTMLSource(src, "Error", ME.message);
        end
    end
end

function loadSamplingData_app(src, fig, eventData)
    st = fig.UserData.sampling;
    cfg = buildSamplingCfgFromEvent(eventData, fig);
    st.config = cfg;

    if cfg.fromPredictions
        if isempty(cfg.predictionFile)
            sendEventToHTMLSource(src, "Error", "Select a prediction file"); return
        end
    else
        if isempty(cfg.dataFile)
            sendEventToHTMLSource(src, "Error", "Select a data file"); return
        end
    end

    sendEventToHTMLSource(src, "StatusUpdate", "Loading data...");
    samples = loadSamplingData(cfg);
    st.samples = samples; st.dataLoaded = true;
    fig.UserData.sampling = st;

    % Detect input parameter names and ranges from schema first
    inputParams = struct('name', {}, 'min', {}, 'max', {});
    db = fig.UserData.db;
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

    % Also check if schema metrics can be found
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

    sendEventToHTMLSource(src, "DataLoaded", struct( ...
        "numPoints", samples.numPoints, ...
        "periodMin", pMin, "periodMax", pMax, ...
        "radiusMin", rMin, "radiusMax", rMax, ...
        "inputParams", inputParams, ...
        "availableMetrics", valid));

    updateSamplingViz(fig, cfg, samples, [], []);
end

function runSampling_app(src, fig, eventData)
    st = fig.UserData.sampling;
    if ~st.dataLoaded
        sendEventToHTMLSource(src, "Error", "Load data first"); return
    end
    setProcessRunning(fig, true, "Sampling");
    cleanupObj = onCleanup(@() cleanupProcess(fig));
    cfg = buildSamplingCfgFromEvent(eventData, fig);
    cfg.stopFcn = @() isProcessStopRequested(fig);
    st.config = cfg;

    if isempty(cfg.metricNames)
        sendEventToHTMLSource(src, "Error", "Select at least one metric"); return
    end

    sendEventToHTMLSource(src, "SamplingProgress", struct("percent",5,"message","Building density..."));

    samples = updateSamplesMetrics_local(st.samples, cfg);
    st.samples = samples;

    density = buildSamplingDensity(cfg, samples);
    st.density = density;

    sendEventToHTMLSource(src, "SamplingProgress", struct("percent",15,"message","Running rejection sampling..."));
    result = runAdaptiveSampling(cfg, samples, density);
    st.result = result; st.samplingComplete = true;
    fig.UserData.sampling = st;

    sendEventToHTMLSource(src, "SamplingProgress", struct("percent",100,"message","Complete!"));
    sendEventToHTMLSource(src, "SamplingComplete", struct( ...
        "count", result.count, ...
        "attempts", result.attempts, ...
        "acceptanceRate", result.acceptanceRate));

    updateSamplingViz(fig, cfg, samples, density, result);
end

function previewDensity_app(src, fig, eventData)
    st = fig.UserData.sampling;
    if ~st.dataLoaded
        sendEventToHTMLSource(src, "Error", "Load data first"); return
    end
    cfg = buildSamplingCfgFromEvent(eventData, fig);
    if isempty(cfg.metricNames)
        sendEventToHTMLSource(src, "Error", "Select at least one metric"); return
    end
    st.config = cfg;
    samples = updateSamplesMetrics_local(st.samples, cfg);
    st.samples = samples;

    density = buildSamplingDensity(cfg, samples);
    st.density = density;
    fig.UserData.sampling = st;

    updateSamplingViz(fig, cfg, samples, density, st.result);
    sendEventToHTMLSource(src, "DensityPreview", struct("success", true));
end

function exportSamplingResults_app(src, fig, eventData)
    st = fig.UserData.sampling;
    if ~st.samplingComplete || isempty(st.result)
        sendEventToHTMLSource(src, "Error", "Run sampling first"); return
    end
    outFile = safeStr(eventData, "outputFile", "adaptive_points.txt");
    workDir = fig.UserData.workDir;
    if workDir ~= ""
        defaultPath = fullfile(workDir, outFile);
    else
        defaultPath = fullfile(pwd, outFile);
    end
    
    [file, path] = uiputfile({'*.txt', 'Text Files (*.txt)'; '*.*', 'All Files (*.*)'}, ...
        'Save Export File As', defaultPath);
        
    if isequal(file, 0) || isequal(path, 0)
        sendEventToHTMLSource(src, "StatusUpdate", "Export cancelled.");
        return;
    end
    
    outFile = fullfile(path, file);
    
    originalPoints = [st.samples.period(:), st.samples.radius(:)];
    exportToComsol(st.result, OutputFile=outFile, ...
        IncludeOriginal=safeBool(eventData,"includeOriginal",false), ...
        OriginalPoints=originalPoints);
    sendEventToHTMLSource(src, "ExportComplete", struct("filename", outFile));
end

function findNanPoints_app(src, fig, eventData)
    try
        % Find available data source:
        % 1. Sampling samples loaded in fig.UserData.sampling.samples
        % 2. Database Sim data in fig.UserData.db.Sim
        % 3. Database SimFile if set
        % 4. Fallback to dataFile from resolveDbPaths
        dataSource = [];
        if isfield(fig.UserData, "sampling") && isfield(fig.UserData.sampling, "samples") && ...
           ~isempty(fig.UserData.sampling.samples) && isfield(fig.UserData.sampling.samples, "allData")
            dataSource = fig.UserData.sampling.samples.allData;
        elseif isfield(fig.UserData, "db") && isfield(fig.UserData.db, "Sim") && ...
               isstruct(fig.UserData.db.Sim) && structRowCount(fig.UserData.db.Sim) > 0
            dataSource = fig.UserData.db;
        elseif isfield(fig.UserData, "db") && isfield(fig.UserData.db, "Global") && ...
               isfield(fig.UserData.db.Global, "SimFile") && isfile(string(fig.UserData.db.Global.SimFile))
            dataSource = string(fig.UserData.db.Global.SimFile);
        end

        if isempty(dataSource)
            [~, ~, simDataFile, ~] = resolveDbPaths(fig);
            if strlength(simDataFile) > 0 && isfile(simDataFile)
                dataSource = simDataFile;
            end
        end

        if isempty(dataSource)
            sendEventToHTMLSource(src, "Error", "No dataset loaded. Load data in Database or Sampling tab first.");
            return;
        end

        sendEventToHTMLSource(src, "StatusUpdate", "Scanning for NaN metrics...");

        precision = safeNum(eventData, "precision", 6);
        res = findNanSamplingPoints(dataSource, Precision=precision);
        fig.UserData.sampling.nanResult = res;

        % Send structured result to HTML component
        sendEventToHTMLSource(src, "NanPointsFound", res);

        if res.hasNans
            sendEventToHTMLSource(src, "StatusUpdate", ...
                sprintf("Found %d unique geometry points with NaNs across %d entries.", res.count, res.totalRows));
        else
            sendEventToHTMLSource(src, "StatusUpdate", "No NaN values detected in any metric.");
        end
    catch ME
        sendEventToHTMLSource(src, "Error", "Failed to scan for NaNs: " + ME.message);
    end
end

function exportNanPoints_app(src, fig, eventData)
    try
        if ~isfield(fig.UserData.sampling, "nanResult") || isempty(fig.UserData.sampling.nanResult) || ...
           fig.UserData.sampling.nanResult.count == 0
            sendEventToHTMLSource(src, "Error", "Scan for NaN points first.");
            return;
        end

        nanRes = fig.UserData.sampling.nanResult;
        defaultName = safeStr(eventData, "outputFile", "comsol_failed_nan_points.txt");
        workDir = fig.UserData.workDir;
        if workDir ~= ""
            defaultPath = fullfile(workDir, defaultName);
        else
            defaultPath = fullfile(pwd, defaultName);
        end

        [file, path] = uiputfile({'*.txt', 'Text Files (*.txt)'; '*.dat', 'Data Files (*.dat)'; '*.*', 'All Files (*.*)'}, ...
            'Save COMSOL Re-sweep File As', defaultPath);

        if isequal(file, 0) || isequal(path, 0)
            sendEventToHTMLSource(src, "StatusUpdate", "Export cancelled.");
            return;
        end

        outFile = fullfile(path, file);
        fmt = safeStr(eventData, "format", "param");
        precision = safeNum(eventData, "precision", 6);

        exportNanPointsToComsol(nanRes, ...
            OutputFile=outFile, ...
            Format=fmt, ...
            Precision=precision);

        sendEventToHTMLSource(src, "ExportNanComplete", struct( ...
            "filename", outFile, ...
            "count", nanRes.count));
        sendEventToHTMLSource(src, "StatusUpdate", ...
            sprintf("Exported %d points to COMSOL file: %s", nanRes.count, file));
    catch ME
        sendEventToHTMLSource(src, "Error", "Export failed: " + ME.message);
    end
end

function highlightNanPoints_app(src, fig, eventData)
    try
        ax = fig.UserData.handles.samplingAx;
        if isempty(ax) || ~isvalid(ax)
            return;
        end

        % Delete any existing NaN highlight scatter
        oldH = findobj(ax, "Tag", "NAN_HIGHLIGHT_POINTS");
        delete(oldH);

        show = safeBool(eventData, "show", true);
        if ~show
            return;
        end

        if ~isfield(fig.UserData.sampling, "nanResult") || isempty(fig.UserData.sampling.nanResult) || ...
           fig.UserData.sampling.nanResult.count == 0
            return;
        end

        nanRes = fig.UserData.sampling.nanResult;
        hold(ax, "on");

        zVal = 2.0;
        zChildren = findobj(ax, "Type", "surface");
        if ~isempty(zChildren)
            try
                zdata = get(zChildren(1), "ZData");
                zVal = max(zdata(:)) * 1.2;
            catch
            end
        end

        pts = nanRes.uniquePoints;
        hScat = scatter3(ax, pts(:, 1), pts(:, 2), repmat(zVal, size(pts, 1), 1), ...
            60, [1 0.5 0], "^", "filled", ...
            "MarkerEdgeColor", [1 1 1], ...
            "LineWidth", 1.2, ...
            "DisplayName", sprintf("Failed/NaN Points (%d)", nanRes.count), ...
            "Tag", "NAN_HIGHLIGHT_POINTS");
        uistack(hScat, "top");
        legend(ax, "show", "TextColor", [160, 178, 214]/255, "Location", "northeast");
    catch ME
        fprintf("[Sampling] Highlight NaN points error: %s\n", ME.message);
    end
end

function resetSampling(src, fig)
    fig.UserData.sampling = struct( ...
        "config",[], "samples",[], "density",[], ...
        "result",[], "dataLoaded",false, "samplingComplete",false);
    ax = fig.UserData.handles.samplingAx;
    cla(ax);
    title(ax, "Sampling Density & Generated Points", "Color", [248, 248, 248]/255);
    sendEventToHTMLSource(src, "StatusUpdate", "Reset complete");
end

function cfg = buildSamplingCfgFromEvent(ev, fig)
    gf = @(n,d) ternaryVal(isfield(ev,n), @()ev.(n), d);
    gs = @(n,d) string(gf(n,d));
    metricNames = sanitiseMetricList(gf("metricNames", []));
    if isempty(metricNames)
        % Check if db has known metrics from Schema or Sim
        db = fig.UserData.db;
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

    if isfield(ev,"autoDetectRanges") && ev.autoDetectRanges
        pR = [NaN NaN]; rR = [NaN NaN];
    elseif isfield(ev,"periodMin") && isfield(ev,"periodMax")
        pR = [ev.periodMin, ev.periodMax]; rR = [ev.radiusMin, ev.radiusMax];
    else
        pR = [NaN NaN]; rR = [NaN NaN];
    end

    % Resolve file paths from db struct
    [dbModelFile, dbRiCsvFile, dbDataFile, dbPredFile] = resolveDbPaths(fig);

    xParam = gs("xAxisParam", "");
    yParam = gs("yAxisParam", "");

    cfg = adaptiveSamplingConfig( ...
        WorkDir         = fig.UserData.workDir, ...
        DataSource      = gs("dataSource", "interpolation"), ...
        DataFile        = dbDataFile, ...
        ModelFile       = dbModelFile, ...
        RiCsvFile       = dbRiCsvFile, ...
        PredictionFile  = dbPredFile, ...
        NumPoints       = gf("numPoints",100), ...
        MaxAttempts     = gf("maxAttempts",1e6), ...
        MinSeparation   = gf("minSeparation",5), ...
        RtpThreshold    = gf("rtpThreshold",0.49), ...
        UniformSampling = gf("uniformSampling",false), ...
        EnforceOriginalSpacing = gf("enforceOriginalSpacing",true), ...
        PeriodRange     = pR, RadiusRange = rR, ...
        MetricNames     = metricNames, ...
        MetricWeights   = padVec(gf("metricWeights",[]), nM), ...
        MetricAlphas    = padVec(gf("metricAlphas",[]),  nM), ...
        OverallExponent = gf("overallExponent",1), ...
        BlurSigma       = gf("blurSigma",0), ...
        OutputFile      = gs("outputFile","adaptive_points.txt"), ...
        DensityThreshold = gf("densityThreshold",0), ...
        GridResolution  = gf("gridResolution",100), ...
        Visualize       = false, ...
        xAxisParam      = xParam, ...
        yAxisParam      = yParam);

    cfg.xAxisParam     = xParam;
    cfg.yAxisParam     = yParam;
    cfg.showOriginal   = gf("showOriginal",true);
    cfg.showGenerated  = gf("showGenerated",true);
    cfg.originalColor  = gs("originalColor","#ebb34f");
    cfg.generatedColor = gs("generatedColor","#48b2ac");
    cfg.pointSize      = gf("pointSize",30);
    cfg.colormap       = gs("colormap","custom");
    cfg.useManualRange = isfield(ev,"autoDetectRanges") && ~ev.autoDetectRanges;
end

function updateSamplingViz(fig, cfg, samples, density, result)
    ax = fig.UserData.handles.samplingAx;
    cla(ax); hold(ax,"on");

    if cfg.useManualRange && ~isnan(cfg.periodRange(1))
        pR = cfg.periodRange; rR = cfg.radiusRange;
    else
        pR = [min(samples.period) max(samples.period)];
        rR = [min(samples.radius) max(samples.radius)];
    end
    maxD = 1;

    if ~isempty(density) && ~cfg.uniformSampling
        gr = cfg.gridResolution;
        pG = linspace(pR(1),pR(2),gr); rG = linspace(rR(1),rR(2),gr);
        [PG,RG] = meshgrid(pG,rG);
        D = density.func(PG(:),RG(:)); D = reshape(D,size(PG)); D(isnan(D)) = 0;
        maxD = max(D(:))+0.01;
        surf(ax,PG,RG,D,"EdgeColor","none","FaceAlpha",0.9);
        view(ax,2);
        cmap = getappdata(fig,"CustomColormap");
        if isempty(cmap), cmap = parula(256); end
        colormap(ax,cmap);
        cb = colorbar(ax); cb.Color = [160, 178, 214]/255;
        clim(ax, [0 1]);
    else
        view(ax,2);
    end

    if cfg.showOriginal && ~isempty(samples)
        scatter3(ax, samples.period, samples.radius, ...
            ones(size(samples.period))*1.1*maxD, ...
            cfg.pointSize, hex2rgb(cfg.originalColor), "filled", ...
            "MarkerEdgeColor","k","LineWidth",0.5,"DisplayName","Original");
    end
    if cfg.showGenerated && ~isempty(result) && result.count > 0
        scatter3(ax, result.points(:,1), result.points(:,2), ...
            ones(result.count,1)*1.2*maxD, ...
            cfg.pointSize*1.2, hex2rgb(cfg.generatedColor), "filled", ...
            "MarkerEdgeColor","w","LineWidth",0.5, ...
            "DisplayName",sprintf("Generated (%d)",result.count));
    end
    hold(ax,"off");
    xlim(ax,pR); ylim(ax,rR);
    xlabel(ax,"Period (nm)","Color",[0.9 0.92 0.95],"FontWeight","bold");
    ylabel(ax,"Radius (nm)","Color",[0.9 0.92 0.95],"FontWeight","bold");
    if ~isempty(result) && result.count > 0
        ttl = sprintf("Generated %d points (%.2f%% acceptance)",result.count,result.acceptanceRate*100);
    else
        ttl = "Sampling Density Preview";
    end
    title(ax,ttl,"Color",[0.9 0.92 0.95],"FontSize",12);
    legend(ax,"Location","northeast","TextColor",[0.9 0.92 0.95], ...
        "Color",[0.2 0.25 0.3],"EdgeColor",[0.4 0.45 0.5]);
    drawnow;
end


%% ########################################################################
%   STAGE 3 — TRAINING HANDLERS
%  ########################################################################
function handleTrainingEvent(src, event, fig, visPanel)
    name = event.HTMLEventName;
    data = event.HTMLEventData;

    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "trainingController") ...
            && ~isempty(fig.UserData.handles.trainingController)
        fig.UserData.handles.trainingController.handleEvent(name, data);
        return;
    end

    try
        switch name
            case "RunTraining"
                runTrainingPipeline(src, data, fig, visPanel);
            case "StopTraining"
                requestProcessStop(fig);
            case "StopProcess"
                requestProcessStop(fig);
            case "RefreshDbState"
                broadcastDbStatus(fig);
            case "SaveDatabaseRequest"
                saveDbFile(fig);
                broadcastDbStatus(fig);
                sendEventToHTMLSource(src, "SaveComplete", "Database saved.");
            case "BrowseCheckpointFile"
                startDir = fig.UserData.workDir;
                if isfolder("C:/tmp/DNNCheckPoints")
                    startDir = "C:/tmp/DNNCheckPoints";
                end
                [cpFile, cpPath] = uigetfile({'*.mat', 'Model & Checkpoint Files (*.mat)'; '*.*', 'All Files (*.*)'}, ...
                    'Select Pretrained Model or Checkpoint File', startDir);
                if ischar(cpFile) || isstring(cpFile)
                    selectedPath = fullfile(cpPath, cpFile);
                    sendEventToHTMLSource(src, "CheckpointFileSelected", struct( ...
                        "filePath", string(selectedPath), ...
                        "fileName", string(cpFile)));
                end
            case "BrowseCheckpointDir"
                cpDir = uigetdir(fig.UserData.workDir, 'Select Checkpoint Save Directory');
                if ischar(cpDir) || isstring(cpDir)
                    sendEventToHTMLSource(src, "CheckpointDirSelected", struct("dirPath", string(cpDir)));
                end
            case "FindLatestCheckpoint"
                res = findLatestCheckpointFile(fig.UserData.workDir);
                sendEventToHTMLSource(src, "LatestCheckpointFound", res);
            otherwise
                fprintf("[Training] Unknown event: %s\n", name);
        end
    catch ME
        if isProcessStopRequested(fig) || getTrainingStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Training", "Training terminated by user.");
        else
            fprintf("[Training] Error: %s\n%s\n", ME.message, getReport(ME));
            sendEventToHTMLSource(src, "TrainError", ME.message);
        end
    end
end

function runTrainingPipeline(src, d, fig, visPanel)
    if isProcessRunning(fig)
        sendEventToHTMLSource(src, "TrainError", ...
            "A process is already running. Please wait for it to finish or click Stop.");
        return;
    end

    progressDisplayMode = lower(safeStr(d, "progressDisplayMode", "app-panel"));
    useAppProgressPanel = strcmpi(progressDisplayMode, "app-panel");
    if useAppProgressPanel
        reporter = makeReporter(src, fig);
        sendEventToHTMLSource(src, "Progress", struct( ...
            "message", "Progress display: App Right Panel (MATLAB monitor disabled)", ...
            "fraction", 0));
    else
        reporter = ProgressReporter.console();
        reporter.StopCheckFcn = @() isProcessStopRequested(fig);
        sendEventToHTMLSource(src, "Progress", struct( ...
            "message", "Progress display: MATLAB Default Monitor", ...
            "fraction", 0));
    end

    setTrainingStopRequested(fig, false);
    setTrainingRunning(fig, true);
    setProcessRunning(fig, true, "Training");
    cleanupObj = onCleanup(@() cleanupTrainingProcess(fig));

    % Always use MATLAB-side workDir (paths corrupt in JS roundtrip)
    workDir = fig.UserData.workDir;

    % Resolve simulation data file from db
    rawFiles = resolveSimDataFile(fig);
    if isempty(rawFiles)
        sendEventToHTMLSource(src, "TrainError", ...
            "No simulation data loaded. Load data in the Database tab.");
        return
    end

    % Parse metrics list
    metricsList = ["Absorptance", "EF_vol", "EF_surf"];
    if isfield(d, "metricsToTrain") && ~isempty(d.metricsToTrain)
        metricsList = string(d.metricsToTrain);
    end

    networkConfig = struct( ...
        "useMultiHead", safeBool(d, "useMultiHead", true), ...
        "fc1a", safeNum(d, "fc1a", 128), ...
        "fc1b", safeNum(d, "fc1b", 256), ...
        "proj1", safeNum(d, "proj1", 256), ...
        "fc2a", safeNum(d, "fc2a", 512), ...
        "fc2b", safeNum(d, "fc2b", 256), ...
        "headHiddenSizes", parseNumberList(safeStr(d, "headHiddenSizes", "128"), 128));

    targetLossWeights = parseNumberList(safeStr(d, "targetLossWeights", ""), []);
    extraTrainingOptions = parseNameValuePairs(safeStr(d, "extraTrainingOptions", ""));

    % RI CSV: resolve from db, then try auto-detect from workDir
    riFile = resolveRiFile(fig);

    % Pre-trained model for continue-training:
    continueTraining = safeBool(d, "continueTraining", false);
    pretrainedSource = safeStr(d, "pretrainedSource", "db");
    customPretrainedFile = strtrim(safeStr(d, "customPretrainedFile", ""));

    if continueTraining
        if (pretrainedSource == "file" || customPretrainedFile ~= "") && isfile(customPretrainedFile)
            preTrainedModelFile = string(customPretrainedFile);
        else
            preTrainedModelFile = resolvePretrainedModel(fig);
        end
        if preTrainedModelFile == "" || ~isfile(preTrainedModelFile)
            sendEventToHTMLSource(src, "TrainError", ...
                "Continue Training is enabled, but no valid pretrained model or checkpoint file was found. Please browse for a valid .mat file or uncheck 'Continue Training'.");
            return;
        end
    else
        preTrainedModelFile = "";
    end

    % Auto-generate output model file (temp location for artifacts)
    defaultModelFile = fullfile(tempdir, "sers_dnn_model.mat");
    if safeBool(d, "saveArtifacts", true) && ~isempty(rawFiles)
        [~, baseName, ~] = fileparts(rawFiles(1));
        defaultModelFile = fullfile(workDir, baseName + "_model.mat");
    end

    plotsMode = safeStr(d, "plots", "none");
    if useAppProgressPanel
        plotsMode = "none";
    end

    featureSchema = safeStr(d, "featureSchema", "v2_physics");
    splitMode     = safeStr(d, "splitMode", "geometry");
    incVertGap    = safeBool(d, "includeVerticalGap", false);
    gapHeightUm   = safeNum(d, "gapHeightUm", 0.005);

    cfg = trainingConfig( ...
        WorkDir             = workDir, ...
        RawDataFiles        = rawFiles(:)', ...
        RICsvFile           = riFile, ...
        OutputModelFile     = defaultModelFile, ...
        PreTrainedModelFile = preTrainedModelFile, ...
        ContinueTraining    = continueTraining, ...
        RatioLimit          = [safeNum(d,"ratioLimitMin",0), safeNum(d,"ratioLimitMax",0.49)], ...
        MetricsToTrain      = metricsList, ...
        MaxEpochs           = safeNum(d, "maxEpochs", 200), ...
        MiniBatchSize       = safeNum(d, "miniBatchSize", 1024), ...
        LearningRate        = safeNum(d, "learningRate", 1e-4), ...
        Verbose             = safeBool(d, "verbose", true), ...
        Holdout             = safeNum(d, "holdout", 0.2), ...
        ValSplit            = safeNum(d, "valSplit", 0.5), ...
        FeatureSchema       = featureSchema, ...
        SplitMode           = splitMode, ...
        IncludeVerticalGap  = incVertGap, ...
        GapHeightUm         = gapHeightUm, ...
        SaveArtifacts       = safeBool(d, "saveArtifacts", true), ...
        FeatureLogTransform = safeBool(d, "featureLogTransform", true), ...
        IncludeRatios       = safeBool(d, "includeRatios", featureSchema == "v1_legacy"), ...
        TargetLogTransform  = safeBool(d, "targetLogTransform", true), ...
        Optimizer           = safeStr(d, "optimizer", "adam"), ...
        LossFunction        = safeStr(d, "lossFunction", "mse"), ...
        LearnRateSchedule   = safeStr(d, "learnRateSchedule", "piecewise"), ...
        LearnRateDropFactor = safeNum(d, "learnRateDropFactor", 0.85), ...
        LearnRateDropPeriod = safeNum(d, "learnRateDropPeriod", 5), ...
        GradientThreshold   = safeNum(d, "gradientThreshold", inf), ...
        GradientThresholdMethod = safeStr(d, "gradientThresholdMethod", "l2norm"), ...
        L2Regularization    = safeNum(d, "l2Regularization", 0.0001), ...
        Momentum                = safeNum(d, "momentum", 0.9), ...
        GradientDecayFactor      = safeNum(d, "gradientDecayFactor", 0.9), ...
        SquaredGradientDecayFactor = safeNum(d, "squaredGradientDecayFactor", 0.999), ...
        Epsilon                 = safeNum(d, "epsilon", 1e-8), ...
        Shuffle                 = safeStr(d, "shuffle", "every-epoch"), ...
        ValidationFrequency     = safeNum(d, "validationFrequency", NaN), ...
        ValidationPatience      = safeNum(d, "validationPatience", NaN), ...
        VerboseFrequency        = safeNum(d, "verboseFrequency", NaN), ...
        Plots                   = plotsMode, ...
        ObjectiveMetricName     = safeStr(d, "objectiveMetricName", "loss"), ...
        OutputNetwork           = safeStr(d, "outputNetwork", "auto"), ...
        ExecutionEnvironment    = safeStr(d, "executionEnvironment", "auto"), ...
        PreprocessingEnvironment = safeStr(d, "preprocessingEnvironment", "serial"), ...
        Acceleration            = safeStr(d, "acceleration", "auto"), ...
        CheckpointPath          = safeStr(d, "checkpointPath", ""), ...
        CheckpointFrequency     = safeNum(d, "checkpointFrequency", NaN), ...
        CheckpointFrequencyUnit = safeStr(d, "checkpointFrequencyUnit", "epoch"), ...
        ResetInputNormalization = safeBool(d, "resetInputNormalization", true), ...
        BatchNormalizationStatistics = safeStr(d, "batchNormalizationStatistics", "auto"), ...
        SequenceLength          = safeStr(d, "sequenceLength", "longest"), ...
        SequencePaddingDirection = safeStr(d, "sequencePaddingDirection", "right"), ...
        SequencePaddingValue    = safeNum(d, "sequencePaddingValue", 0), ...
        InputDataFormats        = safeStr(d, "inputDataFormats", "auto"), ...
        TargetDataFormats       = safeStr(d, "targetDataFormats", "auto"), ...
        CategoricalInputEncoding = safeStr(d, "categoricalInputEncoding", "integer"), ...
        CategoricalTargetEncoding = safeStr(d, "categoricalTargetEncoding", "auto"), ...
        ExtraTrainingOptions    = extraTrainingOptions, ...
        NetworkConfig       = networkConfig, ...
        TargetLossWeights   = targetLossWeights);
    cfg.stopTrainingFcn = @() (getTrainingStopRequested(fig) || isProcessStopRequested(fig));

    results = runTrainingWorkflow(cfg, reporter);

    % Render training diagnostics into the right panel
    try
        delete(allchild(visPanel));
        visualizeTrainingResults(results, Parent=visPanel);
    catch ME2
        fprintf("[Training] Visualization error: %s\n", ME2.message);
    end

    % Write-back to unified database
    try
        if isfield(results, "db") && isstruct(results.db)
            fig.UserData.db = results.db;
        end
        if isfield(results, "model") && isstruct(results.model)
            if ~isfield(fig.UserData.db, "Model") || ~isstruct(fig.UserData.db.Model)
                fig.UserData.db.Model = struct();
            end
            fig.UserData.db.Model.Model = results.model;
            if isfield(results.model, "net")
                fig.UserData.db.Model.Net = results.model.net;
            end
            if isfield(results.model, "targetNames")
                fig.UserData.db.Model.TargetNames = cellstr(results.model.targetNames);
            end
            if isfield(cfg, "outputModelFile") && isfile(string(cfg.outputModelFile))
                fig.UserData.db.Model.NetFile = string(cfg.outputModelFile);
            end

            % Directly populate visExport so Prediction/Visualization works immediately
            ve = fig.UserData.visExport;
            ve.model = results.model;
            ve.modelLoaded = true;
            ve.ri = resolveRefractiveIndexStruct(fig);
            fig.UserData.visExport = ve;
        end
        markDbDirty(fig);
    catch ME_db
        fprintf("[Training] DB write-back warning: %s\n", ME_db.message);
    end

    if getTrainingStopRequested(fig) || isProcessStopRequested(fig)
        notifyProcessStopped(fig, "Training", ...
            sprintf("Training stopped by user and finalized in %.1f s", results.elapsedTotal));
    else
        sendEventToHTMLSource(src, "TrainComplete", ...
            sprintf("Training complete in %.1f s", results.elapsedTotal));
    end
    clear cleanupObj
end

function setTrainingRunning(fig, value)
if ~isvalid(fig)
    return
end
if ~isfield(fig.UserData, "training") || ~isstruct(fig.UserData.training)
    fig.UserData.training = struct("isRunning", false, "stopRequested", false);
end
fig.UserData.training.isRunning = logical(value);
if ~logical(value)
    fig.UserData.training.stopRequested = false;
end
end

function setTrainingStopRequested(fig, value)
if ~isvalid(fig)
    return
end
if ~isfield(fig.UserData, "training") || ~isstruct(fig.UserData.training)
    fig.UserData.training = struct("isRunning", false, "stopRequested", false);
end
fig.UserData.training.stopRequested = logical(value);
end

function value = getTrainingStopRequested(fig)
value = false;
if ~isvalid(fig)
    return
end
if isfield(fig.UserData, "training") && isstruct(fig.UserData.training) && ...
        isfield(fig.UserData.training, "stopRequested")
    value = logical(fig.UserData.training.stopRequested);
end
end

function res = findLatestCheckpointFile(workDir)
%findLatestCheckpointFile Scan disk for recent checkpoint/model .mat files.
    candidateDirs = [
        "C:/tmp/DNNCheckPoints", ...
        fullfile(workDir, "DNNCheckpoints"), ...
        "C:/tmp/DNNCheckPoints_archive"
    ];
    allFiles = [];
    for k = 1:numel(candidateDirs)
        dPath = candidateDirs(k);
        if isfolder(dPath)
            files = dir(fullfile(dPath, "**", "*.mat"));
            if ~isempty(files)
                if isempty(allFiles)
                    allFiles = files;
                else
                    allFiles = [allFiles; files]; %#ok<AGROW>
                end
            end
        end
    end

    res = struct("found", false, "filePath", "", "fileName", "", "dateStr", "", "infoStr", "");
    if isempty(allFiles)
        return;
    end

    % Sort by datenum descending (newest first)
    [~, sortIdx] = sort([allFiles.datenum], "descend");
    allFiles = allFiles(sortIdx);

    for k = 1:numel(allFiles)
        fPath = fullfile(allFiles(k).folder, allFiles(k).name);
        try
            vars = whos('-file', fPath);
            varNames = {vars.name};
            if any(ismember(varNames, {'net', 'Net', 'model', 'Model'}))
                res.found = true;
                res.filePath = string(fPath);
                res.fileName = string(allFiles(k).name);
                res.dateStr = string(allFiles(k).date);
                if ismember('info', varNames)
                    S = load(fPath, 'info');
                    if isfield(S, 'info') && isstruct(S.info)
                        if isfield(S.info, 'Epoch') && isfield(S.info, 'Iteration')
                            res.infoStr = sprintf("Epoch %d, Iteration %d", S.info.Epoch, S.info.Iteration);
                        elseif isfield(S.info, 'Epoch')
                            res.infoStr = sprintf("Epoch %d", S.info.Epoch);
                        end
                    end
                end
                return;
            end
        catch
            continue;
        end
    end
end

%% ########################################################################
%   STAGE 5 — OPTIMIZATION HANDLERS
%  ########################################################################
function handleOptimizeEvent(src, event, fig, ax)
    name = event.HTMLEventName;
    data = event.HTMLEventData;

    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "optimizeController") ...
            && ~isempty(fig.UserData.handles.optimizeController)
        fig.UserData.handles.optimizeController.handleEvent(name, data);
        return;
    end

    try
        switch name
            case "RunOptimize"
                runOptimizePipeline(src, data, fig, ax);
            case "PreviewMetric"
                previewOptimizeMetric(src, data, fig, ax);
            case "UpdateSeeds"
                updateOptimizerSeeds(src, data, fig, ax);
            case "ImportSeedsCsv"
                importSeedsCsv(src, data, fig, ax);
            case "ExportResults"
                exportOptimizeResults(src, data, fig);
            case "GeneratePredictions"
                generateDensePredictions(src, data, fig);
            case "SaveOptimaToDb"
                saveOptimaToDb(src, data, fig);
            case "GetDbOptima"
                sendDbOptimaToPanel(src, fig);
            case "DeleteDbOptima"
                deleteDbOptima(src, data, fig);
            case "SetSeedsFromDbOptima"
                setSeedsFromDbOptima(src, data, fig);
            case "RefreshDbState"
                broadcastDbStatus(fig);
            case "SaveDatabaseRequest"
                saveDbFile(fig);
                broadcastDbStatus(fig);
                sendOptimizeEvent(fig, "SaveComplete", "Database saved.", src);
            case "MetricChanged"
                updateMetricState(src, data, fig);
            case "StopProcess"
                requestProcessStop(fig);
            case "StopOptimize"
                requestProcessStop(fig);
            otherwise
                fprintf("[Optimize] Unknown event: %s\n", name);
        end
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Optimize", "Optimization terminated by user.");
            return;
        end
        try
            fprintf("[Optimize] ERROR in handleOptimizeEvent (%s):\n%s\n", name, getReport(ME, "extended", "hyperlinks", "off"));
        catch
        end
        sendOptimizeEvent(fig, "OptimizeError", ME.message, src);
    end
end

function generateDensePredictions(src, d, fig)
%generateDensePredictions  Generate dense predictions and write to db.Pred.
    setProcessRunning(fig, true, "Optimize");
    cleanupObj = onCleanup(@() cleanupProcess(fig));
    try
        reporter = makeOptimizeReporter(fig, src);
        reporter.info("Generating dense predictions...");

        [modelFile, riCsvFile, ~, ~] = resolveDbPaths(fig);
        if strlength(modelFile) == 0
            sendOptimizeEvent(fig, "PredictionsError", "No model available in database.", src);
            return
        end

        workDir = fig.UserData.workDir;
        laserWl     = safeNum(d, "laserWavelength", 785);
        periodMin   = safeNum(d, "periodMin", 400);
        periodMax   = safeNum(d, "periodMax", 1400);
        radiusMin   = safeNum(d, "radiusMin", 50);
        radiusMax   = safeNum(d, "radiusMax", 450);
        spatialRes  = safeNum(d, "spatialResolution", 2);
        stokesMin   = safeNum(d, "stokesShiftMin", 100);
        stokesMax   = safeNum(d, "stokesShiftMax", 3600);
        stokesRes   = safeNum(d, "stokesShiftResolution", 5);

        % Metrics window
        linkMetrics = true;
        if isfield(d, "linkMetricsToGrid")
            linkMetrics = logical(d.linkMetricsToGrid);
        end
        metricsMin = safeNum(d, "metricsShiftMin", stokesMin);
        metricsMax = safeNum(d, "metricsShiftMax", stokesMax);

        cfg = predictionVisConfig( ...
            WorkDir             = workDir, ...
            ModelFile           = modelFile, ...
            RiCsvFile           = riCsvFile, ...
            LambdaLaser         = laserWl, ...
            PLimits             = [periodMin, periodMax], ...
            RLimits             = [radiusMin, radiusMax], ...
            Resolution          = spatialRes, ...
            StokesShiftLimits   = [stokesMin, stokesMax], ...
            StokesShiftResolution = stokesRes, ...
            LinkMetricsToGrid   = linkMetrics, ...
            MetricsShiftLimits  = [metricsMin, metricsMax], ...
            RecomputePredictions = true, ...
            ExportPredictions   = false, ...
            ExportGraphics      = false);

        % Resolve model & RI from app state
        model = [];
        ri = [];
        if isfield(fig.UserData, "visExport") && isfield(fig.UserData.visExport, "model") ...
                && ~isempty(fig.UserData.visExport.model)
            model = fig.UserData.visExport.model;
        end
        if isfield(fig.UserData, "visExport") && isfield(fig.UserData.visExport, "ri") ...
                && ~isempty(fig.UserData.visExport.ri)
            ri = fig.UserData.visExport.ri;
        else
            ri = resolveRefractiveIndexStruct(fig, riCsvFile);
        end

        % Optional analyte spectrum
        analyteSpec = struct();
        if isfield(fig.UserData, "visExport") && isfield(fig.UserData.visExport, "analyteSpectrum") ...
                && isstruct(fig.UserData.visExport.analyteSpectrum)
            analyteSpec = fig.UserData.visExport.analyteSpectrum;
        elseif isfield(fig.UserData.db, "Global") && isfield(fig.UserData.db.Global, "AnalyteSpectrumFile") ...
                && isfile(string(fig.UserData.db.Global.AnalyteSpectrumFile))
            try
                analyteSpec = loadAndNormalizeAnalyteSpectrum(char(fig.UserData.db.Global.AnalyteSpectrumFile));
            catch
            end
        end

        loadPredArgs = { ...
            "Recompute", true, ...
            "Model", model, "Ri", ri, ...
            "PSamples", cfg.pSamples, "RSamples", cfg.rSamples, ...
            "LambdaSamples", cfg.lambdaSamples, ...
            "LambdaLaser", laserWl, ...
            "StokesShiftLimits", [stokesMin, stokesMax], ...
            "AnalyteSpectrum", analyteSpec, ...
            "InterpResolution", stokesRes, ...
            "PredictionFile", cfg.predictionFile, ...
            "SaveAfterGeneration", false, ...
            "Reporter", reporter};
        if ~linkMetrics
            loadPredArgs = [loadPredArgs, {"MetricsShiftLimits", [metricsMin, metricsMax]}];
        end

        allDataRaw = loadOrGeneratePredictions(loadPredArgs{:});

        if isstruct(allDataRaw) && structRowCount(allDataRaw) > 0
            fig.UserData.db.Pred = allDataRaw;
            markDbDirty(fig);
            broadcastDbStatus(fig);
            n = structRowCount(allDataRaw);
            reporter.complete("GeneratePredictions", sprintf("Dense predictions ready (%d entries).", n));
            sendOptimizeEvent(fig, "PredictionsGenerated", struct("count", n), src);
        else
            sendOptimizeEvent(fig, "PredictionsError", "Generated prediction dataset was empty.", src);
        end
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Optimize", "Dense predictions terminated by user.");
            return;
        end
        sendOptimizeEvent(fig, "PredictionsError", ME.message, src);
    end
end

function saveOptimaToDb(src, d, fig)
%saveOptimaToDb  Append current optimization results to db.Optima.
    try
        seeds = d;
        if isstruct(d) && isfield(d, "seeds")
            seeds = d.seeds;
        end
        if isempty(seeds)
            sendOptimizeEvent(fig, "OptimizeError", "No optima to save.", src);
            return
        end

        % Normalize to struct array
        if iscell(seeds)
            seeds = [seeds{:}];
        end
        if ~isstruct(seeds)
            sendOptimizeEvent(fig, "OptimizeError", "Invalid optima format.", src);
            return
        end

        % IMPORTANT: authoritative metric state is in fig.UserData.optimize
        % (right-panel payload may contain stale defaults from hidden controls).
        optimizedMetric = "";
        metricVariant = "";
        if isfield(fig.UserData, "optimize") && isfield(fig.UserData.optimize, "baseMetric")
            optimizedMetric = string(fig.UserData.optimize.baseMetric);
        elseif isstruct(d) && isfield(d, "metric") && strlength(string(d.metric)) > 0
            optimizedMetric = string(d.metric);
        end
        if isfield(fig.UserData, "optimize") && isfield(fig.UserData.optimize, "metricVariant")
            metricVariant = string(fig.UserData.optimize.metricVariant);
        elseif isstruct(d) && isfield(d, "metricVariant") && strlength(string(d.metricVariant)) > 0
            metricVariant = string(d.metricVariant);
        end
        optimizedMetricCanonical = canonicalMetricName(optimizedMetric, metricVariant);

        db = fig.UserData.db;
        if ~isfield(db, "Optima") || ~isstruct(db.Optima) || ~isfield(db.Optima, "period")
            db.Optima = struct( ...
                "period", zeros(0,1), "radius", zeros(0,1), ...
                "basinTag", string.empty(0,1), "optimizedMetric", string.empty(0,1));
        end

        nSeeds = numel(seeds);
        nSaved = 0;
        for i = 1:nSeeds
            s = seeds(i);
            p  = NaN; r = NaN; tag = "";

            if isfield(s, "period")
                p = double(s.period);
            elseif isfield(s, "P")
                p = double(s.P);
            elseif isfield(s, "p")
                p = double(s.p);
            end

            if isfield(s, "radius")
                r = double(s.radius);
            elseif isfield(s, "R")
                r = double(s.R);
            elseif isfield(s, "r")
                r = double(s.r);
            end

            if isfield(s, "tag"), tag = string(s.tag);
            elseif isfield(s, "Tag"), tag = string(s.Tag); end

            if ~isfinite(p) || ~isfinite(r)
                continue;
            end

            db.Optima.period(end+1,1) = p;
            db.Optima.radius(end+1,1) = r;
            db.Optima.basinTag(end+1,1) = tag;
            db.Optima.optimizedMetric(end+1,1) = optimizedMetricCanonical;
            nSaved = nSaved + 1;
        end

        if nSaved == 0
            sendOptimizeEvent(fig, "OptimizeError", "No valid P/R coordinates found in current seeds.", src);
            return
        end

        fig.UserData.db = db;
        markDbDirty(fig);
        broadcastDbStatus(fig);
        sendOptimizeEvent(fig, "OptimaSaved", struct( ...
            "count", nSaved, "total", numel(db.Optima.period)), src);
    catch ME
        sendOptimizeEvent(fig, "OptimizeError", "Failed to save optima: " + ME.message, src);
    end
end

function sendDbOptimaToPanel(src, fig)
%sendDbOptimaToPanel  Send current db.Optima rows to the HTML panel.
    db = fig.UserData.db;
    if ~isfield(db, "Optima") || ~isfield(db.Optima, "period") || isempty(db.Optima.period)
        sendOptimizeEvent(fig, "DbOptimaData", struct("optima", []), src);
        return
    end
    opt = db.Optima;
    n = numel(opt.period);
    rows = cell(n, 1);
    for i = 1:n
        tagVal = "";
        if isfield(opt, "basinTag") && numel(opt.basinTag) >= i
            tagVal = opt.basinTag(i);
        end
        metricVal = "";
        if isfield(opt, "optimizedMetric") && numel(opt.optimizedMetric) >= i
            metricVal = opt.optimizedMetric(i);
        end
        rows{i} = struct( ...
            "period", opt.period(i), ...
            "radius", opt.radius(i), ...
            "basinTag", tagVal, ...
            "metric", metricVal);
    end
    sendOptimizeEvent(fig, "DbOptimaData", struct("optima", {rows}), src);
end

function deleteDbOptima(src, d, fig)
%deleteDbOptima  Delete selected rows from db.Optima by index.
    try
        indices = d.indices;
        if isempty(indices)
            sendOptimizeEvent(fig, "OptimizeError", "No rows selected for deletion.", src);
            return
        end
        db = fig.UserData.db;
        if ~isfield(db, "Optima") || ~isfield(db.Optima, "period")
            return
        end
        n = numel(db.Optima.period);
        keep = true(n, 1);
        keep(indices) = false;
        fns = fieldnames(db.Optima);
        for i = 1:numel(fns)
            db.Optima.(fns{i}) = db.Optima.(fns{i})(keep);
        end
        fig.UserData.db = db;
        markDbDirty(fig);
        broadcastDbStatus(fig);
        sendDbOptimaToPanel(src, fig);
    catch ME
        sendOptimizeEvent(fig, "OptimizeError", "Delete failed: " + ME.message, src);
    end
end

function setSeedsFromDbOptima(src, d, fig)
%setSeedsFromDbOptima  Copy selected db.Optima rows into seeds.
    try
        indices = d.indices;
        db = fig.UserData.db;
        if ~isfield(db, "Optima") || ~isfield(db.Optima, "period")
            sendOptimizeEvent(fig, "OptimizeError", "No saved optima in database.", src);
            return
        end
        seeds = struct([]);
        for i = 1:numel(indices)
            idx = indices(i);
            pVal = double(db.Optima.period(idx));
            rVal = double(db.Optima.radius(idx));
            tagVal = string(db.Optima.basinTag(idx));

            % Primary fields expected by optimization_tab.html renderer
            seeds(i).P = pVal;
            seeds(i).R = rVal;
            seeds(i).Tag = tagVal;
            seeds(i).Value = NaN;

            % Compatibility aliases used by backend paths
            seeds(i).period = pVal;
            seeds(i).radius = rVal;
            seeds(i).tag = tagVal;
            seeds(i).value = NaN;
            seeds(i).enabled = true;
        end
        sendOptimizeEvent(fig, "SeedsUpdated", struct("seeds", seeds), src);
    catch ME
        sendOptimizeEvent(fig, "OptimizeError", "Set seeds failed: " + ME.message, src);
    end
end

function metricName = localCanonicalMetricName(baseMetric, metricVariant)
%localCanonicalMetricName  Thin delegate — see canonicalMetricName.
    metricName = canonicalMetricName(baseMetric, metricVariant);
end

function runOptimizePipeline(src, d, fig, ax)
    reporter = makeOptimizeReporter(fig, src);
    setProcessRunning(fig, true, "Optimize");
    cleanupObj = onCleanup(@() cleanupProcess(fig));
    showMultiStartPaths = safeBool(d, "showMultiStartPaths", false);
    forceTraceMode = showMultiStartPaths;
    if forceTraceMode
        multiStartDisplayMode = "iter";
    else
        multiStartDisplayMode = safeStr(d, "multiStartDisplay", "off");
    end
    
    % Initialize and validate optimization state
    if ~isfield(fig.UserData, "optimize")
        fig.UserData.optimize = struct();
    end
    validateOptimizeState(fig.UserData.optimize);

    workDir = fig.UserData.workDir;
    mode = lower(safeStr(d, "mode", "detect"));

    % Resolve model and data file paths from db struct
    [modelFile, riCsvFile, dataFile, predictionFile] = resolveDbPaths(fig);

    % Grid definition: always inherited from the last Preview run to guarantee
    % that detect and refine use the identical grid as the heatmap.
    % Falls back to current UI values if Preview has not been run yet.
    if isfield(fig.UserData, "optimize") && isfield(fig.UserData.optimize, "gridDefinition")
        gd = fig.UserData.optimize.gridDefinition;
        gridLambdaLaser  = gd.lambdaLaser;
        gridPLimits      = gd.pLimits;
        gridRLimits      = gd.rLimits;
        gridRawStokesMin = gd.stokesShiftMin;
        gridRawStokesMax = gd.stokesShiftMax;
        gridSpatialRes   = gd.spatialResolution;
        gridStokesRes    = gd.stokesShiftResolution;
    else
        gridLambdaLaser  = safeNum(d, "laserWavelength", 785);
        gridPLimits      = [safeNum(d, "periodMin", 400), safeNum(d, "periodMax", 1400)];
        gridRLimits      = [safeNum(d, "radiusMin", 50),  safeNum(d, "radiusMax", 450)];
        gridRawStokesMin = safeNum(d, "stokesShiftMin", 100);
        gridRawStokesMax = safeNum(d, "stokesShiftMax", 3600);
        gridSpatialRes   = safeNum(d, "spatialResolution", 0.7);
        gridStokesRes    = safeNum(d, "stokesShiftResolution", 5);
    end

    spatialResolution = gridSpatialRes;
    stokesShiftResolution = gridStokesRes;
    tuningRadiusNm = safeNum(d, "refinementRadius", 10);
    if tuningRadiusNm <= 0
        tuningRadiusNm = 20;
    end

    % Metrics window
    linkMetrics = true;
    if isfield(d, "linkMetricsToGrid")
        linkMetrics = logical(d.linkMetricsToGrid);
    end
    metricsMin = safeNum(d, "metricsShiftMin", gridRawStokesMin);
    metricsMax = safeNum(d, "metricsShiftMax", gridRawStokesMax);

    % Extract base metric and variant
    baseMetric = safeStr(d, "metric", "Absorptance");
    metricVariant = safeStr(d, "metricVariant", "laser");

    % Determine Stokes shift range based on variant
    if metricVariant == "laser"
        % Zero-width window at laser wavelength
        stokesShiftMin = 0;
        stokesShiftMax = 0;
    else
        stokesShiftMin = gridRawStokesMin;
        stokesShiftMax = gridRawStokesMax;
    end

    % Check for cached allData from preview or db.Pred
    cachedAllData = [];
    if isfield(fig.UserData, "optimize")
        if isfield(fig.UserData.optimize, "previewResults") && isstruct(fig.UserData.optimize.previewResults) ...
                && isfield(fig.UserData.optimize.previewResults, "allData") && ~isempty(fig.UserData.optimize.previewResults.allData)
            cachedAllData = fig.UserData.optimize.previewResults.allData;
        elseif isfield(fig.UserData.optimize, "lastResults") && isstruct(fig.UserData.optimize.lastResults) ...
                && isfield(fig.UserData.optimize.lastResults, "allData") && ~isempty(fig.UserData.optimize.lastResults.allData)
            cachedAllData = fig.UserData.optimize.lastResults.allData;
        end
    end
    if isempty(cachedAllData) && isfield(fig.UserData, "db") && isfield(fig.UserData.db, "Pred") ...
            && structRowCount(fig.UserData.db.Pred) > 0
        cachedAllData = extractBranchAsSoA(fig.UserData.db, "Pred");
    end

    dataSource = safeStr(d, "dataSource", "model");
    shouldRecompute = safeBool(d, "recomputePredictions", false);
    if dataSource == "predictions" || (~isempty(cachedAllData) && ~shouldRecompute)
        recompFlag = false;
    else
        recompFlag = (mode ~= "refine");
    end

    cfg = localizeMaximaConfig( ...
        WorkDir          = workDir, ...
        DataSource       = dataSource, ...
        DataFile         = dataFile, ...
        DiscreteOnly     = safeBool(d, "discreteOnly", false), ...
        ModelFile        = modelFile, ...
        RiCsvFile        = riCsvFile, ...
        PredictionFile   = predictionFile, ...
        RecomputePredictions = recompFlag, ...
        LambdaLaser      = gridLambdaLaser, ...
        PLimits          = gridPLimits, ...
        RLimits          = gridRLimits, ...
        StokesShiftLimits = [stokesShiftMin, stokesShiftMax], ...
        StokesShiftResolution = stokesShiftResolution, ...
        MetricsToLocate  = string(baseMetric), ...
        LinkMetricsToGrid = linkMetrics, ...
        MetricsShiftLimits = [metricsMin, metricsMax], ...
        Resolution       = spatialResolution, ...
        NumLocalMaxima   = safeNum(d, "candidateTopN", 10), ...
        MultiStartPoints = safeNum(d, "numStartPoints", 50), ...
        MultiStartUseParallel = safeBool(d, "multiStartUseParallel", true) && ~forceTraceMode, ...
        ShowIterationPaths = forceTraceMode, ...
        MultiStartDisplay = multiStartDisplayMode, ...
        FunctionTolerance = safeNum(d, "functionTolerance", 1e-9), ...
        StepTolerance = safeNum(d, "stepTolerance", 1e-9), ...
        MaxIterations = round(safeNum(d, "maxIterations", 10000)), ...
        FminconAlgorithm = safeStr(d, "fminconAlgorithm", "interior-point"), ...
        MaxFunctionEvaluations = round(safeNum(d, "maxFunctionEvaluations", 10000)), ...
        ConstraintTolerance = safeNum(d, "constraintTolerance", 1e-9), ...
        OptimalityTolerance = safeNum(d, "optimalityTolerance", 1e-9), ...
        BasinRetryCount = round(safeNum(d, "basinRetryCount", 4)), ...
        BasinRetryShrinkFactor = safeNum(d, "basinRetryShrinkFactor", 0.5), ...
        KeepRejectedSeeds = safeBool(d, "keepRejectedSeeds", true), ...
        UseAnalyticalGradients = safeBool(d, "useAnalyticalGradients", true), ...
        UseGradientSeedInit = safeBool(d, "useGradientSeedInit", true), ...
        GradientSeedCount = round(safeNum(d, "gradientSeedCount", 0)), ...
        GradientSeedGridSize = round(safeNum(d, "gradientSeedGridSize", 20)), ...
        TuningRadius     = tuningRadiusNm * 1e-3);

    cfg.metricVariant = metricVariant;
    if ~isempty(cachedAllData)
        cfg.cachedAllData = cachedAllData;
    end
    if isfield(fig.UserData, "optimize") && isfield(fig.UserData.optimize, "previewResults") ...
            && isstruct(fig.UserData.optimize.previewResults) && isfield(fig.UserData.optimize.previewResults, "predictor") ...
            && ~isempty(fig.UserData.optimize.previewResults.predictor)
        cfg.predictor = fig.UserData.optimize.previewResults.predictor;
    end

    if mode == "detect"
        cfg.discreteOnly = true;
    elseif mode == "refine"
        cfg.discreteOnly = false;  % Enable MultiStart optimization
        if isfield(d, "seeds") && ~isempty(d.seeds)
            cfg.initialCandidates = buildSeedTable(d.seeds);
            % Skip the expensive grid generation — model-only evaluation path
            cfg.skipGridGeneration = true;
        end
        
        % Initialize parallel pool only when not forcing iteration-path tracing
        if ~forceTraceMode && cfg.multiStartUseParallel
            try
                pool = gcp('nocreate');
                if isempty(pool)
                    % Use process-based pool (not 'Threads'). Thread-based pools
                    % share the main process class loader — inside a uihtml callback,
                    % this causes a WebComponent parse error when MultiStart loads
                    % Global Optimization Toolbox classes. Process-based workers
                    % have independent class loaders, avoiding the conflict.
                    parpool("Processes");
                elseif isa(pool, 'parallel.ThreadPool')
                    % Thread pool already running — replace with process pool
                    delete(pool);
                    parpool("Processes");
                end
            catch ME
                fprintf("[Optimize] Warning: Could not initialize parallel pool: %s\n", ME.message);
                fprintf("[Optimize] Continuing with serial execution.\n");
            end
        end
    end

    results = runLocalizationWorkflow(cfg, reporter);

    % Retain process-based pool across session runs (torn down cleanly on app exit via onAppClose)

    % Store results in app state for later export
    if ~isfield(fig.UserData, "optimize")
        fig.UserData.optimize = struct();
    end
    % State management: clear old refined results when new detection/refinement happens
    fig.UserData.optimize.lastResults = results;
    fig.UserData.optimize.config = d;
    fig.UserData.optimize.baseMetric = baseMetric;
    fig.UserData.optimize.metricVariant = metricVariant;
    % Initialize currentSeeds tracking
    if ~isfield(fig.UserData.optimize, "currentSeeds")
        fig.UserData.optimize.currentSeeds = [];
    end

    if mode == "detect"
        % Detect mode: show only seeds on heatmap
        candidates = extractCandidatesFromResults(results, safeNum(d, "candidateTopN", 10), ...
            safeNum(d, "prominenceThreshold", 0));
        
        try
            delete(allchild(ax));
            plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, [], candidates, [], false);
        catch ME2
            fprintf("[Optimize] Visualization error: %s\n", ME2.message);
        end
        
        sendOptimizeEvent(fig, "SeedsFound", candidates, src);
        sendOptimizeEvent(fig, "OptimizeComplete", ...
            sprintf("Seed detection complete (%d candidates).", numel(candidates)), src);
        return;
    end

    % Refine mode: extract refined seeds with inherited tags, then plot
    refinedSeeds = [];
    originalSeeds = [];
    attemptTrajectories = [];
    
    try
        if mode == "refine"
            % Use incoming UI seeds when available (for tag inheritance only)
            if isfield(d, "seeds") && ~isempty(d.seeds)
                originalSeeds = normalizeSeedInput(d.seeds);
            else
                originalSeeds = [];
            end

            % Always extract refined optima from maximaResults.
            % Use robust inline extraction to avoid helper edge cases.
            refinedSeeds = extractRefinedSeeds(results, baseMetric, originalSeeds);
            attemptTrajectories = extractAttemptTrajectories(results, baseMetric);
            reporter.info(sprintf("[Optimize] Overlay data prepared: refined=%d, trajectories=%d, showPaths=%d", ...
                numel(refinedSeeds), numel(attemptTrajectories), showMultiStartPaths));
        end
    catch ME_refine
        reporter.warn("Optimize", sprintf("Refine extraction failed: %s", ME_refine.message));
        refinedSeeds = [];
        attemptTrajectories = [];
    end

    % Plot heatmap with both original seeds (X) and refined optima (O)
    try
        if isvalid(ax)
            delete(allchild(ax));
            plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, ...
                originalSeeds, refinedSeeds, attemptTrajectories, showMultiStartPaths);
        else
            fprintf("[Optimize] Warning: Axes no longer valid, skipping plot update\n");
        end
    catch ME2
        fprintf("[Optimize] Visualization error: %s\n", ME2.message);
    end

    % Send refined seeds back to UI (always in refine mode, even if empty)
    if mode == "refine"
        reporter.info(sprintf("[Optimize] Emitting SeedsRefined: seeds=%d, trajectories=%d", ...
            numel(refinedSeeds), numel(attemptTrajectories)));
        sendOptimizeEvent(fig, "SeedsRefined", struct( ...
            "seeds", refinedSeeds, ...
            "attemptTrajectories", attemptTrajectories), src);
    end

    if safeBool(d, "exportResults", true)
        assignin("base", "maximaResults", results);
    end

    % Write-back to unified database
    try
        if isfield(results, "allData") && isstruct(results.allData)
            if ~isfield(fig.UserData.db, "Pred") || ~isstruct(fig.UserData.db.Pred)
                fig.UserData.db.Pred = struct();
            end
            fig.UserData.db.Pred = results.allData;
        end
        markDbDirty(fig);
    catch ME_db
        fprintf("[Optimize] DB write-back warning: %s\n", ME_db.message);
    end

    sendOptimizeEvent(fig, "OptimizeComplete", ...
        sprintf("Found %d maxima in %.1f s", ...
            countMaximaResults(results), results.elapsedTotal), src);
end

function candidates = localExtractCandidates(results, topN, prominenceThreshold)
%localExtractCandidates  Thin delegate — see extractCandidatesFromResults.
    candidates = extractCandidatesFromResults(results, topN, prominenceThreshold);
end

function seedTable = localBuildSeedTable(seeds)
%localBuildSeedTable  Thin delegate — see buildSeedTable.
    seedTable = buildSeedTable(seeds);
end

function candidates = localCandidatesToStruct(candidateTable) %#ok<DEFNU>
%localCandidatesToStruct  Kept for compatibility; see extractCandidatesFromResults.
    candidates = struct("P", {}, "R", {}, "Value", {}, "Tag", {});
    if isempty(candidateTable) || height(candidateTable) == 0, return; end
    hasGridValue = any(strcmp(candidateTable.Properties.VariableNames, "GridValue"));
    hasTag = any(strcmp(candidateTable.Properties.VariableNames, "Tag"));
    for i = 1:height(candidateTable)
        candidates(i).P = candidateTable.P_um(i) * 1e3;
        candidates(i).R = candidateTable.R_um(i) * 1e3;
        if hasGridValue, candidates(i).Value = candidateTable.GridValue(i);
        else,           candidates(i).Value = NaN; end
        if hasTag && strlength(candidateTable.Tag(i)) > 0
            candidates(i).Tag = char(candidateTable.Tag(i));
        else
            candidates(i).Tag = sprintf("Seed %d", i);
        end
    end
end

function totalCount = localCountMaxima(results) %#ok<DEFNU>
%localCountMaxima  Thin delegate — see countMaximaResults.
    totalCount = countMaximaResults(results);
end

function trajectoryRows = localExtractAttemptTrajectories(results, baseMetric) %#ok<DEFNU>
%localExtractAttemptTrajectories  Thin delegate — see extractAttemptTrajectories.
    trajectoryRows = extractAttemptTrajectories(results, baseMetric);
end

function refinedSeeds = localExtractRefinedSeeds(results, seeds) %#ok<DEFNU>
%localExtractRefinedSeeds  Thin delegate — see extractRefinedSeeds.
    if nargin < 2, seeds = []; end
    refinedSeeds = extractRefinedSeeds(results, "", seeds);
end

function refinedSeeds = localExtractRefinedSeedsInline(results, baseMetric, seeds) %#ok<DEFNU>
%localExtractRefinedSeedsInline  Thin delegate — see extractRefinedSeeds.
    if nargin < 3, seeds = []; end
    refinedSeeds = extractRefinedSeeds(results, baseMetric, seeds);
end

function values = localEvaluateMetricAtPoints(results, baseMetric, seeds) %#ok<DEFNU>
%localEvaluateMetricAtPoints  Thin delegate — see evaluateMetricAtPoints.
    values = evaluateMetricAtPoints(results, baseMetric, seeds);
end

function previewOptimizeMetric(src, d, fig, ax)
    % Generate and display metric heatmap WITHOUT candidate detection
    % Supports both model-based and interpolation-based (raw data) predictions
    % Robust: safe to call multiple times with different metrics
    reporter = makeOptimizeReporter(fig, src);
    setProcessRunning(fig, true, "Optimize");
    cleanupObj = onCleanup(@() cleanupProcess(fig));
    workDir = fig.UserData.workDir;

    % Resolve model and data file paths from db struct
    [dbModelFile, dbRiCsvFile, dbDataFile, ~] = resolveDbPaths(fig);

    % Extract base metric and variant
    baseMetric = safeStr(d, "metric", "EF_vol");
    metricVariant = safeStr(d, "metricVariant", "avg");
    
    % State validation and clear: ensure clean state before preview
    if ~isfield(fig.UserData, "optimize")
        fig.UserData.optimize = struct();
    end
    % Clear refined results if metric changed (start fresh)
    if isfield(fig.UserData.optimize, "baseMetric") && ...
       fig.UserData.optimize.baseMetric ~= baseMetric
        % Metric changed: clear all results to avoid stale data
        fig.UserData.optimize.previewResults = [];
        fig.UserData.optimize.lastResults = [];
    end

    % Determine Stokes shift range based on variant
    if metricVariant == "laser"
        stokesShiftMin = 0;
        stokesShiftMax = 0;
    else
        stokesShiftMin = safeNum(d, "stokesShiftMin", 100);
        stokesShiftMax = safeNum(d, "stokesShiftMax", 3600);
    end

    try
        dataSource = safeStr(d, "dataSource", "model");
        lambdaLaser = safeNum(d, "laserWavelength", 785);
        pLimits = [safeNum(d, "periodMin", 400), safeNum(d, "periodMax", 1400)];
        rLimits = [safeNum(d, "radiusMin", 50), safeNum(d, "radiusMax", 450)];
        spatialRes = safeNum(d, "spatialResolution", 2);
        stokesRes = safeNum(d, "stokesShiftResolution", 5);
        
        % Compute dense grid parameters
        gp = computeDenseGridParams( ...
            LambdaLaser=lambdaLaser, ...
            PLimits=pLimits, ...
            RLimits=rLimits, ...
            StokesShiftLimits=[stokesShiftMin, stokesShiftMax], ...
            Resolution=spatialRes, ...
            StokesShiftResolution=stokesRes, ...
            OutputUnit="um");
        
        % Build config for predictor factory
        cfg = struct();
        cfg.dataSource = dataSource;
        cfg.workDir = workDir;
        
        allData_raw = [];  % Pre-declare for interpolation mode
        
        hasDbPred = isfield(fig.UserData, "db") && isfield(fig.UserData.db, "Pred") ...
            && structRowCount(fig.UserData.db.Pred) > 0;

        if dataSource == "predictions"
            if ~hasDbPred
                error("No predictions found in database (db.Pred). Generate or load predictions first.");
            end
        elseif dataSource == "model"
            cfg.modelFile = dbModelFile;
            cfg.riCsvFile = dbRiCsvFile;
            
            if ~isfile(cfg.modelFile)
                if hasDbPred
                    dataSource = "predictions";
                    reporter.info("Model not found on disk, but db.Pred is populated. Using pre-computed predictions.");
                else
                    error("Model not loaded in database. Load a model in the Database tab.");
                end
            end
            if dataSource == "model" && strlength(cfg.riCsvFile) > 0 && ~isfile(cfg.riCsvFile)
                warning("RI file not found (will use default): %s", cfg.riCsvFile);
                cfg.riCsvFile = "";
            end
        else  % interpolation mode
            cfg.dataFile = dbDataFile;
            
            if ~isfile(cfg.dataFile)
                error("Simulation data not loaded in database. Load data in the Database tab.");
            end
        end
        
        % Build predictor (model or interpolation)
        reporter.start("BuildPredictor", "Preparing predictor...");
        predictor = [];
        
        if dataSource == "predictions"
            reporter.complete("BuildPredictor", "Using pre-computed predictions from db.Pred.");
            % If model file exists, pre-load model predictor for continuous refinement in Step 3
            if strlength(dbModelFile) > 0 && isfile(dbModelFile)
                try
                    predCfg = struct("dataSource", "model", "workDir", workDir, "modelFile", dbModelFile, "riCsvFile", dbRiCsvFile);
                    predictor = buildPredictorFromConfig(predCfg);
                catch
                    predictor = [];
                end
            end
        elseif dataSource == "interpolation"
            reporter.info("Using fast nearest-neighbor mode for preview (interpolation is slower).");
            
            % Load raw data directly (no interpolant building)
            rawData = load(cfg.dataFile);
            if isfield(rawData, "allData")
                allData_raw = rawData.allData;
            else
                error("Raw data file must contain 'allData' struct.");
            end
            
            % Extract grid vectors
            pVals = unique(allData_raw.period(:), "sorted") * 1e-3;  % nm -> µm
            rVals = unique(allData_raw.radius(:), "sorted") * 1e-3;
            
            % For preview, just use the raw grid (nearest-neighbor)
            % Resample grid parameters to match available raw data
            gp.pSamples = pVals;
            gp.rSamples = rVals;
            
            reporter.complete("BuildPredictor", sprintf("Loaded raw grid: %d periods, %d radii.", ...
                numel(pVals), numel(rVals)));
        else
            % Model mode: standard predictor build
            predictor = buildPredictorFromConfig(cfg, Reporter=reporter);
            reporter.complete("BuildPredictor", "Predictor ready.");
        end
        
        % Generate dense predictions using predictor's predictGrid method or extract db.Pred
        reporter.start("GeneratePredictions", "Generating preview predictions...");
        
        if dataSource == "predictions"
            allData = extractBranchAsSoA(fig.UserData.db, "Pred");
            reporter.complete("GeneratePredictions", sprintf("Loaded %d predictions from db.Pred.", structRowCount(allData)));
        elseif dataSource == "interpolation"
            % For interpolation preview: use raw data directly (already on grid)
            allData = allData_raw;
            
            % Compute averaged metrics if they don't exist
            baseMetricField = baseMetric;
            avgFieldName = baseMetric + "_avg";
            
            if isfield(allData, baseMetricField) && ~isfield(allData, avgFieldName)
                % Compute average for raw spectral data
                spectralData = allData.(baseMetricField);  % [N x L]
                allData.(avgFieldName) = mean(spectralData, 2, "omitnan");  % [N x 1]
                fprintf("[Preview] Computed %s from spectral data (mean across wavelengths).\n", avgFieldName);
            end
            
            % For sparse raw data: interpolate onto dense grid for proper heatmap
            if isfield(allData, avgFieldName)
                avgData = allData.(avgFieldName);
                P_raw = double(allData.period(:));
                R_raw = double(allData.radius(:));
                
                % Remove NaN points
                validIdx = ~isnan(avgData);
                P_valid = P_raw(validIdx);
                R_valid = R_raw(validIdx);
                Z_valid = double(avgData(validIdx));
                
                if numel(P_valid) > 3
                    % Create coarse regular grid for interpolation (fast)
                    pMin = min(P_valid);  pMax = max(P_valid);
                    rMin = min(R_valid);  rMax = max(R_valid);
                    
                    % Use 50 points per dimension for smooth heatmap
                    pInterp = linspace(pMin, pMax, 50);
                    rInterp = linspace(rMin, rMax, 50);
                    [pGrid, rGrid] = meshgrid(pInterp, rInterp);
                    
                    % Scatteredinterpolant: fast nearest-neighbor/linear interpolation
                    try
                        F = scatteredInterpolant(P_valid, R_valid, Z_valid, 'linear', 'nearest');
                        Z_interp = F(pGrid, rGrid);
                        
                        % Replace allData with interpolated grid for plotting
                        allData.period = pGrid(:);
                        allData.radius = rGrid(:);
                        allData.(avgFieldName) = Z_interp(:);
                        
                        % Store original data points for visualization
                        allData.rawDataPoints = struct('P', P_valid, 'R', R_valid);
                        
                        fprintf("[Preview] Interpolated sparse data to 50×50 grid for heatmap.\n");
                    catch
                        % Fallback: use nearest-neighbor only
                        F = scatteredInterpolant(P_valid, R_valid, Z_valid, 'nearest');
                        Z_interp = F(pGrid, rGrid);
                        allData.period = pGrid(:);
                        allData.radius = rGrid(:);
                        allData.(avgFieldName) = Z_interp(:);
                        allData.rawDataPoints = struct('P', P_valid, 'R', R_valid);
                        fprintf("[Preview] Interpolated (nearest-neighbor) to 50×50 grid.\n");
                    end
                end
            end
        else
            % For model: use standard prediction
            if metricVariant == "weighted"
                try
                    analyteSpec = getDefaultAnalyteSpectrum();
                    allData = predictor.predictGrid(gp.pSamples, gp.rSamples, gp.lambdaSamples, ...
                        "LaserWavelength", lambdaLaser, ...
                        "RamanWindow", [stokesShiftMin, stokesShiftMax], ...
                        "AnalyteSpectrum", analyteSpec);
                catch
                    % Analyte spectrum unavailable: fall back to plain prediction
                    allData = predictor.predictGrid(gp.pSamples, gp.rSamples, gp.lambdaSamples, ...
                        "LaserWavelength", lambdaLaser, ...
                        "RamanWindow", [stokesShiftMin, stokesShiftMax]);
                end
            else
                allData = predictor.predictGrid(gp.pSamples, gp.rSamples, gp.lambdaSamples, ...
                    "LaserWavelength", lambdaLaser, ...
                    "RamanWindow", [stokesShiftMin, stokesShiftMax]);
            end
            reporter.complete("GeneratePredictions", "Preview predictions ready.");
        end

        % Ensure derived metric field is present in allData for heatmap & diagnostics
        if metricVariant == "weighted"
            variantForField = "analyte";
        elseif metricVariant == "laser"
            variantForField = "laser";
        else
            variantForField = "avg";
        end
        diagField = resolveDerivedMetricField(baseMetric, variantForField, allData);

        if ~isfield(allData, diagField) && isfield(allData, baseMetric)
            specMat = allData.(baseMetric);
            if variantForField == "laser"
                if isfield(allData, "lambda")
                    [~, lIdx] = min(abs(allData.lambda - lambdaLaser));
                else
                    lIdx = 1;
                end
                allData.(diagField) = specMat(:, lIdx);
            elseif variantForField == "avg"
                allData.(diagField) = mean(specMat, 2, "omitnan");
            elseif variantForField == "analyte"
                analyteSpec = [];
                if isfield(fig.UserData, "visExport") && isfield(fig.UserData.visExport, "analyteSpectrum") ...
                        && isstruct(fig.UserData.visExport.analyteSpectrum)
                    analyteSpec = fig.UserData.visExport.analyteSpectrum;
                elseif isfield(fig.UserData, "db") && isfield(fig.UserData.db, "Global") && isfield(fig.UserData.db.Global, "AnalyteSpectrumFile") ...
                        && isfile(string(fig.UserData.db.Global.AnalyteSpectrumFile))
                    try
                        analyteSpec = loadAndNormalizeAnalyteSpectrum(char(fig.UserData.db.Global.AnalyteSpectrumFile));
                    catch
                    end
                end
                if isstruct(analyteSpec) && isfield(analyteSpec, "shift_cm") && isfield(allData, "RamanShift")
                    shifts = allData.RamanShift(:)';
                    aw = interp1(analyteSpec.shift_cm(:), analyteSpec.intensity(:), shifts, "makima", 0);
                    aw = max(0, aw);
                    if sum(aw) > 0
                        weights = aw / sum(aw);
                        allData.(diagField) = specMat * weights(:);
                    else
                        allData.(diagField) = mean(specMat, 2, "omitnan");
                    end
                else
                    allData.(diagField) = mean(specMat, 2, "omitnan");
                end
            end
        end

        % Synchronize grid samples from allData if using precomputed predictions
        if isfield(allData, "lambda") && ~isempty(allData.lambda)
            lamVals = allData.lambda(:)';
            if max(lamVals) > 50
                gp.lambdaSamples = lamVals * 1e-3;
            else
                gp.lambdaSamples = lamVals;
            end
        end
        if isfield(allData, "period") && isfield(allData, "radius")
            pVals = unique(allData.period(:), "sorted");
            rVals = unique(allData.radius(:), "sorted");
            if ~isempty(pVals)
                if max(pVals) > 50, gp.pSamples = pVals * 1e-3;
                else, gp.pSamples = pVals; end
            end
            if ~isempty(rVals)
                if max(rVals) > 50, gp.rSamples = rVals * 1e-3;
                else, gp.rSamples = rVals; end
            end
        end
        
        % Store results for later use (minimal structure)
        if ~isfield(fig.UserData, "optimize")
            fig.UserData.optimize = struct();
        end
        % Build a minimal metrics cell carrying lambdaSamples for model evaluation
        previewMetricEntry = struct( ...
            "metricName", baseMetric, ...
            "lambdaSamples", gp.lambdaSamples);  % µm, needed by evaluateMetricAtPoints
        previewCfg = struct( ...
            "lambdaLaser", lambdaLaser, ...
            "stokesShiftLimits", [stokesShiftMin, stokesShiftMax], ...
            "metricVariant", metricVariant);
        fig.UserData.optimize.previewResults = struct( ...
            "allData", allData, ...
            "metrics", {{previewMetricEntry}}, ...
            "cfg",     previewCfg);  % cfg needed by evaluateMetricAtPoints
        if exist("predictor", "var") && ~isempty(predictor)
            fig.UserData.optimize.previewResults.predictor = predictor;
        end
        fig.UserData.optimize.baseMetric = baseMetric;
        fig.UserData.optimize.metricVariant = metricVariant;
        % Lock in grid definition so detect/refine always use the same grid as this preview
        rawStokesMin = safeNum(d, "stokesShiftMin", 100);
        rawStokesMax = safeNum(d, "stokesShiftMax", 3600);
        fig.UserData.optimize.gridDefinition = struct( ...
            "lambdaLaser",         lambdaLaser, ...
            "pLimits",             pLimits, ...
            "rLimits",             rLimits, ...
            "stokesShiftMin",      rawStokesMin, ...
            "stokesShiftMax",      rawStokesMax, ...
            "spatialResolution",   spatialRes, ...
            "stokesShiftResolution", stokesRes);
        reporter.info(sprintf("[Preview] Grid locked: %d×%d (p×r samples), %d λ-samples | spatRes=%.2g nm, stokesRes=%.2g cm⁻¹, λ_laser=%.1f nm", ...
            numel(gp.pSamples), numel(gp.rSamples), numel(gp.lambdaSamples), spatialRes, stokesRes, lambdaLaser));

        % Send diagnostic info to HTML panel
        if metricVariant == "weighted"
            variantForField = "analyte";
        elseif metricVariant == "laser"
            variantForField = "laser";
        else
            variantForField = "avg";
        end
        diagField = resolveDerivedMetricField(baseMetric, variantForField, allData);
        if isfield(allData, diagField)
            avgData = allData.(diagField);
            validCount = sum(~isnan(avgData));
            diagnostics = struct( ...
                "metric", diagField, ...
                "totalRows", numel(avgData), ...
                "validRows", validCount, ...
                "nanRows", sum(isnan(avgData)), ...
                "dataSparsity", sprintf("%.1f%%", 100*validCount/numel(avgData)), ...
                "periodCount", numel(unique(allData.period)), ...
                "radiusCount", numel(unique(allData.radius)));
            sendOptimizeEvent(fig, "PreviewDiagnostics", diagnostics, src);
        end

        % Render heatmap only (no markers, no candidates)
        delete(allchild(ax));
        plotOptimizeHeatmap(fig.UserData.optimize.previewResults, baseMetric, metricVariant, ax, [], []);

        sendOptimizeEvent(fig, "PreviewComplete", struct("metric", baseMetric), src);
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Optimize", "Preview terminated by user.");
            if isfield(fig.UserData, "optimize")
                fig.UserData.optimize.previewResults = [];
            end
            return;
        end
        fprintf("[Preview] Error: %s\n", ME.message);
        sendOptimizeEvent(fig, "OptimizeError", "Preview failed: " + string(ME.message), src);
        % Ensure state is not corrupted
        if isfield(fig.UserData, "optimize")
            fig.UserData.optimize.previewResults = [];
        end
    end
end

function updateMetricState(~, d, fig)
%updateMetricState Update fig.UserData.optimize metric/variant when UI changes.
    if ~isstruct(d)
        return;
    end
    
    metric = safeStr(d, "metric", "EF_vol");
    metricVariant = safeStr(d, "metricVariant", "laser");
    
    % Initialize optimize struct if needed
    if ~isfield(fig.UserData, "optimize")
        fig.UserData.optimize = struct();
    end
    
    % Update stored metric state
    fig.UserData.optimize.baseMetric = metric;
    fig.UserData.optimize.metricVariant = metricVariant;
end

function updateOptimizerSeeds(src, d, fig, ax)
    % Re-render heatmap with updated seed markers (no re-detection)
    % Robust: updates existing heatmap with new seed positions and tags
    if ~isfield(fig.UserData, "optimize")
        sendOptimizeEvent(fig, "OptimizeError", "No heatmap available. Run Preview first.", src);
        return;
    end
    
    if ~isfield(fig.UserData.optimize, "lastResults") && ~isfield(fig.UserData.optimize, "previewResults")
        sendOptimizeEvent(fig, "OptimizeError", "No heatmap data. Run Preview or Initialize first.", src);
        return;
    end

    % Use preview or last results — prefer the one that actually has data
    if isfield(fig.UserData.optimize, "lastResults") && isstruct(fig.UserData.optimize.lastResults) && ...
            ~isempty(fieldnames(fig.UserData.optimize.lastResults))
        results = fig.UserData.optimize.lastResults;
    elseif isfield(fig.UserData.optimize, "previewResults") && isstruct(fig.UserData.optimize.previewResults) && ...
            ~isempty(fieldnames(fig.UserData.optimize.previewResults))
        results = fig.UserData.optimize.previewResults;
    else
        sendOptimizeEvent(fig, "OptimizeError", "No heatmap data. Run Preview or Initialize first.", src);
        return;
    end
    baseMetric = fig.UserData.optimize.baseMetric;
    metricVariant = fig.UserData.optimize.metricVariant;

    seeds = [];
    if isfield(d, "seeds") && ~isempty(d.seeds)
        seeds = d.seeds;
    end

    try
        % Evaluate metric values at seeds using model (exact) or grid (fallback)
        if ~isempty(seeds)
            seedVals = evaluateMetricAtPoints(results, baseMetric, seeds);
            seedValsCell = num2cell(seedVals);
            [seeds.Value] = deal(seedValsCell{:});
        end
        
        % Clear and re-plot heatmap with updated seeds
        if isvalid(ax)
            delete(allchild(ax));
            plotOptimizeHeatmap(results, baseMetric, metricVariant, ax, [], seeds);
        end
        sendOptimizeEvent(fig, "SeedsUpdated", struct("seeds", seeds), src);
    catch ME
        fprintf("[UpdateSeeds] Error: %s\n", ME.message);
        sendOptimizeEvent(fig, "OptimizeError", "Update failed: " + string(ME.message), src);
    end
end

function importSeedsCsv(src, d, fig, ax)
    % Import seeds (Tag, P, R) from CSV and update the seeds table/plot.
    workDir = fig.UserData.workDir;
    [fileName, filePath] = uigetfile("*.csv", "Import Seeds CSV", char(workDir));
    if isequal(fileName, 0) || isequal(filePath, 0)
        sendOptimizeEvent(fig, "OptimizeError", "Import canceled.", src);
        return;
    end

    fullPath = fullfile(filePath, fileName);
    try
        opts = detectImportOptions(fullPath, "TextType", "string");
        tbl = readtable(fullPath, opts);
    catch ME
        sendOptimizeEvent(fig, "OptimizeError", "Failed to read CSV: " + string(ME.message), src);
        return;
    end

    if isempty(tbl) || height(tbl) == 0
        sendOptimizeEvent(fig, "OptimizeError", "CSV contains no rows.", src);
        return;
    end

    colNamesOrig = string(tbl.Properties.VariableNames);
    colNamesLower = lower(colNamesOrig);

    tagCol = localFindColumn(colNamesOrig, colNamesLower, ["tag", "name", "label"]);
    pCol = localFindColumn(colNamesOrig, colNamesLower, [
        "period_nm", "p_nm", "period", "p", "periodnm", "p(nm)", "period(nm)"]);
    rCol = localFindColumn(colNamesOrig, colNamesLower, [
        "radius_nm", "r_nm", "radius", "r", "radiusnm", "r(nm)", "radius(nm)"]);

    if pCol == "" || rCol == ""
        sendOptimizeEvent(fig, "OptimizeError", "CSV must include Period/P and Radius/R columns (nm).", src);
        return;
    end

    pVals = localToDouble(tbl.(pCol));
    rVals = localToDouble(tbl.(rCol));
    tagVals = strings(height(tbl), 1);
    if tagCol ~= ""
        tagVals = string(tbl.(tagCol));
    end

    seeds = struct("P", {}, "R", {}, "Value", {}, "Tag", {});
    for i = 1:height(tbl)
        pVal = pVals(i);
        rVal = rVals(i);
        if ~isfinite(pVal) || ~isfinite(rVal)
            continue;
        end
        tag = tagVals(i);
        if strlength(tag) == 0
            tag = "Seed " + string(i);
        end
        seeds(end+1) = struct("P", pVal, "R", rVal, "Value", NaN, "Tag", tag); %#ok<AGROW>
    end

    if isempty(seeds)
        sendOptimizeEvent(fig, "OptimizeError", "No valid seed coordinates found in CSV.", src);
        return;
    end

    if ~isfield(fig.UserData, "optimize")
        fig.UserData.optimize = struct();
    end
    fig.UserData.optimize.currentSeeds = seeds;

    sendOptimizeEvent(fig, "SeedsUpdated", struct("seeds", seeds), src);
    progressData = struct("message", sprintf("[Optimize] Imported %d seeds from CSV.", numel(seeds)), "fraction", 1);
    sendOptimizeEvent(fig, "Progress", progressData, src);

    if isfield(fig.UserData.optimize, "lastResults") || isfield(fig.UserData.optimize, "previewResults")
        try
            updateOptimizerSeeds(src, struct("seeds", seeds), fig, ax);
        catch
        end
    end

    function colName = localFindColumn(origNames, lowerNames, candidates)
        colName = "";
        for ci = 1:numel(candidates)
            idx = find(lowerNames == candidates(ci), 1);
            if ~isempty(idx)
                colName = origNames(idx);
                return;
            end
        end
    end

    function vals = localToDouble(v)
        if isnumeric(v)
            vals = double(v);
        else
            vals = str2double(string(v));
        end
    end
end

function exportOptimizeResults(src, d, fig)
    % Export optimization results to MAT or CSV file
    % Robust: safely validates all state before exporting
    if ~isfield(fig.UserData, "optimize")
        sendOptimizeEvent(fig, "OptimizeError", "Optimization state not initialized.", src);
        return;
    end
    
    if ~isfield(fig.UserData.optimize, "lastResults")
        sendOptimizeEvent(fig, "OptimizeError", "No refinement results to export. Run Fine-Tune first.", src);
        return;
    end

    results = fig.UserData.optimize.lastResults;
    if ~isstruct(results) || ~isfield(results, "metrics")
        sendOptimizeEvent(fig, "OptimizeError", "Results structure is invalid.", src);
        return;
    end
    
    baseMetric = string(safeStr(fig.UserData.optimize, "baseMetric", "EF_vol"));
    metricVariant = string(safeStr(fig.UserData.optimize, "metricVariant", "avg"));
    config = fig.UserData.optimize.config;
    if ~isstruct(config)
        config = struct();
    end

    % Build full metric name for export
    if metricVariant == "laser"
        metricName = baseMetric + "_laser";
    elseif metricVariant == "weighted"
        metricName = baseMetric + "_analyte";
    else
        metricName = baseMetric + "_avg";
    end

    seeds = [];
    if isfield(d, "seeds")
        seeds = d.seeds;
    end

    % Get export format
    exportFormat = safeStr(d, "exportFormat", "mat");

    % Build output filename based on model/data file
    baseName = "optimization";
    if isfield(config, "modelFile") && strlength(string(config.modelFile)) > 0
        [~, baseName] = fileparts(string(config.modelFile));
    elseif isfield(config, "dataFile") && strlength(string(config.dataFile)) > 0
        [~, baseName] = fileparts(string(config.dataFile));
    end
    baseName = string(baseName);
    workDir = fig.UserData.workDir;
    
    % File dialog based on format
    if exportFormat == "csv"
        defaultFile = fullfile(workDir, baseName + "_optima.csv");
        [saveFile, savePath] = uiputfile("*.csv", "Save Optima As CSV", char(defaultFile));
    else
        defaultFile = fullfile(workDir, baseName + "_optima.mat");
        [saveFile, savePath] = uiputfile("*.mat", "Save Optima As MAT", char(defaultFile));
    end
    
    if isequal(saveFile, 0) || isequal(savePath, 0)
        sendOptimizeEvent(fig, "OptimizeError", "Export canceled.", src);
        return;
    end
    outputFile = fullfile(savePath, saveFile);

    try
        % Validate seeds array first
        nRows = 0;
        pVals = [];
        rVals = [];
        metricVals = [];
        tagVals = string.empty(0, 1);

        % Ensure seeds is always an array
        if ~isempty(seeds) && ~iscell(seeds)
            if ~isstruct(seeds)
                error("Seeds must be a struct array or cell array.");
            end
            % Force column vector
            seeds = seeds(:);
            nRows = numel(seeds);
            pVals = zeros(nRows, 1);
            rVals = zeros(nRows, 1);
            metricVals = zeros(nRows, 1);
            tagVals = strings(nRows, 1);
            for k = 1:nRows
                s = seeds(k);
                % Safe field extraction with validation
                if ~isstruct(s)
                    error("Seed %d is not a struct.", k);
                end
                pVals(k) = double(safeNum(s, "P", NaN));
                rVals(k) = double(safeNum(s, "R", NaN));
                if isfield(s, "Value") && isnumeric(s.Value) && isscalar(s.Value) && isfinite(s.Value)
                    metricVals(k) = double(s.Value);
                else
                    metricVals(k) = NaN;
                end
                if isfield(s, "Tag") && strlength(string(s.Tag)) > 0
                    tagVals(k) = string(s.Tag);
                else
                    tagVals(k) = "Point " + string(k);
                end
            end
        else
            % Fallback: extract from maximaResults table
            maximaTable = table();
            if isfield(results, "metrics") && ~isempty(results.metrics)
                metricRes = results.metrics{1};
                if isfield(metricRes, "maximaResults") && ~isempty(metricRes.maximaResults)
                    maximaTable = metricRes.maximaResults;
                end
            end
            if isempty(maximaTable) || height(maximaTable) == 0
                sendOptimizeEvent(fig, "OptimizeError", "No optima available to export.", src);
                return;
            end
            nRows = height(maximaTable);
            pVals = double(maximaTable.P_um(:)) * 1e3;
            rVals = double(maximaTable.R_um(:)) * 1e3;
            avgFieldName = char(metricName);
            if any(strcmp(maximaTable.Properties.VariableNames, avgFieldName))
                metricVals = double(maximaTable.(avgFieldName)(:));
            else
                metricVals = NaN(nRows, 1);
            end
            tagVals = strings(nRows, 1);
            for k = 1:nRows
                tagVals(k) = "Optimum " + string(k);
            end
        end

        if nRows == 0
            sendOptimizeEvent(fig, "OptimizeError", "No optima available to export.", src);
            return;
        end

        % Build per-row metadata (all column vectors)
        metricNames = repmat(metricName, nRows, 1);
        dataSourceStr = string(safeStr(config, "dataSource", "model"));
        dataSourceVals = repmat(dataSourceStr, nRows, 1);

        dataFileStr = "";
        if isfield(config, "dataFile") && strlength(string(config.dataFile)) > 0
            [~, fn, fe] = fileparts(string(config.dataFile));
            dataFileStr = string(fn) + string(fe);
        elseif isfield(config, "modelFile") && strlength(string(config.modelFile)) > 0
            [~, fn, fe] = fileparts(string(config.modelFile));
            dataFileStr = string(fn) + string(fe);
        end
        dataFileVals = repmat(dataFileStr, nRows, 1);

        laserWl = repmat(double(safeNum(config, "laserWavelength", 785)), nRows, 1);

        if metricVariant == "laser"
            stokesWindow = zeros(nRows, 2);
        else
            sMin = double(safeNum(config, "stokesShiftMin", 100));
            sMax = double(safeNum(config, "stokesShiftMax", 3600));
            stokesWindow = repmat([sMin, sMax], nRows, 1);
        end

        % Build export struct with arrays (nm units)
        newOptima = struct();
        newOptima.Tag         = tagVals(:);
        newOptima.p           = pVals(:);
        newOptima.r           = rVals(:);
        newOptima.metricName  = metricNames(:);
        newOptima.metricValue = metricVals(:);
        newOptima.dataSource  = dataSourceVals(:);
        newOptima.dataFileName = dataFileVals(:);
        newOptima.laserWavelength = laserWl(:);
        newOptima.StokesShiftWindow = stokesWindow;

        % Export based on format
        if exportFormat == "csv"
            % CSV export with append support
            exportTable = table(tagVals, pVals, rVals, metricNames, metricVals, ...
                dataSourceVals, dataFileVals, laserWl, ...
                stokesWindow(:,1), stokesWindow(:,2), ...
                'VariableNames', {'Tag', 'Period_nm', 'Radius_nm', 'MetricName', ...
                'MetricValue', 'DataSource', 'DataFileName', 'LaserWavelength_nm', ...
                'StokesShift_Min_cm', 'StokesShift_Max_cm'});
            
            if isfile(outputFile)
                % Append to existing CSV
                existingTable = readtable(outputFile, 'TextType', 'string');
                exportTable = [existingTable; exportTable];
            end
            
            writetable(exportTable, outputFile);
        else
            % MAT export with struct append
            % Append to existing file if present
            if isfile(outputFile)
                existingData = load(outputFile);
                if isfield(existingData, "optima")
                    optima = existingData.optima;
                else
                    optima = struct();
                end
            else
                optima = struct();
            end

            flds = fieldnames(newOptima);
            for f = 1:numel(flds)
                fn = flds{f};
                nv = newOptima.(fn);
                if isfield(optima, fn) && ~isempty(optima.(fn))
                    ov = optima.(fn);
                    if strcmp(fn, "StokesShiftWindow")
                        % Ensure both are Nx2
                        if size(ov, 2) ~= 2, ov = reshape(ov, [], 2); end
                        if size(nv, 2) ~= 2, nv = reshape(nv, [], 2); end
                    end
                    optima.(fn) = [ov; nv];
                else
                    optima.(fn) = nv;
                end
            end

            save(outputFile, "optima", "-v7.3");
        end

        sendOptimizeEvent(fig, "ExportComplete", struct("path", char(outputFile)), src);
    catch ME
        fprintf("[Export] Error at line %d: %s\n", ME.stack(1).line, ME.message);
        sendOptimizeEvent(fig, "OptimizeError", "Export failed: " + string(ME.message), src);
    end
end

%% ########################################################################
%   STAGE 4 — PREDICTION & VISUALIZATION HANDLERS
%  ########################################################################
function handleVisExportEvent(src, event, fig)
    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "predController") ...
            && ~isempty(fig.UserData.handles.predController)
        fig.UserData.handles.predController.handleEvent(event.HTMLEventName, event.HTMLEventData);
        return;
    end
    name = event.HTMLEventName;
    data = event.HTMLEventData;
    try
        switch name
            case "OpenInVisualize"
                openInVisualizeTab(fig, safeStr(data, "branch", "Pred"), "2d");
            case "PredictInterpolate"
                runPredictInterpolate(src, data, fig);
            case "RefreshDbState"
                broadcastDbStatus(fig);
            case "SaveDatabaseRequest"
                saveDbFile(fig);
                broadcastDbStatus(fig);
            case "StopProcess"
                requestProcessStop(fig);
            otherwise
                fprintf("[VisExport] Unknown event: %s\n", name);
        end
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Prediction", "Prediction process terminated by user.");
        else
            sendEventToHTMLSource(src, "VisError", ME.message);
        end
    end
end

function runVisExportToMat(src, d, fig)
    reporter = makeReporter(src);
    ve = fig.UserData.visExport;

    if ~ve.predictionsLoaded || isempty(ve.allData)
        sendEventToHTMLSource(src, "VisError", ...
            "Generate a visualization first to produce predictions.");
        return;
    end

    workDir    = fig.UserData.workDir;
    outputFile = safeStr(d, "outputFile", "dense_predictions.mat");
    if ~contains(outputFile, filesep)
        outputFile = fullfile(workDir, outputFile);
    end

    % Parse metrics and variants from JS arrays
    metrics  = parseCellOrString(d, "metrics");
    variants = parseCellOrString(d, "variants");

    try
        outPath = exportDensePredictions(ve.allData, ...
            OutputFile=outputFile, ...
            Metrics=metrics, ...
            Variants=variants, ...
            Reporter=reporter);
        sendEventToHTMLSource(src, "ExportComplete", struct("path", char(outPath)));
    catch ME
        sendEventToHTMLSource(src, "VisError", "Export failed: " + string(ME.message));
    end
end

function runPredictInterpolate(src, d, fig)
%runPredictInterpolate Generate prediction/interpolation and store in DB branches.
    reporter = makeReporter(src, fig);
    setProcessRunning(fig, true, "Prediction");
    cleanupObj = onCleanup(@() cleanupProcess(fig));
    ve = fig.UserData.visExport;

    dataSource  = safeStr(d, "dataSource", "model");
    predictionTarget = safeStr(d, "predictionTarget", "grid");
    workDir     = fig.UserData.workDir;

    laserWl         = safeNum(d, "laserWavelength", 785);
    periodMin       = safeNum(d, "periodMin", 400);
    periodMax       = safeNum(d, "periodMax", 1400);
    radiusMin       = safeNum(d, "radiusMin", 50);
    radiusMax       = safeNum(d, "radiusMax", 450);
    spatialRes      = safeNum(d, "spatialResolution", 2);
    stokesMin       = safeNum(d, "stokesShiftMin", 100);
    stokesMax       = safeNum(d, "stokesShiftMax", 3600);
    stokesRes       = safeNum(d, "stokesShiftResolution", 5);
    batchSize       = safeNum(d, "batchSize", 1000);
    interpMethod    = safeStr(d, "interpMethod", "linear");
    spectralMethod  = safeStr(d, "spectralMethod", "makima");

    % Metrics window
    linkMetrics     = true;
    if isfield(d, "linkMetricsToGrid")
        linkMetrics = logical(d.linkMetricsToGrid);
    end
    metricsMin      = safeNum(d, "metricsShiftMin", stokesMin);
    metricsMax      = safeNum(d, "metricsShiftMax", stokesMax);

    selectedFields = string.empty;
    if isfield(d, "selectedFields")
        selectedFields = parseCellOrString(d, "selectedFields");
    end

    [modelFile, riCsvFile, dataFile, predictionFile] = resolveDbPaths(fig);
    analyteFile = resolveAnalyteFile(fig);

    try
        reporter.progress("PredictInterpolate", 0.01, ...
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

        pointMode = predictionTarget == "optima";

        if dataSource == "model"
            [ok, ~, ~] = ensureVisExportModelAndRi(fig, src, reporter);
            if ~ok
                return;
            end
            ve = fig.UserData.visExport;

            if strlength(analyteFile) > 0 && isfile(analyteFile)
                try
                    ve.analyteSpectrum = loadAndNormalizeAnalyteSpectrum(analyteFile);
                catch
                    ve.analyteSpectrum = struct();
                end
            end

            reporter.start("PredictInterpolate");
            execEnv = "cpu";
            try
                if canUseGPU() && gpuDeviceCount() > 0
                    execEnv = "gpu";
                    g = gpuDevice();
                    reporter.info(sprintf("GPU acceleration enabled: %s (%.1f GB VRAM).", ...
                        g.Name, g.TotalMemory / 1e9));
                else
                    reporter.info("DNN inference running on CPU (no compatible GPU detected).");
                end
            catch
                reporter.info("DNN inference running on CPU.");
            end

            if pointMode
                gp = computeDenseGridParams( ...
                    LambdaLaser=laserWl, ...
                    PLimits=[periodMin, periodMax], ...
                    RLimits=[radiusMin, radiusMax], ...
                    StokesShiftLimits=[stokesMin, stokesMax], ...
                    Resolution=spatialRes, ...
                    StokesShiftResolution=stokesRes, ...
                    OutputUnit="um");
                [pPointsNm, rPointsNm] = getPredictionTargetPoints(fig.UserData.db, predictionTarget);
                predictor = createModelPredictor(ve.model, ve.ri, "ExecutionEnvironment", execEnv);
                metricsWindow = [];
                if ~linkMetrics
                    metricsWindow = [metricsMin, metricsMax];
                end
                allDataRaw = buildPointPredictionSoA( ...
                    predictor, pPointsNm, rPointsNm, gp.lambdaSamples, ...
                    laserWl, [stokesMin, stokesMax], stokesRes, ...
                    ve.analyteSpectrum, reporter, "PredictInterpolate", metricsWindow);
                reporter.complete("PredictInterpolate", ...
                    sprintf("Predicted %d saved optima points.", numel(pPointsNm)));
                allDataFiltered = allDataRaw;
            else
                cfg = predictionVisConfig( ...
                    WorkDir=char(workDir), ...
                    ModelFile=char(resolvePath(modelFile, workDir)), ...
                    RiCsvFile=char(riCsvFile), ...
                    PredictionFile=char(predictionFile), ...
                    LambdaLaser=laserWl, ...
                    PLimits=[periodMin, periodMax], ...
                    RLimits=[radiusMin, radiusMax], ...
                    StokesShiftLimits=[stokesMin, stokesMax], ...
                    Resolution=spatialRes, ...
                    StokesShiftResolution=stokesRes, ...
                    LinkMetricsToGrid=linkMetrics, ...
                    MetricsShiftLimits=[metricsMin, metricsMax], ...
                    Metrics=["Absorptance", "EF_vol", "EF_surf", "M_vol", "M_surf"], ...
                    ExportPredictions=false, ...
                    ExportGraphics=false);

                loadPredArgs2 = { ...
                    "Recompute", true, ...
                    "Model", ve.model, "Ri", ve.ri, ...
                    "PSamples", cfg.pSamples, "RSamples", cfg.rSamples, ...
                    "LambdaSamples", cfg.lambdaSamples, ...
                    "LambdaLaser", laserWl, ...
                    "StokesShiftLimits", [stokesMin, stokesMax], ...
                    "AnalyteSpectrum", ve.analyteSpectrum, ...
                    "InterpResolution", stokesRes, ...
                    "BatchSize", max(batchSize, 2000), ...
                    "ExecutionEnvironment", execEnv, ...
                    "PredictionFile", cfg.predictionFile, ...
                    "SaveAfterGeneration", (strlength(predictionFile) > 0), ...
                    "Reporter", reporter};
                if ~linkMetrics
                    loadPredArgs2 = [loadPredArgs2, {"MetricsShiftLimits", [metricsMin, metricsMax]}];
                end

                allDataRaw = loadOrGeneratePredictions(loadPredArgs2{:});
                reporter.complete("PredictInterpolate", "Dense predictions generated.");
                allDataFiltered = allDataRaw;
            end
        else
            reporter.start("Interpolate");
            dfPath = resolvePath(dataFile, workDir);
            if ~isfile(dfPath)
                reporter.fail("Interpolate", "Data file not found: " + dfPath);
                sendEventToHTMLSource(src, "VisError", "Data file not found: " + dfPath);
                return;
            end
            ld = load(dfPath);
            if isfield(ld, "allData")
                simData = ld.allData;
            else
                flds = fieldnames(ld);
                simData = ld.(flds{1});
            end

            % Derive the minimal set of base spectral targets from selectedFields:
            % strip _laser/_avg/_analyte suffixes, intersect with actual sim data fields.
            baseTargets = deriveBaseTargetsFromSelection(selectedFields, simData);
            reporter.progress("Interpolate", 0.10, sprintf( ...
                "Base targets from selection: [%s].", strjoin(baseTargets, ", ")));

            % Use "linear" barycentric interpolation: same accuracy as "natural" for dense
            % COMSOL grids but orders-of-magnitude faster (no Voronoi cell-area computation).
            predictor = createDataPredictor(simData, ...
                TargetNames=baseTargets, ...
                InterpMethod=interpMethod, SpectralMethod=spectralMethod, ...
                LaserWavelength=laserWl);
            reporter.progress("Interpolate", 0.15, sprintf( ...
                "Predictor ready: %d targets, %d spatial λ-slices (%s/%s).", ...
                numel(predictor.targetNames), numel(predictor.lambdaGrid), ...
                interpMethod, spectralMethod));
            if pointMode
                reporter.progress("Interpolate", 0.20, "Computing wavelength grid params...");
                gp = computeDenseGridParams( ...
                    LambdaLaser=laserWl, ...
                    PLimits=[periodMin, periodMax], ...
                    RLimits=[radiusMin, radiusMax], ...
                    StokesShiftLimits=[stokesMin, stokesMax], ...
                    Resolution=spatialRes, ...
                    StokesShiftResolution=stokesRes, ...
                    OutputUnit="nm");
                reporter.progress("Interpolate", 0.25, sprintf( ...
                    "λ grid: %d pts (%.0f–%.0f nm, %.0f–%.0f cm⁻¹).", ...
                    numel(gp.lambdaSamples), min(gp.lambdaSamples), max(gp.lambdaSamples), ...
                    gp.stokesShiftLimits(1), gp.stokesShiftLimits(2)));
                reporter.progress("Interpolate", 0.28, "Reading saved optima from db.Optima...");
                [pPointsNm, rPointsNm] = getPredictionTargetPoints(fig.UserData.db, predictionTarget);
                if isempty(pPointsNm)
                    reporter.fail("Interpolate", "No saved optima found in db.Optima. Run Stage 5 first.");
                    sendEventToHTMLSource(src, "VisError", ...
                        "No saved optima in db.Optima. Run optimisation (Stage 5) first.");
                    return;
                end
                reporter.progress("Interpolate", 0.30, sprintf( ...
                    "Found %d optima: p=[%.0f…%.0f] nm, r=[%.0f…%.0f] nm.", ...
                    numel(pPointsNm), min(pPointsNm), max(pPointsNm), ...
                    min(rPointsNm), max(rPointsNm)));
                reporter.progress("Interpolate", 0.32, "Starting batch spectral interpolation...");
                % Load analyte spectrum for _analyte derived metrics
                interpAnalyte = struct();
                if strlength(analyteFile) > 0 && isfile(analyteFile)
                    try
                        interpAnalyte = loadAndNormalizeAnalyteSpectrum(analyteFile);
                    catch
                        interpAnalyte = struct();
                    end
                end
                % buildPointPredictionSoA already calls recomputeDerivedMetrics internally;
                metricsWindowInterp = [];
                if ~linkMetrics
                    metricsWindowInterp = [metricsMin, metricsMax];
                end
                allDataRaw = buildPointPredictionSoA( ...
                    predictor, pPointsNm, rPointsNm, gp.lambdaSamples, ...
                    laserWl, [stokesMin, stokesMax], stokesRes, ...
                    interpAnalyte, reporter, "Interpolate", metricsWindowInterp);
                % Diagnostic: verify spectral column alignment
                localValidateColumnAlignment(allDataRaw, reporter);
                reporter.complete("Interpolate", ...
                    sprintf("Interpolated %d saved optima points.", numel(pPointsNm)));
                % Derived metrics already computed inside buildPointPredictionSoA — skip below.
                allDataFiltered = allDataRaw;
            else
                gp = computeDenseGridParams( ...
                    LambdaLaser=laserWl, ...
                    PLimits=[periodMin, periodMax], ...
                    RLimits=[radiusMin, radiusMax], ...
                    StokesShiftLimits=[stokesMin, stokesMax], ...
                    Resolution=spatialRes, ...
                    StokesShiftResolution=stokesRes);

                allDataRaw = predictor.predictGrid( ...
                    gp.pSamples, gp.rSamples, gp.lambdaSamples, ...
                    "LaserWavelength", gp.lambdaLaser, ...
                    "RamanWindow", gp.stokesShiftLimits, ...
                    "BatchSize", batchSize, ...
                    "ProgressFcn", @(frac, msg) reporter.progress("Interpolate", frac, msg));

                reporter.complete("Interpolate", "Dense interpolation generated from db.Sim.");

                % Load analyte spectrum for _analyte derived metrics
                interpAnalyteDense = struct();
                if strlength(analyteFile) > 0 && isfile(analyteFile)
                    try
                        interpAnalyteDense = loadAndNormalizeAnalyteSpectrum(analyteFile);
                    catch
                        interpAnalyteDense = struct();
                    end
                end

                % Use metrics window for derived metrics if not linked
                derivedWindow = [stokesMin, stokesMax];
                if ~linkMetrics
                    derivedWindow = [metricsMin, metricsMax];
                end
                derivedCfg = importSweepConfig( ...
                    WorkDir=fig.UserData.workDir, ...
                    LaserWavelength=laserWl, ...
                    RamanWindow=derivedWindow, ...
                    DetectShiftWindow=false, ...
                    InterpResolution=stokesRes, ...
                    SpectralInterpMethod="makima");
                [allDataRaw, ~] = recomputeDerivedMetrics(allDataRaw, derivedCfg, interpAnalyteDense, reporter);
                % Diagnostic: verify spectral column alignment
                localValidateColumnAlignment(allDataRaw, reporter);
                allDataFiltered = allDataRaw;
            end
        end

        [allDataFiltered, includedFields] = selectPredictionFieldsCanonical(allDataFiltered, selectedFields);
        if isempty(includedFields)
            sendEventToHTMLSource(src, "VisError", ...
                "No selected metric/variant fields were found in generated data.");
            return;
        end

        [fig.UserData.db, branchPath] = storePredictionResults( ...
            fig.UserData.db, allDataFiltered, dataSource, predictionTarget);
        markDbDirty(fig);
        broadcastDbStatus(fig);

        ve.allData = allDataFiltered;
        ve.predictionsLoaded = true;
        fig.UserData.visExport = ve;

        sendEventToHTMLSource(src, "PredictComplete", struct( ...
            "entries", structRowCount(allDataFiltered), ...
            "branch", char(branchPath), ...
            "fields", {cellstr(includedFields)}));
    catch ME
        if isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Prediction", "Predict/Interpolate terminated by user.");
            return;
        end
        reporter.fail("PredictInterpolate", string(ME.message));
        sendEventToHTMLSource(src, "VisError", ...
            "Predict/Interpolate failed: " + string(ME.message));
    end
end

function localValidateColumnAlignment(allData, reporter)
%localValidateColumnAlignment Diagnostic: verify spectral columns match lambda order.
    if ~isfield(allData, "lambda") || ~isfield(allData, "RamanShift")
        return;
    end
    lam1 = allData.lambda(1, 1);
    lamE = allData.lambda(1, end);
    rs1  = allData.RamanShift(1, 1);
    rsE  = allData.RamanShift(1, end);

    reporter.progress("Validate", 0, sprintf( ...
        "Column alignment: lambda=[%.1f..%.1f nm], shift=[%.0f..%.0f cm-1]", ...
        lam1, lamE, rs1, rsE));

    spectralFields = ["EF_vol", "EF_surf", "Absorptance", "M_vol", "M_surf"];
    for i = 1:numel(spectralFields)
        fn = spectralFields(i);
        if isfield(allData, fn) && size(allData.(fn), 2) > 1
            v1 = allData.(fn)(1, 1);
            vE = allData.(fn)(1, end);
            reporter.progress("Validate", 0, sprintf( ...
                "  %s: col1=%.4g  colEnd=%.4g", fn, v1, vE));
        end
        laserFn = fn + "_laser";
        if isfield(allData, laserFn)
            vL = allData.(laserFn)(1);
            reporter.progress("Validate", 0, sprintf( ...
                "  %s: %.4g", laserFn, vL));
        end
    end

    % Check for likely column reversal: if RamanShift is monotonically
    % DECREASING instead of increasing, columns may be flipped.
    if rsE < rs1
        reporter.warn("Validate", sprintf( ...
            "WARNING: RamanShift decreases from col1 (%.0f) to colEnd (%.0f) — columns may be flipped!", rs1, rsE));
    end
end

function fieldName = resolveMetricField(baseMetric, variant, allData)
%resolveMetricField Map metric+variant to the actual SoA field name.
    switch variant
        case "laser"
            varArg = "laser";
        case "weighted"
            varArg = "analyte";
        case "avg"
            varArg = "avg";
        otherwise
            varArg = "";
    end

    if varArg ~= ""
        resolved = resolveDerivedMetricField(baseMetric, varArg, allData);
        if resolved ~= "" && isfield(allData, char(resolved))
            fieldName = resolved;
            return;
        end
    end

    % Fallback to base field (with Absorptance <-> Abs aliasing)
    if isfield(allData, char(baseMetric))
        fieldName = string(baseMetric);
    elseif baseMetric == "Absorptance" && isfield(allData, "Abs")
        fieldName = "Abs";
    elseif baseMetric == "Abs" && isfield(allData, "Absorptance")
        fieldName = "Absorptance";
    else
        fieldName = "";
    end
end

function vals = parseCellOrString(d, fieldName)
%parseCellOrString Extract string array from event data field (cell or string).
    if ~isstruct(d) || ~isfield(d, fieldName)
        vals = string.empty;
        return;
    end
    raw = d.(fieldName);
    if isstring(raw)
        vals = raw;
    elseif iscell(raw)
        vals = string(raw);
    else
        vals = string(raw);
    end
    vals = vals(strlength(vals) > 0);
end

function baseTargets = deriveBaseTargetsFromSelection(selectedFields, simData)
%deriveBaseTargetsFromSelection  Reduce selected UI fields to base spectral targets.
%
%   selectedFields may contain e.g. ["EF_vol","EF_vol_laser","EF_vol_avg",
%   "Absorptance","Absorptance_laser","EF_surf_analyte"].
%   This strips the derived suffixes to get ["EF_vol","Absorptance","EF_surf"]
%   and cross-checks against actual [N x L] fields in simData.

    derivedSuffixes = ["_laser", "_avg", "_analyte", "_approx"];
    bases = string.empty;

    for i = 1:numel(selectedFields)
        f = selectedFields(i);
        base = f;
        for s = derivedSuffixes
            if endsWith(f, s)
                base = extractBefore(f, strlength(f) - strlength(s) + 1);
                break;
            end
        end
        bases(end+1) = base; %#ok<AGROW>
    end

    bases = unique(bases, "stable");

    % Keep only bases that actually exist as spectral [N x L] fields in simData.
    if ~isempty(simData) && isstruct(simData)
        N = size(simData.period, 1);
        L = size(simData.lambda, 2);
        valid = false(size(bases));
        for i = 1:numel(bases)
            fn = char(bases(i));
            if isfield(simData, fn)
                v = simData.(fn);
                valid(i) = isnumeric(v) && isequal(size(v), [N, L]);
            end
        end
        bases = bases(valid);
    end

    if isempty(bases)
        % Fallback: standard DNN output targets
        bases = ["Absorptance", "EF_vol", "EF_surf"];
        % Further filter to what exists
        if isstruct(simData)
            exists = arrayfun(@(f) isfield(simData, char(f)), bases);
            bases = bases(exists);
        end
    end

    baseTargets = bases;
end

%% ########################################################################
%   STAGE 6 — VISUALIZE HANDLERS (1D spectra / 2D maps / 3D volumes)
%  ########################################################################
function handleVisualizeEvent(src, event, fig)
%handleVisualizeEvent  Dispatch events from the Stage 6 Visualize panel.
%   All renders are transient: nothing produced here is written to the
%   database.
    if isfield(fig.UserData, "handles") && isfield(fig.UserData.handles, "visController") ...
            && ~isempty(fig.UserData.handles.visController)
        fig.UserData.handles.visController.handleEvent(event.HTMLEventName, event.HTMLEventData);
        return;
    end
    name = event.HTMLEventName;
    data = event.HTMLEventData;
    try
        switch name
            case "RequestBranchInfo"
                sendVisualizeBranchInfo(src, fig);
            case "Render"
                runVisualizeRender(src, data, fig);
            case "ClearTraces"
                fig.UserData.visualize.traces = emptyVisualizeTraces();
                ax = fig.UserData.handles.visualizeAx1D;
                if ~isempty(ax.Legend), delete(ax.Legend); end
                cla(ax, "reset");
                styleDarkAxes(ax, "Wavelength (nm)", "Metric value", "1D Spectra");
            case "RefreshDbState"
                broadcastDbStatus(fig);
            case "SaveDatabaseRequest"
                saveDbFile(fig);
                broadcastDbStatus(fig);
            case "StopProcess"
                requestProcessStop(fig);
            otherwise
                fprintf("[Visualize] Unknown event: %s\n", name);
        end
    catch ME
        if strcmp(ME.identifier, "Visualize:Reported")
            return;   % already reported to the panel
        elseif isProcessStopRequested(fig) || strcmp(ME.identifier, "Process:Terminated")
            notifyProcessStopped(fig, "Visualize", "Visualization terminated by user.");
        else
            fprintf("[Visualize] %s\n", getReport(ME, "basic"));
            sendEventToHTMLSource(src, "VisError", string(ME.message));
        end
    end
end

function openInVisualizeTab(fig, branch, mode)
%openInVisualizeTab  Switch to Stage 6 and preselect a data branch / mode.
    h = fig.UserData.handles;
    if ~isfield(h, "visualizeTab") || isempty(h.visualizeTab) || ~isvalid(h.visualizeTab)
        return;
    end
    h.mainTabGroup.SelectedTab = h.visualizeTab;   % does not fire SelectionChangedFcn
    drawnow;
    resizeVisualizePanel(fig);
    sendVisualizeBranchInfo(h.visualizeHtml, fig);
    sendEventToHTMLSource(h.visualizeHtml, "PreselectBranch", ...
        struct("branch", string(branch), "mode", string(mode)));
end

function sendVisualizeBranchInfo(src, fig)
%sendVisualizeBranchInfo  Describe db.Sim / db.Interp / db.Pred for the panel.
    db = fig.UserData.db;
    branches = struct();
    for b = ["Sim", "Interp", "Pred"]
        branches.(b) = describeVisualizeBranch(safeStruct(db, b));
    end
    [hasModel, targets] = localVisualizeModelInfo(fig, branches.Sim);
    payload = struct( ...
        "branches",     branches, ...
        "hasModel",     hasModel, ...
        "modelTargets", {cellstr(targets)}, ...
        "laserWl",      localVisualizeLaserWl(db));
    sendEventToHTMLSource(src, "VisualizeBranchInfo", payload);
end

function info = describeVisualizeBranch(S)
%describeVisualizeBranch  Row count, (p, r) layout and metric lists of one SoA branch.
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
            if lr(2) < 10, lr = lr * 1e3; end   % µm -> nm
            info.lambdaRange = lr;
        end
    end
    [spec, scal] = localClassifyVisualizeFields(S, n);
    info.spectralFields = cellstr(spec);
    info.scalarFields = cellstr(scal);
end

function [spec, scal] = localClassifyVisualizeFields(S, n)
%localClassifyVisualizeFields  Split numeric metric fields into [N x L] and [N x 1].
%   Scalar variants (_laser, _avg, _analyte, BEE_/AEE_) are listed first.
    meta = ["period", "radius", "lambda", "lambda_nm", "RamanShift", ...
            "LaserWl", "lambda_exc_nm", "RamanWindow", "RamanWindowEffective", ...
            "p", "r", "particle_r", "f"];
    L = 0;
    if isfield(S, "lambda"), L = size(S.lambda, 2); end
    spec = strings(1, 0);
    scal = strings(1, 0);
    for f = reshape(string(fieldnames(S)), 1, [])
        if any(f == meta), continue; end
        v = S.(f);
        if ~(isnumeric(v) || islogical(v)) || ~ismatrix(v) || size(v, 1) ~= n
            continue;
        end
        if size(v, 2) == 1
            scal(end+1) = f; %#ok<AGROW>
        elseif L > 1 && size(v, 2) == L
            spec(end+1) = f; %#ok<AGROW>
        end
    end
    isVariant = endsWith(scal, ["_laser", "_avg", "_analyte"]) | startsWith(scal, ["BEE_", "AEE_"]);
    scal = [scal(isVariant), scal(~isVariant)];
end

function [hasModel, targets] = localVisualizeModelInfo(fig, simInfo)
%localVisualizeModelInfo  Model availability and its spectral target names.
    targets = strings(1, 0);
    status = buildDbStatusStruct(fig);
    hasModel = logical(status.hasModel);
    db = fig.UserData.db;
    ve = struct();
    if isfield(fig.UserData, "visExport"), ve = fig.UserData.visExport; end
    model = [];
    if isstruct(ve) && isfield(ve, "model") && isstruct(ve.model) && isfield(ve.model, "targetNames")
        model = ve.model;
    elseif isstruct(db) && isfield(db, "Model") && isstruct(db.Model) && isfield(db.Model, "Model") ...
            && isstruct(db.Model.Model) && isfield(db.Model.Model, "targetNames")
        model = db.Model.Model;
    end
    if ~isempty(model)
        hasModel = true;
        targets = reshape(string(model.targetNames), 1, []);
    elseif hasModel && isfield(db.Model, "TargetNames") && ~isempty(db.Model.TargetNames)
        targets = reshape(string(db.Model.TargetNames), 1, []);
    elseif hasModel
        % Target names are unknown until the model is loaded; offer the
        % Sim spectral metrics (unavailable ones are reported at render).
        targets = reshape(string(simInfo.spectralFields), 1, []);
    end
end

function wl = localVisualizeLaserWl(db)
%localVisualizeLaserWl  Median laser wavelength (nm) recorded in the data branches.
    wl = 785;
    for b = ["Sim", "Interp", "Pred"]
        S = safeStruct(db, b);
        for f = ["LaserWl", "lambda_exc_nm"]
            if isfield(S, f) && isnumeric(S.(f)) && ~isempty(S.(f))
                v = double(S.(f)(:));
                v = v(isfinite(v) & v > 0);
                if ~isempty(v)
                    wl = median(v);
                    if wl < 10, wl = wl * 1e3; end   % µm -> nm
                    return;
                end
            end
        end
    end
end

function runVisualizeRender(src, d, fig)
%runVisualizeRender  Render one 1D / 2D / 3D view from the panel configuration.
    setProcessRunning(fig, true, "Visualize");
    cleanupObj = onCleanup(@() cleanupProcess(fig));
    reporter = makeReporter(src, fig);
    h = fig.UserData.handles;
    resizeVisualizePanel(fig);

    mode = lower(safeStr(d, "mode", "2d"));
    switch mode
        case "1d"
            h.visualizeTabGroup.SelectedTab = h.visualizeTab1D;
            [msg, warns] = renderVisualize1D(src, d, fig, reporter);
        case "2d"
            h.visualizeTabGroup.SelectedTab = h.visualizeTab2D;
            [msg, warns] = renderVisualize2D(d, fig, reporter);
        case "3d"
            h.visualizeTabGroup.SelectedTab = h.visualizeTab3D;
            drawnow;
            [msg, warns] = renderVisualize3D(d, fig, reporter);
        otherwise
            error("Visualize:UnknownMode", "Unknown visualization mode: %s", mode);
    end
    drawnow;
    reporter.checkStop("Render");
    sendEventToHTMLSource(src, "VisualizeComplete", ...
        struct("message", string(msg), "warnings", {cellstr(warns)}));
end

function [msg, warns] = renderVisualize1D(src, d, fig, reporter)
%renderVisualize1D  Spectral traces at one (p, r) from Sim / Interp / Model.
    warns = strings(1, 0);
    source = lower(safeStr(d, "source", "sim"));
    if ~ismember(source, ["sim", "interp", "model"])
        error("Visualize:BadSource", "Unknown 1D source: %s", source);
    end
    p = safeNum(d, "p", NaN);
    r = safeNum(d, "r", NaN);
    if ~isfinite(p) || ~isfinite(r)
        error("Visualize:BadInput", "Period and radius must be finite numbers.");
    end
    metrics = reshape(parseCellOrString(d, "metrics"), 1, []);
    if isempty(metrics)
        error("Visualize:NoMetric", "Select at least one metric.");
    end
    xAxis = lower(safeStr(d, "xAxis", "lambda"));
    if ~ismember(xAxis, ["lambda", "shift"]), xAxis = "lambda"; end
    smoothing = lower(safeStr(d, "smoothing", "makima"));
    if ~ismember(smoothing, ["makima", "pchip", "spline", "linear", "none"]), smoothing = "makima"; end
    laserWl = safeNum(d, "laserWavelength", 785);
    if ~(laserWl > 0), laserWl = 785; end

    S = safeStruct(fig.UserData.db, "Sim");
    reporter.start("Spectra1D", "Evaluating " + source + " spectra...");
    switch source
        case "sim"
            out = lookupSpectrum1D("sim", p, r, metrics, SimData=S);
            sendEventToHTMLSource(src, "VisualizeSnapped", struct( ...
                "p", out.p, "r", out.r, "distance", out.distance, "index", out.simIndex));
            srcLabel = "Sim";
        case "interp"
            method = lower(safeStr(d, "interpMethod", "natural"));
            if ~ismember(method, ["natural", "linear", "nearest"]), method = "natural"; end
            pred = localVisualizeDataPredictor(fig, S, method, reporter);
            out = lookupSpectrum1D("interp", p, r, metrics, SimData=S, ...
                DataPredictor=pred, InterpMethod=method);
            if out.outsideHull
                warns(end+1) = sprintf(['(p, r) = (%.1f, %.1f) nm lies outside the simulated ' ...
                    'convex hull; values fall back to the nearest sample.'], p, r);
            end
            srcLabel = "Interp";
        otherwise   % "model"
            [ok, model, ri] = ensureVisExportModelAndRi(fig, src, reporter);
            if ~ok
                error("Visualize:Reported", "Model or refractive-index data unavailable.");
            end
            lam = localVisualizeModelLambda(d, S, laserWl);
            out = lookupSpectrum1D("model", p, r, metrics, ...
                ModelPredictor=createModelPredictor(model, ri), LambdaGrid=lam);
            srcLabel = "Model";
    end
    reporter.checkStop("Spectra1D");
    if ~isempty(out.missing)
        warns(end+1) = "Not available from this source: " + strjoin(out.missing, ", ") + ".";
    end
    if isempty(out.metrics)
        error("Visualize:NoData", "None of the selected metrics are available from the %s source.", srcLabel);
    end

    newTraces = emptyVisualizeTraces();
    for m = 1:numel(out.metrics)
        tr = struct( ...
            "lambda", reshape(out.lambda, 1, []), ...
            "y", reshape(out.values(:, m), 1, []), ...
            "label", sprintf("%s | %s (p=%.1f, r=%.1f nm)", out.metrics(m), srcLabel, out.p, out.r), ...
            "isDense", out.isDense);
        newTraces(end+1) = tr; %#ok<AGROW>
    end

    titleStr = sprintf("Spectra at p = %.1f nm, r = %.1f nm", out.p, out.r);
    if safeBool(d, "hold", false)
        traces = [fig.UserData.visualize.traces, newTraces];
        maxTraces = 24;
        if numel(traces) > maxTraces
            traces = traces(end-maxTraces+1:end);
            warns(end+1) = sprintf("Only the latest %d traces are kept.", maxTraces);
        end
        if numel(traces) > numel(newTraces)
            titleStr = "Spectral traces";
        end
    else
        traces = newTraces;
    end
    fig.UserData.visualize.traces = traces;

    ax = fig.UserData.handles.visualizeAx1D;
    plotSpectraLines(ax, traces, XAxis=xAxis, LaserWavelength=laserWl, ...
        LogY=safeBool(d, "logY", true), Smoothing=smoothing, ...
        Normalize=safeBool(d, "normalize", false), Title=titleStr);
    reporter.complete("Spectra1D", sprintf("%d trace(s) evaluated.", numel(newTraces)));
    msg = sprintf("1D: %d trace(s) from %s plotted (%d on axes).", numel(newTraces), srcLabel, numel(traces));
end

function pred = localVisualizeDataPredictor(fig, S, method, reporter)
%localVisualizeDataPredictor  Cached createDataPredictor over all Sim spectral metrics.
%   The cache lives in fig.UserData.visualize (memory only) and is keyed
%   on the Sim sample set and the spatial method.
    if ~isfield(S, "period") || ~isfield(S, "lambda") || isempty(S.period)
        error("Visualize:NoSim", "db.Sim is empty; load simulation data first.");
    end
    P = double(S.period(:));
    R = double(S.radius(:));
    key = sprintf("%d|%d|%.9g|%.9g|%s", numel(P), size(S.lambda, 2), ...
        sum(P, "omitnan"), sum(R, "omitnan"), method);
    vis = fig.UserData.visualize;
    if ~isempty(vis.dataPredictor) && strcmp(vis.dataPredictorKey, key)
        pred = vis.dataPredictor;
        return;
    end
    [spec, ~] = localClassifyVisualizeFields(S, numel(P));
    if isempty(spec)
        error("Visualize:NoSpectral", "db.Sim has no spectral [N x L] metrics to interpolate.");
    end
    reporter.info("Building spatial interpolant over db.Sim (cached for later queries)...");
    pred = createDataPredictor(S, TargetNames=spec, InterpMethod=method, SpectralMethod="makima");
    fig.UserData.visualize.dataPredictor = pred;
    fig.UserData.visualize.dataPredictorKey = key;
end

function lam = localVisualizeModelLambda(d, S, laserWl)
%localVisualizeModelLambda  Dense wavelength grid (nm) for model inference.
%   Blank limits default to the Sim wavelength range, or to
%   [lambda_L, lambda(3600 cm^-1)] when no simulation data are loaded.
    lamMin = safeNum(d, "lambdaMin", NaN);
    lamMax = safeNum(d, "lambdaMax", NaN);
    step = safeNum(d, "lambdaStep", 1);
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

function [msg, warns] = renderVisualize2D(d, fig, reporter)
%renderVisualize2D  Scalar metric or spectral slice over the (p, r) plane.
    warns = strings(1, 0);
    [branch, S] = localVisualizeBranch(fig, d);
    metric = safeStr(d, "metric", "");
    if strlength(metric) == 0 || ~isfield(S, metric)
        error("Visualize:NoMetric", "Metric ""%s"" not found in db.%s.", metric, branch);
    end
    kind = lower(safeStr(d, "metricKind", "scalar"));
    P = double(S.period(:));
    R = double(S.radius(:));
    reporter.start("Map2D", "Rendering 2D map of " + metric + "...");
    if kind == "slice"
        shift = safeNum(d, "sliceShift", 1000);
        laserWl = safeNum(d, "laserWavelength", 785);
        lamT = 1 / (1 / laserWl - shift * 1e-7);
        if ~isfinite(lamT) || lamT <= 0
            error("Visualize:BadShift", "Raman shift %.0f cm⁻¹ is not reachable from λ_L = %.1f nm.", shift, laserWl);
        end
        [v, nOut] = localExtractSpectralSlice(S, metric, lamT);
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
    reporter.checkStop("Map2D");

    method = lower(safeStr(d, "renderMethod", "triangulated"));
    if ~ismember(method, ["triangulated", "nearest"]), method = "triangulated"; end
    cmap = loadColormapSafe(256, ~safeBool(d, "invertColormap", false));

    sp = []; sr = [];
    showSim = safeBool(d, "showSimPoints", false);
    if showSim
        simS = safeStruct(fig.UserData.db, "Sim");
        if isfield(simS, "period") && isfield(simS, "radius") && ~isempty(simS.period)
            sp = double(simS.period(:));
            sr = double(simS.radius(:));
        else
            showSim = false;
            warns(end+1) = "db.Sim is empty; no sample overlay drawn.";
        end
    end
    op = []; orr = [];
    if safeBool(d, "showOptima", false)
        [op, orr] = localVisualizeOptima(fig.UserData.db);
        if isempty(op), warns(end+1) = "No saved optima to overlay."; end
    end

    ax = fig.UserData.handles.visualizeAx2D;
    info = plotScatteredMap2D(ax, P, R, v, Method=method, Colormap=cmap, ...
        LogScale=safeBool(d, "logScale", false), Title=titleStr, ColorbarLabel=metric, ...
        ShowPoints=showSim, PointsP=sp, PointsR=sr, OptimaP=op, OptimaR=orr);
    reporter.complete("Map2D", "2D map rendered.");
    if info.isGridded
        layout = sprintf("grid %d×%d (r × p)", info.gridSize(1), info.gridSize(2));
    else
        layout = info.method + " rendering of scattered samples";
    end
    msg = sprintf("2D: %s from db.%s, %d finite samples, %s.", metric, branch, info.nValid, layout);
end

function [v, nOut] = localExtractSpectralSlice(S, metric, lamT)
%localExtractSpectralSlice  Per-row nearest-wavelength sample of a spectral metric.
%   Rows whose wavelength range does not contain lamT return NaN.
    M = S.(metric);
    N = size(M, 1);
    if size(M, 2) < 2
        error("Visualize:NotSpectral", "%s is not a spectral [N x L] metric.", metric);
    end
    lam = double(S.lambda);
    if max(lam(:), [], "omitnan") < 10, lam = lam * 1e3; end   % µm -> nm
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

function [op, orr] = localVisualizeOptima(db)
%localVisualizeOptima  Saved optima coordinates (nm) from db.Optima.
    op = []; orr = [];
    O = safeStruct(db, "Optima");
    if isfield(O, "period") && isfield(O, "radius") && ~isempty(O.period)
        op = double(O.period(:));
        orr = double(O.radius(:));
        n = min(numel(op), numel(orr));
        op = op(1:n); orr = orr(1:n);
        if max(op, [], "omitnan") < 10   % stored in µm
            op = op * 1e3; orr = orr * 1e3;
        end
    end
end

function [msg, warns] = renderVisualize3D(d, fig, reporter)
%renderVisualize3D  Annotated volshow of a spectral metric on a gridded branch.
%   Scattered branches are rejected rather than resampled on the fly; the
%   gridded resample belongs in db.Interp (Stage 4 interpolation).
    warns = strings(1, 0);
    [branch, S] = localVisualizeBranch(fig, d);
    metric = safeStr(d, "metric", "");
    [spec, ~] = localClassifyVisualizeFields(S, numel(S.period));
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
    reporter.start("Volume3D", "Assembling " + metric + " volume...");

    % Wavelength axis (first row; spot-check that rows share it)
    lamAll = S.lambda;
    lamRow = double(lamAll(1, :));
    if size(lamAll, 1) > 1
        chk = unique(round(linspace(1, size(lamAll, 1), min(64, size(lamAll, 1)))));
        dev = max(abs(double(lamAll(chk, :)) - lamRow), [], "all", "omitnan");
        if dev > 1e-6 * max(abs(lamRow), [], "omitnan")
            warns(end+1) = "Rows use different λ grids; the first row's grid is used for the volume.";
        end
    end
    if max(lamRow, [], "omitnan") < 10, lamRow = lamRow * 1e3; end   % µm -> nm
    lamCols = find(isfinite(lamRow));
    [lamSorted, ord] = sort(lamRow(lamCols), "ascend");
    lamCols = lamCols(ord);

    % Decimate each axis to at most maxSamples nodes before assembly
    maxS = max(16, round(safeNum(d, "maxSamples", 256)));
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
    reporter.checkStop("Volume3D");

    pV = pU(iP); rV = rU(iR); lV = lamSorted(iL);

    % Optional overlay: full-height columns at the simulated (p, r) samples
    overlay = [];
    if safeBool(d, "showSimColumns", false)
        simS = safeStruct(fig.UserData.db, "Sim");
        if isfield(simS, "period") && isfield(simS, "radius") && ~isempty(simS.period)
            if np >= 2
                jp = interp1(pV(:), (1:np)', double(simS.period(:)), "nearest");   % NaN outside
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

    cmap = [];   % renderer default: flipped AuroraAustralis
    if safeBool(d, "invertColormap", false)
        cmap = loadColormapSafe(256, false);
    end
    renderAnnotatedVolume(fig.UserData.handles.visualizeViewer, vol, pV, rV, lV, ...
        Colormap=cmap, LogScale=safeBool(d, "logScale", true), ...
        MetricLabel=metric, OverlayMask=overlay);
    reporter.complete("Volume3D", "Volume rendered.");
    msg = sprintf("3D: %s volume %d×%d×%d (r × p × λ) from db.%s.", metric, nr, np, nl, branch);
end

function [branch, S] = localVisualizeBranch(fig, d)
%localVisualizeBranch  Validate the requested data branch and return its SoA struct.
    branch = safeStr(d, "branch", "Sim");
    if ~ismember(branch, ["Sim", "Interp", "Pred"])
        error("Visualize:BadBranch", "Unknown data branch: %s", branch);
    end
    S = safeStruct(fig.UserData.db, branch);
    if ~isfield(S, "period") || ~isfield(S, "radius") || isempty(S.period)
        error("Visualize:EmptyBranch", "db.%s is empty.", branch);
    end
end

function t = emptyVisualizeTraces()
%emptyVisualizeTraces  0x0 trace struct used by the 1D spectra view.
    t = struct("lambda", {}, "y", {}, "label", {}, "isDense", {});
end

function cmap = loadColormapSafe(n, doFlip)
    try, cmap = loadColormap("AuroraAustralis.txt", n);
    catch, cmap = parula(n); end
    if doFlip, cmap = flipud(cmap); end
end

function mf = detectMetricFields(allData)
    exc = ["period","radius","lambda","lambda_nm","RamanShift", ...
           "LaserWl","lambda_exc_nm","RamanWindow","RamanWindowEffective", ...
           "p","r","particle_r","f"];
    flds = string(fieldnames(allData));
    mf = flds(~contains(flds,"_avg") & ~ismember(flds,exc));
end

function loadCustomColormap(fig)
    cmFile = fullfile(fileparts(mfilename("fullpath")), "..", "..", ...
        "src", "vis", "AuroraAustralis.txt");
    if ~isfile(cmFile)
        cmFile = "AuroraAustralis.txt";
    end
    try
        cmap = flipud(loadColormap(cmFile, 256));
    catch
        cmap = parula(256);
    end
    setappdata(fig, "CustomColormap", cmap);
end

function riLoaded = loadRefractiveIndexData(fig)
    riLoaded = false;
    paths = {fullfile(fig.UserData.workDir,"McPeak.csv"), ...
             fullfile(fileparts(mfilename("fullpath")),"McPeak.csv"), ...
             fullfile(pwd,"McPeak.csv")};
    for i = 1:numel(paths)
        if isfile(paths{i})
            try
                ri = load_gold_refractive_index(paths{i},"WavelengthUnit","um");
                if isfield(fig.UserData,"visState")
                    fig.UserData.visState.ri = ri;
                end
                riLoaded = true;
                return
            catch
            end
        end
    end
end

%% --- Safe field access helpers ---
function v = safeStr(s, f, d)
    if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = string(s.(f)); else, v = string(d); end
end
function v = safeNum(s, f, d)
    if isstruct(s) && isfield(s,f) && ~isempty(s.(f))
        v = double(s.(f));
        if isnan(v)
            v = d;
        end
    else
        v = d;
    end
end
function v = safeBool(s, f, d)
    if isstruct(s) && isfield(s,f), v = logical(s.(f)); else, v = d; end
end
function v = safeStruct(s, f)
    %safeStruct Return s.(f) as a struct, or an empty struct if absent or wrong type.
    if isstruct(s) && isfield(s, f) && isstruct(s.(f))
        v = s.(f);
    else
        v = struct();
    end
end


%% ########################################################################
%   OPTIMIZATION WORKFLOW: ROBUSTNESS & STATE MANAGEMENT HELPERS
%  ########################################################################

% Validate that refinement state remains consistent across operations
function validateOptimizeState(optimize)
    % Ensure optimize struct has all required fields
    if ~isstruct(optimize)
        error("optimize state must be a struct");
    end
    
    % Basic fields
    if ~isfield(optimize, "previewResults")
        optimize.previewResults = [];
    end
    if ~isfield(optimize, "lastResults")
        optimize.lastResults = [];
    end
    if ~isfield(optimize, "baseMetric")
        optimize.baseMetric = "EF_vol";
    end
    if ~isfield(optimize, "metricVariant")
        optimize.metricVariant = "avg";
    end
    if ~isfield(optimize, "currentSeeds")
        optimize.currentSeeds = [];
    end
end

% Safe extraction of seed coordinates and tags from table data
function seeds = extractAndValidateSeeds(tableData)
    seeds = normalizeSeedInput(tableData);
end

% Reset optimization state (called when starting new workflow stage)
function optimize = resetOptimizeState(optimize, fullReset)
    if nargin < 2
        fullReset = false;
    end
    
    if fullReset
        % Complete reset
        optimize = struct();
        optimize.previewResults = [];
        optimize.lastResults = [];
        optimize.baseMetric = "EF_vol";
        optimize.metricVariant = "avg";
        optimize.currentSeeds = [];
        optimize.config = struct();
    else
        % Partial reset: keep preview, clear refined
        if isfield(optimize, "lastResults")
            optimize.lastResults = [];
        end
        if isfield(optimize, "currentSeeds")
            optimize.currentSeeds = [];
        end
    end
end
