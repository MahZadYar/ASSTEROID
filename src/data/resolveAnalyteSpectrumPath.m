function analyteFile = resolveAnalyteSpectrumPath(db)
%resolveAnalyteSpectrumPath Return analyte spectrum file path or empty string.
%
%   analyteFile = resolveAnalyteSpectrumPath(db)
%
%   Input:
%       db - Unified database struct.
%
%   Output:
%       analyteFile - String path to analyte spectrum file, or "".

    arguments
        db struct
    end

    analyteFile = "";
    if isfield(db, "Global") && isfield(db.Global, "AnalyteSpectrumFile") ...
            && strlength(string(db.Global.AnalyteSpectrumFile)) > 0
        analyteFile = string(db.Global.AnalyteSpectrumFile);
    end
end
