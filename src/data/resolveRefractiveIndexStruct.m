function ri = resolveRefractiveIndexStruct(target, riCsvFile)
%resolveRefractiveIndexStruct Robustly resolve a valid RI struct with nFunc/kFunc.
%   ri = resolveRefractiveIndexStruct(target, riCsvFile)
%
%   target can be a figure handle, AssteroidSession, or db struct.
%
%   Resolution priority:
%     1. target.UserData.visExport.ri (if figure with valid functions)
%     2. db.RI (rebuilding interpolants from lambda/n/k vectors if present)
%     3. Explicit riCsvFile argument
%     4. Refractive index file resolved from db.Global.RefractiveIndexFile
%     5. Built-in default gold refractive index

    if nargin < 2
        riCsvFile = "";
    end

    isValidRi = @(r) isstruct(r) && isfield(r, "nFunc") && isa(r.nFunc, "function_handle") ...
        && isfield(r, "kFunc") && isa(r.kFunc, "function_handle");

    % Extract fig and db
    fig = [];
    db = struct();
    if nargin >= 1 && ~isempty(target)
        if isa(target, "matlab.ui.Figure") || isgraphics(target) || (isstruct(target) && isfield(target, "UserData"))
            fig = target;
            if isfield(fig.UserData, "session") && ~isempty(fig.UserData.session) ...
                    && isvalid(fig.UserData.session) && ~isempty(fig.UserData.session.db)
                db = fig.UserData.session.db;
            elseif isfield(fig.UserData, "db") && isstruct(fig.UserData.db)
                db = fig.UserData.db;
            end
        elseif isa(target, "AssteroidSession")
            db = target.db;
        elseif isstruct(target)
            if isfield(target, "db") && isstruct(target.db)
                db = target.db;
            else
                db = target;
            end
        end
    end

    % 1. Check existing visExport.ri if fig is available
    if ~isempty(fig) && isstruct(fig.UserData) && isfield(fig.UserData, "visExport") ...
            && isstruct(fig.UserData.visExport) && isfield(fig.UserData.visExport, "ri") ...
            && ~isempty(fig.UserData.visExport.ri)
        rCand = fig.UserData.visExport.ri;
        if isValidRi(rCand)
            ri = rCand;
            return;
        end
    end

    % 2. Check db.RI
    if isstruct(db) && isfield(db, "RI") && isstruct(db.RI)
        dbRi = db.RI;
        % Prefer fresh interpolants from raw vectors over stale deserialized handles
        if isfield(dbRi, "lambda") && isfield(dbRi, "n") && isfield(dbRi, "k") && ~isempty(dbRi.lambda)
            try
                Fn = griddedInterpolant(double(dbRi.lambda(:)), double(dbRi.n(:)), 'linear', 'nearest');
                Fk = griddedInterpolant(double(dbRi.lambda(:)), double(dbRi.k(:)), 'linear', 'nearest');
                ri = dbRi;
                ri.nFunc = @(lq) Fn(double(lq));
                ri.kFunc = @(lq) Fk(double(lq));
                if ~isempty(fig) && isstruct(fig.UserData) && isfield(fig.UserData, "db")
                    fig.UserData.db.RI = ri;
                end
                return;
            catch
                % continue
            end
        elseif isValidRi(dbRi)
            try
                testVal = dbRi.nFunc(0.785);
                if isfinite(testVal)
                    ri = dbRi;
                    return;
                end
            catch
                % Stale serialized handle, fall through
            end
        elseif isfield(dbRi, "SourceFile") && strlength(string(dbRi.SourceFile)) > 0 && isfile(string(dbRi.SourceFile))
            [~, ~, ext] = fileparts(string(dbRi.SourceFile));
            if strcmpi(ext, ".csv")
                try
                    ri = load_gold_refractive_index(string(dbRi.SourceFile));
                    if isValidRi(ri)
                        ri.SourceFile = string(dbRi.SourceFile);
                        if ~isempty(fig) && isstruct(fig.UserData) && isfield(fig.UserData, "db")
                            fig.UserData.db.RI = ri;
                        end
                        return;
                    end
                catch
                    % continue
                end
            end
        end
    end

    % 3. Check explicit riCsvFile path
    if strlength(string(riCsvFile)) > 0 && isfile(string(riCsvFile))
        [~, ~, ext] = fileparts(string(riCsvFile));
        if strcmpi(ext, ".csv")
            try
                ri = load_gold_refractive_index(string(riCsvFile));
                if isValidRi(ri)
                    return;
                end
            catch
                % continue
            end
        end
    end

    % 4. Check resolveRiPath(db)
    riFile = resolveRiPath(db);
    if strlength(riFile) > 0 && isfile(riFile)
        [~, ~, ext] = fileparts(riFile);
        if strcmpi(ext, ".csv")
            try
                ri = load_gold_refractive_index(riFile);
                if isValidRi(ri)
                    return;
                end
            catch
                % continue
            end
        end
    end

    % 5. Built-in default gold RI fallback
    try
        ri = getDefaultRefractiveIndex(WavelengthUnit="um");
    catch
        ri = struct();
    end
end
