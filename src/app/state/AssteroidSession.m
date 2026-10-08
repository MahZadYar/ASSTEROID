classdef AssteroidSession < handle
% ASSTEROIDSESSION Central observable session state store for ASSTEROID.
%
%   AssteroidSession provides a single source of truth for the active
%   working directory, loaded database, trained models, refractive index
%   tables, and background process status. It emits events when branches
%   change so that all UI controllers can synchronize reactively.
%
%   Events:
%     DatabaseLoaded      - Fired after a database is loaded into session
%     DatabaseSaved       - Fired after the database is persisted to disk
%     BranchModified      - Fired when a branch (Sim, Pred, etc.) is updated
%     ModelLoaded         - Fired when a surrogate DNN model is loaded
%     ProcessStateChanged - Fired when background jobs start, stop, or halt
%
%   See also: DatabaseEngine, createDatabaseStruct

    properties
        workDir         (1,1) string = string(pwd)
        db              (1,1) struct = struct()
        dbFile          (1,1) string = ""
        dbDirty         (1,1) logical = false
        model           = []
        modelLoaded     (1,1) logical = false
        ri              = []
        riLoaded        (1,1) logical = false
        analyteSpectrum (1,1) struct = struct()
        process         (1,1) struct = struct( ...
            "isRunning",     false, ...
            "stopRequested", false, ...
            "activeStage",   "")
    end

    properties (Dependent)
        dirty
    end

    events
        DatabaseLoaded
        DatabaseSaved
        BranchModified
        ModelLoaded
        RiLoaded
        ProcessStateChanged
    end

    methods
        function obj = AssteroidSession(workFolder)
        % ASSTEROIDSESSION Construct an initialized session instance.
            if nargin >= 1 && strlength(string(workFolder)) > 0
                obj.workDir = string(workFolder);
            else
                obj.workDir = string(pwd);
            end
            obj.db = createDatabaseStruct();
        end

        function info = loadDatabase(obj, dbPath, reporter)
        % LOADDATABASE Load a database via DatabaseEngine and update session.
            arguments
                obj            (1,1) AssteroidSession
                dbPath         (1,1) string
                reporter             = []
            end

            [loadedDb, info] = DatabaseEngine.loadDatabase(dbPath, reporter);
            obj.db = loadedDb;
            obj.dbFile = dbPath;
            obj.dbDirty = false;

            % Update workDir if stored in DB
            if isfield(obj.db, "Global") && isfield(obj.db.Global, "WorkDir") ...
                    && strlength(string(obj.db.Global.WorkDir)) > 0
                obj.workDir = string(obj.db.Global.WorkDir);
            else
                obj.workDir = string(fileparts(dbPath));
            end

            % Check for embedded model
            if isfield(obj.db, "Model") && isstruct(obj.db.Model)
                if isfield(obj.db.Model, "Model") && isstruct(obj.db.Model.Model)
                    obj.model = obj.db.Model.Model;
                    obj.modelLoaded = true;
                    notify(obj, "ModelLoaded");
                elseif isfield(obj.db.Model, "Net") && ~isempty(obj.db.Model.Net)
                    obj.model = obj.db.Model;
                    obj.modelLoaded = true;
                    notify(obj, "ModelLoaded");
                end
            end

            % Check for embedded RI
            if isfield(obj.db, "RI") && isstruct(obj.db.RI)
                if isfield(obj.db.RI, "lambda") && ~isempty(obj.db.RI.lambda)
                    obj.ri = obj.db.RI;
                    obj.riLoaded = true;
                    notify(obj, "RiLoaded");
                end
            end

            notify(obj, "DatabaseLoaded");
        end

        function info = saveDatabase(obj, savePath, reporter)
        % SAVEDATABASE Persist the in-memory database to disk via DatabaseEngine.
            arguments
                obj            (1,1) AssteroidSession
                savePath       (1,1) string = obj.dbFile
                reporter             = []
            end

            if savePath == ""
                error("AssteroidSession:NoPath", "No file path specified for saving.");
            end

            info = DatabaseEngine.saveDatabase(obj.db, savePath, reporter);
            obj.dbFile = savePath;
            obj.dbDirty = false;

            notify(obj, "DatabaseSaved");
        end

        function [future, info] = saveDatabaseAsync(obj, savePath, onComplete, reporter)
        % SAVEDATABASEASYNC Persist database asynchronously via backgroundPool / process pool.
            arguments
                obj            (1,1) AssteroidSession
                savePath       (1,1) string = obj.dbFile
                onComplete           = []
                reporter             = []
            end

            if savePath == ""
                error("AssteroidSession:NoPath", "No file path specified for saving.");
            end

            cbWrapper = @(res) obj.handleAsyncSaveComplete(res, savePath, onComplete);
            [future, info] = DatabaseEngine.saveDatabaseAsync(obj.db, savePath, cbWrapper, reporter);
            if ~info.isAsync
                obj.dbFile = savePath;
                obj.dbDirty = false;
                notify(obj, "DatabaseSaved");
            end
        end

        function handleAsyncSaveComplete(obj, info, savePath, userCallback)
            obj.dbFile = savePath;
            obj.dbDirty = false;
            notify(obj, "DatabaseSaved");
            if ~isempty(userCallback)
                userCallback(info);
            end
        end

        function markDirty(obj)
        % MARKDIRTY Flag the session as having unsaved modifications.
            obj.dbDirty = true;
            notify(obj, "BranchModified");
        end

        function setProcessRunning(obj, isRunning, stageName)
        % SETPROCESSRUNNING Update background process execution state.
            if nargin < 3, stageName = ""; end
            obj.process.isRunning = logical(isRunning);
            if isRunning
                obj.process.stopRequested = false;
                obj.process.activeStage = string(stageName);
            else
                obj.process.activeStage = "";
            end
            notify(obj, "ProcessStateChanged");
        end

        function requestStop(obj)
        % REQUESTSTOP Signal a cancellation request for the active process.
            obj.process.stopRequested = true;
            notify(obj, "ProcessStateChanged");
        end

        function tf = isStopRequested(obj)
        % ISSTOPREQUESTED True if user clicked stop for the active process.
            tf = obj.process.stopRequested;
        end

        function status = getStatusStruct(obj)
        % GETSTATUSSTRUCT Summary struct representation for UI broadcast.
            status = struct( ...
                "dbFile",         obj.dbFile, ...
                "dbDirty",        obj.dbDirty, ...
                "projectName",    "", ...
                "authors",        "", ...
                "description",    "", ...
                "paperDOI",       "", ...
                "hasSimData",     false, ...
                "simEntries",     0, ...
                "hasModel",       obj.modelLoaded, ...
                "modelFile",      "", ...
                "hasPredictions", false, ...
                "predEntries",    0, ...
                "hasInterp",      false, ...
                "interpEntries",  0, ...
                "hasRI",          obj.riLoaded, ...
                "hasAnalyte",     false, ...
                "analyteFile",    "", ...
                "hasOptima",      false, ...
                "optimaCount",    0, ...
                "workDir",        obj.workDir, ...
                "simFile",        "");

            db_ = obj.db;
            if ~isstruct(db_), return; end

            if isfield(db_, "Global")
                g = db_.Global;
                if isfield(g, "ProjectName"), status.projectName = string(g.ProjectName); end
                if isfield(g, "Authors"),     status.authors     = string(g.Authors);     end
                if isfield(g, "Description"), status.description = string(g.Description); end
                if isfield(g, "PaperDOI"),    status.paperDOI    = string(g.PaperDOI);    end
                if isfield(g, "SimFile"),     status.simFile     = string(g.SimFile);     end
                if isfield(g, "AnalyteSpectrumFile") && strlength(string(g.AnalyteSpectrumFile)) > 0
                    status.hasAnalyte = true;
                    status.analyteFile = string(g.AnalyteSpectrumFile);
                end
            end

            if isfield(db_, "Sim") && isstruct(db_.Sim)
                n = structRowCount(db_.Sim);
                status.simEntries = n;
                status.hasSimData = n > 0;
            end

            if isfield(db_, "Model") && isstruct(db_.Model)
                m = db_.Model;
                hasNet = isfield(m, "Net") && ~isempty(m.Net);
                hasNetFile = isfield(m, "NetFile") && strlength(string(m.NetFile)) > 0;
                hasInner = isfield(m, "Model") && ~isempty(m.Model);
                status.hasModel = obj.modelLoaded || hasNet || hasNetFile || hasInner;
                if hasNetFile
                    status.modelFile = string(m.NetFile);
                end
            end

            if isfield(db_, "RI") && isstruct(db_.RI)
                hasLambda = isfield(db_.RI, "lambda") && ~isempty(db_.RI.lambda);
                status.hasRI = obj.riLoaded || hasLambda;
            end

            if isfield(db_, "Pred") && isstruct(db_.Pred)
                n = structRowCount(db_.Pred);
                status.predEntries = n;
                status.hasPredictions = n > 0;
            end

            if isfield(db_, "Interp") && isstruct(db_.Interp)
                n = structRowCount(db_.Interp);
                status.interpEntries = n;
                status.hasInterp = n > 0;
            end

            if isfield(db_, "Optima") && isstruct(db_.Optima) && isfield(db_.Optima, "period")
                nOpt = numel(db_.Optima.period);
                status.hasOptima = nOpt > 0;
                status.optimaCount = nOpt;
            end
        end

        function tf = hasSimData(obj)
        % HASSIMDATA True if session has a non-empty simulation data branch.
            tf = isfield(obj.db, "Sim") && isstruct(obj.db.Sim) && structRowCount(obj.db.Sim) > 0;
        end

        function tf = hasModel(obj)
        % HASMODEL True if session has a valid DNN surrogate model loaded or stored.
            tf = obj.modelLoaded || (isfield(obj.db, "Model") && isstruct(obj.db.Model) && ...
                ((isfield(obj.db.Model, "Net") && ~isempty(obj.db.Model.Net)) || ...
                 (isfield(obj.db.Model, "Model") && ~isempty(obj.db.Model.Model)) || ...
                 (isfield(obj.db.Model, "NetFile") && strlength(string(obj.db.Model.NetFile)) > 0)));
        end

        function tf = hasRI(obj)
        % HASRI True if session has valid refractive index data loaded or stored.
            tf = obj.riLoaded || (isfield(obj.db, "RI") && isstruct(obj.db.RI) && ...
                isfield(obj.db.RI, "lambda") && ~isempty(obj.db.RI.lambda));
        end

        function val = get.dirty(obj)
            val = obj.dbDirty;
        end

        function set.dirty(obj, val)
            obj.dbDirty = logical(val);
        end
    end
end
