function riFile = resolveRiPath(db)
%resolveRiPath Return RI CSV file path or empty string for auto-detect.
%
%   riFile = resolveRiPath(db)
%
%   Input:
%       db - Unified database struct.
%
%   Output:
%       riFile - String path to RI source file, or "" for pipeline auto-detect.

    arguments
        db struct
    end

    riFile = "";
    if isfield(db, "RI") && isstruct(db.RI) && isfield(db.RI, "SourceFile") ...
            && strlength(string(db.RI.SourceFile)) > 0 && isfile(string(db.RI.SourceFile))
        riFile = string(db.RI.SourceFile);
    end
end
