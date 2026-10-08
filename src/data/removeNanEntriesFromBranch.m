function [cleanBranchOrDb, removedCount, removedIdx, report] = removeNanEntriesFromBranch(branchOrDb, options)
% removeNanEntriesFromBranch  Remove rows/entries containing NaN values from a database branch or unified DB.
%
%   cleanBranch = removeNanEntriesFromBranch(branch)
%   cleanDb = removeNanEntriesFromBranch(db)
%   [clean, removedCount, removedIdx, report] = removeNanEntriesFromBranch(branchOrDb, Name=Value)
%
%   Scans all metric and geometry fields in a database branch (or db.Sim if a
%   unified database struct is provided), identifies all rows where any metric
%   or input parameter contains NaN values (e.g., from failed, diverged, or timed-out
%   COMSOL FEM simulations), and filters them out across all aligned data arrays.
%
%   Branch metadata (Source, Parent, Method, LaserWl, StokesWindow, Shifts, etc.)
%   and shared dimension-mismatched fields (e.g. uniform wavelength vectors) are
%   carefully preserved.
%
%   Inputs:
%       branchOrDb  - Either:
%                     - Unified database struct (db) containing .Sim
%                     - Database branch struct (e.g. db.Sim or flat SoA allData)
%
%   Name-Value Arguments:
%       BranchName  - (string) Branch to clean if db struct is provided (default: "Sim")
%       MetricNames - (cell) Specific metric names to check (default: all numeric metric arrays)
%       InputNames  - (cell) Input geometry names (default: auto-detected)
%       CheckInputs - (logical) Check geometry inputs for NaNs as well (default: true)
%       Verbose     - (logical) Print cleaning report to console (default: false)
%
%   Outputs:
%       cleanBranchOrDb - Cleaned branch struct (or unified db struct)
%       removedCount    - Number of rows removed (double)
%       removedIdx      - Array of 1-based row indices removed
%       report          - Diagnostic struct with field-by-field NaN statistics
%
%   See also: findNanSamplingPoints, exportNanPointsToComsol, removeRowsFromStruct,
%             structRowCount, populateBranch, extractBranchAsSoA

arguments
    branchOrDb
    options.BranchName (1,1) string = "Sim"
    options.MetricNames cell = {}
    options.InputNames cell = {}
    options.CheckInputs (1,1) logical = true
    options.Verbose (1,1) logical = false
end

    cleanBranchOrDb = branchOrDb;
    removedCount = 0;
    removedIdx = [];
    report = struct( ...
        'totalRowsBefore', 0, ...
        'totalRowsAfter', 0, ...
        'removedCount', 0, ...
        'removedIdx', [], ...
        'fieldNanCounts', struct(), ...
        'metricsWithNan', string([]) ...
    );

    if isempty(branchOrDb) || ~isstruct(branchOrDb)
        return;
    end

    %% 1. Determine if input is a unified db struct or a direct branch struct
    isDb = isfield(branchOrDb, "Sim") && isstruct(branchOrDb.Sim);
    if isDb
        targetBranchName = options.BranchName;
        if ~isfield(branchOrDb, targetBranchName) || ~isstruct(branchOrDb.(targetBranchName))
            error("removeNanEntriesFromBranch:BranchNotFound", ...
                "Branch '%s' does not exist or is not a struct in database.", targetBranchName);
        end
        branch = branchOrDb.(targetBranchName);
    else
        targetBranchName = "";
        branch = branchOrDb;
    end

    %% 2. Check row count
    totalRows = structRowCount(branch);
    report.totalRowsBefore = totalRows;
    report.totalRowsAfter = totalRows;
    if totalRows == 0
        return;
    end

    %% 3. Identify metadata fields to protect from indexing
    protectedMeta = ["Source", "Parent", "Method", "ModelRef", "Resolution", ...
                     "LaserWl", "StokesWindow", "Shifts", "AnalyteSpectrum", ...
                     "AnalyteShifts", "SourceFiles", "TrainDataRef", "RamanWindow", ...
                     "RamanShift", "lambda_exc_nm", "Schema", "Net", "NetFile"];

    %% 4. Identify input parameter names
    inputNames = options.InputNames;
    if isempty(inputNames)
        candidateInputs = ["period", "radius", "particle_r", "gap", "thick", "thickness", ...
                           "pitch", "height", "diameter", "angle", "p", "r"];
        bf = string(fieldnames(branch));
        detected = [];
        for ci = candidateInputs
            if any(strcmpi(bf, ci))
                matchName = bf(strcmpi(bf, ci));
                val = branch.(matchName(1));
                if isnumeric(val) && size(val, 1) == totalRows
                    detected(end+1) = matchName(1); %#ok<AGROW>
                end
            end
        end
        if isempty(detected)
            detected = ["period", "radius"];
        end
        inputNames = cellstr(unique(detected, "stable"));
    end

    %% 5. Scan for NaNs across all row-aligned fields
    nanMask = false(totalRows, 1);
    fieldNanCounts = struct();
    metricsWithNan = string([]);

    flds = fieldnames(branch);
    for k = 1:numel(flds)
        fn = flds{k};
        if ismember(fn, protectedMeta)
            continue;
        end

        val = branch.(fn);
        if isempty(val) || ~(isnumeric(val) || islogical(val))
            continue;
        end

        if size(val, 1) ~= totalRows
            % Shared/metadata array (e.g. 1xL lambda) -> skip scanning for row deletion
            continue;
        end

        isInput = ismember(fn, inputNames);
        if isInput && ~options.CheckInputs
            continue;
        end

        % If specific MetricNames requested, restrict non-input fields to those
        if ~isempty(options.MetricNames) && ~isInput && ~ismember(fn, options.MetricNames)
            continue;
        end

        % Check if 1D or multi-dimensional
        if ismatrix(val) && size(val, 2) > 1
            fMask = any(isnan(double(val)), 2);
        else
            fMask = isnan(double(val(:)));
        end

        c = nnz(fMask);
        fieldNanCounts.(fn) = c;
        if c > 0
            nanMask = nanMask | fMask;
            if ~isInput
                metricsWithNan(end+1) = string(fn); %#ok<AGROW>
            end
        end
    end

    report.fieldNanCounts = fieldNanCounts;
    report.metricsWithNan = unique(metricsWithNan, "stable");

    %% 6. Perform pruning if any NaNs found
    if ~any(nanMask)
        if options.Verbose
            fprintf("[removeNanEntriesFromBranch] No NaN values found across %d entries.\n", totalRows);
        end
        return;
    end

    removedIdx = find(nanMask);
    removedCount = numel(removedIdx);
    keepMask = ~nanMask;
    remainingCount = nnz(keepMask);

    report.removedCount = removedCount;
    report.removedIdx = removedIdx;
    report.totalRowsAfter = remainingCount;

    cleanBranch = struct();
    for k = 1:numel(flds)
        fn = flds{k};
        val = branch.(fn);

        if ismember(fn, protectedMeta) || isempty(val) || size(val, 1) ~= totalRows
            % Preserve metadata and non-aligned fields untouched
            cleanBranch.(fn) = val;
        else
            % Filter aligned rows
            if iscell(val)
                cleanBranch.(fn) = val(keepMask, :);
            else
                subs = repmat({':'}, 1, ndims(val));
                subs{1} = keepMask;
                cleanBranch.(fn) = val(subs{:});
            end
        end
    end

    if isDb
        branchOrDb.(targetBranchName) = cleanBranch;
        cleanBranchOrDb = branchOrDb;
    else
        cleanBranchOrDb = cleanBranch;
    end

    if options.Verbose
        fprintf("[removeNanEntriesFromBranch] Removed %d NaN rows from %s (%d -> %d entries).\n", ...
            removedCount, targetBranchName, totalRows, remainingCount);
    end
end
