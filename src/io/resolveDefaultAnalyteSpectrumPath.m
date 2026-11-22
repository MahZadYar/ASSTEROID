function [datPath, canonicalKey, displayLabel, isBuiltIn] = resolveDefaultAnalyteSpectrumPath(presetOrPath, options)
%resolveDefaultAnalyteSpectrumPath Resolve built-in analyte preset or file path.
%
%   [datPath, canonicalKey, displayLabel, isBuiltIn] = ...
%       resolveDefaultAnalyteSpectrumPath(presetOrPath)
%   resolves a built-in gas-phase Raman analyte preset name, alias,
%   "default:<preset>" token, or built-in DefaultAnalyteSpectrum*.dat path
%   into its canonical file path inside src/io.
%
%   Built-in presets (100-4200 cm^-1, 785 nm scaled, 20 cm^-1 Gaussian FWHM):
%     "CH4"  - 12CH4  (Methane,   MeCaSDa/CaSDa24 296 K, peak 2917 cm^-1)
%     "C2H4" - 12C2H4 (Ethylene,  ECaSDa 296 K, peak 3021 cm^-1)
%     "NH3"  - NH3    (Ammonia,   NIST/CCCBDB 296 K, peak 3337 cm^-1)
%     "C2H2" - C2H2   (Acetylene, NIST/CCCBDB 296 K, peaks 1974, 3374 cm^-1)
%     "H2O"  - H2O    (Water,     NIST/CCCBDB 296 K, peak 3657 cm^-1)
%
%   Name-Value Arguments:
%     Strict (1,1) logical = true - Error when input is not a known built-in
%            preset or built-in file. When false, returns isBuiltIn = false
%            and empty strings for unrecognized or custom file paths.
%
%   See also: getDefaultAnalyteSpectrum, loadAndNormalizeAnalyteSpectrum, resolveAnalyteSpectrum

    arguments
        presetOrPath (1,1) string = "CH4"
        options.Strict (1,1) logical = true
    end

    datPath = "";
    canonicalKey = "";
    displayLabel = "";
    isBuiltIn = false;

    ioDir = string(fileparts(mfilename("fullpath")));
    catalog = builtInCatalog();

    rawInput = strtrim(string(presetOrPath));
    key = lower(rawInput);
    if startsWith(key, "default:")
        key = strtrim(extractAfter(key, strlength("default:")));
    end

    % 1. Match preset key or alias
    for k = 1:numel(catalog)
        if any(key == catalog(k).aliases)
            candidate = fullfile(ioDir, catalog(k).fileName);
            if ~isfile(candidate)
                error("resolveDefaultAnalyteSpectrumPath:MissingAsset", ...
                    "Built-in analyte spectrum file '%s' not found in %s.", ...
                    catalog(k).fileName, ioDir);
            end
            datPath = string(candidate);
            canonicalKey = catalog(k).key;
            displayLabel = catalog(k).label;
            isBuiltIn = true;
            return;
        end
    end

    % 2. Match explicit file path pointing to one of the built-in assets in src/io
    for k = 1:numel(catalog)
        builtInPath = fullfile(ioDir, catalog(k).fileName);
        if pathsReferToSameFile(rawInput, builtInPath)
            if ~isfile(builtInPath)
                error("resolveDefaultAnalyteSpectrumPath:MissingAsset", ...
                    "Built-in analyte spectrum file '%s' not found in %s.", ...
                    catalog(k).fileName, ioDir);
            end
            datPath = string(builtInPath);
            canonicalKey = catalog(k).key;
            displayLabel = catalog(k).label;
            isBuiltIn = true;
            return;
        end
    end

    if options.Strict
        validKeys = strjoin([catalog.key], ", ");
        error("resolveDefaultAnalyteSpectrumPath:UnknownPreset", ...
            "Unknown built-in analyte preset '%s'. Available presets: %s.", ...
            rawInput, validKeys);
    end
end

function catalog = builtInCatalog()
    catalog = [ ...
        struct("key", "CH4",  "fileName", "DefaultAnalyteSpectrum.dat", ...
               "label", "12CH4 (Methane)", ...
               "aliases", {{["ch4", "methane", "12ch4", "default", ""]}}), ...
        struct("key", "C2H4", "fileName", "DefaultAnalyteSpectrum_C2H4.dat", ...
               "label", "12C2H4 (Ethylene)", ...
               "aliases", {{["c2h4", "ethylene", "ethene", "12c2h4"]}}), ...
        struct("key", "NH3",  "fileName", "DefaultAnalyteSpectrum_NH3.dat", ...
               "label", "NH3 (Ammonia)", ...
               "aliases", {{["nh3", "ammonia"]}}), ...
        struct("key", "C2H2", "fileName", "DefaultAnalyteSpectrum_C2H2.dat", ...
               "label", "C2H2 (Acetylene)", ...
               "aliases", {{["c2h2", "acetylene", "ethyne"]}}), ...
        struct("key", "H2O",  "fileName", "DefaultAnalyteSpectrum_H2O.dat", ...
               "label", "H2O (Water)", ...
               "aliases", {{["h2o", "water", "water_vapor", "water vapor", "steam"]}}) ...
    ];
    for i = 1:numel(catalog)
        if iscell(catalog(i).aliases)
            catalog(i).aliases = catalog(i).aliases{1};
        end
    end
end

function tf = pathsReferToSameFile(pathA, pathB)
    tf = false;
    if strlength(pathA) == 0 || strlength(pathB) == 0
        return;
    end
    normA = normalizePathString(pathA);
    normB = normalizePathString(pathB);
    if ispc
        tf = strcmpi(normA, normB);
    else
        tf = strcmp(normA, normB);
    end
end

function out = normalizePathString(p)
    s = replace(strtrim(string(p)), "\", "/");
    if ~startsWith(s, "/") && ~startsWith(s, "//") && isempty(regexp(s, "^[A-Za-z]:/", "once"))
        s = replace(string(pwd), "\", "/") + "/" + s;
    end
    parts = split(s, "/");
    resolved = strings(0, 1);
    for idx = 1:numel(parts)
        seg = parts(idx);
        if seg == "" && idx == 1 && startsWith(s, "//")
            resolved(end+1) = ""; %#ok<AGROW>
        elseif seg == "" || seg == "."
            continue;
        elseif seg == ".."
            if ~isempty(resolved) && ~endsWith(resolved(end), ":")
                resolved(end) = [];
            end
        else
            resolved(end+1) = seg; %#ok<AGROW>
        end
    end
    out = strjoin(resolved, "/");
    if startsWith(s, "/") && ~startsWith(out, "/")
        out = "/" + out;
    end
end
