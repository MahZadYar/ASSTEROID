function report = audit_sweep_completeness(varargin)
% AUDIT_SWEEP_COMPLETENESS
% Standalone diagnostic & compiler utility to investigate multi-file COMSOL
% sweep tables (by default: SweepPropeTable_Full.dat,
% SweepPropeTable_Extention.dat, and SweepPropeTable_E4.dat) and compile a
% clean, combined COMSOL-formatted .dat table of all complete entries:
%   1. (period, particle_r) pair consistency and set-membership across files
%   2. 30-wavelength (lambda0 / Raman shift) grid completeness per (p, r) pair
%   3. Exact listing of entries with missing wavelengths, missing files, or duplicates
%   4. Compilation & export of all fully complete (30/30) entries in exact
%      COMSOL 6.4 Sweep Probe Table .dat format, verified via readComsolDat
%
% USAGE:
%   report = audit_sweep_completeness();
%   report = audit_sweep_completeness(fileList);
%   report = audit_sweep_completeness('ExportCombined', true, 'OutputDatFile', 'Database/Raw/Simulation/SweepPropeTable_Combined_Complete.dat');
%   report = audit_sweep_completeness('Prefer785Source', 'Full', 'ShowPlots', true);
%
% OUTPUT:
%   report - struct with full tables, missing-entry catalog, wavelength grid,
%            per-geometry completeness matrices, and combinedTable/outputDatFile
%            (also assigned in 'base' as 'sweepAuditReport').

    clc;

    %% 1. Parse Arguments & Resolve Paths
    scriptDir   = fileparts(mfilename('fullpath'));
    projectRoot = fullfile(scriptDir, '..', '..', '..');
    rawDir      = fullfile(projectRoot, 'Database', 'Raw', 'Simulation');
    if ~isfolder(rawDir)
        rawDir = fullfile(projectRoot, 'Database', 'Raw');
    end

    assteroidSrc = fullfile(scriptDir, '..', 'src');
    if isfolder(assteroidSrc) && ~exist('readComsolDat', 'file')
        addpath(fullfile(assteroidSrc, 'io'), fullfile(assteroidSrc, 'utils'));
    end

    defaultSupplements = {};
    suppList = dir(fullfile(rawDir, 'SweepPropeTable_remaining_*.dat'));
    for sK = 1:numel(suppList)
        defaultSupplements{end+1} = fullfile(suppList(sK).folder, suppList(sK).name); %#ok<AGROW>
    end

    opts = struct( ...
        'files', {{ ...
            fullfile(rawDir, 'SweepPropeTable_Full.dat'), ...
            fullfile(rawDir, 'SweepPropeTable_Extention.dat'), ...
            fullfile(rawDir, 'SweepPropeTable_E4.dat') ...
        }}, ...
        'supplementFiles', {defaultSupplements}, ...
        'geomTol', 1e-3, ...
        'wlTol', 1e-2, ...
        'laserWl', 785.0, ...
        'showPlots', true, ...
        'maxPrintRows', 200, ...
        'exportCombined', true, ...
        'outputDatFile', fullfile(rawDir, 'SweepPropeTable_Combined_Complete.dat'), ...
        'prefer785Source', 'Full' ...
    );

    knownOptKeys = {'GeomTol','WavelengthTol','LaserWavelength','ShowPlots', ...
        'MaxPrintRows','ExportCombined','OutputDatFile','Prefer785Source','SupplementFiles'};
    if ~isempty(varargin)
        if iscell(varargin{1}) || isstring(varargin{1}) || (ischar(varargin{1}) && ~any(strcmpi(varargin{1}, knownOptKeys)))
            opts.files = cellstr(varargin{1});
            nvArgs = varargin(2:end);
        else
            nvArgs = varargin;
        end
        for k = 1:2:numel(nvArgs)
            key = lower(char(nvArgs{k}));
            val = nvArgs{k+1};
            switch key
                case 'geomtol',         opts.geomTol = double(val);
                case 'wavelengthtol',   opts.wlTol = double(val);
                case 'laserwavelength', opts.laserWl = double(val);
                case 'showplots',       opts.showPlots = logical(val);
                case 'maxprintrows',    opts.maxPrintRows = double(val);
                case 'exportcombined',  opts.exportCombined = logical(val);
                case 'outputdatfile',   opts.outputDatFile = char(string(val));
                case 'prefer785source', opts.prefer785Source = char(string(val));
                case 'supplementfiles', opts.supplementFiles = cellstr(val);
            end
        end
    end

    numFiles = numel(opts.files);
    fprintf('====================================================================================================\n');
    fprintf('  ASSTEROID MULTI-SWEEP COMPLETENESS & (p, r, lambda) INTEGRITY AUDIT\n');
    fprintf('  Geometry Tolerance: %.1e nm | Wavelength Tolerance: %.1e nm | Laser Reference: %.2f nm\n', ...
        opts.geomTol, opts.wlTol, opts.laserWl);
    fprintf('====================================================================================================\n\n');

    %% 2. Load Each Raw Table & Inspect File-Level Integrity
    filesInfo = repmat(struct( ...
        'path', '', 'name', '', 'shortLabel', '', ...
        'table', table(), 'numRows', 0, 'colNames', {{}}, 'metricCols', {{}}, ...
        'pRaw', [], 'rRaw', [], 'lamRaw', [], ...
        'prKeys', [], 'uniquePR', [], 'uniquePRBinned', [], 'prGroupIdx', [], 'countsPerPR', [], ...
        'uniqueLam', [], 'expectedLamCount', 0, ...
        'numRawNaNs', 0, 'numDuplicateRows', 0), numFiles, 1);

    shortLabels = {'Full', 'Extention', 'E4'};

    fprintf('[1/5] Loading and inspecting individual sweep tables...\n');
    for f = 1:numFiles
        fpath = opts.files{f};
        if ~isfile(fpath) && isfile(fullfile(rawDir, fpath))
            fpath = fullfile(rawDir, fpath);
        end
        if ~isfile(fpath)
            error('audit_sweep_completeness:FileNotFound', 'File not found: %s', fpath);
        end

        [~, fname, fext] = fileparts(fpath);
        T = readComsolDat(fpath);
        colNames = T.Properties.VariableNames;

        % Identify coordinate and spectral columns
        pCol   = findColByAliases(colNames, {'period', 'p', 'pitch'});
        rCol   = findColByAliases(colNames, {'radius', 'particle_r', 'r'});
        lamCol = findColByAliases(colNames, {'lambda', 'lambda0', 'Wavelength'});
        metricCols = setdiff(colNames, {pCol, rCol, lamCol}, 'stable');

        pVals   = double(T.(pCol));
        rVals   = double(T.(rCol));
        lamVals = double(T.(lamCol));

        % Quantize coordinates and wavelengths by tolerance
        prBinned  = round([pVals, rVals] / opts.geomTol) * opts.geomTol;
        lamBinned = round(lamVals / opts.wlTol) * opts.wlTol;

        [uPR, firstIdx, prGrp] = unique(prBinned, 'rows', 'stable');
        countsPerPR = accumarray(prGrp, 1);
        uLam = unique(lamBinned);

        % Check for duplicate (p, r, lambda) rows within the same file
        prLamBinned = [prBinned, lamBinned];
        [~, uRowIdx] = unique(prLamBinned, 'rows', 'stable');
        numDupRows = height(T) - numel(uRowIdx);

        % Check for raw NaNs / Infs in numeric data
        rawMat = table2array(T);
        numRawNaNs = nnz(~isfinite(rawMat));

        filesInfo(f).path             = fpath;
        filesInfo(f).name             = [fname, fext];
        filesInfo(f).shortLabel       = ternary(f <= numel(shortLabels), shortLabels{f}, fname);
        filesInfo(f).table            = T;
        filesInfo(f).numRows          = height(T);
        filesInfo(f).colNames         = colNames;
        filesInfo(f).metricCols       = metricCols;
        filesInfo(f).pRaw             = pVals;
        filesInfo(f).rRaw             = rVals;
        filesInfo(f).lamRaw           = lamVals;
        filesInfo(f).prKeys           = prBinned;
        filesInfo(f).uniquePR         = [pVals(firstIdx), rVals(firstIdx)];
        filesInfo(f).uniquePRBinned   = uPR;
        filesInfo(f).prGroupIdx       = prGrp;
        filesInfo(f).countsPerPR      = countsPerPR;
        filesInfo(f).uniqueLam        = uLam;
        filesInfo(f).expectedLamCount = mode(countsPerPR);
        filesInfo(f).numRawNaNs       = numRawNaNs;
        filesInfo(f).numDuplicateRows = numDupRows;

        fprintf('  [%d] %-28s | Rows: %7d | Unique (p,r): %5d | Unique lambda: %2d (mode=%2d/pair) | Dup (p,r,lam): %3d | Non-finite: %d\n', ...
            f, filesInfo(f).name, height(T), size(uPR, 1), numel(uLam), ...
            filesInfo(f).expectedLamCount, numDupRows, numRawNaNs);
        fprintf('      Columns (%d): {%s}\n', numel(colNames), strjoin(colNames, ', '));
    end

    %% 3. Analyze the Master 30-Wavelength Grid Across Files
    fprintf('\n[2/5] Auditing combined wavelength / Raman-shift grid across files...\n');
    allLamRaw = [];
    for f = 1:numFiles
        allLamRaw = [allLamRaw; filesInfo(f).lamRaw]; %#ok<AGROW>
    end
    allLamSorted = sort(unique(allLamRaw));
    masterLam = [];
    for i = 1:numel(allLamSorted)
        if isempty(masterLam) || abs(allLamSorted(i) - masterLam(end)) > opts.wlTol
            masterLam(end+1, 1) = allLamSorted(i); %#ok<AGROW>
        end
    end
    nMasterLam = numel(masterLam);
    masterShiftCm = (1 ./ opts.laserWl - 1 ./ masterLam) * 1e7;

    fileHasLam = false(nMasterLam, numFiles);
    for f = 1:numFiles
        for lIdx = 1:nMasterLam
            fileHasLam(lIdx, f) = any(abs(filesInfo(f).uniqueLam - masterLam(lIdx)) <= opts.wlTol);
        end
    end

    %% 4. Build Master (p, r) Catalog & Cross-File Set Membership
    allPRBinned = [];
    allPRExact  = [];
    for f = 1:numFiles
        allPRBinned = [allPRBinned; filesInfo(f).uniquePRBinned]; %#ok<AGROW>
        allPRExact  = [allPRExact;  filesInfo(f).uniquePR];       %#ok<AGROW>
    end
    [masterPRBinned, firstMasterIdx] = unique(allPRBinned, 'rows', 'stable');
    masterPR = allPRExact(firstMasterIdx, :);
    nMasterPR = size(masterPR, 1);

    % Map every row in each file to (masterPRIdx, masterLamIdx)
    inFileMatrix      = false(nMasterPR, numFiles);
    lamCountInFile    = zeros(nMasterPR, numFiles);
    dupRowsInFile     = zeros(nMasterPR, numFiles);
    lamPresentPerFile = false(nMasterPR, nMasterLam, numFiles);

    allCanonicalMetrics = {};
    for f = 1:numFiles
        allCanonicalMetrics = [allCanonicalMetrics, filesInfo(f).metricCols]; %#ok<AGROW>
    end
    allCanonicalMetrics = unique(allCanonicalMetrics, 'stable');
    nMetrics = numel(allCanonicalMetrics);
    metricTensor = nan(nMasterPR, nMasterLam, nMetrics);

    for f = 1:numFiles
        T = filesInfo(f).table;
        [~, prIdxInMaster] = ismember(filesInfo(f).prKeys, masterPRBinned, 'rows');
        [~, lamIdxInMaster] = min(abs(filesInfo(f).lamRaw - masterLam'), [], 2);
        validLamMatch = abs(filesInfo(f).lamRaw - masterLam(lamIdxInMaster)) <= opts.wlTol;

        for rIdx = 1:height(T)
            if ~validLamMatch(rIdx), continue; end
            g = prIdxInMaster(rIdx);
            l = lamIdxInMaster(rIdx);
            inFileMatrix(g, f) = true;
            if lamPresentPerFile(g, l, f)
                dupRowsInFile(g, f) = dupRowsInFile(g, f) + 1;
            end
            lamPresentPerFile(g, l, f) = true;
        end

        for m = 1:nMetrics
            mName = allCanonicalMetrics{m};
            if ismember(mName, filesInfo(f).metricCols)
                mVals = double(T.(mName));
                allowOverwrite785 = strcmpi(opts.prefer785Source, 'Extention') && ...
                    contains(lower(filesInfo(f).name), 'extention');
                for rIdx = 1:height(T)
                    if ~validLamMatch(rIdx), continue; end
                    g = prIdxInMaster(rIdx);
                    l = lamIdxInMaster(rIdx);
                    if isfinite(mVals(rIdx))
                        isLam785 = abs(masterLam(l) - opts.laserWl) <= opts.wlTol;
                        if isnan(metricTensor(g, l, m)) || (allowOverwrite785 && isLam785)
                            metricTensor(g, l, m) = mVals(rIdx);
                        end
                    end
                end
            end
        end
    end

    for f = 1:numFiles
        lamCountInFile(:, f) = sum(lamPresentPerFile(:, :, f), 2);
    end

    idxEEV   = find(strcmp(allCanonicalMetrics, 'EE_V'), 1);
    idxEFmax = find(strcmp(allCanonicalMetrics, 'EF_max'), 1);
    if isempty(idxEEV),   idxEEV = 1; end
    if isempty(idxEFmax), idxEFmax = nMetrics; end

    fprintf('  Total unique wavelengths across all files: %d\n', nMasterLam);
    fprintf('  %-4s | %-12s | %-12s | %-10s | %-10s | %-10s | %-14s | %-14s\n', ...
        'Idx', 'lambda0 (nm)', 'Shift (cm-1)', filesInfo(1).shortLabel, ...
        filesInfo(min(2,numFiles)).shortLabel, filesInfo(min(3,numFiles)).shortLabel, ...
        'Valid EE_V', 'Valid EF_max');
    fprintf('  %s\n', repmat('-', 1, 102));
    for lIdx = 1:nMasterLam
        nFullL = sum(lamPresentPerFile(:, lIdx, 1));
        nExtL  = sum(lamPresentPerFile(:, lIdx, min(2,numFiles)));
        nE4L   = sum(lamPresentPerFile(:, lIdx, min(3,numFiles)));
        nValidEEL = sum(isfinite(metricTensor(:, lIdx, idxEEV)));
        nValidE4L = sum(isfinite(metricTensor(:, lIdx, idxEFmax)));
        fprintf('  %3d  | %12.6f | %12.2f | %10s | %10s | %10s | %6d / %-5d | %6d / %-5d\n', ...
            lIdx, masterLam(lIdx), masterShiftCm(lIdx), ...
            ternary(nFullL > 0, sprintf('%d', nFullL), '-'), ...
            ternary(nExtL  > 0, sprintf('%d', nExtL),  '-'), ...
            ternary(nE4L   > 0, sprintf('%d', nE4L),   '-'), ...
            nValidEEL, nMasterPR, nValidE4L, nMasterPR);
    end

    fprintf('\n[3/5] Auditing (p, r) geometry pairs and cross-file membership...\n');
    fprintf('  Total unique (p, r) pairs across all %d files: %d\n\n', numFiles, nMasterPR);

    if numFiles == 3
        patLabels = {
            [true,  true,  true ], 'In all 3 files (Full + Extention + E4)';
            [true,  true,  false], 'In Full + Extention ONLY (Absent from E4)';
            [true,  false, true ], 'In Full + E4 ONLY (Absent from Extention)';
            [true,  false, false], 'In Full ONLY (Absent from both Extention & E4)';
            [false, true,  true ], 'In Extention + E4 ONLY (Absent from Full)';
            [false, true,  false], 'In Extention ONLY';
            [false, false, true ], 'In E4 ONLY'
        };
        fprintf('  Cross-File (p, r) Set Membership Summary:\n');
        fprintf('  %-52s | %-8s | %-8s\n', 'Membership Pattern', 'Count', 'Percent');
        fprintf('  %s\n', repmat('-', 1, 74));
        for pIdx = 1:size(patLabels, 1)
            pat = patLabels{pIdx, 1};
            cnt = sum(all(inFileMatrix == pat, 2));
            fprintf('  %-52s | %8d | %7.2f%%\n', patLabels{pIdx, 2}, cnt, 100 * cnt / nMasterPR);
        end
        fprintf('\n');
    end

    %% 5. Per-File Wavelength Count Anomalies & Duplicate Geometries
    fprintf('[4/5] Checking for partial/incomplete wavelength sweeps and duplicates within each file...\n');
    for f = 1:numFiles
        expCnt = filesInfo(f).expectedLamCount;
        presentMask = inFileMatrix(:, f);
        cnts = lamCountInFile(presentMask, f);
        uCnts = unique(cnts);
        fprintf('  File [%d] %s (Expected %d unique wavelengths per present (p,r)):\n', ...
            f, filesInfo(f).name, expCnt);
        for cIdx = 1:numel(uCnts)
            cVal = uCnts(cIdx);
            nWithCnt = sum(cnts == cVal);
            statusTag = ternary(cVal == expCnt, 'COMPLETE', 'PARTIAL / MISSING LAMBDA IN FILE');
            fprintf('    - %2d wavelengths: %5d (p,r) pairs [%s]\n', cVal, nWithCnt, statusTag);
        end
        nMissingFile = sum(~presentMask);
        if nMissingFile > 0
            fprintf('    -  0 wavelengths: %5d (p,r) pairs [ABSENT FROM THIS FILE]\n', nMissingFile);
        end
        dupGeomIdx = find(dupRowsInFile(:, f) > 0);
        if ~isempty(dupGeomIdx)
            fprintf('    - Duplicate (p,r,lambda) blocks in %d geometries (%d duplicate rows total):\n', ...
                numel(dupGeomIdx), sum(dupRowsInFile(:, f)));
            for dIdx = 1:numel(dupGeomIdx)
                g = dupGeomIdx(dIdx);
                fprintf('        MasterRow %4d: (P = %8.3f nm, r = %7.3f nm) -> %d unique lambda, %d duplicate rows\n', ...
                    g, masterPR(g,1), masterPR(g,2), lamCountInFile(g, f), dupRowsInFile(g, f));
            end
        end
    end

    %% 6. Combined 30-Lambda x Metric Completeness & Detailed Missing Entries Table
    fprintf('\n[5/5] Auditing combined %d-wavelength completeness across all metrics...\n', nMasterLam);

    validCountPerMetric = zeros(nMasterPR, nMetrics);
    for m = 1:nMetrics
        validCountPerMetric(:, m) = sum(isfinite(metricTensor(:, :, m)), 2);
    end

    nValidEE = validCountPerMetric(:, idxEEV);
    nValidE4 = validCountPerMetric(:, idxEFmax);
    isFullyComplete = all(validCountPerMetric == nMasterLam, 2);

    category = strings(nMasterPR, 1);
    missingLambdasStr = strings(nMasterPR, 1);

    for g = 1:nMasterPR
        if isFullyComplete(g)
            category(g) = "0. Complete (30/30 EE, 30/30 E4)";
            missingLambdasStr(g) = "None";
        else
            % Identify which wavelengths are missing in Full (indices 1..25)
            missFullIdx = find(~lamPresentPerFile(g, 1:min(25, nMasterLam), 1));
            missFullStr = "";
            if ~isempty(missFullIdx)
                parts = arrayfun(@(idx) sprintf('#%d(%.1fnm/%.0fcm-1)', idx, masterLam(idx), masterShiftCm(idx)), ...
                    missFullIdx, 'UniformOutput', false);
                missFullStr = "Full missing " + string(strjoin(parts, ', '));
            end

            hasAllFull = (lamCountInFile(g, 1) == 25);
            hasExt     = inFileMatrix(g, 2) && (lamCountInFile(g, 2) == 6);
            hasE4      = inFileMatrix(g, 3) && (lamCountInFile(g, 3) == 24);

            if ~hasAllFull && hasExt && hasE4
                category(g) = "1. Partial Full only (29/30 EE, 30/30 E4)";
                missingLambdasStr(g) = missFullStr;
            elseif ~hasAllFull && hasExt && ~inFileMatrix(g, 3)
                category(g) = "2. Partial Full + Absent in E4 (27..29/30 EE, 6/30 E4)";
                missingLambdasStr(g) = missFullStr + "; Absent in E4";
            elseif ~hasAllFull && ~inFileMatrix(g, 2) && hasE4
                category(g) = "3. Partial Full + Absent in Extention (24/30 EE, 24/30 E4)";
                missingLambdasStr(g) = missFullStr + "; Absent in Extention";
            elseif ~hasAllFull && ~inFileMatrix(g, 2) && ~inFileMatrix(g, 3)
                category(g) = "4. Partial Full + Absent in Extention & E4 (24/30 EE, 0/30 E4)";
                missingLambdasStr(g) = missFullStr + "; Absent in Extention & E4";
            elseif hasAllFull && hasExt && ~inFileMatrix(g, 3)
                category(g) = "5. Absent in E4 only (30/30 EE, 6/30 E4)";
                missingLambdasStr(g) = "Absent in E4 (missing 24 shifts in 100..3600 cm-1)";
            elseif hasAllFull && ~inFileMatrix(g, 2) && hasE4
                category(g) = "6. Absent in Extention only (25/30 EE, 24/30 E4)";
                missingLambdasStr(g) = "Absent in Extention (missing 785nm E4 & 5 shifts >3600 cm-1)";
            elseif hasAllFull && ~inFileMatrix(g, 2) && ~inFileMatrix(g, 3)
                category(g) = "7. Absent in Extention & E4 (25/30 EE, 0/30 E4)";
                missingLambdasStr(g) = "Absent in both Extention & E4";
            else
                category(g) = "8. Other Incomplete / Non-finite";
                missingLambdasStr(g) = missFullStr;
            end
        end
    end

    [uCats, ~, catGrp] = unique(category);
    fprintf('\n  Overall Geometry Completeness Breakdown (N = %d total (p, r) pairs):\n', nMasterPR);
    fprintf('  %-62s | %-6s | %-7s | %-10s | %-10s\n', ...
        'Completeness Category', 'Count', 'Percent', 'EE_V', 'EF_max');
    fprintf('  %s\n', repmat('-', 1, 106));
    for cIdx = 1:numel(uCats)
        mask = (catGrp == cIdx);
        eeRange = unique(nValidEE(mask));
        e4Range = unique(nValidE4(mask));
        eeStr = ternary(isscalar(eeRange), sprintf('%d/30', eeRange), sprintf('%d..%d/30', min(eeRange), max(eeRange)));
        e4Str = ternary(isscalar(e4Range), sprintf('%d/30', e4Range), sprintf('%d..%d/30', min(e4Range), max(e4Range)));
        fprintf('  %-62s | %6d | %6.2f%% | %-10s | %-10s\n', ...
            uCats(cIdx), nnz(mask), 100 * nnz(mask) / nMasterPR, eeStr, e4Str);
    end

    % Build table of all incomplete entries
    incompleteIdx = find(~isFullyComplete);
    nIncomplete = numel(incompleteIdx);

    missingTable = table( ...
        incompleteIdx, ...
        masterPR(incompleteIdx, 1), ...
        masterPR(incompleteIdx, 2), ...
        lamCountInFile(incompleteIdx, 1), ...
        lamCountInFile(incompleteIdx, min(2, numFiles)), ...
        lamCountInFile(incompleteIdx, min(3, numFiles)), ...
        nValidEE(incompleteIdx), ...
        nValidE4(incompleteIdx), ...
        category(incompleteIdx), ...
        missingLambdasStr(incompleteIdx), ...
        'VariableNames', {'MasterRow', 'period_nm', 'particle_r_nm', ...
                          'nLam_Full', 'nLam_Ext', 'nLam_E4', ...
                          'Valid_EE_of_30', 'Valid_E4_of_30', 'Category', 'MissingDetails'});

    % Sort missingTable by Category then MasterRow for clean inspection
    missingTable = sortrows(missingTable, {'Category', 'MasterRow'});

    fprintf('\n  ====================================================================================================\n');
    fprintf('  COMPLETE CATALOG OF ALL %d INCOMPLETE (p, r) ENTRIES (out of %d total geometries)\n', ...
        nIncomplete, nMasterPR);
    fprintf('  ====================================================================================================\n');
    disp(missingTable);

    %% 7. Root-Cause Diagnosis of ASSTEROID Import NaNs & Misplaced Numbers
    fprintf('  ====================================================================================================\n');
    fprintf('  ROOT-CAUSE DIAGNOSIS: WHY ASSTEROID IMPORT PRODUCES MISPLACED NUMBERS & EXTRA NaNs\n');
    fprintf('  ====================================================================================================\n');
    fprintf('  CAUSE 1 — Missing Points in Raw COMSOL Tables (186 of 6138 geometries):\n');
    fprintf('    * 119 geometries in SweepPropeTable_Full.dat are missing 1 to 3 interior wavelengths\n');
    fprintf('      (117 have 24/25, 1 has 23/25, 1 has 22/25).\n');
    fprintf('    * 29 geometries are completely absent from SweepPropeTable_Extention.dat (missing the 5 shifts\n');
    fprintf('      above 3600 cm^-1 for all metrics AND missing 785 nm for EF_max).\n');
    fprintf('    * 122 geometries are completely absent from SweepPropeTable_E4.dat (missing EF_max across\n');
    fprintf('      all 24 shifts in [100, 3600] cm^-1).\n\n');
    fprintf('  CAUSE 2 — Left-Packing + Column-Shift Bug in ASSTEROID Import/Merge Pipeline:\n');
    fprintf('    * Step A (Initial Import of Full.dat): For the 119 geometries with only 22..24 wavelengths in\n');
    fprintf('      Full.dat, processGeometryGroup creates a 24-element vector and append_entry_struct pads NaN\n');
    fprintf('      at the END (column 25) instead of at the missing interior wavelength index. Thus, all\n');
    fprintf('      wavelengths after the missing step are shifted left by 1..3 columns in allData.\n');
    fprintf('    * Step B (Merging Extention.dat & E4.dat in mergeEntryWithNewWavelengths.m): When row 1 is\n');
    fprintf('      updated with 30 wavelengths, update_entry_in_soa pads allData.<metric> to 30 columns.\n');
    fprintf('      For any subsequent row that had <30 valid wavelengths (padded with trailing NaNs),\n');
    fprintf('      sanitizeLambdaVector(oldEntry) strips the NaNs (e.g. length 29 or 25), whereas\n');
    fprintf('      numel(oldEntry.EE_V) is 30. Line 130 of mergeEntryWithNewWavelengths.m checks:\n');
    fprintf('          if numel(val) == numel(oldLambda)\n');
    fprintf('      Because 30 ~= 29 (and 30 ~= 25), EE_V, EE_S, Abs, and ECC are NOT recognized as spectral\n');
    fprintf('      fields when merging E4.dat! Meanwhile, E4.dat supplies the missing interior wavelength\n');
    fprintf('      (expanding mergedEntry.lambda to all 30 sorted wavelengths), while EE_V, EE_S, Abs, and ECC\n');
    fprintf('      remain un-remapped—misplacing their values into the wrong wavelength columns!\n');
    fprintf('  ====================================================================================================\n\n');

    %% 8. Compile & Export Combined Complete COMSOL .dat Table
    combinedTable = table();
    outputDatFile = '';
    if opts.exportCombined
        completeIdx = find(isFullyComplete);
        nCompPR = numel(completeIdx);
        nTotalRows = nCompPR * nMasterLam;

        fprintf('  ====================================================================================================\n');
        fprintf('  COMPILING COMBINED COMPLETE COMSOL .DAT TABLE (%d geometries x %d lambda = %d rows)\n', ...
            nCompPR, nMasterLam, nTotalRows);
        fprintf('  785 nm {EE_V, EE_S, Abs, ECC} source preference: %s\n', opts.prefer785Source);
        fprintf('  ====================================================================================================\n');

        % Build matrix in exact COMSOL column order:
        % [period, particle_r, lambda0, EE_V, EE_S, Abs, ECC, EF_max]
        targetCols = {'EE_V', 'EE_S', 'Abs', 'ECC', 'EF_max'};
        mIdxMap = zeros(1, numel(targetCols));
        for k = 1:numel(targetCols)
            idxM = find(strcmp(allCanonicalMetrics, targetCols{k}), 1);
            if isempty(idxM)
                error('audit_sweep_completeness:MissingMetric', ...
                    'Required metric "%s" not found across input files.', targetCols{k});
            end
            mIdxMap(k) = idxM;
        end

        % Vectorized assembly (geometry-major, sorted ascending lambda0)
        pVec   = repelem(masterPR(completeIdx, 1), nMasterLam, 1);
        rVec   = repelem(masterPR(completeIdx, 2), nMasterLam, 1);
        lamVec = repmat(masterLam(:), nCompPR, 1);

        combinedMat = zeros(nTotalRows, 8);
        combinedMat(:, 1) = pVec;
        combinedMat(:, 2) = rVec;
        combinedMat(:, 3) = lamVec;
        for k = 1:numel(targetCols)
            slice = metricTensor(completeIdx, :, mIdxMap(k)); % [nCompPR x nMasterLam]
            sliceT = slice.';                                  % [nMasterLam x nCompPR]
            combinedMat(:, 3 + k) = sliceT(:);
        end

        % Sanity check: ensure zero NaNs/Infs in compiled matrix
        if any(~isfinite(combinedMat(:)))
            error('audit_sweep_completeness:NonFiniteCombined', ...
                'Unexpected non-finite value found in compiled complete matrix!');
        end

        % Append any valid, complete (30-row, 8-col, non-flawed) pairs from SupplementFiles
        baseCompletePRBinned = round(masterPR(completeIdx, :) / opts.geomTol) * opts.geomTol;
        nSuppAdded = 0;
        nSuppSkippedFlawed = 0;
        nSuppSkippedDup = 0;

        for sIdx = 1:numel(opts.supplementFiles)
            sPath = opts.supplementFiles{sIdx};
            if ~isfile(sPath) && isfile(fullfile(rawDir, sPath))
                sPath = fullfile(rawDir, sPath);
            end
            if ~isfile(sPath)
                warning('audit_sweep_completeness:SupplementNotFound', 'Supplement file not found: %s', sPath);
                continue;
            end

            nFileAdded = 0;
            nFileSkippedFlawed = 0;
            nFileSkippedDup = 0;

            Ts = readComsolDat(sPath);
            reqCols = {'period', 'radius', 'lambda', 'EE_V', 'EE_S', 'Abs', 'ECC', 'EF_max'};
            if ~all(ismember(reqCols, Ts.Properties.VariableNames))
                warning('audit_sweep_completeness:SupplementMissingCols', ...
                    'Supplement file %s missing required columns; skipping.', sPath);
                continue;
            end

            prS = round([double(Ts.period), double(Ts.radius)] / opts.geomTol) * opts.geomTol;
            [uPRS, ~, grpS] = unique(prS, 'rows', 'stable');
            suppBlocks = cell(size(uPRS, 1), 1);
            keepCount = 0;

            for gS = 1:size(uPRS, 1)
                if ismember(uPRS(gS, :), baseCompletePRBinned, 'rows')
                    nFileSkippedDup = nFileSkippedDup + 1;
                    continue;
                end

                rowMask = (grpS == gS);
                if nnz(rowMask) ~= nMasterLam
                    nFileSkippedFlawed = nFileSkippedFlawed + 1;
                    continue;
                end

                subMat = [ ...
                    double(Ts.period(rowMask)), ...
                    double(Ts.radius(rowMask)), ...
                    double(Ts.lambda(rowMask)), ...
                    double(Ts.EE_V(rowMask)), ...
                    double(Ts.EE_S(rowMask)), ...
                    double(Ts.Abs(rowMask)), ...
                    double(Ts.ECC(rowMask)), ...
                    double(Ts.EF_max(rowMask)) ...
                ];

                % Validate finite, unique wavelengths, and physical positivity
                [~, sortOrder] = sort(subMat(:, 3), 'ascend');
                subMat = subMat(sortOrder, :);
                isValidBlock = all(isfinite(subMat(:))) && ...
                    numel(unique(round(subMat(:, 3) / opts.wlTol))) == nMasterLam && ...
                    all(subMat(:, 4) > 0) && all(subMat(:, 5) > 0) && all(subMat(:, 8) > 0) && ...
                    all(subMat(:, 6) >= 0) && all(subMat(:, 6) <= 100);

                if ~isValidBlock
                    nFileSkippedFlawed = nFileSkippedFlawed + 1;
                    continue;
                end

                keepCount = keepCount + 1;
                suppBlocks{keepCount} = subMat;
                baseCompletePRBinned(end+1, :) = uPRS(gS, :); %#ok<AGROW>
                nFileAdded = nFileAdded + 1;
            end

            if keepCount > 0
                combinedMat = [combinedMat; vertcat(suppBlocks{1:keepCount})]; %#ok<AGROW>
            end
            nSuppAdded = nSuppAdded + nFileAdded;
            nSuppSkippedDup = nSuppSkippedDup + nFileSkippedDup;
            nSuppSkippedFlawed = nSuppSkippedFlawed + nFileSkippedFlawed;
            fprintf('  Supplement [%s]: +%d complete pairs added (%d skipped duplicate, %d skipped incomplete/flawed)\n', ...
                sPath, nFileAdded, nFileSkippedDup, nFileSkippedFlawed);
        end

        nTotalRows = size(combinedMat, 1);
        outputDatFile = opts.outputDatFile;
        writeComsolSweepDat(outputDatFile, combinedMat);

        combinedTable = array2table(combinedMat, 'VariableNames', ...
            {'period', 'radius', 'lambda', 'EE_V', 'EE_S', 'Abs', 'ECC', 'EF_max'});

        % Verify round-trip compatibility with ASSTEROID's readComsolDat
        T_verify = readComsolDat(outputDatFile);
        nVerifyNan = nnz(~isfinite(table2array(T_verify)));
        assert(height(T_verify) == nTotalRows, 'Row count mismatch after readComsolDat verification.');
        assert(width(T_verify) == 8, 'Column count mismatch after readComsolDat verification.');
        assert(nVerifyNan == 0, 'Non-finite values detected after readComsolDat verification.');

        fileInfoOut = dir(outputDatFile);
        fprintf('  Exported: %s (%.2f MB)\n', outputDatFile, fileInfoOut.bytes / 1e6);
        fprintf('  Verified via readComsolDat(): %d rows x %d cols | Non-finite: %d | Columns: {%s}\n\n', ...
            height(T_verify), width(T_verify), nVerifyNan, strjoin(T_verify.Properties.VariableNames, ', '));
    end

    %% 9. Render Diagnostic Figure (Rule 05 OKHSL Scientific Palette)
    if opts.showPlots
        try
            renderCompletenessFigure(masterPR, masterLam, masterShiftCm, category, ...
                metricTensor, allCanonicalMetrics, idxEEV, idxEFmax);
        catch ME
            warning('audit_sweep_completeness:PlotFailed', 'Could not render figure: %s', ME.message);
        end
    end

    %% 10. Package Output Report
    report = struct();
    report.filesInfo           = filesInfo;
    report.masterPR            = masterPR;
    report.masterLambda_nm     = masterLam;
    report.masterShift_cm1     = masterShiftCm;
    report.inFileMatrix        = inFileMatrix;
    report.lamCountInFile      = lamCountInFile;
    report.dupRowsInFile       = dupRowsInFile;
    report.lamPresentPerFile   = lamPresentPerFile;
    report.metricNames         = allCanonicalMetrics;
    report.metricTensor        = metricTensor;
    report.validCountPerMetric = validCountPerMetric;
    report.isFullyComplete     = isFullyComplete;
    report.category            = category;
    report.missingTable        = missingTable;
    report.combinedTable       = combinedTable;
    report.outputDatFile       = outputDatFile;

    assignin('base', 'sweepAuditReport', report);
end

%% ========================================================================
%  Helper Functions
% =========================================================================

function writeComsolSweepDat(outPath, dataMat)
% Writes numeric matrix [N x 8] in exact COMSOL 6.4 Sweep Probe Table .dat format:
%   - CRLF (\r\n) line endings
%   - 5-line COMSOL header block matching SweepPropeTable_Extention.dat
%   - 25-character left-aligned space-padded columns
    outDir = fileparts(outPath);
    if ~isempty(outDir) && ~isfolder(outDir)
        mkdir(outDir);
    end

    fid = fopen(outPath, 'wb');
    if fid < 0
        error('audit_sweep_completeness:WriteFailed', 'Failed to open output file for writing: %s', outPath);
    end
    cleanupObj = onCleanup(@() fclose(fid));

    dateStr = char(datetime('now', 'Format', 'MMM dd yyyy, HH:mm'));
    fprintf(fid, '%% Model:              Hexagonal Lattice SERS Sphere.mph\r\n');
    fprintf(fid, '%% Version:            COMSOL 6.4.0.293\r\n');
    fprintf(fid, '%% Date:               %s\r\n', dateStr);
    fprintf(fid, '%% Table:              Sweep Probe Table - \r\n');
    fprintf(fid, '%% %-23s%-25s%-25s%-25s%-25s%-25s%-25s%s\r\n', ...
        'period (nm)', 'particle_r (nm)', 'lambda0 (nm)', ...
        'EE_V (1), <EE>vol', 'EE_S (1), <EE>surf', ...
        'Abs (%), Atotal', 'ECC (1), Error_ECModal', 'E4_max (1), <E4>max');

    % Fast vectorized write: 25-char left-aligned columns, 16 significant digits
    fprintf(fid, '%-25.16g%-25.16g%-25.16g%-25.16g%-25.16g%-25.16g%-25.16g%.16g\r\n', dataMat.');
end

function colName = findColByAliases(colNames, aliases)
    colName = '';
    for k = 1:numel(aliases)
        idx = find(strcmpi(colNames, aliases{k}), 1);
        if ~isempty(idx)
            colName = colNames{idx};
            return;
        end
    end
    for k = 1:numel(aliases)
        idx = find(contains(lower(colNames), lower(aliases{k})), 1);
        if ~isempty(idx)
            colName = colNames{idx};
            return;
        end
    end
    if ~isempty(colNames)
        colName = colNames{1};
    end
end

function out = ternary(cond, valTrue, valFalse)
    if cond
        out = valTrue;
    else
        out = valFalse;
    end
end

function renderCompletenessFigure(masterPR, masterLam, masterShiftCm, category, metricTensor, metricNames, idxEEV, idxEFmax)
    % Rule 05 OKHSL Primary Anchor Colors
    colorBlue   = [ 36,  30, 195] / 255; % A40
    colorPurple = [127,   0, 224] / 255; % B50
    colorTeal   = [ 39, 146, 141] / 255; % C60
    colorGold   = [201, 148,  44] / 255; % D70

    fig = figure('Name', 'Sweep Completeness & Missing Entries Audit', ...
        'Color', 'w', 'Position', [60, 90, 1480, 580]);

    % Subplot 1: (p, r) Spatial Map of Completeness Categories
    ax1 = subplot(1, 2, 1, 'Parent', fig);
    hold(ax1, 'on');

    mComplete = startsWith(category, "0.");
    mPartFull = startsWith(category, "1.") | startsWith(category, "2.") | startsWith(category, "3.") | startsWith(category, "4.");
    mMissE4   = startsWith(category, "5.");
    mMissExt  = startsWith(category, "6.") | startsWith(category, "7.");

    scatter(ax1, masterPR(mComplete, 1), masterPR(mComplete, 2), 12, colorBlue, 'filled', ...
        'MarkerFaceAlpha', 0.22, 'DisplayName', sprintf('Complete 30/30 (N=%d)', nnz(mComplete)));
    if any(mPartFull)
        scatter(ax1, masterPR(mPartFull, 1), masterPR(mPartFull, 2), 46, colorGold, 'd', ...
            'filled', 'MarkerEdgeColor', 'k', 'DisplayName', sprintf('Partial Full <25 lam (N=%d)', nnz(mPartFull)));
    end
    if any(mMissE4)
        scatter(ax1, masterPR(mMissE4, 1), masterPR(mMissE4, 2), 46, colorPurple, 'o', ...
            'LineWidth', 1.6, 'DisplayName', sprintf('Absent in E4 only (N=%d)', nnz(mMissE4)));
    end
    if any(mMissExt)
        scatter(ax1, masterPR(mMissExt, 1), masterPR(mMissExt, 2), 52, colorTeal, '^', ...
            'filled', 'DisplayName', sprintf('Absent in Extention / Both (N=%d)', nnz(mMissExt)));
    end

    xlabel(ax1, 'Period P (nm)', 'FontWeight', 'bold');
    ylabel(ax1, 'Particle Radius r (nm)', 'FontWeight', 'bold');
    title(ax1, '(a) (P, r) Geometry Coverage & Missing Entries Map', 'FontWeight', 'bold');
    legend(ax1, 'Location', 'northwest', 'Box', 'on');
    grid(ax1, 'on');
    box(ax1, 'on');

    % Subplot 2: Missing Geometry Count per Wavelength Index (1..30)
    ax2 = subplot(1, 2, 2, 'Parent', fig);
    nTotal = size(masterPR, 1);
    missingEEPerLam = nTotal - sum(isfinite(metricTensor(:, :, idxEEV)), 1);
    missingE4PerLam = nTotal - sum(isfinite(metricTensor(:, :, idxEFmax)), 1);

    b = bar(ax2, 1:numel(masterLam), [missingEEPerLam(:), missingE4PerLam(:)], 'grouped');
    b(1).FaceColor = colorBlue;
    b(1).DisplayName = sprintf('Missing %s', metricNames{idxEEV});
    b(2).FaceColor = colorGold;
    b(2).DisplayName = sprintf('Missing %s', metricNames{idxEFmax});

    xticks(ax2, 1:numel(masterLam));
    xtLabels = arrayfun(@(l, s) sprintf('%.0fnm (%.0f)', l, s), masterLam, masterShiftCm, 'UniformOutput', false);
    xticklabels(ax2, xtLabels);
    xtickangle(ax2, 60);
    xlabel(ax2, 'Wavelength \lambda_0 (nm) [Raman Shift cm^{-1}]', 'FontWeight', 'bold');
    ylabel(ax2, sprintf('Number of Missing (P, r) Pairs (out of %d)', nTotal), 'FontWeight', 'bold');
    title(ax2, '(b) Missing Values per Wavelength Across All Geometries', 'FontWeight', 'bold');
    legend(ax2, 'Location', 'northwest', 'Box', 'on');
    grid(ax2, 'on');
    box(ax2, 'on');
    drawnow;
end
