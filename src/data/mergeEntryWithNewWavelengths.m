function [mergedEntry, isUpdated] = mergeEntryWithNewWavelengths(oldEntry, newEntry, varargin)
% mergeEntryWithNewWavelengths Schema-aware fine-grained merge of spectral curves and metrics.
%
%   [mergedEntry, isUpdated] = mergeEntryWithNewWavelengths(oldEntry, newEntry, cfg, analyteSpectrum, metricNames, c)
%
%   Merges newEntry into oldEntry for matching geometry (p, r). Features:
%     1. Wavelength grid: union of old and new wavelengths sorted ascending with tolerance.
%     2. Selective metric update: only metrics in metricNames (from the import table)
%        update corresponding (p, r, lambda) values; untouched metrics keep their values.
%     3. NaN preservation & backfill: older entries for new metrics are filled with NaNs;
%        subsequent batches backfill missing NaNs without overwriting valid data.
%     4. Dynamic derived metrics: automatically recomputes _laser, _broad (_avg), and _analyte
%        for all active spectral metrics (including new metrics like E4).
%
%   Legacy signature compatibility:
%     mergedEntry = mergeEntryWithNewWavelengths(oldEntry, newEntry, ramanWindow, interpSamples)
%
%   See also: runImportSweepWorkflow, update_entry_in_soa, extractEntryStruct

    isUpdated = false;

    if isempty(oldEntry) || ~isstruct(oldEntry)
        mergedEntry = newEntry;
        isUpdated = true;
        return;
    end
    if isempty(newEntry) || ~isstruct(newEntry)
        mergedEntry = oldEntry;
        isUpdated = false;
        return;
    end

    %% Parse optional arguments (modern vs. legacy signature)
    cfg = struct();
    analyteSpectrum = struct();
    metricNames = {};
    c = 299792458;

    if nargin >= 3 && isstruct(varargin{1})
        % Modern signature: (oldEntry, newEntry, cfg, analyteSpectrum, metricNames, c)
        cfg = varargin{1};
        if nargin >= 4 && isstruct(varargin{2})
            analyteSpectrum = varargin{2};
        end
        if nargin >= 5 && (iscell(varargin{3}) || isstring(varargin{3}))
            metricNames = cellstr(varargin{3});
        end
        if nargin >= 6 && isnumeric(varargin{4}) && isscalar(varargin{4})
            c = double(varargin{4});
        end
    elseif nargin >= 3 && isnumeric(varargin{1})
        % Legacy signature: (oldEntry, newEntry, ramanWindow, interpSamples)
        cfg.ramanWindow = varargin{1};
        if nargin >= 4 && isnumeric(varargin{2})
            cfg.interpResolution = (cfg.ramanWindow(2) - cfg.ramanWindow(1)) / max(2, varargin{2});
        end
        cfg.replaceExisting = true;
        cfg.wavelengthTolerance = 1e-4;
    end

    tol = 1e-4;
    if isfield(cfg, "wavelengthTolerance") && isfinite(cfg.wavelengthTolerance) && cfg.wavelengthTolerance > 0
        tol = double(cfg.wavelengthTolerance);
    end

    replaceExisting = false;
    if isfield(cfg, "replaceExisting")
        replaceExisting = logical(cfg.replaceExisting);
    end
    recalculateExisting = false;
    if isfield(cfg, "recalculateExisting")
        recalculateExisting = logical(cfg.recalculateExisting);
    end

    %% 1. Sanitize & extract wavelength vectors
    oldLambda = sanitizeLambdaVector(oldEntry);
    newLambda = sanitizeLambdaVector(newEntry);

    if isempty(oldLambda) && isempty(newLambda)
        mergedEntry = preferNonEmptyFields(oldEntry, newEntry);
        isUpdated = true;
        return;
    elseif isempty(oldLambda)
        mergedEntry = newEntry;
        isUpdated = true;
        return;
    elseif isempty(newLambda)
        mergedEntry = oldEntry;
        isUpdated = false;
        return;
    end

    oldLambda = double(oldLambda(:)');
    newLambda = double(newLambda(:)');

    %% 2. Construct sorted union of wavelengths with tolerance
    combined = [oldLambda(:); newLambda(:)];
    combinedSorted = sort(combined);
    mergedLambda = [];
    for i = 1:numel(combinedSorted)
        lam = combinedSorted(i);
        if isempty(mergedLambda) || abs(lam - mergedLambda(end)) > tol
            mergedLambda(end+1) = lam; %#ok<AGROW>
        end
    end
    mergedLambda = mergedLambda(:)';
    nMerged = numel(mergedLambda);

    if nMerged > numel(oldLambda)
        isUpdated = true;
    end

    %% 3. Identify all spectral metric fields
    reserved = {'period', 'radius', 'p', 'r', 'gap', 'thickness', 'angle', ...
                'height', 'pitch', 'particle_r', 'diameter', ...
                'lambda', 'lambda_nm', 'lambda0', 'f', 'RamanShift', ...
                'RamanWindow', 'RamanWindowEffective', 'LaserWl', 'lambda_exc_nm', ...
                'kappa_V', 'kappa_S', 'VolCorr', 'SurfCorr', 'V_corr', 'S_corr', ...
                'StokesWindow', 'Shifts', 'Source', 'Parent', 'Method', 'ModelRef', ...
                'AnalyteSpectrum', 'AnalyteShifts'};

    oldSpectral = {};
    oldFlds = fieldnames(oldEntry);
    for k = 1:numel(oldFlds)
        fn = oldFlds{k};
        if ismember(fn, reserved) || isDerivedVariantName(fn)
            continue;
        end
        val = oldEntry.(fn);
        if (isnumeric(val) || islogical(val)) && numel(val) == numel(oldLambda)
            oldSpectral{end+1} = fn; %#ok<AGROW>
        end
    end

    newSpectral = {};
    newFlds = fieldnames(newEntry);
    for k = 1:numel(newFlds)
        fn = newFlds{k};
        if ismember(fn, reserved) || isDerivedVariantName(fn)
            continue;
        end
        val = newEntry.(fn);
        if (isnumeric(val) || islogical(val)) && numel(val) == numel(newLambda)
            newSpectral{end+1} = fn; %#ok<AGROW>
        end
    end

    if ~isempty(metricNames)
        for k = 1:numel(metricNames)
            mn = metricNames{k};
            if isfield(newEntry, mn) && ~ismember(mn, newSpectral) && ~ismember(mn, reserved)
                newSpectral{end+1} = mn; %#ok<AGROW>
            end
        end
    end

    allSpectralFields = unique([oldSpectral, newSpectral]);

    %% 4. Initialize merged entry with metadata from oldEntry
    mergedEntry = oldEntry;

    % Update input parameters and geometric loading factors from newEntry if present
    updateScalars = {'period', 'radius', 'p', 'r', 'kappa_V', 'kappa_S', 'VolCorr', 'SurfCorr'};
    for k = 1:numel(updateScalars)
        fn = updateScalars{k};
        if isfield(newEntry, fn) && ~isempty(newEntry.(fn)) && isfinite(newEntry.(fn)(1))
            mergedEntry.(fn) = newEntry.(fn);
        end
    end

    %% 5. Merge each spectral metric field with fine-grained coordinate replacement
    for k = 1:numel(allSpectralFields)
        fn = allSpectralFields{k};
        mergedData = nan(1, nMerged);

        % Populate from oldEntry
        hasOld = isfield(oldEntry, fn) && isnumeric(oldEntry.(fn));
        if hasOld
            oldVals = double(ensureRowVector(oldEntry.(fn)));
            for i = 1:numel(oldLambda)
                idxM = find(abs(mergedLambda - oldLambda(i)) <= tol, 1);
                if ~isempty(idxM) && i <= numel(oldVals)
                    mergedData(idxM) = oldVals(i);
                end
            end
        else
            % Field is new to this entry!
            isUpdated = true;
        end

        % Update from newEntry only if field is in the incoming import
        hasNew = isfield(newEntry, fn) && isnumeric(newEntry.(fn));
        isImported = isempty(metricNames) || any(strcmp(fn, metricNames));

        if hasNew && isImported
            newVals = double(ensureRowVector(newEntry.(fn)));
            for j = 1:numel(newLambda)
                idxM = find(abs(mergedLambda - newLambda(j)) <= tol, 1);
                if isempty(idxM) || j > numel(newVals)
                    continue;
                end
                vNew = newVals(j);
                existedInOld = any(abs(oldLambda - newLambda(j)) <= tol);

                if ~existedInOld
                    % New wavelength coordinate
                    if ~isnan(vNew)
                        mergedData(idxM) = vNew;
                        isUpdated = true;
                    end
                else
                    % Overlapping wavelength coordinate (e.g. laser wl, or NaN backfill)
                    if isnan(mergedData(idxM))
                        if ~isnan(vNew)
                            mergedData(idxM) = vNew;
                            isUpdated = true;
                        end
                    elseif replaceExisting || recalculateExisting
                        if ~isnan(vNew) && (isnan(mergedData(idxM)) || abs(mergedData(idxM) - vNew) > eps(vNew))
                            mergedData(idxM) = vNew;
                            isUpdated = true;
                        end
                    end
                end
            end
        end

        mergedEntry.(fn) = mergedData;
    end

    %% 6. Synchronize legacy metric aliases if present
    aliasPairs = {
        'EE_V', 'EF_vol';
        'EE_S', 'EF_surf';
        'Abs',  'Absorptance';
        'ECC',  'ECCheck'
    };
    for a = 1:size(aliasPairs, 1)
        f1 = aliasPairs{a, 1};
        f2 = aliasPairs{a, 2};
        if isfield(mergedEntry, f1) && isfield(mergedEntry, f2)
            v1 = ensureRowVector(mergedEntry.(f1));
            v2 = ensureRowVector(mergedEntry.(f2));
            if numel(v1) == nMerged && numel(v2) == nMerged
                nan1 = isnan(v1);
                nan2 = isnan(v2);
                v1(nan1 & ~nan2) = v2(nan1 & ~nan2);
                v2(~nan1 & nan2) = v1(~nan1 & nan2);
                mergedEntry.(f1) = v1;
                mergedEntry.(f2) = v2;
            elseif numel(v1) == nMerged
                mergedEntry.(f2) = v1;
            elseif numel(v2) == nMerged
                mergedEntry.(f1) = v2;
            end
        elseif isfield(mergedEntry, f1) && ~isfield(mergedEntry, f2)
            mergedEntry.(f2) = mergedEntry.(f1);
        elseif ~isfield(mergedEntry, f1) && isfield(mergedEntry, f2)
            mergedEntry.(f1) = mergedEntry.(f2);
        end
    end

    %% 7. Laser wavelength & Raman shift recomputation
    laserWl_nm = NaN;
    if isfield(oldEntry, "LaserWl") && ~isempty(oldEntry.LaserWl) && isfinite(oldEntry.LaserWl(1))
        laserWl_nm = double(oldEntry.LaserWl(1));
    elseif isfield(newEntry, "LaserWl") && ~isempty(newEntry.LaserWl) && isfinite(newEntry.LaserWl(1))
        laserWl_nm = double(newEntry.LaserWl(1));
    elseif isfield(cfg, "laserWavelength") && isfinite(cfg.laserWavelength)
        laserWl_nm = double(cfg.laserWavelength);
    else
        laserWl_nm = min(mergedLambda);
    end
    if laserWl_nm < 1
        laserWl_nm = laserWl_nm * 1e9; % meters to nm
    end

    mergedEntry.lambda = mergedLambda;
    mergedEntry.lambda_nm = mergedLambda;
    lambda_m = mergedLambda * 1e-9;
    mergedEntry.f = c ./ lambda_m;
    mergedEntry.LaserWl = laserWl_nm;
    mergedEntry.lambda_exc_nm = laserWl_nm;

    RamanShift_cm = (1 ./ (laserWl_nm * 1e-9) - 1 ./ lambda_m) / 100;
    mergedEntry.RamanShift = RamanShift_cm;

    ramanWindow = [100, 3600];
    if isfield(cfg, "ramanWindow") && numel(cfg.ramanWindow) == 2
        ramanWindow = double(cfg.ramanWindow);
    end
    mergedEntry.RamanWindow = ramanWindow;
    shiftMin = ramanWindow(1);
    shiftMax = ramanWindow(2);
    mergedEntry.RamanWindowEffective = [shiftMin, shiftMax];

    %% 8. Derived scalar variants (_laser, _broad, _analyte) for all metrics
    [~, laserIdx] = min(abs(mergedLambda - laserWl_nm));
    stokesWindowMask = (RamanShift_cm > 0) & (RamanShift_cm >= shiftMin) & (RamanShift_cm <= shiftMax);
    shiftRange = shiftMax - shiftMin;

    interpRes = 1;
    if isfield(cfg, "interpResolution") && isfinite(cfg.interpResolution) && cfg.interpResolution > 0
        interpRes = double(cfg.interpResolution);
    end
    interpSamples = max(2, round(shiftRange / interpRes));

    interpMethod = "makima";
    if isfield(cfg, "spectralInterpMethod") && strlength(string(cfg.spectralInterpMethod)) > 0
        interpMethod = string(cfg.spectralInterpMethod);
    end

    hasValidAnalyte = isstruct(analyteSpectrum) && ...
        isfield(analyteSpectrum, "shift_cm") && ~isempty(analyteSpectrum.shift_cm);

    allMergedFlds = fieldnames(mergedEntry);
    for k = 1:numel(allMergedFlds)
        fn = allMergedFlds{k};
        if ismember(fn, reserved) || isDerivedVariantName(fn)
            continue;
        end
        data = mergedEntry.(fn);
        if ~isnumeric(data) || numel(data) ~= nMerged
            continue;
        end

        % Laser-line variant
        mergedEntry.(fn + "_laser") = data(laserIdx);

        % Broadband variant
        validStokes = stokesWindowMask & isfinite(data);
        if nnz(validStokes) >= 2 && shiftRange > 0
            rs = RamanShift_cm(validStokes);
            dvals = data(validStokes);
            [rs, sOrd] = sort(rs);
            dvals = dvals(sOrd);
            shiftDense = linspace(shiftMin, shiftMax, interpSamples);
            dense = safeInterpolateLocal(rs, dvals, shiftDense, interpMethod);
            denom = shiftDense(end) - shiftDense(1);
            if denom > 0
                bVal = trapz(shiftDense, dense) / denom;
            else
                bVal = mean(dense, 'omitnan');
            end
            mergedEntry.(fn + "_broad") = bVal;
            mergedEntry.(fn + "_avg")   = bVal;
        elseif isfinite(data(laserIdx))
            mergedEntry.(fn + "_broad") = data(laserIdx);
            mergedEntry.(fn + "_avg")   = data(laserIdx);
        else
            mergedEntry.(fn + "_broad") = NaN;
            mergedEntry.(fn + "_avg")   = NaN;
        end

        % Analyte-weighted variant
        if hasValidAnalyte && nnz(validStokes) >= 2 && shiftRange > 0
            rs = RamanShift_cm(validStokes);
            dvals = data(validStokes);
            [rs, sOrd] = sort(rs);
            dvals = dvals(sOrd);
            shiftDense = linspace(shiftMin, shiftMax, interpSamples);
            dense = safeInterpolateLocal(rs, dvals, shiftDense, interpMethod);
            mergedEntry.(fn + "_analyte") = computeAnalyteWeightedMetric(shiftDense, dense, analyteSpectrum);
        else
            mergedEntry.(fn + "_analyte") = NaN;
        end
    end
end

%% ========================================================================
%  LOCAL HELPERS
%  ========================================================================

function tf = isDerivedVariantName(fn)
    fn = char(fn);
    tf = endsWith(fn, '_laser') || endsWith(fn, '_broad') || ...
         endsWith(fn, '_avg') || endsWith(fn, '_analyte');
end

function out = preferNonEmptyFields(eA, eB)
    out = eA;
    fldsB = fieldnames(eB);
    for i = 1:numel(fldsB)
        fn = fldsB{i};
        if ~isfield(out, fn) || isempty(out.(fn))
            out.(fn) = eB.(fn);
        end
    end
end

function dense = safeInterpolateLocal(rs, data, shiftDense, method)
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
