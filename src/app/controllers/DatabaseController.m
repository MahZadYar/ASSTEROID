classdef DatabaseController < handle
% DATABASECONTROLLER Controller for Stage 0 Database Manager.
%
%   Coordinates database loading, atomic saving, tree inspection, branch
%   data loading/clearing, and metadata synchronization between the
%   database_tab.html UI and the AssteroidSession state.
%
%   See also: AssteroidSession, DatabaseEngine, assteroid_app

    properties (SetAccess = private)
        session (1,1) AssteroidSession
        fig     matlab.ui.Figure
        htmlComponent
    end

    methods
        function obj = DatabaseController(session, fig, htmlComponent)
        % DATABASECONTROLLER Construct controller attached to session and UI.
            obj.session = session;
            obj.fig = fig;
            obj.htmlComponent = htmlComponent;
        end

        function handleEvent(obj, eventName, eventData)
        % HANDLEEVENT Dispatch events received from database_tab.html.
            src = obj.htmlComponent;
            fig_ = obj.fig;
            sess = obj.session;

            try
                switch eventName
                    case "BrowseDbFile"
                        [file, path] = uigetfile( ...
                            {"*.mat", "MAT Files"}, "Select Database File", sess.workDir);
                        if file ~= 0
                            fullPath = fullfile(path, file);
                            obj.sendToHTML("BrowseResult", ...
                                struct("field", "dbFile", "path", fullPath));
                        end

                    case "LoadDatabase"
                        dbPath = "";
                        if isstruct(eventData) && isfield(eventData, "path")
                            dbPath = string(eventData.path);
                        end
                        if dbPath == ""
                            obj.sendToHTML("Error", "No file path specified.");
                            return;
                        end
                        if ~isfile(dbPath)
                            obj.sendToHTML("Error", "File not found: " + dbPath);
                            return;
                        end

                        obj.sendProgress(sprintf("Initiating database load: '%s'...", dbPath));
                        drawnow;

                        reporter = @(msg, type) obj.sendProgress(msg);
                        info = sess.loadDatabase(dbPath, reporter);

                        % Sync legacy fig.UserData for backward compatibility
                        if ~isempty(fig_) && isvalid(fig_)
                            fig_.UserData.db = sess.db;
                            fig_.UserData.dbFile = sess.dbFile;
                            fig_.UserData.dbDirty = false;
                            fig_.UserData.workDir = sess.workDir;
                        end

                        obj.sendToHTML("LoadComplete", ...
                            sprintf("Database loaded: %s (%.2f s, %s)", ...
                                dbPath, info.elapsed, info.sizeString));
                        obj.broadcastStatus();

                    case "SaveDatabase"
                        if isstruct(eventData) && isfield(eventData, "path") && strlength(string(eventData.path)) > 0
                            sess.dbFile = string(eventData.path);
                        end
                        if sess.dbFile == ""
                            [file, path] = uiputfile( ...
                                {"*.mat", "MAT Files"}, "Save Database As", ...
                                fullfile(sess.workDir, "database.mat"));
                            if file == 0, return; end
                            sess.dbFile = string(fullfile(path, file));
                        end

                        obj.sendProgress(sprintf("Initiating database save: '%s'...", sess.dbFile));
                        drawnow;

                        reporter = @(msg, type) obj.sendProgress(msg);
                        info = sess.saveDatabase(sess.dbFile, reporter);

                        if ~isempty(fig_) && isvalid(fig_)
                            fig_.UserData.dbDirty = false;
                        end

                        obj.sendToHTML("SaveComplete", ...
                            sprintf("Database saved in %.2f s (Size: %s, %.1f MB/s).", ...
                                info.elapsed, info.sizeString, info.rateMBs));
                        obj.broadcastStatus();

                    case "BrowseSaveAs"
                        [file, path] = uiputfile( ...
                            {"*.mat", "MAT Files"}, "Save Database As", ...
                            fullfile(sess.workDir, "database.mat"));
                        if file ~= 0
                            savePath = string(fullfile(path, file));
                            obj.sendProgress(sprintf("Initiating database save to '%s'...", savePath));
                            drawnow;

                            reporter = @(msg, type) obj.sendProgress(msg);
                            info = sess.saveDatabase(savePath, reporter);

                            if ~isempty(fig_) && isvalid(fig_)
                                fig_.UserData.dbFile = sess.dbFile;
                                fig_.UserData.dbDirty = false;
                            end

                            obj.sendToHTML("SaveComplete", ...
                                sprintf("Database saved in %.2f s (Size: %s, %.1f MB/s).", ...
                                    info.elapsed, info.sizeString, info.rateMBs));
                            obj.broadcastStatus();
                        end

                    case "NewDatabase"
                        sess.db = createDatabaseStruct();
                        sess.dbFile = "";
                        sess.markDirty();
                        if ~isempty(fig_) && isvalid(fig_)
                            fig_.UserData.db = sess.db;
                            fig_.UserData.dbFile = "";
                            fig_.UserData.dbDirty = true;
                        end
                        obj.broadcastStatus();

                    case "UpdateMetadata"
                        if isfield(eventData, "projectName"), sess.db.Global.ProjectName = string(eventData.projectName); end
                        if isfield(eventData, "authors"),     sess.db.Global.Authors = string(eventData.authors); end
                        if isfield(eventData, "description"), sess.db.Global.Description = string(eventData.description); end
                        if isfield(eventData, "paperDOI"),    sess.db.Global.PaperDOI = string(eventData.paperDOI); end
                        sess.markDirty();
                        if ~isempty(fig_) && isvalid(fig_)
                            fig_.UserData.db = sess.db;
                            fig_.UserData.dbDirty = true;
                        end
                        obj.broadcastStatus();

                    case "InspectDb"
                        treeData = DatabaseController.serializeToTree(sess.db, "db", 4);
                        obj.sendToHTML("DbTree", treeData);

                    case "BrowseWorkDir"
                        d = uigetdir(sess.workDir, "Select Working Directory");
                        if d ~= 0
                            sess.workDir = string(d);
                            if ~isempty(fig_) && isvalid(fig_)
                                fig_.UserData.workDir = sess.workDir;
                            end
                            obj.broadcastStatus();
                        end

                    case "ExportHDF5"
                        hdfFile = fullfile(sess.workDir, "database_export.h5");
                        [f, p] = uiputfile("*.h5", "Export HDF5", hdfFile);
                        if f ~= 0
                            exportDatabaseToHDF5(sess.db, fullfile(p, f));
                            obj.sendToHTML("ExportComplete", sprintf("Exported to %s", fullfile(p, f)));
                        end

                    case "ExportONNX"
                        if isfield(sess.db, "Model") && isfield(sess.db.Model, "Net") && ~isempty(sess.db.Model.Net)
                            onnxFile = fullfile(sess.workDir, "surrogate_model.onnx");
                            [f, p] = uiputfile("*.onnx", "Export ONNX", onnxFile);
                            if f ~= 0
                                exportModelToOnnx(sess.db.Model.Net, fullfile(p, f));
                                obj.sendToHTML("ExportComplete", sprintf("ONNX exported to %s", fullfile(p, f)));
                            end
                        else
                            obj.sendToHTML("Error", "No trained model available to export.");
                        end

                    case "RefreshDbState"
                        obj.broadcastStatus();

                    case "StopProcess"
                        sess.requestStop();

                    otherwise
                        fprintf("[DatabaseController] Unhandled event: %s\n", eventName);
                end
            catch ME
                fprintf("[DatabaseController] ERROR in %s: %s\n", eventName, ME.message);
                obj.sendToHTML("Error", ME.message);
            end
        end

        function broadcastStatus(obj)
        % BROADCASTSTATUS Push updated session summary to all HTML panels.
            status = obj.session.getStatusStruct();
            obj.sendToHTML("DbStatus", status);

            fig_ = obj.fig;
            if ~isempty(fig_) && isvalid(fig_) && isfield(fig_.UserData, "handles") ...
                    && isfield(fig_.UserData.handles, "htmlPanels")
                panels = fig_.UserData.handles.htmlPanels;
                for k = 1:numel(panels)
                    if isvalid(panels(k)) && panels(k) ~= obj.htmlComponent
                        try
                            sendEventToHTMLSource(panels(k), "DbStatus", status);
                        catch
                        end
                    end
                end
            end
        end

    end

    methods (Access = private)
        function sendToHTML(obj, eventName, payload)
            if ~isempty(obj.htmlComponent) && isvalid(obj.htmlComponent)
                sendEventToHTMLSource(obj.htmlComponent, eventName, payload);
            end
        end

        function sendProgress(obj, msg)
            timestamp = string(datetime("now", "Format", "HH:mm:ss"));
            fullMsg = sprintf("[%s] %s", timestamp, msg);
            obj.sendToHTML("Progress", struct("message", fullMsg, "fraction", []));
            fprintf("%s\n", fullMsg);
        end
    end

    methods (Static)
        function node = serializeToTree(val, name, maxDepth)
        % SERIALIZETOTREE Recursively serialize a MATLAB value into a tree struct.
            if nargin < 3, maxDepth = 4; end
            node = struct('name', string(name), 'type', '', 'size', '', ...
                          'value', '', 'children', {{}});

            if isstruct(val) && numel(val) == 1
                node.type = 'struct';
                fns = fieldnames(val);
                node.size = sprintf('1×1 struct (%d fields)', numel(fns));
                if maxDepth > 0
                    for k = 1:numel(fns)
                        child = DatabaseController.serializeToTree(val.(fns{k}), fns{k}, maxDepth - 1);
                        node.children{end+1} = child;
                    end
                else
                    node.value = sprintf('{%s}', strjoin(string(fns), ', '));
                end

            elseif isstruct(val) && numel(val) > 1
                node.type = 'struct[]';
                node.size = sprintf('%s struct (%d fields)', mat2str(size(val)), numel(fieldnames(val)));
                if maxDepth > 0
                    nShow = min(numel(val), 5);
                    for k = 1:nShow
                        child = DatabaseController.serializeToTree(val(k), sprintf('[%d]', k), maxDepth - 1);
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
                        child = DatabaseController.serializeToTree(val{k}, sprintf('{%d}', k), maxDepth - 1);
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
                    node.size = sprintf('%d layers', numel(val.Layers));
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
                node.value = '<unsupported>';
            end
        end
    end
end
