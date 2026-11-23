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
%   See also: importSweepConfig, readSweepTable, mergeEntryWithNewWavelengths,
%             update_entry_in_soa, ProgressReporter

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

    %% 2. Load analyte Raman spectrum & optional multi-analyte library
    reporter.start("LoadAnalyte", "Resolving analyte Raman spectrum...");
    [analyteSpectrum, resolvedAnalytePath] = resolveAnalyteSpectrum(struct(), ...
        ExplicitFile=cfg.analyteSpectrumFile, FallbackToDefault=true, Reporter=reporter);
    analyteKeysCfg = string.empty;
    if isfield(cfg, "analyteKeys") && ~isempty(cfg.analyteKeys)
        analyteKeysCfg = strtrim(string(cfg.analyteKeys(:)));
        analyteKeysCfg = analyteKeysCfg(strlength(analyteKeysCfg) > 0);
    end
    hasExplicitLib = isfield(cfg, "analyteLibrary") && isstruct(cfg.analyteLibrary) && ~isempty(cfg.analyteLibrary);
    if ~hasExplicitLib && ~isempty(analyteKeysCfg)
        existingDbCtx = getConfigField(cfg, "existingDb", struct([]));
        cfg.analyteLibrary = resolveAnalyteLibrary(existingDbCtx, ...
            Keys=analyteKeysCfg, ExplicitFile=cfg.analyteSpectrumFile, ...
            FallbackToDefault=false, Reporter=reporter);
    end
    if isfield(cfg, "analyteLibrary") && ~isempty(cfg.analyteLibrary)
        reporter.complete("LoadAnalyte", sprintf("Loaded %s plus %d analyte library variant(s).", ...
            resolvedAnalytePath, numel(cfg.analyteLibrary)));
    elseif strlength(cfg.analyteSpectrumFile) > 0 && strlength(resolvedAnalytePath) > 0
        reporter.complete("LoadAnalyte", sprintf("Loaded analyte spectrum: %s", resolvedAnalytePath));
    else
        reporter.complete("LoadAnalyte", sprintf("Using built-in analyte spectrum: %s", resolvedAnalytePath));
    end

    %% 3. Load existing database (merge mode)
    targetBranch = string(getConfigField(cfg, "targetBranch", "Sim"));
    isOptimaTarget = (targetBranch == "Optima.Sim");
    if isOptimaTarget
        reporter.info("Target branch: db.Optima.Sim (FEM verification of saved optima; db.Sim untouched).");
    end

    allDataStruct = struct();
    if isOptimaTarget
        % The sweep is first parsed into unique geometries; matching to the saved
        % optima and merging with any previous db.Optima.Sim batch happen in step 7b.
        reporter.complete("LoadExisting", "Parsing verification sweep into a fresh geometry table.");
    elseif cfg.mode == "merge"
        reporter.start("LoadExisting", "Loading existing database...");
        if isfield(cfg, "existingData") && isstruct(cfg.existingData) && ~isempty(fieldnames(cfg.existingData))
            allDataStruct = stripBranchMetadata(cfg.existingData, {}, cfg.metricVariants);
            allDataStruct = normalizeGeometryFields(allDataStruct);
            nExisting = structRowCount(allDataStruct);
            reporter.complete("LoadExisting", sprintf("Using in-memory database (%d existing entries).", nExisting));
        elseif strlength(string(cfg.outputFile)) > 0 && isfile(cfg.outputFile)
            try
                S = load(cfg.outputFile, "allData");
                if isfield(S, "allData") && isstruct(S.allData)
                    allDataStruct = normalizeGeometryFields(S.allData);
                    nExisting = structRowCount(allDataStruct);
                    reporter.complete("LoadExisting", sprintf("Loaded %d existing entries from %s.", nExisting, cfg.outputFile));
                else
                    reporter.warn("LoadExisting", "No valid allData in file; starting fresh.");
                end
            catch ME
                reporter.warn("LoadExisting", "Load failed: " + ME.message + ". Starting fresh.");
            end
        elseif isfield(cfg, "databaseFile") && isfile(cfg.databaseFile)
            try
                loaded = load(cfg.databaseFile, "db");
                if isfield(loaded, "db") && isfield(loaded.db, "Sim") && isstruct(loaded.db.Sim)
                    allDataStruct = extractBranchAsSoA(loaded.db, "Sim");
                    allDataStruct = stripBranchMetadata(allDataStruct, {}, cfg.metricVariants);
                    allDataStruct = normalizeGeometryFields(allDataStruct);
                    nExisting = structRowCount(allDataStruct);
                    reporter.complete("LoadExisting", sprintf("Loaded %d existing entries from %s (db.Sim).", nExisting, cfg.databaseFile));
                end
            catch ME
                reporter.warn("LoadExisting", "Could not load db.Sim: " + ME.message);
            end
        else
            reporter.complete("LoadExisting", "No existing database found; starting fresh.");
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
    geomTol = 1e-3;
    if isfield(cfg, "geometryTolerance") && isnumeric(cfg.geometryTolerance) && isfinite(cfg.geometryTolerance) && cfg.geometryTolerance > 0
        geomTol = double(cfg.geometryTolerance);
    end

    % Build key matrix from input columns
    nInputs = numel(inputNames);
    keyMatrix = zeros(height(T), nInputs);
    for k = 1:nInputs
        keyMatrix(:, k) = cols.(inputNames{k});
    end
    keyMatrixBinned = round(keyMatrix / geomTol) * geomTol;
    [~, firstIdx, G] = unique(keyMatrixBinned, "rows", "stable");
    keyPairs = round(keyMatrix(firstIdx, :) / geomTol) * geomTol;
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

        % Check for existing entries (generalized for N input params within geomTol)
        existingIdx = findExistingRowsGeneric(allDataStruct, inputNames, keyPairs(g, :), geomTol);

        if ~isempty(existingIdx)
            targetRow = existingIdx(1);
            oldEntry = extractEntryStruct(allDataStruct, targetRow);

            % Fine-grained schema-aware merge of spectral curves and metrics
            [mergedEntry, isUpdated] = mergeEntryWithNewWavelengths(oldEntry, entry, cfg, analyteSpectrum, metricNames, c);

            if isUpdated || (isfield(cfg, "replaceExisting") && cfg.replaceExisting)
                allDataStruct = update_entry_in_soa(allDataStruct, targetRow, mergedEntry);
                replacedDuplicates = replacedDuplicates + 1;
            else
                skippedExisting = skippedExisting + 1;
            end

            % Clean up any duplicate rows for this geometry if they existed
            if numel(existingIdx) > 1
                allDataStruct = removeRowsFromStruct(allDataStruct, existingIdx(2:end));
            end
        else
            allDataStruct = append_entry_struct(allDataStruct, entry);
            entriesWritten = entriesWritten + 1;
        end
    end

    reporter.complete("ProcessGroups", sprintf( ...
        "Processed %d groups: %d written, %d replaced/updated, %d skipped.", ...
        numGroups, entriesWritten, replacedDuplicates, skippedExisting));

    if fewPointsGroups > 0
        reporter.warn("ProcessGroups", sprintf("%d groups had <2 spectral points; proceeded with limited data.", fewPointsGroups));
    end

    %% 7b. Base unified database (prefer in-memory session db over disk)
    dbFile = cfg.databaseFile;
    existingDb = getConfigField(cfg, "existingDb", struct([]));
    hasExistingDb = isstruct(existingDb) && isscalar(existingDb) && ~isempty(fieldnames(existingDb));

    optimaReport = struct();
    if isOptimaTarget
        reporter.start("MatchOptima", "Matching imported geometries to saved optima (db.Optima)...");
        db = resolveBaseDatabase(existingDb, hasExistingDb, dbFile, reporter);
        if ~isfield(db, "Optima") || ~isstruct(db.Optima)
            db.Optima = struct();
        end
        existingOptSim = struct();
        if cfg.mode == "merge" && isfield(db.Optima, "Sim") && isstruct(db.Optima.Sim) ...
                && ~isempty(fieldnames(db.Optima.Sim))
            existingOptSim = stripBranchMetadata(extractBranchAsSoA(db.Optima, "Sim"), {}, struct());
        end
        [allDataStruct, optimaReport] = mergeOptimaVerificationData(db.Optima, allDataStruct, ...
            existingOptSim, cfg, analyteSpectrum, metricNames, c);
        reporter.complete("MatchOptima", optimaReport.summaryText);
        if height(optimaReport.unmatchedOptima) > 0 || optimaReport.nUnusedGeometries > 0
            reporter.warn("MatchOptima", optimaReport.summaryText);
        end

        % Spectral-integration settings must match the main database for a fair comparison
        if isfield(db, "Sim") && isstruct(db.Sim) && isfield(db.Sim, "StokesWindow") ...
                && numel(db.Sim.StokesWindow) == 2 && ~cfg.detectShiftWindow ...
                && any(abs(double(db.Sim.StokesWindow(:)') - double(cfg.ramanWindow(:)')) > 1e-6)
            reporter.warn("MatchOptima", sprintf( ...
                "Raman window [%g, %g] cm^-1 differs from db.Sim.StokesWindow [%g, %g] cm^-1; derived _broad/_analyte metrics will not be comparable.", ...
                cfg.ramanWindow(1), cfg.ramanWindow(2), db.Sim.StokesWindow(1), db.Sim.StokesWindow(2)));
        end
    end

    %% 8. Save output (legacy SoA format only if explicitly requested)
    totalEntries = structRowCount(allDataStruct);
    if ~isOptimaTarget && strlength(string(cfg.outputFile)) > 0 && (entriesWritten > 0 || replacedDuplicates > 0)
        reporter.start("Save", sprintf("Saving legacy SoA dataset to %s...", cfg.outputFile));
        allData = allDataStruct; %#ok<NASGU>
        w = whos("allData");
        if w.bytes > 2e9
            save(cfg.outputFile, "allData", "-v7.3");
        else
            save(cfg.outputFile, "allData");
        end
        reporter.complete("Save", sprintf("Saved %d entries to %s", totalEntries, cfg.outputFile));
    else
        reporter.complete("Save", "Dataset synchronized in memory.");
    end

    %% 9. Pack into unified database
    reporter.start("PackDB", "Packing into unified database (in-memory)...");
    if ~isOptimaTarget
        db = resolveBaseDatabase(existingDb, hasExistingDb, dbFile, reporter);
    end

    analyteArgs = {};
    if isstruct(analyteSpectrum) && isfield(analyteSpectrum, "shift_cm") && isfield(analyteSpectrum, "intensity")
        analyteArgs = {"AnalyteSpectrum", double(analyteSpectrum.intensity(:)'), ...
                       "AnalyteShifts",   double(analyteSpectrum.shift_cm(:)')};
    end

    if isOptimaTarget
        db.Optima.Sim = populateBranch(allDataStruct, "Simulation.FEM.COMSOL.OptimaVerification", ...
            "Parent", "Optima", ...
            "LaserWl", cfg.laserWavelength, ...
            "StokesWindow", cfg.ramanWindow, ...
            analyteArgs{:});
        db.Optima.Sim.Method = "matched:" + string(cfg.optimaMatchTolerance) + "nm";
    else
        db.Sim = populateBranch(allDataStruct, "Simulation.FEM.COMSOL", ...
            "LaserWl", cfg.laserWavelength, ...
            "StokesWindow", cfg.ramanWindow);

        % Store the column schema in the database
        db.Schema = schema;
    end

    % Populate RI branch if not already present
    if ~isfield(db, "RI") || ~isstruct(db.RI)
        db.RI = struct();
    end
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

    if isOptimaTarget
        reporter.complete("PackDB", sprintf("Prepared db.Optima.Sim (%d optima rows, %d verified) in memory.", ...
            totalEntries, optimaReport.nVerified));
    else
        reporter.complete("PackDB", sprintf("Prepared db.Sim (%d entries) in memory.", totalEntries));
    end

    %% Assemble results
    allData = allDataStruct;
    summary = struct();
    summary.totalEntries       = totalEntries;
    summary.numEntries         = totalEntries;
    summary.newEntries         = entriesWritten;
    summary.replacedDuplicates = replacedDuplicates;
    summary.skippedExisting    = skippedExisting;
    summary.numGroups          = numGroups;
    summary.inputFile          = inputPath;
    summary.outputFile         = cfg.outputFile;
    summary.databaseFile       = dbFile;
    summary.targetBranch       = targetBranch;

    results = struct();
    results.allData      = allData;
    results.db           = db;
    results.summary      = summary;
    results.cfg          = cfg;
    results.schema       = schema;
    results.optimaReport = optimaReport;
    results.elapsedTotal = toc(totalTimer);

    reporter.info(sprintf("Import complete in %.1f s. Total entries: %d", ...
        results.elapsedTotal, totalEntries));
end

%% ========================================================================
%  LOCAL HELPERS
%  ========================================================================

function db = resolveBaseDatabase(existingDb, hasExistingDb, dbFile, reporter)
    %resolveBaseDatabase In-memory session db if provided, else database file, else fresh.
    if hasExistingDb
        db = existingDb;
        return;
    end
    db = createDatabaseStruct();
    if strlength(string(dbFile)) > 0 && isfile(dbFile)
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
end

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

function idx = findExistingRowsGeneric(dataStruct, inputNames, keyValues, geomTol)
    %findExistingRowsGeneric Find rows matching all input parameter values within geomTol.
    if nargin < 4 || isempty(geomTol)
        geomTol = 1e-3;
    end
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

        tol = max(geomTol, eps(max(abs(finiteVals))));
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

    % If multiple candidates match within geomTol, pick the closest one in Euclidean distance
    if numel(idx) > 1
        dists = zeros(numel(idx), 1);
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
            if ~isempty(vals)
                dists = dists + (vals(idx) - double(paramVal)).^2;
            end
        end
        [~, minPos] = min(dists);
        idx = idx(minPos);
    end
end

function entry = processGeometryGroup(idx, cols, keyValues, ...
        inputNames, spectralName, metricNames, cfg, analyteSpectrum, c)
    %processGeometryGroup Process a single geometry group (dynamic schema).
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
        uniqueIdx = [];
        ord = (1:nnz(idx))';
    end

    % Store spectral variable
    if ~isempty(spectralName)
        entry.(spectralName) = spectralSorted(:)';
    end

    % Geometric loading capacity factors (stored as scalar per geometry)
    loadingFactorNames = ["kappa_V", "kappa_S", "VolCorr", "SurfCorr", "V_corr", "S_corr"];

    % Store all metric columns (sorted by spectral variable)
    for k = 1:numel(metricNames)
        mn = metricNames{k};
        if isfield(cols, mn)
            rawVals = double(cols.(mn)(idx));
            rawVals(~isfinite(rawVals)) = NaN;
            sortedVals = rawVals(ord);
            if ~isempty(uniqueIdx)
                sortedVals = sortedVals(1:numel(spectralSorted));
            end
            if any(strcmpi(mn, loadingFactorNames)) && ~isempty(sortedVals)
                entry.(mn) = sortedVals(1);
            else
                entry.(mn) = sortedVals(:)';
            end
        end
    end

    % === Spectral metric variant computation ===
    if ~isempty(spectralName) && numel(spectralSorted) >= 2
        laserLambda_nm = cfg.laserWavelength;

        % Compute Raman shift (assumes spectral variable is wavelength in nm)
        RamanShift_cm = (1 ./ (laserLambda_nm * 1e-9) - 1 ./ (spectralSorted(:)' * 1e-9)) / 100;
        RamanShift_cm = RamanShift_cm(:)';
        entry.RamanShift = RamanShift_cm;
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
            if any(strcmpi(mn, loadingFactorNames)), continue; end

            spectralData = entry.(mn);
            if numel(spectralData) ~= numel(spectralSorted), continue; end

            % _laser variant: value at laser wavelength
            laserFieldName = mn + "_laser";
            if isVariantEnabled(mv, laserFieldName)
                entry.(laserFieldName) = spectralData(laserIdx);
            end

            % _broad variant: spectral average over Raman window
            broadFieldName = mn + "_broad";
            broadEnabled = isVariantEnabled(mv, broadFieldName);
            validStokes = stokesWindowMask & isfinite(spectralData);
            if broadEnabled && nnz(validStokes) >= 2 && shiftRange > 0
                broadVal = computeSpectralAverage( ...
                    RamanShift_cm, validStokes, shiftMin, shiftMax, ...
                    interpSamples, spectralData, cfg.spectralInterpMethod);
                entry.(broadFieldName) = broadVal;
            elseif broadEnabled
                entry.(broadFieldName) = spectralData(laserIdx);
            end

            % _analyte variant(s): active spectrum plus optional multi-analyte library
            analyteLib = getConfigField(cfg, "analyteLibrary", struct([]));
            analyteFieldName = mn + "_analyte";
            wantActive = isVariantEnabled(mv, analyteFieldName);
            wantAnyLib = false;
            if isstruct(analyteLib) && ~isempty(analyteLib)
                for li = 1:numel(analyteLib)
                    if isVariantEnabled(mv, mn + "_" + string(analyteLib(li).key))
                        wantAnyLib = true;
                        break;
                    end
                end
            end

            denseShiftVals = [];
            denseSpecVals = [];
            if (wantActive || wantAnyLib) && nnz(validStokes) >= 2 && shiftRange > 0
                [denseShiftVals, denseSpecVals] = computeDenseShiftCurve( ...
                    RamanShift_cm, validStokes, shiftMin, shiftMax, interpSamples, ...
                    spectralData, cfg.spectralInterpMethod);
            end

            if wantActive
                if ~isempty(denseSpecVals)
                    entry.(analyteFieldName) = computeAnalyteWeightedMetric(denseShiftVals, denseSpecVals, analyteSpectrum);
                else
                    entry.(analyteFieldName) = NaN;
                end
            end

            if isstruct(analyteLib) && ~isempty(analyteLib)
                for li = 1:numel(analyteLib)
                    kName = string(analyteLib(li).key);
                    if strlength(kName) == 0, continue; end
                    libFieldName = mn + "_" + kName;
                    if ~isVariantEnabled(mv, libFieldName)
                        continue;
                    end
                    if ~isempty(denseSpecVals)
                        sp = analyteLib(li);
                        if isfield(sp, "spectrum") && isstruct(sp.spectrum), sp = sp.spectrum; end
                        entry.(libFieldName) = computeAnalyteWeightedMetric(denseShiftVals, denseSpecVals, sp);
                    else
                        entry.(libFieldName) = NaN;
                    end
                end
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

function [shiftDense, dense] = computeDenseShiftCurve(RamanShift_cm, mask, shiftMin, shiftMax, ...
        interpSamples, spectralData, interpMethod)
    %computeDenseShiftCurve Interpolate spectral slice once onto dense Raman shift grid.
    shiftDense = linspace(shiftMin, shiftMax, interpSamples);
    rs = RamanShift_cm(mask);
    data = spectralData(mask);
    [rs, rsOrd] = sort(rs);
    data = data(rsOrd);
    dense = safeInterpolate(rs, data, shiftDense, interpMethod);
end

function val = computeAnalyteVariant(RamanShift_cm, mask, shiftMin, shiftMax, ...
        interpSamples, spectralData, analyteSpectrum, interpMethod)
    %computeAnalyteVariant Analyte-weighted spectral average.
    [shiftDense, dense] = computeDenseShiftCurve( ...
        RamanShift_cm, mask, shiftMin, shiftMax, interpSamples, spectralData, interpMethod);
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

function S = stripBranchMetadata(S, activeMetricNames, metricVariants)
    %stripBranchMetadata Remove branch-level metadata and deprecated legacy metric aliases from SoA.
    if isempty(S) || ~isstruct(S)
        return;
    end
    if nargin < 2
        activeMetricNames = {};
    end
    activeMetricNames = cellstr(activeMetricNames);
    if nargin < 3 || ~isstruct(metricVariants)
        metricVariants = struct();
    end

    metaFields = ["Source", "Parent", "Method", "ModelRef", "Resolution", ...
                  "SourceFiles", "TrainDataRef", "LaserWl", "StokesWindow", "Shifts", ...
                  "AnalyteSpectrum", "AnalyteShifts"];
    for k = 1:numel(metaFields)
        fn = char(metaFields(k));
        if isfield(S, fn)
            S = rmfield(S, fn);
        end
    end

    % Strip deprecated legacy aliases and _avg fields
    deprecatedPrefixes = ["EF_vol", "EF_surf", "Absorptance", "ECCheck", ...
                          "M_vol", "M_surf", "M2_vol", "M2_surf", "EF_vol_M", "EF_surf_M", "EF_Abs"];
    allFlds = fieldnames(S);
    for k = 1:numel(allFlds)
        fn = allFlds{k};
        if endsWith(fn, "_avg")
            S = rmfield(S, fn);
            continue;
        end
        if ismember(fn, activeMetricNames)
            continue;
        end
        for dp = deprecatedPrefixes
            if strcmp(fn, dp) || startsWith(fn, dp + "_")
                if isfield(S, fn)
                    S = rmfield(S, fn);
                end
                break;
            end
        end
    end

    % If specific metric variants were explicitly deselected (false) in config, strip them
    mvFlds = fieldnames(metricVariants);
    for k = 1:numel(mvFlds)
        vName = mvFlds{k};
        if isfield(metricVariants, vName) && ~logical(metricVariants.(vName))
            if isfield(S, vName)
                S = rmfield(S, vName);
            end
        end
    end
end
