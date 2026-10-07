function results = runImportSweepWorkflow(cfg, reporter)
%runImportSweepWorkflow Orchestrate sweep import and DB construction.
%
%   results = runImportSweepWorkflow(cfg) executes the full import pipeline:
%   read sweep table → auto-detect or apply column schema → group by input
%   parameters → compute spectral metrics → merge/rebuild SoA database → save .mat.
%
%   results = runImportSweepWorkflow(cfg, reporter) reports progress
%   through a ProgressReporter instance (console, silent, or callback).
%
%   The workflow is fully schema-driven: column names, input parameters,
%   spectral variables, and output metrics are all defined by the column
%   schema (cfg.columnSchema). When no schema is provided, heuristics
%   auto-detect roles from column names.
%
%   Inputs:
%       cfg      – struct from importSweepConfig.
%       reporter – (optional) ProgressReporter. Defaults to silent.
%
%   Outputs:
%       results  – struct with fields:
%           .allData          – Final SoA struct
%           .summary          – struct with import statistics
%           .cfg              – config snapshot
%           .schema           – resolved column schema
%           .elapsedTotal     – wall-clock seconds
%
%   See also: importSweepConfig, readSweepTable, ProgressReporter

arguments
    cfg      (1,1) struct
    reporter       = ProgressReporter.silent()
end

    totalTimer = tic;
    c = 299792458; % speed of light (m/s)

    %% 0. Working directory
    if cfg.workDir ~= "" && cfg.workDir ~= string(pwd)
        cd(cfg.workDir);
    end
    reporter.info(sprintf("=== Sweep Import (mode: %s) ===", cfg.mode));

    %% 1. Resolve input file
    reporter.start("ResolveInput", "Locating sweep data file...");
    inputPath = resolveInputFile(cfg);
    reporter.complete("ResolveInput", sprintf("Input: %s", inputPath));

    %% 2. Load analyte Raman spectrum
    analyteSpectrum = struct();
    reporter.start("LoadAnalyte", "Resolving analyte Raman spectrum...");
    if cfg.analyteSpectrumFile ~= "" && isfile(cfg.analyteSpectrumFile)
        try
            analyteSpectrum = loadAndNormalizeAnalyteSpectrum(cfg.analyteSpectrumFile);
            if isfield(analyteSpectrum, "shift_cm")
                reporter.complete("LoadAnalyte", sprintf("Loaded from file: %s", cfg.analyteSpectrumFile));
            else
                analyteSpectrum = struct();
            end
        catch
            analyteSpectrum = struct();
        end
    elseif cfg.analyteSpectrumFile ~= "" && ~isfile(cfg.analyteSpectrumFile)
        reporter.warn("LoadAnalyte", sprintf("Configured analyte file not found: %s", cfg.analyteSpectrumFile));
    end

    if ~isfield(analyteSpectrum, "shift_cm")
        analyteSpectrum = getDefaultAnalyteSpectrum();
        reporter.complete("LoadAnalyte", "Using codebase default analyte spectrum.");
    end

    %% 3. Load existing database (merge mode)
    allDataStruct = struct();
    if cfg.mode == "merge" && isfile(cfg.outputFile)
        reporter.start("LoadExisting", "Loading existing database...");
        try
            S = load(cfg.outputFile, "allData");
            if isfield(S, "allData") && isstruct(S.allData)
                allDataStruct = normalizeGeometryFields(S.allData);
                nExisting = structRowCount(allDataStruct);
                reporter.complete("LoadExisting", sprintf("Loaded %d existing entries.", nExisting));
            else
                reporter.warn("LoadExisting", "No valid allData in file; starting fresh.");
            end
        catch ME
            reporter.warn("LoadExisting", "Load failed: " + ME.message + ". Starting fresh.");
        end
    elseif cfg.mode == "rebuild"
        reporter.info("Rebuild mode — ignoring any existing database.");
    end

    %% 4. Read sweep table
    reporter.start("ReadSweep", sprintf("Reading %s...", inputPath));
    T = readSweepTable(inputPath);
    T.Properties.VariableNames = sanitizeVarNames(T.Properties.VariableNames);
    
    % Apply user renaming from schema if provided
    if ~isempty(cfg.columnSchema) && isstruct(cfg.columnSchema)
        for k = 1:numel(cfg.columnSchema)
            if isfield(cfg.columnSchema(k), 'originalName') && ...
               strlength(cfg.columnSchema(k).originalName) > 0 && ...
               strlength(cfg.columnSchema(k).name) > 0
                
                origName = cfg.columnSchema(k).originalName;
                newName = cfg.columnSchema(k).name;
                
                if ~strcmp(origName, newName)
                    idx = find(strcmp(T.Properties.VariableNames, origName), 1);
                    if ~isempty(idx)
                        T.Properties.VariableNames{idx} = newName;
                    end
                end
            end
        end
    end
    reporter.complete("ReadSweep", sprintf("Read %d rows, %d columns.", height(T), width(T)));

    %% 5. Resolve column schema
    reporter.start("ResolveSchema", "Resolving column schema...");
    schema = resolveColumnSchema(cfg, T);
    inputNames   = schemaFieldsByRole(schema, "input");
    spectralName = schemaFieldsByRole(schema, "spectral");
    metricNames  = schemaFieldsByRole(schema, "metric");

    if isempty(inputNames)
        error("runImportSweepWorkflow:NoInputParams", ...
            "No input parameters defined in column schema.");
    end
    if isempty(spectralName)
        reporter.warn("ResolveSchema", "No spectral variable defined — metric variants will use single-point mode.");
    else
        spectralName = spectralName{1}; % use first spectral column
    end

    reporter.complete("ResolveSchema", sprintf( ...
        "Inputs: {%s}, Spectral: %s, Metrics: {%s}", ...
        strjoin(inputNames, ", "), ...
        string(ternary(isempty(spectralName), "(none)", spectralName)), ...
        strjoin(metricNames, ", ")));

    %% 6. Extract columns dynamically
    reporter.start("ExtractColumns", "Extracting columns...");
    cols = struct();
    allColNames = T.Properties.VariableNames;
    for k = 1:numel(allColNames)
        cn = allColNames{k};
        cols.(cn) = T{:, cn};
    end
    reporter.complete("ExtractColumns", sprintf("Extracted %d columns.", numel(allColNames)));

    %% 7. Group by input parameters and process
    % Build key matrix from input columns
    nInputs = numel(inputNames);
    keyMatrix = zeros(height(T), nInputs);
    for k = 1:nInputs
        keyMatrix(:, k) = cols.(inputNames{k});
    end
    [keyPairs, ~, G] = unique(keyMatrix, "rows", "stable");
    numGroups = size(keyPairs, 1);

    reporter.start("ProcessGroups", sprintf("Processing %d geometry groups...", numGroups));

    entriesWritten = 0;
    replacedDuplicates = 0;
    skippedExisting = 0;
    fewPointsGroups = 0;

    for g = 1:numGroups
        idx = (G == g);

        if nnz(idx) < 2
            fewPointsGroups = fewPointsGroups + 1;
        end

        % Report progress every 5%
        if mod(g, max(1, round(numGroups / 20))) == 0 || g == numGroups
            keyParts = cell(1, nInputs);
            for ki = 1:nInputs
                keyParts{ki} = char(sprintf('%s=%.4g', inputNames{ki}, keyPairs(g, ki)));
            end
            keyStr = strjoin(keyParts, ', ');
            reporter.progress("ProcessGroups", g / numGroups, ...
                sprintf("Group %d/%d (%s)", g, numGroups, keyStr));
        end

        entry = processGeometryGroup(idx, cols, keyPairs(g, :), ...
            inputNames, spectralName, metricNames, cfg, analyteSpectrum, c);
        if isempty(entry)
            continue
        end

        % Check for existing entries (generalized for N input params)
        existingIdx = findExistingRowsGeneric(allDataStruct, inputNames, keyPairs(g, :));

        if ~isempty(existingIdx)
            if isfield(cfg, "replaceExisting") && cfg.replaceExisting
                % Overwrite / replace existing entries with newly imported entry
                allDataStruct = removeRowsFromStruct(allDataStruct, existingIdx);
                replacedDuplicates = replacedDuplicates + numel(existingIdx);
            elseif isfield(cfg, "recalculateExisting") && cfg.recalculateExisting
                % Legacy merge with existing
                if ~isempty(spectralName)
                    oldEntry = extractEntryStruct(allDataStruct, existingIdx(1));
                    interpSamples = max(2, round((cfg.ramanWindow(2) - cfg.ramanWindow(1)) / cfg.interpResolution));
                    entry = mergeEntryWithNewWavelengths(oldEntry, entry, cfg.ramanWindow, interpSamples);
                end
                allDataStruct = removeRowsFromStruct(allDataStruct, existingIdx);
                replacedDuplicates = replacedDuplicates + numel(existingIdx);
            else
                % Default: skip existing entries when parameters match
                skippedExisting = skippedExisting + numel(existingIdx);
                continue;
            end
        end

        allDataStruct = append_entry_struct(allDataStruct, entry);
        entriesWritten = entriesWritten + 1;
    end

    reporter.complete("ProcessGroups", sprintf( ...
        "Processed %d groups: %d written, %d replaced, %d skipped.", ...
        numGroups, entriesWritten, replacedDuplicates, skippedExisting));

    if fewPointsGroups > 0
        reporter.warn("ProcessGroups", sprintf("%d groups had <2 spectral points; proceeded with limited data.", fewPointsGroups));
    end

    %% 8. Save output (legacy SoA format)
    reporter.start("Save", "Saving database...");
    totalEntries = structRowCount(allDataStruct);
    if entriesWritten > 0 || replacedDuplicates > 0
        allData = allDataStruct; %#ok<NASGU>
        w = whos("allData");
        if w.bytes > 2e9
            save(cfg.outputFile, "allData", "-v7.3");
        else
            save(cfg.outputFile, "allData");
        end
        reporter.complete("Save", sprintf("Saved %d entries to %s", totalEntries, cfg.outputFile));
    else
        reporter.complete("Save", "No changes; dataset already up to date.");
    end

    %% 9. Pack into unified database
    reporter.start("PackDB", "Packing into unified database (in-memory only)...");
    dbFile = cfg.databaseFile;
    db = createDatabaseStruct();
    if isfile(dbFile)
        try
            loaded = load(dbFile, "db");
            if isfield(loaded, "db") && isstruct(loaded.db)
                db = loaded.db;
            else
                reporter.warn("PackDB", "database.mat exists but contains no valid 'db'; using fresh in-memory DB.");
            end
        catch ME
            reporter.warn("PackDB", "Could not load existing database.mat: " + ME.message + ". Using fresh in-memory DB.");
        end
    end

    db.Sim = populateBranch(allDataStruct, "Simulation.FEM.COMSOL", ...
        "LaserWl", cfg.laserWavelength, ...
        "StokesWindow", cfg.ramanWindow);

    % Store the column schema in the database
    db.Schema = schema;

    % Populate RI branch if not already present
    if isempty(fieldnames(db.RI))
        try
            riData = load_gold_refractive_index();
            db.RI.Source   = "McPeak et al. 2015";
            db.RI.Material = "Au";
            db.RI.lambda   = riData.lambda_nm(:)';
            db.RI.n        = riData.n(:)';
            db.RI.k        = riData.k(:)';
        catch
            reporter.warn("PackDB", "Could not load gold RI for db.RI.");
        end
    end

    reporter.complete("PackDB", sprintf("Prepared db.Sim (%d entries) in memory (not auto-saved).", totalEntries));

    %% Assemble results
    allData = allDataStruct;
    summary = struct();
    summary.totalEntries      = totalEntries;
    summary.numEntries        = totalEntries;
    summary.newEntries        = max(entriesWritten - replacedDuplicates, 0);
    summary.replacedDuplicates = replacedDuplicates;
    summary.skippedExisting   = skippedExisting;
    summary.numGroups         = numGroups;
    summary.inputFile         = inputPath;
    summary.outputFile        = cfg.outputFile;
    summary.databaseFile      = dbFile;

    results = struct();
    results.allData      = allData;
    results.db           = db;
    results.summary      = summary;
    results.cfg          = cfg;
    results.schema       = schema;
    results.elapsedTotal = toc(totalTimer);

    reporter.info(sprintf("Import complete in %.1f s. Total entries: %d", ...
        results.elapsedTotal, totalEntries));
end

%% ========================================================================
%  LOCAL HELPERS
%  ========================================================================

function inputPath = resolveInputFile(cfg)
    %resolveInputFile Find the sweep data file.
    candidates = {
        string(cfg.inputFile)
        fullfile(cfg.workDir, cfg.inputFile)
    };
    inputPath = "";
    for k = 1:numel(candidates)
        if isfile(candidates{k})
            inputPath = candidates{k};
            return
        end
    end
    if inputPath == ""
        error("runImportSweepWorkflow:FileNotFound", ...
            "Sweep data file not found. Tried:\n  %s", strjoin(string(candidates), "\n  "));
    end
end

function schema = resolveColumnSchema(cfg, T)
    %resolveColumnSchema Build or validate the column schema.
    %   If cfg.columnSchema is non-empty, validate it against the table.
    %   Otherwise, auto-detect roles from column names using heuristics.

    colNames = T.Properties.VariableNames;

    if ~isempty(cfg.columnSchema) && isstruct(cfg.columnSchema) && numel(cfg.columnSchema) > 0
        % Use provided schema — validate that names exist in the table
        schema = cfg.columnSchema;
        for k = 1:numel(schema)
            if ~ismember(schema(k).name, colNames)
                warning("runImportSweepWorkflow:SchemaColumnMissing", ...
                    "Schema column '%s' not found in data file. Ignoring.", schema(k).name);
                schema(k).role = "ignore";
            end
        end
        return;
    end

    % Auto-detect schema from column names
    inputPatterns    = ["period", "radius", "p", "r", "gap", "thickness", "angle", ...
                        "height", "pitch", "particle_r", "diameter"];
    spectralPatterns = ["lambda", "wavelength", "freq", "frequency", "omega"];

    schema = struct('name', {}, 'role', {});
    for k = 1:numel(colNames)
        cn = colNames{k};
        cnLow = lower(cn);

        entry = struct('name', cn, 'role', "metric");

        % Check spectral first (higher priority than input)
        if any(strcmpi(cnLow, spectralPatterns))
            entry.role = "spectral";
        elseif any(strcmpi(cnLow, inputPatterns))
            entry.role = "input";
        end
        % Everything else stays "metric"

        schema(end+1) = entry; %#ok<AGROW>
    end
end

function names = schemaFieldsByRole(schema, role)
    %schemaFieldsByRole Return column names matching a given role.
    names = {};
    for k = 1:numel(schema)
        if string(schema(k).role) == string(role)
            names{end+1} = schema(k).name; %#ok<AGROW>
        end
    end
end

function idx = findExistingRowsGeneric(dataStruct, inputNames, keyValues)
    %findExistingRowsGeneric Find rows matching all input parameter values.
    idx = [];
    if isempty(dataStruct) || ~isstruct(dataStruct)
        return;
    end

    % Start with all rows matching first input param, then intersect
    for k = 1:numel(inputNames)
        paramName = inputNames{k};
        paramVal  = keyValues(k);

        candidateList = {paramName};
        if any(strcmpi(paramName, ["particle_r", "radius", "r"]))
            candidateList = [candidateList, {"particle_r", "radius", "r"}];
        elseif any(strcmpi(paramName, ["period", "p"]))
            candidateList = [candidateList, {"period", "p"}];
        end
        candidateList = unique(cellstr(candidateList), 'stable');

        vals = extractGeometryField(dataStruct, candidateList);
        if isempty(vals)
            return;
        end

        finiteVals = vals(isfinite(vals));
        if isempty(finiteVals)
            return;
        end

        tol = max(1e-12, eps(max(abs(finiteVals))));
        matchIdx = find(abs(vals - double(paramVal)) <= tol);

        if k == 1
            idx = matchIdx;
        else
            idx = intersect(idx, matchIdx);
        end

        if isempty(idx)
            return;
        end
    end
end

function entry = processGeometryGroup(idx, cols, keyValues, ...
        inputNames, spectralName, metricNames, cfg, analyteSpectrum, c)
    %processGeometryGroup Process a single geometry group (dynamic schema).
    %   Groups rows by input parameter values, sorts by spectral variable,
    %   and computes derived metrics.

    entry = struct();

    % Store input parameter values (scalars)
    for k = 1:numel(inputNames)
        entry.(inputNames{k}) = keyValues(k);
    end

    % Sort by spectral variable (if present)
    if ~isempty(spectralName) && isfield(cols, spectralName)
        spectralVals = cols.(spectralName)(idx);
        [spectralSorted, ord] = sort(spectralVals);

        % Remove duplicate spectral values
        [spectralSorted, uniqueIdx] = unique(spectralSorted, "stable");
        ord = ord(uniqueIdx);
    else
        spectralSorted = [];
        ord = (1:nnz(idx))';
        if islogical(idx)
            linearIdx = find(idx);
        else
            linearIdx = idx;
        end
    end

    % Store spectral variable
    if ~isempty(spectralName)
        entry.(spectralName) = spectralSorted(:)';
    end

    % Store all metric columns (sorted by spectral variable)
    for k = 1:numel(metricNames)
        mn = metricNames{k};
        if isfield(cols, mn)
            rawVals = cols.(mn)(idx);
            sortedVals = rawVals(ord);
            if ~isempty(uniqueIdx)
                sortedVals = sortedVals(1:numel(spectralSorted));
            end
            entry.(mn) = sortedVals(:)';
        end
    end

    % === Spectral metric variant computation ===
    % Only if we have a spectral variable with enough points
    if ~isempty(spectralName) && numel(spectralSorted) >= 2
        laserLambda_nm = cfg.laserWavelength;

        % Compute Raman shift (assumes spectral variable is wavelength in nm)
        RamanShift_cm = (1 ./ (laserLambda_nm * 1e-9) - 1 ./ (spectralSorted * 1e-9)) / 100;
        entry.RamanShift = RamanShift_cm(:)';
        entry.LaserWl = laserLambda_nm;

        % Frequency conversion
        lambdaSorted_m = spectralSorted * 1e-9;
        f_sorted = c ./ lambdaSorted_m;
        entry.f = f_sorted(:)';

        % Raman window
        ramanWindow = cfg.ramanWindow;
        if cfg.detectShiftWindow
            stokesShifts = RamanShift_cm(RamanShift_cm > 0);
            if ~isempty(stokesShifts)
                ramanWindow = [min(stokesShifts), max(stokesShifts)];
            end
        end
        entry.RamanWindow = ramanWindow;
        entry.RamanWindowEffective = ramanWindow;
        shiftMin = ramanWindow(1);
        shiftMax = ramanWindow(2);

        % Laser index
        [~, laserIdx] = min(abs(spectralSorted - laserLambda_nm));

        % Stokes window mask
        stokesWindowMask = (RamanShift_cm > 0) & ...
                           (RamanShift_cm >= shiftMin) & ...
                           (RamanShift_cm <= shiftMax);
        shiftRange = shiftMax - shiftMin;
        interpSamples = max(2, round(shiftRange / cfg.interpResolution));

        % Compute metric variants for each metric
        mv = getConfigField(cfg, "metricVariants", struct());

        for k = 1:numel(metricNames)
            mn = metricNames{k};
            if ~isfield(entry, mn), continue; end

            spectralData = entry.(mn);
            if numel(spectralData) ~= numel(spectralSorted), continue; end

            % _laser variant: value at laser wavelength
            laserFieldName = mn + "_laser";
            if isVariantEnabled(mv, laserFieldName)
                entry.(laserFieldName) = spectralData(laserIdx);
            end

            % _avg variant: spectral average over Raman window
            avgFieldName = mn + "_avg";
            if isVariantEnabled(mv, avgFieldName) && nnz(stokesWindowMask) >= 2 && shiftRange > 0
                entry.(avgFieldName) = computeSpectralAverage( ...
                    RamanShift_cm, stokesWindowMask, shiftMin, shiftMax, ...
                    interpSamples, spectralData, cfg.spectralInterpMethod);
            elseif isVariantEnabled(mv, avgFieldName)
                entry.(avgFieldName) = spectralData(laserIdx);
            end

            % _analyte variant: analyte-weighted average
            analyteFieldName = mn + "_analyte";
            if isVariantEnabled(mv, analyteFieldName) && nnz(stokesWindowMask) >= 2 && shiftRange > 0
                entry.(analyteFieldName) = computeAnalyteVariant( ...
                    RamanShift_cm, stokesWindowMask, shiftMin, shiftMax, ...
                    interpSamples, spectralData, analyteSpectrum, cfg.spectralInterpMethod);
            elseif isVariantEnabled(mv, analyteFieldName)
                entry.(analyteFieldName) = NaN;
            end
        end
    else
        % No spectral variable or single-point: store LaserWl for metadata
        entry.LaserWl = cfg.laserWavelength;
        entry.RamanWindow = cfg.ramanWindow;
    end
end

function avg = computeSpectralAverage(RamanShift_cm, mask, shiftMin, shiftMax, ...
        interpSamples, spectralData, interpMethod)
    %computeSpectralAverage Dense interpolation + trapz averaging over Raman window.
    shiftDense = linspace(shiftMin, shiftMax, interpSamples);
    rs = RamanShift_cm(mask);
    data = spectralData(mask);
    [rs, rsOrd] = sort(rs);
    data = data(rsOrd);

    dense = safeInterpolate(rs, data, shiftDense, interpMethod);
    denom = shiftDense(end) - shiftDense(1);
    if denom > 0
        avg = trapz(shiftDense, dense) / denom;
    else
        avg = mean(dense, 'omitnan');
    end
end

function val = computeAnalyteVariant(RamanShift_cm, mask, shiftMin, shiftMax, ...
        interpSamples, spectralData, analyteSpectrum, interpMethod)
    %computeAnalyteVariant Analyte-weighted spectral average.
    shiftDense = linspace(shiftMin, shiftMax, interpSamples);
    rs = RamanShift_cm(mask);
    data = spectralData(mask);
    [rs, rsOrd] = sort(rs);
    data = data(rsOrd);

    dense = safeInterpolate(rs, data, shiftDense, interpMethod);
    val = computeAnalyteWeightedMetric(shiftDense, dense, analyteSpectrum);
end

function dense = safeInterpolate(rs, data, shiftDense, method)
    %safeInterpolate Interpolate with selected method and NaN fallback.
    try
        switch lower(string(method))
            case "makima"
                dense = makima(rs, data, shiftDense);
            case "pchip"
                dense = pchip(rs, data, shiftDense);
            case "linear"
                dense = interp1(rs, data, shiftDense, "linear", "extrap");
            case "spline"
                dense = spline(rs, data, shiftDense);
            otherwise
                dense = makima(rs, data, shiftDense);
        end
    catch
        dense = nan(size(shiftDense));
    end
end

function val = getConfigField(cfg, fieldName, defaultVal)
    %getConfigField Safely read a field from a config struct with a default.
    fieldName = char(fieldName);
    if isfield(cfg, fieldName)
        val = cfg.(fieldName);
    else
        val = defaultVal;
    end
end

function enabled = isVariantEnabled(metricVariants, key)
    %isVariantEnabled Return true if a metric+variant should be computed.
    %   Missing keys default to true for backward compatibility.
    key = char(key);
    if isfield(metricVariants, key)
        enabled = logical(metricVariants.(key));
    else
        enabled = true;
    end
end

function r = ternary(cond, trueVal, falseVal)
    if cond, r = trueVal; else, r = falseVal; end
end
