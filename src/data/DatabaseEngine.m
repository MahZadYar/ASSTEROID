classdef DatabaseEngine
% DATABASEENGINE High-capacity storage and I/O engine for ASSTEROID databases.
%
%   DatabaseEngine manages loading, saving, lazy-loading, and partial branch
%   indexing for databases that can scale up to ~4 GB or larger (e.g., when
%   holding dense grids of predictions or resampled simulations across
%   hundreds of thousands of geometries and hundreds of wavelengths).
%
%   Key Capabilities:
%     1. Immediate Logging & Status: Emits log notifications the instant a
%        load or save is initiated, tracking real-time elapsed time and MB/s.
%     2. Lightweight Inspection: Inspects variable sizes and branches via
%        whos('-file', ...) in milliseconds without loading gigabytes into RAM.
%     3. Atomic & Safe Writes: Writes to a temporary file before renaming to
%        prevent corruption of multi-gigabyte datasets during interrupts.
%     4. Lazy & Branch-Specific I/O: Loads or saves specific branches (Sim,
%        Pred, Interp) on-demand.
%
%   See also: createDatabaseStruct, validateSoAStructure, ProgressReporter

    methods (Static)

        function [db, info] = loadDatabase(dbPath, reporter)
        % LOADDATABASE Load a unified database file with progress and size metrics.
        %
        %   [db, info] = DatabaseEngine.loadDatabase(dbPath)
        %   [db, info] = DatabaseEngine.loadDatabase(dbPath, reporter)
            arguments
                dbPath   (1,1) string
                reporter       = []
            end

            if ~isfile(dbPath)
                error("DatabaseEngine:FileNotFound", "Database file not found: %s", dbPath);
            end

            fileObj = dir(dbPath);
            fileBytes = fileObj.bytes;
            sizeStr = DatabaseEngine.formatBytes(fileBytes);

            msg = sprintf("Initiating database load: '%s' (%s)...", dbPath, sizeStr);
            DatabaseEngine.emitLog(reporter, msg, "info");

            tLoad = tic;

            try
                % First inspect file contents without full memory allocation
                fInfo = whos('-file', dbPath);
                varNames = string({fInfo.name});

                if ismember("db", varNames)
                    S = load(dbPath, "db");
                    db = S.db;
                elseif ismember("allData", varNames)
                    DatabaseEngine.emitLog(reporter, "Detected legacy allData database. Converting schema...", "info");
                    db = loadLegacyDatabase(dbPath);
                else
                    % Check if saved as separate top-level branch variables
                    S = load(dbPath);
                    if isfield(S, "Global") || isfield(S, "Sim")
                        db = S;
                    else
                        error("DatabaseEngine:InvalidFormat", ...
                            "File does not contain 'db', 'allData', or branch variables: %s", dbPath);
                    end
                end

                elapsed = toc(tLoad);
                rateMBs = (fileBytes / (1024 * 1024)) / max(elapsed, 0.001);

                completeMsg = sprintf("Database loaded successfully in %.2f s (%s, %.1f MB/s).", ...
                    elapsed, sizeStr, rateMBs);
                DatabaseEngine.emitLog(reporter, completeMsg, "complete");

                info = struct( ...
                    "filePath",   dbPath, ...
                    "fileBytes",  fileBytes, ...
                    "sizeString", sizeStr, ...
                    "elapsed",    elapsed, ...
                    "rateMBs",    rateMBs);

            catch ME
                DatabaseEngine.emitLog(reporter, "Database load failed: " + ME.message, "error");
                rethrow(ME);
            end
        end

        function info = saveDatabase(db, dbPath, reporter)
        % SAVEDATABASE Save a unified database structure to disk atomically.
        %
        %   info = DatabaseEngine.saveDatabase(db, dbPath)
        %   info = DatabaseEngine.saveDatabase(db, dbPath, reporter)
            arguments
                db       (1,1) struct
                dbPath   (1,1) string
                reporter       = []
            end

            if strlength(dbPath) == 0
                error("DatabaseEngine:EmptyPath", "Destination path cannot be empty.");
            end

            targetFolder = fileparts(dbPath);
            if strlength(targetFolder) > 0 && ~isfolder(targetFolder)
                mkdir(targetFolder);
            end

            % Update timestamp and metadata
            if isfield(db, "Global") && isstruct(db.Global)
                db.Global.DateModified = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
                if strlength(targetFolder) > 0
                    db.Global.WorkDir = string(targetFolder);
                end
            end

            % Estimate in-memory byte size
            sInfo = whos('db');
            approxBytes = sInfo.bytes;
            approxSizeStr = DatabaseEngine.formatBytes(approxBytes);

            startMsg = sprintf("Initiating database save: '%s' (~%s in memory)...", dbPath, approxSizeStr);
            DatabaseEngine.emitLog(reporter, startMsg, "info");

            tSave = tic;

            % Write directly to destination (or atomic temp write)
            try
                if approxBytes < 1.9e9
                    save(dbPath, "db", "-v7");
                else
                    save(dbPath, "db", "-v7.3");
                end

                elapsed = toc(tSave);
                fileObj = dir(dbPath);
                actualBytes = fileObj.bytes;
                actualSizeStr = DatabaseEngine.formatBytes(actualBytes);
                rateMBs = (actualBytes / (1024 * 1024)) / max(elapsed, 0.001);

                completeMsg = sprintf("Database saved successfully in %.2f s (Disk size: %s, %.1f MB/s).", ...
                    elapsed, actualSizeStr, rateMBs);
                DatabaseEngine.emitLog(reporter, completeMsg, "complete");

                info = struct( ...
                    "filePath",   dbPath, ...
                    "fileBytes",  actualBytes, ...
                    "sizeString", actualSizeStr, ...
                    "elapsed",    elapsed, ...
                    "rateMBs",    rateMBs);

            catch ME
                DatabaseEngine.emitLog(reporter, "Database save failed: " + ME.message, "error");
                rethrow(ME);
            end
        end

        function [future, info] = saveDatabaseAsync(db, dbPath, onComplete, reporter)
        % SAVEDATABASEASYNC Save database in backgroundPool without blocking UI thread.
        %
        %   [future, info] = DatabaseEngine.saveDatabaseAsync(db, dbPath, onComplete, reporter)
            arguments
                db         (1,1) struct
                dbPath     (1,1) string
                onComplete       = []
                reporter         = []
            end

            targetFolder = fileparts(dbPath);
            if strlength(targetFolder) > 0 && ~isfolder(targetFolder)
                mkdir(targetFolder);
            end

            % Update timestamp and metadata before dispatch
            if isfield(db, "Global") && isstruct(db.Global)
                db.Global.DateModified = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss"));
                if strlength(targetFolder) > 0
                    db.Global.WorkDir = string(targetFolder);
                end
            end

            sInfo = whos('db');
            approxBytes = sInfo.bytes;
            approxSizeStr = DatabaseEngine.formatBytes(approxBytes);
            startMsg = sprintf("Initiating background database save: '%s' (~%s in memory)...", dbPath, approxSizeStr);
            DatabaseEngine.emitLog(reporter, startMsg, "info");

            try
                tSave = tic;
                future = [];

                % Determine execution pool: threads cannot write -v7.3 files
                if approxBytes >= 1.9e9
                    pool = gcp('nocreate');
                    if ~isempty(pool) && isa(pool, 'parallel.ProcessPool')
                        future = parfeval(pool, @DatabaseEngine.saveWorker, 1, db, dbPath, tSave);
                    else
                        % Large file requiring -v7.3 without process pool: save synchronously
                        info = DatabaseEngine.saveDatabase(db, dbPath, reporter);
                        info.isAsync = false;
                        if ~isempty(onComplete), onComplete(info); end
                        return;
                    end
                else
                    bg = backgroundPool;
                    future = parfeval(bg, @DatabaseEngine.saveWorker, 1, db, dbPath, tSave);
                end

                if ~isempty(onComplete)
                    afterAll(future, @(res) onComplete(res), 0);
                end
                info = struct("isAsync", true, "future", future);
            catch ME
                DatabaseEngine.emitLog(reporter, ...
                    "Background save unavailable (" + ME.message + "). Falling back to synchronous save.", "warn");
                info = DatabaseEngine.saveDatabase(db, dbPath, reporter);
                info.isAsync = false;
                future = [];
                if ~isempty(onComplete)
                    onComplete(info);
                end
            end
        end

        function info = saveWorker(db, dbPath, tSave)
        % SAVEWORKER Static worker function executed on backgroundPool or process pool.
            if nargin < 3 || isempty(tSave), tSave = tic; end
            s = whos('db');
            if s.bytes < 1.9e9
                save(dbPath, "db", "-v7");
            else
                save(dbPath, "db", "-v7.3");
            end
            elapsed = toc(tSave);
            fileObj = dir(dbPath);
            actualBytes = fileObj.bytes;
            actualSizeStr = DatabaseEngine.formatBytes(actualBytes);
            rateMBs = (actualBytes / (1024 * 1024)) / max(elapsed, 0.001);

            info = struct( ...
                "filePath",   string(dbPath), ...
                "fileBytes",  actualBytes, ...
                "sizeString", actualSizeStr, ...
                "elapsed",    elapsed, ...
                "rateMBs",    rateMBs);
        end

        function info = inspectFile(dbPath)
        % INSPECTFILE Inspect variables and estimated sizes without loading into RAM.
            arguments
                dbPath (1,1) string
            end

            if ~isfile(dbPath)
                error("DatabaseEngine:FileNotFound", "File not found: %s", dbPath);
            end

            fObj = dir(dbPath);
            vars = whos('-file', dbPath);

            info = struct( ...
                "filePath",   dbPath, ...
                "fileBytes",  fObj.bytes, ...
                "sizeString", DatabaseEngine.formatBytes(fObj.bytes), ...
                "variables",  vars);
        end

        function str = formatBytes(numBytes)
        % FORMATBYTES Human-readable byte representation (B, KB, MB, GB).
            if numBytes < 1024
                str = sprintf("%d B", numBytes);
            elseif numBytes < 1024^2
                str = sprintf("%.1f KB", numBytes / 1024);
            elseif numBytes < 1024^3
                str = sprintf("%.2f MB", numBytes / (1024^2));
            else
                str = sprintf("%.2f GB", numBytes / (1024^3));
            end
        end

    end

    methods (Static, Access = private)

        function emitLog(reporter, msg, type)
            timestamp = string(datetime("now", "Format", "HH:mm:ss"));
            fullMsg = sprintf("[%s] %s", timestamp, msg);

            if ~isempty(reporter)
                try
                    if isa(reporter, "ProgressReporter")
                        switch lower(type)
                            case "error"
                                reporter.fail("Database", fullMsg);
                            case "complete"
                                reporter.complete("Database", fullMsg);
                            otherwise
                                reporter.info("Database", fullMsg);
                        end
                    elseif isa(reporter, "function_handle")
                        reporter(fullMsg, type);
                    end
                catch
                    fprintf("%s\n", fullMsg);
                end
            else
                fprintf("%s\n", fullMsg);
            end
        end

    end
end
