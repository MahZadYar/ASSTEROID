function key = sanitizeAnalyteKey(rawInput)
%sanitizeAnalyteKey Convert an analyte name, label, or file path into a field-safe key.
%
%   key = sanitizeAnalyteKey(rawInput) returns a canonical identifier suitable
%   for direct appending in SoA struct field names (e.g. "EE_V_<key>" such
%   as "EE_V_CH4", "EE_V_H2S", or "EE_V_CO_probe").
%
%   Built-in presets and paths map to their canonical key ("CH4", "C2H4",
%   "H2S", "NH3", "C2H2", "H2O", "SF6", "SO2", "CO2"); custom paths use their cleaned filename stem.
%
%   See also: getBuiltInAnalyteCatalog, parseMetricVariantName, resolveAnalyteLibrary

    arguments
        rawInput (1,1) string
    end

    s = strtrim(rawInput);
    if strlength(s) == 0
        key = "Custom";
        return;
    end

    % Resolve built-in presets/paths directly to canonical key
    [~, builtInKey, ~, isBuiltIn] = resolveDefaultAnalyteSpectrumPath(s, Strict=false);
    if isBuiltIn && strlength(builtInKey) > 0
        key = builtInKey;
        return;
    end

    % Extract filename stem when given a path or extension
    if contains(s, "/") || contains(s, "\") || ~isempty(regexp(s, "\.[A-Za-z0-9]{1,5}$", "once"))
        [~, stem, ~] = fileparts(char(s));
        s = string(stem);
    end

    % Strip leading "analyte_" or "weighted_" prefix if supplied
    ls = lower(s);
    if startsWith(ls, "analyte_") && strlength(s) > 8
        s = extractAfter(s, 8);
    elseif startsWith(ls, "weighted_") && strlength(s) > 9
        s = extractAfter(s, 9);
    end

    % Collapse non-alphanumeric runs to underscores and trim leading/trailing underscores
    s = regexprep(s, "[^A-Za-z0-9]+", "_");
    s = regexprep(s, "^_+|_+$", "");
    if strlength(s) == 0
        s = "Custom";
    end

    if ~isempty(regexp(s, "^[0-9]", "once"))
        s = "A_" + s;
    end

    % Guard against collisions with metric modifiers or bare metric suffixes
    reservedTokens = [ ...
        "laser", "broad", "broadband", "avg", "analyte", "weighted", "approx", ...
        "m", "max", "min", "um", "nm", "cm", "vol", "surf", "abs", "raw", ...
        "norm", "corr", "grid", "std", "mean", "median", "rmse", "mae", "r2", ...
        "spectral", "all", "active", "selected", "working"];
    if any(strcmpi(s, reservedTokens))
        s = "Analyte_" + s;
    end

    % Bound length so <base>_<key> stays well under MATLAB's 63-char limit
    if strlength(s) > 36
        s = extractBefore(s, 37);
        s = regexprep(s, "_+$", "");
    end

    key = s;
    try
        knownAnalyteKeysRegistry("add", key);
    catch
    end
end
