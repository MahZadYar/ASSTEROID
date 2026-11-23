function library = resolveAnalyteLibrary(target, options)
%resolveAnalyteLibrary Resolve and load built-in and custom analyte spectra.
%
%   library = resolveAnalyteLibrary(target) returns a 1xK struct array of
%   resolved analyte entries from the built-in catalog and any custom entries
%   registered on target (db, AssteroidSession, or app figure).
%
%   Each struct entry contains:
%       key          - Canonical field-safe suffix (e.g. "CH4", "H2S", "Custom1")
%       variant      - Canonical variant token (identical to key, e.g. "H2S")
%       label        - Display label (e.g. "H2S (Hydrogen Sulfide)")
%       filePath     - Resolved source file path (string)
%       isBuiltIn    - Logical true for bundled presets in src/io/
%       isActive     - Logical true when matching db.Global.AnalyteSpectrumFile
%       peakShift_cm - Dominant Raman shift (cm^-1) of normalized spectrum
%       spectrum     - Struct with fields .shift_cm and .intensity
%
%   Name-Value Options:
%       Keys              (1,:) string  = string.empty  % Filter by keys ("H2S"), "all", "selected", or "active"
%       IncludeBuiltIn    (1,1) logical = true
%       IncludeCustom     (1,1) logical = true
%       FallbackToDefault (1,1) logical = true
%       ExplicitFile      (1,1) string  = ""
%       CachedSpectrum    (1,1) struct  = struct()
%       Reporter                        = []
%
%   See also: getBuiltInAnalyteCatalog, resolveAnalyteSpectrum, parseMetricVariantName

    arguments
        target = []
        options.Keys (1,:) string = string.empty
        options.IncludeBuiltIn (1,1) logical = true
        options.IncludeCustom (1,1) logical = true
        options.FallbackToDefault (1,1) logical = true
        options.ExplicitFile (1,1) string = ""
        options.CachedSpectrum (1,1) struct = struct()
        options.Reporter = []
    end

    db = extractDbStruct(target);
    activeFile = strtrim(options.ExplicitFile);
    if strlength(activeFile) == 0 && ~isempty(target)
        try
            activeFile = strtrim(string(resolveAnalyteFile(target)));
        catch
            activeFile = "";
        end
    end
    activeBuiltInKey = "";
    if strlength(activeFile) > 0
        [resolvedBuiltIn, bKey, ~, isBI] = resolveDefaultAnalyteSpectrumPath(activeFile, Strict=false);
        if isBI
            activeBuiltInKey = bKey;
            activeFile = resolvedBuiltIn;
        end
    end

    % Build full candidate metadata list (spectrum loaded lazily for matching keys)
    allEntries = emptyEntryTemplate();
    seenKeys = strings(1, 0);

    if options.IncludeBuiltIn
        cat = getBuiltInAnalyteCatalog();
        for k = 1:numel(cat)
            e = emptyEntryStruct();
            e.key       = cat(k).key;
            e.variant   = cat(k).key;
            e.label     = cat(k).label;
            e.filePath  = cat(k).filePath;
            e.isBuiltIn = true;
            e.isActive  = (activeBuiltInKey == cat(k).key) || ...
                          (strlength(activeBuiltInKey) == 0 && cat(k).key == "CH4" && strlength(activeFile) == 0);
            allEntries(end+1) = e; %#ok<AGROW>
            seenKeys(end+1) = lower(e.key); %#ok<AGROW>
        end
    end

    if options.IncludeCustom
        % Custom entries explicitly registered in db.Global.AnalyteLibrary
        if isstruct(db) && isfield(db, "Global") && isstruct(db.Global) ...
                && isfield(db.Global, "AnalyteLibrary") && isstruct(db.Global.AnalyteLibrary)
            libRaw = db.Global.AnalyteLibrary;
            for k = 1:numel(libRaw)
                rawItem = libRaw(k);
                fp = "";
                if isfield(rawItem, "filePath"), fp = strtrim(string(rawItem.filePath)); end
                kRaw = "";
                if isfield(rawItem, "key"), kRaw = strtrim(string(rawItem.key)); end
                if strlength(kRaw) == 0, kRaw = fp; end
                kClean = sanitizeAnalyteKey(kRaw);
                if any(lower(kClean) == seenKeys)
                    continue;
                end
                lbl = kClean;
                if isfield(rawItem, "label") && strlength(strtrim(string(rawItem.label))) > 0
                    lbl = strtrim(string(rawItem.label));
                end
                e = emptyEntryStruct();
                e.key       = kClean;
                e.variant   = kClean;
                e.label     = lbl;
                e.filePath  = fp;
                e.isBuiltIn = false;
                e.isActive  = (strlength(activeFile) > 0 && samePathCheck(fp, activeFile));
                if isfield(rawItem, "spectrum") && hasValidSpectrum(rawItem.spectrum)
                    e.spectrum = rawItem.spectrum;
                end
                allEntries(end+1) = e; %#ok<AGROW>
                seenKeys(end+1) = lower(kClean); %#ok<AGROW>
            end
        end

        % Active custom AnalyteSpectrumFile not in built-in catalog / AnalyteLibrary
        if strlength(activeFile) > 0 && strlength(activeBuiltInKey) == 0
            kCustom = sanitizeAnalyteKey(activeFile);
            idxExisting = find(lower(seenKeys) == lower(kCustom), 1);
            if isempty(idxExisting)
                e = emptyEntryStruct();
                e.key       = kCustom;
                e.variant   = kCustom;
                e.label     = kCustom + " (Custom)";
                e.filePath  = activeFile;
                e.isBuiltIn = false;
                e.isActive  = true;
                if hasValidSpectrum(options.CachedSpectrum)
                    e.spectrum = options.CachedSpectrum;
                end
                allEntries(end+1) = e; %#ok<AGROW>
                seenKeys(end+1) = lower(kCustom); %#ok<AGROW>
            else
                allEntries(idxExisting).isActive = true;
            end
        end
    end

    % Register all discovered keys so parseMetricVariantName recognizes custom names cleanly
    try
        knownAnalyteKeysRegistry("add", [allEntries.key]);
    catch
    end

    % Filter requested keys
    reqKeys = strtrim(string(options.Keys(:)));
    reqKeys = reqKeys(strlength(reqKeys) > 0);
    if numel(reqKeys) == 1 && (lower(reqKeys(1)) == "selected" || lower(reqKeys(1)) == "working")
        if isstruct(db) && isfield(db, "Global") && isstruct(db.Global) && isfield(db.Global, "SelectedAnalytes")
            reqKeys = strtrim(string(db.Global.SelectedAnalytes(:)'));
            reqKeys = reqKeys(strlength(reqKeys) > 0);
            if isempty(reqKeys)
                library = emptyEntryTemplate();
                return;
            end
        else
            reqKeys = string.empty;
        end
    end
    selectAll = isempty(reqKeys) || any(lower(reqKeys) == "all");

    if selectAll
        selected = allEntries;
    else
        selected = emptyEntryTemplate();
        selectedKeySet = strings(1, 0);
        for i = 1:numel(reqKeys)
            rk = reqKeys(i);
            rkl = lower(rk);
            if rkl == "active" || rkl == "analyte" || rkl == "weighted"
                % Resolve active analyte
                [specAct, srcAct] = resolveAnalyteSpectrum(target, ...
                    ExplicitFile=options.ExplicitFile, ...
                    CachedSpectrum=options.CachedSpectrum, ...
                    FallbackToDefault=options.FallbackToDefault, ...
                    Reporter=options.Reporter);
                if ~hasValidSpectrum(specAct)
                    continue;
                end
                [~, bKey, bLbl, isBI] = resolveDefaultAnalyteSpectrumPath(srcAct, Strict=false);
                if isBI
                    keyOut = bKey;
                    lblOut = bLbl;
                else
                    keyOut = sanitizeAnalyteKey(srcAct);
                    lblOut = keyOut + " (Custom)";
                end
                if ~any(lower(keyOut) == selectedKeySet)
                    e = emptyEntryStruct();
                    e.key       = keyOut;
                    e.variant   = keyOut;
                    e.label     = lblOut;
                    e.filePath  = srcAct;
                    e.isBuiltIn = isBI;
                    e.isActive  = true;
                    e.spectrum  = specAct;
                    selected(end+1) = e; %#ok<AGROW>
                    selectedKeySet(end+1) = lower(keyOut); %#ok<AGROW>
                end
                continue;
            end

            % Strip analyte_/weighted_ prefix or parse field name
            parsed = parseMetricVariantName(rk);
            if strlength(parsed.analyteKey) > 0
                lookupKey = parsed.analyteKey;
            else
                lookupKey = rk;
            end

            matchIdx = find(lower([allEntries.key]) == lower(lookupKey), 1);
            if isempty(matchIdx)
                % Try built-in alias / default: lookup
                [~, bKey, ~, isBI] = resolveDefaultAnalyteSpectrumPath(lookupKey, Strict=false);
                if isBI
                    matchIdx = find(lower([allEntries.key]) == lower(bKey), 1);
                end
            end
            if isempty(matchIdx) && isfile(lookupKey)
                % Direct custom path supplied in Keys
                kFile = sanitizeAnalyteKey(lookupKey);
                if ~any(lower(kFile) == selectedKeySet)
                    e = emptyEntryStruct();
                    e.key       = kFile;
                    e.variant   = kFile;
                    e.label     = kFile + " (Custom)";
                    e.filePath  = lookupKey;
                    e.isBuiltIn = false;
                    selected(end+1) = e; %#ok<AGROW>
                    selectedKeySet(end+1) = lower(kFile); %#ok<AGROW>
                end
                continue;
            end

            if ~isempty(matchIdx)
                cand = allEntries(matchIdx);
                if ~any(lower(cand.key) == selectedKeySet)
                    selected(end+1) = cand; %#ok<AGROW>
                    selectedKeySet(end+1) = lower(cand.key); %#ok<AGROW>
                end
            end
        end
    end

    % Load spectra and compute peakShift_cm for selected entries
    library = emptyEntryTemplate();
    for i = 1:numel(selected)
        e = selected(i);
        if ~hasValidSpectrum(e.spectrum)
            e.spectrum = loadEntrySpectrum(e, options.Reporter);
        end
        if ~hasValidSpectrum(e.spectrum)
            continue;
        end
        [~, pkIdx] = max(e.spectrum.intensity);
        if ~isempty(pkIdx) && isfinite(e.spectrum.shift_cm(pkIdx))
            e.peakShift_cm = double(e.spectrum.shift_cm(pkIdx));
        end
        library(end+1) = e; %#ok<AGROW>
    end

    if isempty(library) && options.FallbackToDefault
        try
            cat = getBuiltInAnalyteCatalog();
            ch4 = cat(1);
            spec = getDefaultAnalyteSpectrum("CH4");
            [~, pkIdx] = max(spec.intensity);
            e = emptyEntryStruct();
            e.key          = ch4.key;
            e.variant      = ch4.key;
            e.label        = ch4.label;
            e.filePath     = ch4.filePath;
            e.isBuiltIn    = true;
            e.isActive     = true;
            e.peakShift_cm = double(spec.shift_cm(pkIdx));
            e.spectrum     = spec;
            library        = e;
        catch ME
            reportWarn(options.Reporter, sprintf("Default analyte library unavailable: %s", ME.message));
        end
    end
end

function spec = loadEntrySpectrum(entry, reporter)
    persistent builtInCache
    if isempty(builtInCache)
        builtInCache = struct();
    end

    spec = struct();
    if entry.isBuiltIn
        cacheField = char(entry.key);
        if isfield(builtInCache, cacheField) && hasValidSpectrum(builtInCache.(cacheField))
            spec = builtInCache.(cacheField);
            return;
        end
        try
            spec = getDefaultAnalyteSpectrum(entry.key);
            if hasValidSpectrum(spec)
                builtInCache.(cacheField) = spec;
                return;
            end
        catch ME
            reportWarn(reporter, sprintf("Failed to load built-in analyte '%s': %s", entry.key, ME.message));
        end
    end

    if strlength(entry.filePath) > 0 && isfile(entry.filePath)
        try
            spec = loadAndNormalizeAnalyteSpectrum(char(entry.filePath));
        catch ME
            reportWarn(reporter, sprintf("Failed to load custom analyte '%s': %s", entry.filePath, ME.message));
        end
    end
end

function e = emptyEntryStruct()
    e = struct( ...
        "key",          "", ...
        "variant",      "", ...
        "label",        "", ...
        "filePath",     "", ...
        "isBuiltIn",    false, ...
        "isActive",     false, ...
        "peakShift_cm", NaN, ...
        "spectrum",     struct());
end

function arr = emptyEntryTemplate()
    arr = repmat(emptyEntryStruct(), 1, 0);
end

function db = extractDbStruct(target)
    db = struct();
    if nargin < 1 || isempty(target)
        return;
    end
    if isa(target, "matlab.ui.Figure") || isgraphics(target) || (isstruct(target) && isfield(target, "UserData"))
        if isfield(target.UserData, "session") && ~isempty(target.UserData.session) ...
                && isvalid(target.UserData.session) && isstruct(target.UserData.session.db)
            db = target.UserData.session.db;
        elseif isfield(target.UserData, "db") && isstruct(target.UserData.db)
            db = target.UserData.db;
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

function tf = hasValidSpectrum(spec)
    tf = isstruct(spec) && isfield(spec, "shift_cm") && ~isempty(spec.shift_cm) ...
        && isfield(spec, "intensity") && ~isempty(spec.intensity);
end

function tf = samePathCheck(a, b)
    if strlength(a) == 0 || strlength(b) == 0
        tf = false;
        return;
    end
    na = replace(strtrim(string(a)), "\", "/");
    nb = replace(strtrim(string(b)), "\", "/");
    if ispc
        tf = strcmpi(na, nb);
    else
        tf = strcmp(na, nb);
    end
end

function reportWarn(rep, msg)
    if isempty(rep), return; end
    try
        if ismethod(rep, "warn")
            rep.warn("LoadAnalyteLibrary", msg);
        end
    catch
    end
end
