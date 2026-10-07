scriptDir = fileparts(mfilename('fullpath'));
addpath(scriptDir);

workDir = pwd;

filename1 = "prl_sweep.mat";
filename2 = "prl_sweep_15wls.mat";
outputFile = "prl_sweep_merged.mat";

db1 = load_all_data(filename1);
db2 = load_all_data(filename2);

entriesMap = combine_entries(db1, db2);
mapKeys = keys(entriesMap);
mapKeys = sort(mapKeys);
numMerged = numel(mapKeys);
mergedEntries = cell(1, numMerged);
for k = 1:numMerged
    mergedEntries{k} = entriesMap(mapKeys{k});
end

allData = struct();
for k = 1:numMerged
    allData = append_entry_struct(allData, mergedEntries{k});
end

if isempty(fieldnames(allData))
    error('No entries merged; verify source MAT files.');
end

entries1 = struct_row_count(db1);
entries2 = struct_row_count(db2);

w = whos('allData');
useV73 = w.bytes > 2e9;
if useV73
    save(outputFile, 'allData', '-v7.3');
else
    save(outputFile, 'allData');
end

fprintf('Merged dataset saved to %s\n Source entries: %d + %d -> %d unique pairs\n', char(outputFile), entries1, entries2, numMerged);

function dataStruct = load_all_data(filename)
if ~isfile(filename)
    error('File not found: %s', filename);
end
S = load(filename, 'allData');
if ~isfield(S, 'allData') || ~isstruct(S.allData)
    error('Missing allData struct in %s', filename);
end
dataStruct = S.allData;
end

function entriesMap = combine_entries(db1, db2)
entriesMap = containers.Map('KeyType', 'char', 'ValueType', 'any');
datasets = {db1, db2};
for d = 1:numel(datasets)
    dataset = datasets{d};
    rowCount = struct_row_count(dataset);
    for idx = 1:rowCount
        entry = extract_entry(dataset, idx);
        key = make_key(entry);
        if isKey(entriesMap, key)
            merged = merge_entries(entriesMap(key), entry);
            entriesMap(key) = merged;
        else
            entriesMap(key) = entry;
        end
    end
end
end

function entry = extract_entry(S, idx)
entry = struct();
flds = fieldnames(S);
for k = 1:numel(flds)
    fn = flds{k};
    val = S.(fn);
    if isempty(val)
        entry.(fn) = [];
        continue;
    end
    if iscell(val)
        if size(val, 2) == 1
            entry.(fn) = val{idx, 1};
        else
            entry.(fn) = val(idx, :);
        end
    else
        subs = repmat({':'}, 1, ndims(val));
        subs{1} = idx;
        slice = squeeze(val(subs{:}));
        entry.(fn) = slice;
    end
end
end

function key = make_key(entry)
if ~isfield(entry, 'p') || ~isfield(entry, 'r')
    error('Entry missing p/r fields.');
end
pVal = double(entry.p(1));
rVal = double(entry.r(1));
key = sprintf('%.15g|%.15g', pVal, rVal);
end

function merged = merge_entries(entryA, entryB)
tolNm = 1e-6;
lambdaA = sanitize_lambda(entryA);
lambdaB = sanitize_lambda(entryB);
lambdaCountA = numel(lambdaA);
lambdaCountB = numel(lambdaB);

if isempty(lambdaA) && isempty(lambdaB)
    merged = prefer_entry(entryA, entryB);
    return;
end

if isempty(lambdaA)
    combinedLambda = lambdaB(:);
elseif isempty(lambdaB)
    combinedLambda = lambdaA(:);
else
    combinedLambda = uniquetol([lambdaA(:); lambdaB(:)], tolNm, 'DataScale', 1);
end
combinedLambda = sort(combinedLambda(:));
combinedLambda = combinedLambda';

baseSpectral = {'EF_vol','EF_surf','E_vol','E_surf','M_vol','M_surf', ...
    'M2_vol','M2_surf','intW_vol','intW_t','Absorptance','Reflectance', ...
    'Transmittance','EnergyCheck','SkinDepth_nm','EF_vol_M','EF_surf_M','EF_Abs'};
spectralFields = baseSpectral;
excludedFields = {'lambda','lambda_nm','f','RamanShift','RamanWindow','RamanWindowEffective', ...
    'p','r','period','particle_r','LaserWl','lambda_exc_nm','Absorptance_avg','EF_vol_avg', ...
    'EF_surf_avg','EF_vol_M_avg','EF_surf_M_avg','EF_Abs_avg','M_vol_laser','M_surf_laser', ...
    'Absorptance_laser','EF_vol_laser','EF_surf_laser'};
candidateFields = unique([fieldnames(entryA); fieldnames(entryB)]);
for i = 1:numel(candidateFields)
    fn = candidateFields{i};
    if ismember(fn, excludedFields)
        continue;
    end
    if should_merge_field(entryA, entryB, fn, lambdaCountA, lambdaCountB)
        spectralFields = append_unique_field(spectralFields, fn);
    end
end

combinedData = struct();
for k = 1:numel(spectralFields)
    fn = spectralFields{k};
    combinedData.(fn) = merge_spectral_field(fn, entryA, entryB, combinedLambda, tolNm);
end

merged = prefer_entry(entryA, entryB);

ramanWindow = pick_raman_window(entryA, entryB);
interpSamples = 300;

lambdaSorted_nm = combinedLambda(:)';
lambdaSorted_m = lambdaSorted_nm * 1e-9;
if isempty(lambdaSorted_nm)
    merged.lambda = [];
    merged.lambda_nm = [];
    merged.f = [];
    merged.RamanShift = [];
    merged.RamanWindow = ramanWindow;
    merged.RamanWindowEffective = [NaN, NaN];
    return;
end

c0 = 299792458;
f_sorted = c0 ./ lambdaSorted_m;

% Determine laser wavelength from stored metadata (prefer entryA).
% Legacy files stored LaserWl in meters; detect and convert.
laserWl_nm = NaN;
for src = {entryA, entryB}
    e = src{1};
    if isfield(e, 'LaserWl') && isfinite(e.LaserWl(1))
        laserWl_nm = double(e.LaserWl(1));
        break;
    end
    if isfield(e, 'lambda_exc_nm') && isfinite(e.lambda_exc_nm(1))
        laserWl_nm = double(e.lambda_exc_nm(1));
        break;
    end
end
if ~isfinite(laserWl_nm)
    laserWl_nm = min(lambdaSorted_nm);  % last-resort fallback
end
if laserWl_nm < 1  % stored in meters — convert
    laserWl_nm = laserWl_nm * 1e9;
end

RamanShift_cm = (1./(laserWl_nm * 1e-9) - 1./lambdaSorted_m) / 100;
[~, laserIdx] = min(abs(RamanShift_cm));

shiftMin = max(ramanWindow(1), min(RamanShift_cm(RamanShift_cm > 0)));
shiftMax = min(ramanWindow(2), max(RamanShift_cm(RamanShift_cm > 0)));

EF_vol_sorted = combinedData.EF_vol;
EF_surf_sorted = combinedData.EF_surf;
M_vol_sorted = combinedData.M_vol;
M_surf_sorted = combinedData.M_surf;
Absorptance_sorted = combinedData.Absorptance;

M_vol_laser = pick_value(M_vol_sorted, laserIdx);
M_surf_laser = pick_value(M_surf_sorted, laserIdx);
Absorptance_laser = pick_value(Absorptance_sorted, laserIdx);

EF_vol_M_sorted = M_vol_laser .* M_vol_sorted;
EF_surf_M_sorted = M_surf_laser .* M_surf_sorted;
EF_Abs_sorted = Absorptance_laser .* Absorptance_sorted;

[EF_vol_avg, EF_surf_avg, Absorptance_avg, EF_vol_M_avg, EF_surf_M_avg, EF_Abs_avg] = ...
    compute_averages(RamanShift_cm, EF_vol_sorted, EF_surf_sorted, Absorptance_sorted, ...
    EF_vol_M_sorted, EF_surf_M_sorted, EF_Abs_sorted, shiftMin, shiftMax, interpSamples);

merged.lambda = lambdaSorted_m;
merged.lambda_nm = lambdaSorted_nm;
merged.f = f_sorted;
merged.RamanShift = RamanShift_cm;
merged.LaserWl = laserWl_nm;
merged.lambda_exc_nm = laserWl_nm;
merged.RamanWindow = ramanWindow;
if shiftMax > shiftMin
    merged.RamanWindowEffective = [shiftMin, shiftMax];
else
    merged.RamanWindowEffective = [NaN, NaN];
end

for k = 1:numel(spectralFields)
    fn = spectralFields{k};
    merged.(fn) = combinedData.(fn);
end

merged.EF_vol_M = EF_vol_M_sorted;
merged.EF_surf_M = EF_surf_M_sorted;
merged.EF_Abs = EF_Abs_sorted;
merged.EF_vol_laser = pick_value(EF_vol_sorted, laserIdx);
merged.EF_surf_laser = pick_value(EF_surf_sorted, laserIdx);
merged.M_vol_laser = M_vol_laser;
merged.M_surf_laser = M_surf_laser;
merged.Absorptance_laser = Absorptance_laser;
merged.Absorptance_avg = Absorptance_avg;
merged.EF_vol_avg = EF_vol_avg;
merged.EF_surf_avg = EF_surf_avg;
merged.EF_vol_M_avg = EF_vol_M_avg;
merged.EF_surf_M_avg = EF_surf_M_avg;
merged.EF_Abs_avg = EF_Abs_avg;
end

function spectralFields = append_unique_field(spectralFields, fn)
if ~any(strcmp(spectralFields, fn))
    spectralFields{end+1} = fn; %#ok<AGROW>
end
end

function vec = sanitize_lambda(entry)
if isfield(entry, 'lambda_nm')
    vec = ensure_row(entry.lambda_nm);
    vec = vec(~isnan(vec));
else
    vec = [];
end
end

function pref = prefer_entry(a, b)
pref = a;
fieldsB = fieldnames(b);
for k = 1:numel(fieldsB)
    fn = fieldsB{k};
    if ~isfield(pref, fn)
        pref.(fn) = b.(fn);
    else
        val = pref.(fn);
        if isempty(val) || (isnumeric(val) && all(isnan(val)))
            pref.(fn) = b.(fn);
        end
    end
end
end

function mergedVals = merge_spectral_field(fieldName, entryA, entryB, combinedLambda, tolNm)
mergedVals = NaN(1, numel(combinedLambda));
lambdaA = sanitize_lambda(entryA);
lambdaB = sanitize_lambda(entryB);
valsA = fetch_spectral(entryA, fieldName, numel(lambdaA));
valsB = fetch_spectral(entryB, fieldName, numel(lambdaB));

for i = 1:numel(lambdaA)
    idx = find(abs(combinedLambda - lambdaA(i)) <= tolNm, 1);
    if isempty(idx)
        continue;
    end
    if ~isnan(valsA(i))
        mergedVals(idx) = valsA(i);
    end
end

for i = 1:numel(lambdaB)
    idx = find(abs(combinedLambda - lambdaB(i)) <= tolNm, 1);
    if isempty(idx)
        continue;
    end
    if ~isnan(valsB(i))
        mergedVals(idx) = valsB(i);
    end
end
end

function vals = fetch_spectral(entry, fieldName, lambdaCount)
if ~isfield(entry, fieldName)
    vals = NaN(1, lambdaCount);
    return;
end
vals = ensure_row(entry.(fieldName));
if lambdaCount == 0
    vals = [];
    return;
end
if numel(vals) < lambdaCount
    vals(end+1:lambdaCount) = NaN;
elseif numel(vals) > lambdaCount
    vals = vals(1:lambdaCount);
end
end

function arr = ensure_row(val)
arr = double(val(:)');
end

function tf = should_merge_field(entryA, entryB, fieldName, lambdaCountA, lambdaCountB)
tf = false;
lenA = field_vector_length(entryA, fieldName);
lenB = field_vector_length(entryB, fieldName);
if lambdaCountA > 1 && lenA >= lambdaCountA
    tf = true;
elseif lambdaCountB > 1 && lenB >= lambdaCountB
    tf = true;
end
end

function len = field_vector_length(entry, fieldName)
len = 0;
if ~isfield(entry, fieldName)
    return;
end
vals = entry.(fieldName);
if ~(isnumeric(vals) || islogical(vals))
    return;
end
vals = ensure_row(vals);
len = numel(vals);
end

function ramanWindow = pick_raman_window(entryA, entryB)
ramanWindow = [100, 3500];
if isfield(entryA, 'RamanWindow') && numel(entryA.RamanWindow) >= 2
    ramanWindow = entryA.RamanWindow(1:2);
end
if isfield(entryB, 'RamanWindow') && numel(entryB.RamanWindow) >= 2 && any(isnan(ramanWindow))
    ramanWindow = entryB.RamanWindow(1:2);
elseif isfield(entryB, 'RamanWindow') && numel(entryB.RamanWindow) >= 2
    % Prefer narrower window if both present.
    ramanWindow = entryB.RamanWindow(1:2);
end
end

function val = pick_value(vec, idx)
if isempty(vec) || idx < 1 || idx > numel(vec)
    val = NaN;
else
    val = vec(idx);
end
end

function [evAvg, esAvg, absAvg, evmAvg, esmAvg, eabsAvg] = compute_averages(shift, ev, es, absVals, evm, esm, eabs, shiftMin, shiftMax, interpSamples)
evAvg = NaN; esAvg = NaN; absAvg = NaN; evmAvg = NaN; esmAvg = NaN; eabsAvg = NaN;
% Average over the Stokes window using dense interpolation in shift space
stokesMask = (shift > 0) & (shift >= shiftMin) & (shift <= shiftMax);
if nnz(stokesMask) < 2 || ~(shiftMax > shiftMin)
    return;
end
rs = shift(stokesMask);
[rs, rsOrd] = sort(rs);
shiftDense = linspace(shiftMin, shiftMax, interpSamples);

applyOrd = @(v) v(rsOrd);
ev_dense  = interp_spectrum(rs, applyOrd(ev(stokesMask)),  shiftDense);
es_dense  = interp_spectrum(rs, applyOrd(es(stokesMask)),  shiftDense);
abs_dense = interp_spectrum(rs, applyOrd(absVals(stokesMask)), shiftDense);
evm_dense = interp_spectrum(rs, applyOrd(evm(stokesMask)), shiftDense);
esm_dense = interp_spectrum(rs, applyOrd(esm(stokesMask)), shiftDense);
eabs_dense = interp_spectrum(rs, applyOrd(eabs(stokesMask)), shiftDense);

span = shiftDense(end) - shiftDense(1);
if span <= 0
    return;
end
evAvg = trapz(shiftDense, ev_dense) / span;
esAvg = trapz(shiftDense, es_dense) / span;
absAvg = trapz(shiftDense, abs_dense) / span;
evmAvg = trapz(shiftDense, evm_dense) / span;
esmAvg = trapz(shiftDense, esm_dense) / span;
eabsAvg = trapz(shiftDense, eabs_dense) / span;
end

function vals = interp_spectrum(x, v, xi)
if numel(x) >= 3
    vals = makima(x, v, xi);
else
    vals = interp1(x, v, xi, 'linear', 'extrap');
end
end

function N = struct_row_count(S)
N = 0;
if ~isstruct(S)
    return;
end
flds = fieldnames(S);
for k = 1:numel(flds)
    val = S.(flds{k});
    if ~isempty(val)
        N = size(val, 1);
        return;
    end
end
end

