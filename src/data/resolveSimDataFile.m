function rawFiles = resolveSimDataFile(target)
%resolveSimDataFile Resolve simulation data file path(s) from fig, session, or db.
%   rawFiles = resolveSimDataFile(target)
%
%   Accepts a figure handle, AssteroidSession, db struct, or UserData struct.
%   Delegates to resolveSimDataPath.
%
%   See also: resolveSimDataPath, resolveRiFile, resolvePretrainedModel

    db = extractDbFromTarget(target);
    rawFiles = resolveSimDataPath(db);
end

function db = extractDbFromTarget(target)
    if nargin < 1 || isempty(target)
        db = struct();
        return;
    end
    if isa(target, "matlab.ui.Figure") || isgraphics(target) || (isstruct(target) && isfield(target, "UserData"))
        if isfield(target.UserData, "session") && ~isempty(target.UserData.session) ...
                && isvalid(target.UserData.session) && ~isempty(target.UserData.session.db)
            db = target.UserData.session.db;
        elseif isfield(target.UserData, "db") && isstruct(target.UserData.db)
            db = target.UserData.db;
        else
            db = struct();
        end
    elseif isa(target, "AssteroidSession")
        db = target.db;
    elseif isstruct(target)
        if isfield(target, "db") && isstruct(target.db)
            db = target.db;
        else
            db = target;
        end
    else
        db = struct();
    end
end
