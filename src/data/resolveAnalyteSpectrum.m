function [analyteSpec, sourcePath] = resolveAnalyteSpectrum(target, options)
%resolveAnalyteSpectrum Resolve and load the active analyte Raman spectrum.
%
%   [analyteSpec, sourcePath] = resolveAnalyteSpectrum(target) resolves the
%   analyte spectrum using a unified priority order:
%     1. ExplicitFile (or db.Global.AnalyteSpectrumFile resolved from target),
%        supporting both file paths and "default:<preset>" tokens.
%     2. CachedSpectrum (or target.analyteSpectrum when target is an
%        AssteroidSession / visExport struct).
%     3. Built-in default preset ("CH4") when FallbackToDefault is true.
%
%   Built-in DefaultAnalyteSpectrum*.dat assets are loaded losslessly via
%   getDefaultAnalyteSpectrum; custom experimental files use
%   loadAndNormalizeAnalyteSpectrum.
%
%   See also: resolveAnalyteFile, getDefaultAnalyteSpectrum, loadAndNormalizeAnalyteSpectrum

    arguments
        target = []
        options.ExplicitFile (1,1) string = ""
        options.CachedSpectrum (1,1) struct = struct()
        options.FallbackToDefault (1,1) logical = true
        options.Reporter = []
    end

    analyteSpec = struct();
    sourcePath = "";

    fileCandidate = strtrim(options.ExplicitFile);
    if strlength(fileCandidate) == 0 && ~isempty(target)
        fileCandidate = strtrim(string(resolveAnalyteFile(target)));
    end

    % Expand built-in preset tokens (e.g. "default:NH3")
    if startsWith(lower(fileCandidate), "default:")
        try
            [resolvedPath, ~, ~] = resolveDefaultAnalyteSpectrumPath(fileCandidate, Strict=true);
            fileCandidate = resolvedPath;
        catch ME
            reportWarn(options.Reporter, ME.message);
            fileCandidate = "";
        end
    end

    if strlength(fileCandidate) > 0
        if isfile(fileCandidate)
            try
                analyteSpec = loadAndNormalizeAnalyteSpectrum(char(fileCandidate));
                if hasValidSpectrum(analyteSpec)
                    sourcePath = fileCandidate;
                    return;
                end
            catch ME
                reportWarn(options.Reporter, sprintf("Failed to load analyte spectrum '%s': %s", fileCandidate, ME.message));
            end
        else
            reportWarn(options.Reporter, sprintf("Configured analyte spectrum file not found: %s", fileCandidate));
        end
    end

    if hasValidSpectrum(options.CachedSpectrum)
        analyteSpec = options.CachedSpectrum;
        return;
    end

    if isa(target, "AssteroidSession") && hasValidSpectrum(target.analyteSpectrum)
        analyteSpec = target.analyteSpectrum;
        return;
    elseif (isa(target, "matlab.ui.Figure") || isgraphics(target)) ...
            && isstruct(target.UserData) && isfield(target.UserData, "visExport") ...
            && isstruct(target.UserData.visExport) && isfield(target.UserData.visExport, "analyteSpectrum") ...
            && hasValidSpectrum(target.UserData.visExport.analyteSpectrum)
        analyteSpec = target.UserData.visExport.analyteSpectrum;
        return;
    end

    if options.FallbackToDefault
        try
            analyteSpec = getDefaultAnalyteSpectrum("CH4");
            sourcePath = resolveDefaultAnalyteSpectrumPath("CH4", Strict=false);
        catch ME
            reportWarn(options.Reporter, sprintf("Default analyte spectrum unavailable: %s", ME.message));
        end
    end
end

function tf = hasValidSpectrum(spec)
    tf = isstruct(spec) && isfield(spec, "shift_cm") && ~isempty(spec.shift_cm) ...
        && isfield(spec, "intensity") && ~isempty(spec.intensity);
end

function reportWarn(rep, msg)
    if isempty(rep)
        return;
    end
    try
        if ismethod(rep, "warn")
            rep.warn("LoadAnalyte", msg);
        end
    catch
    end
end
