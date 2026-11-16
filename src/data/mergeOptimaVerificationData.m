function [optSim, report] = mergeOptimaVerificationData(dbOptima, newData, existingSim, cfg, analyteSpectrum, metricNames, c)
% mergeOptimaVerificationData  Match a FEM verification sweep to the saved optima.
%
%   [optSim, report] = mergeOptimaVerificationData(dbOptima, newData)
%   [optSim, report] = mergeOptimaVerificationData(dbOptima, newData, existingSim, cfg, ...
%                                                  analyteSpectrum, metricNames, c)
%
%   Builds the db.Optima.Sim branch: a Structure-of-Arrays that is ROW-ALIGNED
%   with db.Optima (row i of db.Optima.Sim is the full-wave FEM ground truth of
%   saved optimum i). Each imported geometry (one row of newData, produced by
%   the Stage 1 import parser) is matched to the nearest saved optimum in the
%   (P, r) plane; it is accepted when the Euclidean distance does not exceed
%   cfg.optimaMatchTolerance (nm). Several optima may share one geometry (e.g.
%   the EE_S_broad and EE_S_analyte optima of the same basin); they then receive
%   identical spectra.
%
%   When existingSim (a previous db.Optima.Sim SoA) is supplied, rows are
%   re-aligned to the current optima by geometry (within cfg.geometryTolerance)
%   and merged with mergeEntryWithNewWavelengths, so a 300-wavelength sweep that
%   arrives in several COMSOL batches is assembled incrementally (union of the
%   wavelength grids, NaN backfill, derived metrics recomputed).
%
%   Inputs:
%       dbOptima        - db.Optima struct (period, radius [nm]; optional basinTag,
%                         optimizedMetric, metricVariant, metricValue).
%       newData         - SoA of imported geometries (period/radius or particle_r,
%                         lambda [N x L], spectral metrics [N x L], scalars).
%       existingSim     - (optional) previous db.Optima.Sim SoA (metadata stripped).
%       cfg             - (optional) import config (optimaMatchTolerance,
%                         geometryTolerance, wavelengthTolerance, ramanWindow, ...).
%       analyteSpectrum - (optional) analyte struct (shift_cm, intensity).
%       metricNames     - (optional) imported metric column names.
%       c               - (optional) speed of light (m/s).
%
%   Outputs:
%       optSim - Row-aligned SoA [nOptima rows] with the imported spectral and
%                scalar fields plus verification metadata:
%                  period, radius        canonical optimum coordinates (= db.Optima)
%                  femPeriod, femRadius  coordinates actually simulated in FEM
%                  matchDistance         Euclidean (P, r) distance in nm
%                  optimaIndex           row index in db.Optima at import time
%                  isVerified            1 if FEM spectra are present, else 0
%                  basinTag, optimizedMetric, metricVariant (strings)
%                  surrogateMetricValue  db.Optima.metricValue (surrogate estimate)
%       report - Matching summary (counts, unmatched optima, unused geometries,
%                match distances, summaryText).
%
%   See also: runImportSweepWorkflow, mergeEntryWithNewWavelengths,
%             computeOptimaFemVerificationMetrics

    arguments
        dbOptima struct
        newData struct
        existingSim struct = struct()
        cfg struct = struct()
        analyteSpectrum struct = struct()
        metricNames = {}
        c (1,1) double = 299792458
    end

    %% 1. Saved optima
    if ~isfield(dbOptima, "period") || ~isfield(dbOptima, "radius") || isempty(dbOptima.period)
        error("mergeOptimaVerificationData:NoOptima", ...
            "db.Optima contains no saved optima. Save the optima in Stage 5 before importing their FEM verification sweep.");
    end
    optP = double(dbOptima.period(:));
    optR = double(dbOptima.radius(:));
    nOpt = numel(optP);
    if numel(optR) ~= nOpt
        error("mergeOptimaVerificationData:InconsistentOptima", ...
            "db.Optima.period (%d) and db.Optima.radius (%d) differ in length.", nOpt, numel(optR));
    end
    basinTag        = stringColumn(dbOptima, "basinTag", nOpt);
    optimizedMetric = stringColumn(dbOptima, "optimizedMetric", nOpt);
    metricVariant   = stringColumn(dbOptima, "metricVariant", nOpt);
    surrogateValue  = numericColumn(dbOptima, "metricValue", nOpt);

    matchTol = getCfg(cfg, "optimaMatchTolerance", 0.5);
    geomTol  = getCfg(cfg, "geometryTolerance", 1e-3);

    %% 2. Imported geometries
    newData = normalizeGeometryFields(newData);
    nFem = 0;
    femP = zeros(0, 1); femR = zeros(0, 1);
    if isfield(newData, "period") && isfield(newData, "radius") && ~isempty(newData.period)
        femP = double(newData.period(:));
        femR = double(newData.radius(:));
        nFem = numel(femP);
    end

    [nearestFem, nearestDist] = nearestNeighbour(optP, optR, femP, femR);
    isMatched = isfinite(nearestDist) & nearestDist <= matchTol;

    %% 3. Existing verification rows (incremental multi-batch import)
    hasExisting = isstruct(existingSim) && isfield(existingSim, "period") ...
        && isfield(existingSim, "radius") && ~isempty(existingSim.period);
    existingIdx = zeros(nOpt, 1);
    if hasExisting
        exP = double(existingSim.period(:));
        exR = double(existingSim.radius(:));
        [nearestEx, distEx] = nearestNeighbour(optP, optR, exP, exR);
        keep = isfinite(distEx) & distEx <= max(geomTol, 1e-9);
        existingIdx(keep) = nearestEx(keep);
    end

    %% 4. Build row-aligned entries
    metaFields = ["period", "radius", "femPeriod", "femRadius", "matchDistance", ...
                  "optimaIndex", "isVerified", "basinTag", "optimizedMetric", ...
                  "metricVariant", "surrogateMetricValue"];
    entries = cell(nOpt, 1);
    for i = 1:nOpt
        oldEntry = struct();
        if existingIdx(i) > 0
            oldEntry = extractEntryStruct(existingSim, existingIdx(i));
        end
        newEntry = struct();
        if isMatched(i)
            newEntry = extractEntryStruct(newData, nearestFem(i));
        end

        hasOld = ~isempty(fieldnames(oldEntry)) && hasSpectralData(oldEntry);
        hasNew = ~isempty(fieldnames(newEntry));

        femPi = NaN; femRi = NaN; distI = NaN;
        if hasOld
            femPi = scalarField(oldEntry, "femPeriod", NaN);
            femRi = scalarField(oldEntry, "femRadius", NaN);
            distI = scalarField(oldEntry, "matchDistance", NaN);
        end
        if hasNew
            femPi = scalarField(newEntry, "period", NaN);
            femRi = scalarField(newEntry, "radius", NaN);
            distI = nearestDist(i);
        end

        if hasOld && hasNew
            oldEntry = stripFields(oldEntry, metaFields);
            [entry, ~] = mergeEntryWithNewWavelengths(oldEntry, newEntry, cfg, analyteSpectrum, metricNames, c);
        elseif hasNew
            entry = newEntry;
        elseif hasOld
            entry = stripFields(oldEntry, metaFields);
        else
            entry = struct();
        end

        entry.period               = optP(i);
        entry.radius               = optR(i);
        entry.femPeriod            = femPi;
        entry.femRadius            = femRi;
        entry.matchDistance        = distI;
        entry.optimaIndex          = i;
        entry.isVerified           = double(hasOld || hasNew);
        entry.basinTag             = basinTag(i);
        entry.optimizedMetric      = optimizedMetric(i);
        entry.metricVariant        = metricVariant(i);
        entry.surrogateMetricValue = surrogateValue(i);
        entries{i} = entry;
    end

    %% 5. Assemble SoA (append_entry_struct pads differing wavelength counts with NaN)
    optSim = struct();
    for i = 1:nOpt
        optSim = append_entry_struct(optSim, entries{i});
    end

    %% 6. Matching report
    usedFem = unique(nearestFem(isMatched));
    unusedFem = setdiff((1:nFem)', usedFem(:));
    [~, uniqueOptGeomIdx] = unique(round([optP, optR] / max(geomTol, 1e-9)), "rows", "stable");

    report = struct();
    report.nOptima                 = nOpt;
    report.nUniqueOptimaGeometries = numel(uniqueOptGeomIdx);
    report.nImportedGeometries     = nFem;
    report.nMatchedThisImport      = nnz(isMatched);
    report.nVerified               = nnz(cellfun(@(e) e.isVerified, entries));
    report.nUnusedGeometries       = numel(unusedFem);
    report.matchTolerance          = matchTol;
    report.maxMatchDistanceNm      = maxOrNaN(nearestDist(isMatched));
    report.medianMatchDistanceNm   = medianOrNaN(nearestDist(isMatched));

    missing = find(~isMatched & existingIdx == 0);
    report.unmatchedOptima = table(missing(:), basinTag(missing), optimizedMetric(missing), ...
        optP(missing), optR(missing), nearestDist(missing), ...
        'VariableNames', {'OptimaIndex', 'BasinTag', 'OptimizedMetric', 'PeriodNm', 'RadiusNm', 'NearestFemDistNm'});

    unusedNearestOpt = zeros(numel(unusedFem), 1);
    unusedNearestDist = nan(numel(unusedFem), 1);
    if ~isempty(unusedFem)
        [unusedNearestOpt, unusedNearestDist] = nearestNeighbour(femP(unusedFem), femR(unusedFem), optP, optR);
    end
    report.unusedGeometries = table(femP(unusedFem), femR(unusedFem), unusedNearestOpt, unusedNearestDist, ...
        'VariableNames', {'PeriodNm', 'RadiusNm', 'NearestOptimaIndex', 'NearestOptimumDistNm'});

    report.summaryText = buildSummary(report);
end

%% ========================================================================
%  Local helpers
%  ========================================================================

function [idx, dist] = nearestNeighbour(qP, qR, refP, refR)
%nearestNeighbour  Nearest reference geometry for every query geometry.
    nQ = numel(qP);
    idx = zeros(nQ, 1);
    dist = inf(nQ, 1);
    if isempty(refP)
        return;
    end
    for i = 1:nQ
        d = hypot(refP - qP(i), refR - qR(i));
        [dMin, j] = min(d);
        if isfinite(dMin)
            idx(i) = j;
            dist(i) = dMin;
        end
    end
end

function tf = hasSpectralData(entry)
    tf = false;
    if isfield(entry, "isVerified") && isnumeric(entry.isVerified) && ~isempty(entry.isVerified)
        tf = entry.isVerified(1) > 0;
        if ~tf, return; end
    end
    if isfield(entry, "lambda")
        tf = any(isfinite(double(entry.lambda(:))));
    end
end

function S = stripFields(S, names)
    for k = 1:numel(names)
        if isfield(S, names(k))
            S = rmfield(S, names(k));
        end
    end
end

function v = scalarField(S, name, defaultVal)
    v = defaultVal;
    if isfield(S, name) && isnumeric(S.(name)) && ~isempty(S.(name))
        v = double(S.(name)(1));
    end
end

function col = stringColumn(S, name, n)
    col = strings(n, 1);
    if isfield(S, name) && ~isempty(S.(name))
        vals = string(S.(name)(:));
        m = min(n, numel(vals));
        col(1:m) = vals(1:m);
    end
    col(ismissing(col)) = "";
end

function col = numericColumn(S, name, n)
    col = nan(n, 1);
    if isfield(S, name) && isnumeric(S.(name)) && ~isempty(S.(name))
        vals = double(S.(name)(:));
        m = min(n, numel(vals));
        col(1:m) = vals(1:m);
    end
end

function v = getCfg(cfg, name, defaultVal)
    v = defaultVal;
    if isfield(cfg, name) && isnumeric(cfg.(name)) && isscalar(cfg.(name)) ...
            && isfinite(cfg.(name)) && cfg.(name) > 0
        v = double(cfg.(name));
    end
end

function v = maxOrNaN(x)
    if isempty(x), v = NaN; else, v = max(x); end
end

function v = medianOrNaN(x)
    if isempty(x), v = NaN; else, v = median(x); end
end

function txt = buildSummary(r)
    lines = strings(0, 1);
    lines(end+1) = sprintf("Optima FEM verification import: %d/%d saved optima verified (%d unique geometries).", ...
        r.nVerified, r.nOptima, r.nUniqueOptimaGeometries);
    lines(end+1) = sprintf("  Imported geometries: %d | matched to optima in this import: %d optima rows | unused geometries: %d.", ...
        r.nImportedGeometries, r.nMatchedThisImport, r.nUnusedGeometries);
    if isfinite(r.maxMatchDistanceNm)
        lines(end+1) = sprintf("  Match distance (P, r): median %.3g nm, max %.3g nm (tolerance %.3g nm).", ...
            r.medianMatchDistanceNm, r.maxMatchDistanceNm, r.matchTolerance);
    end
    if height(r.unmatchedOptima) > 0
        tags = r.unmatchedOptima.BasinTag + "/" + r.unmatchedOptima.OptimizedMetric;
        lines(end+1) = sprintf("  WARNING: %d optima have no FEM verification data: %s", ...
            height(r.unmatchedOptima), strjoin(tags(1:min(end, 12)), ", "));
    end
    if r.nUnusedGeometries > 0
        lines(end+1) = sprintf("  WARNING: %d imported geometries match no saved optimum within %.3g nm (nearest distance up to %.3g nm).", ...
            r.nUnusedGeometries, r.matchTolerance, max(r.unusedGeometries.NearestOptimumDistNm));
    end
    txt = strjoin(lines, newline);
end
