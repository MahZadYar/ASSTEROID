classdef ImportController < handle
% IMPORTCONTROLLER Controller for Stage 1 Simulation Ingest & QA.
%
%   Coordinates raw electromagnetic simulation sweep imports (COMSOL .dat/.txt),
%   column schema inference, QA summaries, metric recalculations, and database
%   persistence into db.Sim branch within AssteroidSession.
%
%   See also: AssteroidSession, DatabaseController, importSweepConfig, runImportSweepWorkflow

    properties (SetAccess = private)
        session (1,1) AssteroidSession
        fig           = []
        htmlComponent = []
        visPanel      = []
    end

    methods
        function obj = ImportController(session, fig, htmlComponent, visPanel)
        % IMPORTCONTROLLER Construct controller attached to session and UI.
            arguments
                session     (1,1) AssteroidSession
                fig               = []
                htmlComponent     = []
                visPanel          = []
            end
            obj.session = session;
            obj.fig = fig;
            obj.htmlComponent = htmlComponent;
            obj.visPanel = visPanel;
        end

        function handleEvent(obj, eventName, eventData)
        % HANDLEEVENT Dispatch event received from import_tab.html.
            if nargin < 3, eventData = struct(); end

            try
                switch eventName
                    case "PreviewFile"
                        obj.previewImportFile(eventData);
                    case "RunImport"
                        obj.runImportPipeline(eventData);
                    case "RecalculateDerived"
                        obj.recalculateImportDerivedMetrics(eventData);
                    case "BrowseFile"
                        obj.browseFile(eventData);
                    case "RefreshDbState"
                        obj.refreshDbState();
                    case "SaveDatabaseRequest"
                        obj.saveDatabase();
                    case "StopProcess"
                        obj.stopImport();
                    otherwise
                        fprintf("[ImportController] Unknown event: %s\n", eventName);
                end
            catch ME
                if obj.isStopRequested() || strcmp(ME.identifier, "Process:Terminated")
                    obj.notifyStopped("Import process terminated by user.");
                else
                    obj.sendToHTML("ImportError", ME.message);
                end
            end
        end

        function previewImportFile(obj, d)
        % PREVIEWIMPORTFILE Parse sweep table header and emit schema preview.
            inputFile = obj.safeStr(d, "inputFile", "SweepPropeTable.dat");

            candidates = { ...
                string(inputFile), ...
                fullfile(obj.session.workDir, inputFile)};
            if ~isempty(obj.fig) && isvalid(obj.fig) && isfield(obj.fig.UserData, "workDir")
                candidates{end+1} = fullfile(obj.fig.UserData.workDir, inputFile);
            end

            filePath = "";
            for k = 1:numel(candidates)
                if isfile(candidates{k})
                    filePath = candidates{k};
                    break;
                end
            end
            if filePath == ""
                obj.sendToHTML("ImportError", sprintf("File not found: %s", inputFile));
                return;
            end

            % Read file using project sweep table reader
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

            obj.sendToHTML("PreviewResult", result);
        end

        function runImportPipeline(obj, d)
        % RUNIMPORTPIPELINE Execute comprehensive simulation import & QA.
            rep = obj.makeReporter();
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            analyteFile = obj.resolveAnalyteFile();
            outputFile = obj.resolveOutputFile();

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
                WorkDir             = obj.session.workDir, ...
                InputFile           = obj.safeStr(d, "inputFile", "SweepPropeTable.dat"), ...
                OutputFile          = outputFile, ...
                AnalyteSpectrumFile = analyteFile, ...
                ColumnSchema        = columnSchema, ...
                LaserWavelength     = obj.safeNum(d, "laserWavelength", 785), ...
                RamanWindow         = [obj.safeNum(d,"ramanWindowMin",100), obj.safeNum(d,"ramanWindowMax",3600)], ...
                DetectShiftWindow   = obj.safeBool(d, "detectShiftWindow", false), ...
                InterpResolution    = obj.safeNum(d, "interpResolution", 1), ...
                SpectralInterpMethod = obj.safeStr(d, "spectralInterpMethod", "makima"), ...
                Mode                = obj.safeStr(d, "mode", "merge"), ...
                ReplaceExisting     = obj.safeBool(d, "replaceExisting", false), ...
                RecalculateExisting = obj.safeBool(d, "recalculateExisting", false), ...
                MetricVariants      = obj.safeStruct(d, "metricVariants"));

            results = runImportSweepWorkflow(cfg, rep);

            % Render QA plots into the right panel (if available)
            if ~isempty(obj.visPanel) && isvalid(obj.visPanel)
                try
                    obj.visPanel.Visible = "on";
                    delete(allchild(obj.visPanel));
                    visualizeImportSummary(results, Parent=obj.visPanel);
                catch ME2
                    obj.visPanel.Visible = "off";
                    fprintf("[ImportController] Visualization error: %s\n", ME2.message);
                end
            end

            % Write-back to session and figure database
            if isfield(results, "db") && isstruct(results.db)
                obj.session.db = results.db;
            end
            if isfield(cfg, "outputFile") && strlength(string(cfg.outputFile)) > 0
                if ~isfield(obj.session.db, "Global") || ~isstruct(obj.session.db.Global)
                    obj.session.db.Global = struct();
                end
                outPath = string(cfg.outputFile);
                isAbsWin = ~isempty(regexp(char(outPath), '^[A-Za-z]:[\\/]', 'once'));
                isAbsUnc = startsWith(outPath, "\\");
                isAbsUnix = startsWith(outPath, "/");
                if ~(isAbsWin || isAbsUnc || isAbsUnix)
                    outPath = fullfile(string(cfg.workDir), outPath);
                end
                obj.session.db.Global.SimFile = outPath;
            end

            obj.session.markDirty();
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.db = obj.session.db;
                obj.fig.UserData.dbDirty = true;
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                    obj.fig.UserData.app.markDbDirty();
                end
            end

            obj.refreshDbState();

            obj.sendToHTML("ImportComplete", ...
                sprintf("%d entries imported in %.1f s", ...
                    results.summary.numEntries, results.elapsedTotal));
        end

        function recalculateImportDerivedMetrics(obj, d)
        % RECALCULATEIMPORTDERIVEDMETRICS Recompute *_laser, *_avg, *_analyte for db.Sim.
            rep = obj.makeReporter();
            obj.setRunning(true);
            cObj = onCleanup(@() obj.setRunning(false));

            if ~isfield(obj.session.db, "Sim") || ~isstruct(obj.session.db.Sim) || structRowCount(obj.session.db.Sim) == 0
                obj.sendToHTML("ImportError", "No simulation data in database (db.Sim is empty).");
                return;
            end

            cfg = importSweepConfig( ...
                WorkDir             = obj.session.workDir, ...
                LaserWavelength     = obj.safeNum(d, "laserWavelength", 785), ...
                RamanWindow         = [obj.safeNum(d,"ramanWindowMin",100), obj.safeNum(d,"ramanWindowMax",3600)], ...
                DetectShiftWindow   = obj.safeBool(d, "detectShiftWindow", false), ...
                InterpResolution    = obj.safeNum(d, "interpResolution", 1), ...
                SpectralInterpMethod = obj.safeStr(d, "spectralInterpMethod", "makima"), ...
                MetricVariants      = obj.safeStruct(d, "metricVariants"));

            % Resolve analyte spectrum
            analyteSpectrum = struct();
            analyteFile = obj.resolveAnalyteFile();
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

            soaData = extractBranchAsSoA(obj.session.db, "Sim");
            [soaData, updatedCount] = recomputeDerivedMetrics(soaData, cfg, analyteSpectrum, rep);

            % Write updated fields back to db.Sim preserving metadata
            soaFields = fieldnames(soaData);
            for kf = 1:numel(soaFields)
                obj.session.db.Sim.(soaFields{kf}) = soaData.(soaFields{kf});
            end

            obj.session.markDirty();
            if ~isempty(obj.fig) && isvalid(obj.fig)
                obj.fig.UserData.db = obj.session.db;
                obj.fig.UserData.dbDirty = true;
                if isfield(obj.fig.UserData, "app") && isfield(obj.fig.UserData.app, "markDbDirty")
                    obj.fig.UserData.app.markDbDirty();
                end
            end

            obj.refreshDbState();
            obj.sendToHTML("RecalculateComplete", sprintf("Updated %d geometry rows.", updatedCount));
        end

        function browseFile(obj, d)
        % BROWSEFILE Open OS file selection dialog and send result back to UI.
            fieldId = "";
            fileType = "file";
            if isstruct(d)
                if isfield(d, "field"), fieldId = string(d.field); end
                if isfield(d, "type"),  fileType = string(d.type); end
            end

            startDir = obj.session.workDir;
            if fileType == "folder"
                folder = uigetdir(startDir, "Select Folder");
                if folder ~= 0
                    obj.sendToHTML("BrowseResult", struct("field", fieldId, "path", string(folder)));
                end
            else
                [file, path] = uigetfile({"*.dat;*.txt;*.csv;*.mat", "Data Files"}, "Select File", startDir);
                if file ~= 0
                    fullPath = fullfile(path, file);
                    obj.sendToHTML("BrowseResult", struct("field", fieldId, "path", string(fullPath)));
                end
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

        function stopImport(obj)
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
        function outputFile = resolveOutputFile(obj)
            outputFile = "prl_sweep.mat";
            db = obj.session.db;
            if isfield(db, "Global") && isfield(db.Global, "SimFile")
                sf = string(db.Global.SimFile);
                if strlength(sf) > 0
                    outputFile = sf;
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
            else
                analyteFile = resolveAnalyteSpectrumPath(obj.session.db);
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
                    obj.fig.UserData.app.setProcessRunning(isRunning, "Import");
                elseif isfield(obj.fig.UserData, "process")
                    obj.fig.UserData.process.isRunning = logical(isRunning);
                end
            end
            obj.session.setProcessRunning(isRunning, "Import");
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
                    obj.fig.UserData.app.notifyProcessStopped("Import", msg);
                else
                    obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
                end
            else
                obj.sendToHTML("Progress", struct("status", "Stopped", "message", msg));
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

        function s = safeStruct(~, parent, fieldName)
            s = struct();
            if isfield(parent, fieldName) && isstruct(parent.(fieldName))
                s = parent.(fieldName);
            end
        end
    end
end
