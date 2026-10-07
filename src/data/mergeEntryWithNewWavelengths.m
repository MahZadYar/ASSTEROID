function mergedEntry = mergeEntryWithNewWavelengths(oldEntry, newEntry, ramanWindow, interpSamples)
% mergeEntryWithNewWavelengths  Insert new spectral samples into an existing entry.

tolNm = 1e-6;
oldLambda = sanitizeLambdaVector(oldEntry);
newLambda = sanitizeLambdaVector(newEntry);

if isempty(oldLambda)
    mergedEntry = newEntry;
    return;
end
if isempty(newLambda)
    mergedEntry = oldEntry;
    return;
end

baseFields = {'EF_vol','EF_surf','E_vol','E_surf','M_vol','M_surf', ...
    'M2_vol','M2_surf','intW_vol','intW_t','Absorptance','Reflectance', ...
    'Transmittance','ECCheck','SkinDepth','ResistiveLoss'};

oldLambdaRow = ensureRowVector(getFieldSafe(oldEntry, 'lambda'));
oldMask = ~isnan(oldLambdaRow);
idxOldValid = oldMask;

newLambdaRow = ensureRowVector(getFieldSafe(newEntry, 'lambda'));
newMask = ~isnan(newLambdaRow);
idxNewValid = newMask;

combinedLambda = oldLambda;
combinedData = struct();
for k = 1:numel(baseFields)
    fn = baseFields{k};
    oldVals = ensureRowVector(getFieldSafe(oldEntry, fn));
    oldVals = padRowToLength(oldVals, numel(oldMask));
    combinedData.(fn) = oldVals(idxOldValid);
end

newData = struct();
for k = 1:numel(baseFields)
    fn = baseFields{k};
    newVals = ensureRowVector(getFieldSafe(newEntry, fn));
    newVals = padRowToLength(newVals, numel(newMask));
    newData.(fn) = newVals(idxNewValid);
end

for i = 1:numel(newLambda)
    lam = newLambda(i);
    idx = find(abs(combinedLambda - lam) <= tolNm, 1);
    if isempty(idx)
        combinedLambda(end+1) = lam; %#ok<AGROW>
        for k = 1:numel(baseFields)
            fn = baseFields{k};
            combinedData.(fn)(end+1) = newData.(fn)(i);
        end
    else
        for k = 1:numel(baseFields)
            fn = baseFields{k};
            combinedData.(fn)(idx) = newData.(fn)(i);
        end
    end
end

[lambdaSorted, sortIdx] = sort(combinedLambda);
for k = 1:numel(baseFields)
    fn = baseFields{k};
    combinedData.(fn) = combinedData.(fn)(sortIdx);
end

if isempty(lambdaSorted)
    mergedEntry = newEntry;
    return;
end

lambdaSorted_m = lambdaSorted * 1e-9;
c0 = 299792458;
f_sorted = c0 ./ lambdaSorted_m;

% Determine laser wavelength (nm) from stored metadata, NOT from min(lambda)
laserWl_nm = getFieldSafe(oldEntry, 'LaserWl');
if isempty(laserWl_nm) || ~isfinite(laserWl_nm)
    laserWl_nm = getFieldSafe(newEntry, 'LaserWl');
end
if isempty(laserWl_nm) || ~isfinite(laserWl_nm)
    % Legacy files stored LaserWl in meters — detect and convert
    laserWl_nm = getFieldSafe(oldEntry, 'lambda_exc_nm');
    if isempty(laserWl_nm) || ~isfinite(laserWl_nm)
        warning('mergeEntryWithNewWavelengths:NoLaserWl', ...
            'No LaserWl metadata found; falling back to nearest column to min(lambda).');
        laserWl_nm = min(lambdaSorted);
    end
end
laserWl_nm = double(laserWl_nm(1));

% If stored value looks like meters (< 1), convert to nm
if laserWl_nm < 1
    laserWl_nm = laserWl_nm * 1e9;
end

RamanShift_cm = (1./(laserWl_nm * 1e-9) - 1./(lambdaSorted * 1e-9)) / 100;
[~, laserIdx] = min(abs(RamanShift_cm));

EF_vol_sorted = combinedData.EF_vol;
EF_surf_sorted = combinedData.EF_surf;
E_vol_sorted = combinedData.E_vol;
E_surf_sorted = combinedData.E_surf;
M_vol_sorted = combinedData.M_vol;
M_surf_sorted = combinedData.M_surf;
M2_vol_sorted = combinedData.M2_vol;
M2_surf_sorted = combinedData.M2_surf;
intW_vol_sorted = combinedData.intW_vol;
intW_t_sorted = combinedData.intW_t;
absorptance_sorted = combinedData.Absorptance;
reflectance_sorted = combinedData.Reflectance;
transmittance_sorted = combinedData.Transmittance;
ECCheck_sorted = combinedData.ECCheck;
skinDepth_sorted = combinedData.SkinDepth;
resistiveLoss_sorted = combinedData.ResistiveLoss;

% Derived spectral combinations
M_vol_laser = M_vol_sorted(laserIdx);
M_surf_laser = M_surf_sorted(laserIdx);
Absorptance_laser = absorptance_sorted(laserIdx);
EF_vol_M_sorted = (M_vol_laser .* M_vol_sorted(:))';
EF_surf_M_sorted = (M_surf_laser .* M_surf_sorted(:))';
EF_Abs_sorted = (Absorptance_laser .* absorptance_sorted(:))';

stokesAvail = RamanShift_cm(RamanShift_cm > 0);
if isempty(stokesAvail)
    shiftMin = NaN;
    shiftMax = NaN;
else
    shiftMin = max(ramanWindow(1), min(stokesAvail));
    shiftMax = min(ramanWindow(2), max(stokesAvail));
end

EF_vol_avg = NaN;
EF_surf_avg = NaN;
Absorptance_avg = NaN;
EF_vol_M_avg = NaN;
EF_surf_M_avg = NaN;
EF_Abs_avg = NaN;
stokesWindowMask = isfinite(shiftMin) & isfinite(shiftMax) & (RamanShift_cm > 0) & (RamanShift_cm >= shiftMin) & (RamanShift_cm <= shiftMax);
if nnz(stokesWindowMask) >= 2 && (shiftMax - shiftMin) > 0
    shiftDense = linspace(shiftMin, shiftMax, interpSamples);
    rs = RamanShift_cm(stokesWindowMask);
    [rs, rsOrd] = sort(rs);

    ev = EF_vol_sorted(stokesWindowMask); ev = ev(rsOrd);
    es = EF_surf_sorted(stokesWindowMask); es = es(rsOrd);
    ab = absorptance_sorted(stokesWindowMask); ab = ab(rsOrd);
    evm = EF_vol_M_sorted(stokesWindowMask); evm = evm(rsOrd);
    esm = EF_surf_M_sorted(stokesWindowMask); esm = esm(rsOrd);
    eab = EF_Abs_sorted(stokesWindowMask); eab = eab(rsOrd);

    ev_dense = pchip(rs, ev, shiftDense);
    es_dense = pchip(rs, es, shiftDense);
    EF_vol_avg = trapz(shiftDense, ev_dense) / (shiftDense(end) - shiftDense(1));
    EF_surf_avg = trapz(shiftDense, es_dense) / (shiftDense(end) - shiftDense(1));

    abs_dense = pchip(rs, ab, shiftDense);
    Absorptance_avg = trapz(shiftDense, abs_dense) / (shiftDense(end) - shiftDense(1));

    evm_dense = pchip(rs, evm, shiftDense);
    esm_dense = pchip(rs, esm, shiftDense);
    eabs_dense = pchip(rs, eab, shiftDense);
    EF_vol_M_avg = trapz(shiftDense, evm_dense) / (shiftDense(end) - shiftDense(1));
    EF_surf_M_avg = trapz(shiftDense, esm_dense) / (shiftDense(end) - shiftDense(1));
    EF_Abs_avg = trapz(shiftDense, eabs_dense) / (shiftDense(end) - shiftDense(1));
end

mergedEntry = oldEntry;
scalarFieldsFromNew = {'period','radius'};
for k = 1:numel(scalarFieldsFromNew)
    fn = scalarFieldsFromNew{k};
    if isfield(newEntry, fn)
        mergedEntry.(fn) = newEntry.(fn);
    end
end
mergedEntry.lambda = lambdaSorted(:)';
mergedEntry.f = f_sorted(:)';
mergedEntry.RamanShift = RamanShift_cm(:)';
mergedEntry.LaserWl = laserWl_nm;
mergedEntry.RamanWindow = ramanWindow;
mergedEntry.RamanWindowEffective = [shiftMin, shiftMax];
mergedEntry.EF_vol = EF_vol_sorted(:)';
mergedEntry.EF_surf = EF_surf_sorted(:)';
mergedEntry.E_vol = E_vol_sorted(:)';
mergedEntry.E_surf = E_surf_sorted(:)';
mergedEntry.M_vol = M_vol_sorted(:)';
mergedEntry.M_surf = M_surf_sorted(:)';
mergedEntry.M2_vol = M2_vol_sorted(:)';
mergedEntry.M2_surf = M2_surf_sorted(:)';
mergedEntry.intW_vol = intW_vol_sorted(:)';
mergedEntry.intW_t = intW_t_sorted(:)';
mergedEntry.Absorptance = absorptance_sorted(:)';
mergedEntry.Reflectance = reflectance_sorted(:)';
mergedEntry.Transmittance = transmittance_sorted(:)';
mergedEntry.ECCheck = ECCheck_sorted(:)';
mergedEntry.SkinDepth = skinDepth_sorted(:)';
mergedEntry.ResistiveLoss = resistiveLoss_sorted(:)';
mergedEntry.EF_vol_laser = EF_vol_sorted(laserIdx);
mergedEntry.EF_surf_laser = EF_surf_sorted(laserIdx);
mergedEntry.M_vol_laser = M_vol_laser;
mergedEntry.M_surf_laser = M_surf_laser;
mergedEntry.Absorptance_laser = Absorptance_laser;
mergedEntry.EF_vol_M = EF_vol_M_sorted;
mergedEntry.EF_surf_M = EF_surf_M_sorted;
mergedEntry.EF_Abs = EF_Abs_sorted;
mergedEntry.Absorptance_avg = Absorptance_avg;
mergedEntry.EF_vol_avg = EF_vol_avg;
mergedEntry.EF_surf_avg = EF_surf_avg;
mergedEntry.EF_vol_M_avg = EF_vol_M_avg;
mergedEntry.EF_surf_M_avg = EF_surf_M_avg;
mergedEntry.EF_Abs_avg = EF_Abs_avg;
end