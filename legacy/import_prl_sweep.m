% import_prl_sweep
% Script to ingest COMSOL parameter sweep (prl_sweep.csv), reshape spectra into
% structure-of-arrays entries, compute Raman-shift-averaged EF metrics, and
% append results into allData.mat using save_append.

%% Configuration -----------------------------------------------------------
scriptDir = fileparts(mfilename('fullpath'));
addpath(scriptDir);
workDir = pwd;
inputFileName = 'SweepPropeTableCylinder.dat'; % Input sweep data file (COMSOL export)
outputFileName = 'prl_sweep_cylinder_tall.mat'; % Name of the output MAT file
dataCandidates = {
    fullfile(pwd, inputFileName);
};
dataFile = '';
for candidateIdx = 1:numel(dataCandidates)
    if isfile(dataCandidates{candidateIdx})
        dataFile = dataCandidates{candidateIdx};
        break;
    end
end
if isempty(dataFile)
    candidateList = strjoin(dataCandidates, newline);
    error('No sweep data file found. Expected one of:\n%s', candidateList);
end
% fprintf('Input sweep file: %s\n', dataFile);
outputFile = fullfile(pwd, outputFileName);     % Output MAT file (SoA layout)
ramanWindow = [100, 3500];                     % Stokes Shifts (cm^-1) window for spectral averaging
interpSamples = 300;                          % Points for dense interpolation grid

% Reset destination file to ensure a clean SoA (optional)
% fprintf('Target MAT file: %s (existing entries will be retained).\n', outputFile);

allDataStruct = struct();
replacedDuplicates = 0;

if isfile(outputFile)
    try
        S_existing = load(outputFile, 'allData');
        if isfield(S_existing, 'allData') && isstruct(S_existing.allData)
            allDataStruct = normalizeGeometryFields(S_existing.allData);
        end
    catch ME
        warning('Failed to load existing entries from %s (%s). Proceeding with empty dataset.', outputFile, ME.message);
    end
end

%% Load sweep table ---------------------------------------------------------
T = readSweepTable(dataFile);
% Sanitize variable names by keeping the first token before whitespace
T.Properties.VariableNames = sanitizeVarNames(T.Properties.VariableNames);
varNames = T.Properties.VariableNames;
% display the detected variable names
disp('Detected variable names in the sweep data:');
disp(varNames);
% Extract required columns (numeric vectors)
period = getColumn(T, varNames, 'period');           % meters
radius = getColumn(T, varNames, 'radius');       % meters
lambda = getColumn(T, varNames, 'lambda');       % nanometers
E_vol = getColumn(T, varNames, 'E_vol');
E_surf = getColumn(T, varNames, 'E_surf');
M_vol = getColumn(T, varNames, 'M_vol');
M_surf = getColumn(T, varNames, 'M_surf');
M2_vol = getColumn(T, varNames, 'M2_vol');
M2_surf = getColumn(T, varNames, 'M2_surf');
EF_vol = getColumn(T, varNames, 'EF_vol');
EF_surf = getColumn(T, varNames, 'EF_surf');
intW_vol = getColumn(T, varNames, 'intW_vol');
intW_t = getColumn(T, varNames, 'intW_t');
absorptance = getColumn(T, varNames, 'Absorptance');
reflectance = getColumn(T, varNames, 'Reflectance');
transmittance = getColumn(T, varNames, 'Transmittance');
ECCheck = getColumn(T, varNames, 'ECCheck');
skinDepth = getColumn(T, varNames, 'SkinDepth');

%% Group by geometric parameters ------------------------------------------
keyMatrix = [period, radius];
[keyPairs, ~, G] = unique(keyMatrix, 'rows', 'stable');
numGroups = size(keyPairs, 1);

c = 299792458; % speed of light (m/s)
entriesWritten = 0;
sampleShiftRange = nan(numGroups, 2);

for g = 1:numGroups
    idx = (G == g);
    if nnz(idx) < 2
        warning('Group %d has <2 spectral points; proceeding with limited data.', g);
    end

    % Sort by wavelength ascending
    [lambdaSorted, ord] = sort(lambda(idx));
    % Apply same ordering to all spectral metrics
    EF_vol_sorted = EF_vol(idx);     EF_vol_sorted = EF_vol_sorted(ord);
    EF_surf_sorted = EF_surf(idx);   EF_surf_sorted = EF_surf_sorted(ord);
    E_vol_sorted = E_vol(idx);       E_vol_sorted = E_vol_sorted(ord);
    E_surf_sorted = E_surf(idx);     E_surf_sorted = E_surf_sorted(ord);
    M_vol_sorted = M_vol(idx);       M_vol_sorted = M_vol_sorted(ord);
    M_surf_sorted = M_surf(idx);     M_surf_sorted = M_surf_sorted(ord);
    M2_vol_sorted = M2_vol(idx);     M2_vol_sorted = M2_vol_sorted(ord);
    M2_surf_sorted = M2_surf(idx);   M2_surf_sorted = M2_surf_sorted(ord);
    intW_vol_sorted = intW_vol(idx); intW_vol_sorted = intW_vol_sorted(ord);
    intW_t_sorted = intW_t(idx);     intW_t_sorted = intW_t_sorted(ord);
    absorptance_sorted = absorptance(idx); absorptance_sorted = absorptance_sorted(ord);
    reflectance_sorted = reflectance(idx); reflectance_sorted = reflectance_sorted(ord);
    transmittance_sorted = transmittance(idx); transmittance_sorted = transmittance_sorted(ord);
    ECCheck_sorted = ECCheck(idx); ECCheck_sorted = ECCheck_sorted(ord);
    skinDepth_sorted = skinDepth(idx); skinDepth_sorted = skinDepth_sorted(ord);

    % Remove duplicate wavelengths to keep interpolation stable
    [lambdaSorted, uniqueIdx] = unique(lambdaSorted, 'stable');
    if numel(uniqueIdx) < numel(ord)
        EF_vol_sorted = EF_vol_sorted(uniqueIdx);
        EF_surf_sorted = EF_surf_sorted(uniqueIdx);
        E_vol_sorted = E_vol_sorted(uniqueIdx);
        E_surf_sorted = E_surf_sorted(uniqueIdx);
        M_vol_sorted = M_vol_sorted(uniqueIdx);
        M_surf_sorted = M_surf_sorted(uniqueIdx);
        M2_vol_sorted = M2_vol_sorted(uniqueIdx);
        M2_surf_sorted = M2_surf_sorted(uniqueIdx);
        intW_vol_sorted = intW_vol_sorted(uniqueIdx);
        intW_t_sorted = intW_t_sorted(uniqueIdx);
        absorptance_sorted = absorptance_sorted(uniqueIdx);
        reflectance_sorted = reflectance_sorted(uniqueIdx);
        transmittance_sorted = transmittance_sorted(uniqueIdx);
        ECCheck_sorted = ECCheck_sorted(uniqueIdx);
        skinDepth_sorted = skinDepth_sorted(uniqueIdx);
    end

    lambdaSorted_m = lambdaSorted * 1e-9;
    laserLambda_m = min(lambdaSorted_m); % assume smallest wavelength equals the excitation line
    lambdaExc = laserLambda_m * 1e9;
    f_sorted = c ./ lambdaSorted_m;      % Hz
    RamanShift_cm = (1./laserLambda_m - 1./lambdaSorted_m) / 100; % cm^-1

    % Spectral averaging over Raman window
    shiftMin = max(ramanWindow(1), RamanShift_cm(1));
    shiftMax = min(ramanWindow(2), RamanShift_cm(end));
    % Laser-line approximations (value closest to zero shift)
    [~, laserIdx] = min(abs(RamanShift_cm));
    EF_vol_approx = EF_vol_sorted(laserIdx);
    EF_surf_approx = EF_surf_sorted(laserIdx);
    M_vol_laser = M_vol_sorted(laserIdx);
    M_surf_laser = M_surf_sorted(laserIdx);
    Abs_laser = absorptance_sorted(laserIdx);

    EF_vol_M_sorted = (M_vol_laser .* M_vol_sorted(:))';
    EF_surf_M_sorted = (M_surf_laser .* M_surf_sorted(:))';
    EF_Abs_sorted = (Abs_laser .* absorptance_sorted(:))';

    canAverageSpectra = (shiftMax - shiftMin) > 0 && numel(lambdaSorted) >= 2;
    if canAverageSpectra
        shiftDense = linspace(shiftMin, shiftMax, interpSamples);
        ev_dense = makima(RamanShift_cm, EF_vol_sorted, shiftDense);
        es_dense = makima(RamanShift_cm, EF_surf_sorted, shiftDense);
        EF_vol_avg = trapz(shiftDense, ev_dense) / (shiftDense(end) - shiftDense(1));
        EF_surf_avg = trapz(shiftDense, es_dense) / (shiftDense(end) - shiftDense(1));
        abs_dense = makima(RamanShift_cm, absorptance_sorted, shiftDense);
        Abs_avg = trapz(shiftDense, abs_dense) / (shiftDense(end) - shiftDense(1));
        evm_dense = makima(RamanShift_cm, EF_vol_M_sorted, shiftDense);
        esm_dense = makima(RamanShift_cm, EF_surf_M_sorted, shiftDense);
        eabs_dense = makima(RamanShift_cm, EF_Abs_sorted, shiftDense);
        EF_vol_M_avg = trapz(shiftDense, evm_dense) / (shiftDense(end) - shiftDense(1));
        EF_surf_M_avg = trapz(shiftDense, esm_dense) / (shiftDense(end) - shiftDense(1));
        EF_Abs_avg = trapz(shiftDense, eabs_dense) / (shiftDense(end) - shiftDense(1));
    else
        % Fall back to laser-line values when only a single wavelength is present
        EF_vol_avg = EF_vol_approx;
        EF_surf_avg = EF_surf_approx;
        Abs_avg = Abs_laser;
        EF_vol_M_avg = EF_vol_M_sorted(laserIdx);
        EF_surf_M_avg = EF_surf_M_sorted(laserIdx);
        EF_Abs_avg = EF_Abs_sorted(laserIdx);
    end

    entry = struct();
    entry.period = keyPairs(g,1);
    entry.radius = keyPairs(g,2);
    entry.lambda = lambdaSorted_m(:)';
    entry.lambda = lambdaSorted(:)';
    entry.f = f_sorted(:)';
    entry.RamanShift = RamanShift_cm(:)';
    entry.LaserWl = laserLambda_m;
    entry.lambda_exc = lambdaExc;
    entry.RamanWindow = ramanWindow;
    entry.RamanWindowEffective = [shiftMin, shiftMax];
    entry.EF_vol = EF_vol_sorted(:)';
    entry.EF_surf = EF_surf_sorted(:)';
    entry.E_vol = E_vol_sorted(:)';
    entry.E_surf = E_surf_sorted(:)';
    entry.M_vol = M_vol_sorted(:)';
    entry.M_surf = M_surf_sorted(:)';
    entry.M2_vol = M2_vol_sorted(:)';
    entry.M2_surf = M2_surf_sorted(:)';
    entry.intW_vol = intW_vol_sorted(:)';
    entry.intW_t = intW_t_sorted(:)';
    entry.Absorptance = absorptance_sorted(:)';
    entry.Reflectance = reflectance_sorted(:)';
    entry.Transmittance = transmittance_sorted(:)';
    entry.ECCheck = ECCheck_sorted(:)';
    entry.SkinDepth = skinDepth_sorted(:)';
    entry.Abs_avg = Abs_avg;
    entry.EF_vol_avg = EF_vol_avg;
    entry.EF_surf_avg = EF_surf_avg;
    entry.EF_vol_approx = EF_vol_approx;
    entry.EF_surf_approx = EF_surf_approx;
    entry.M_vol_laser = M_vol_laser;
    entry.M_surf_laser = M_surf_laser;
    entry.Abs_laser = Abs_laser;
    entry.EF_vol_M = EF_vol_M_sorted;
    entry.EF_surf_M = EF_surf_M_sorted;
    entry.EF_Abs = EF_Abs_sorted;
    entry.EF_vol_M_avg = EF_vol_M_avg;
    entry.EF_surf_M_avg = EF_surf_M_avg;
    entry.EF_Abs_avg = EF_Abs_avg;
    existingIdx = findExistingRows(allDataStruct, keyPairs(g,1), keyPairs(g,2));
    if ~isempty(existingIdx)
        oldEntry = extractEntryStruct(allDataStruct, existingIdx(1));
        entry = mergeEntryWithNewWavelengths(oldEntry, entry, ramanWindow, interpSamples);
        allDataStruct = removeRowsFromStruct(allDataStruct, existingIdx);
        replacedDuplicates = replacedDuplicates + numel(existingIdx);
    end

    if isfield(entry, 'RamanWindowEffective') && numel(entry.RamanWindowEffective) >= 2
        sampleShiftRange(g,:) = entry.RamanWindowEffective(1:2);
    else
        sampleShiftRange(g,:) = [NaN, NaN];
    end
    allDataStruct = append_entry_struct(allDataStruct, entry);
    entriesWritten = entriesWritten + 1;
end

validRanges = sampleShiftRange(~any(isnan(sampleShiftRange),2), :);
if ~isempty(validRanges)
    % fprintf('Effective Raman shift coverage across entries: [%.1f, %.1f] cm^-1\n', ...
    %     min(validRanges(:,1)), max(validRanges(:,2)));
end

totalEntries = structRowCount(allDataStruct);
newEntries = max(entriesWritten - replacedDuplicates, 0);
fprintf('Output File:\t\t%s\n New Entries:\t\t%d\n Replaced Duplicates:\t%d\n Total Entries:\t\t%d\n', outputFileName, newEntries, replacedDuplicates, totalEntries);
if entriesWritten > 0 || replacedDuplicates > 0
    allData = allDataStruct; %#ok<NASGU>
    w = whos('allData');
    useV73 = ~isempty(w) && w.bytes > 2e9;
    if useV73
        save(outputFile, 'allData', '-v7.3');
    else
        save(outputFile, 'allData');
    end
else
    fprintf('No changes applied; dataset already up to date.\n');
end

%% Helper functions --------------------------------------------------------
function T = readSweepTable(filePath)
[~,~,ext] = fileparts(filePath);
switch lower(ext)
    case '.csv'
        opts = detectImportOptions(filePath, 'Delimiter', ';', 'DecimalSeparator', ',', ...
            'VariableNamingRule', 'preserve');
        opts = setvaropts(opts, opts.VariableNames, 'TreatAsMissing', {'', 'NaN'});
        T = readtable(filePath, opts);
    case {'.dat', '.txt'}
        T = readComsolDat(filePath);
    otherwise
        error('Unsupported sweep data file extension: %s', ext);
end
end

function T = readComsolDat(filePath)
fid = fopen(filePath, 'r');
if fid < 0
    error('Failed to open sweep data file: %s', filePath);
end
cleanupObj = onCleanup(@() fclose(fid));

% Discard the first four metadata rows (commented)
numMetaLines = 4;
for ii = 1:numMetaLines
    metaLine = fgetl(fid);
    if ~ischar(metaLine)
        error('File %s ended before metadata line %d could be read.', filePath, ii);
    end
end

headerLine = fgetl(fid);
if ~ischar(headerLine)
    error('Header line not found in %s.', filePath);
end

headerText = headerLine;
if ~isempty(headerText) && headerText(1) == '%'
    headerText(1) = ' ';
end

dataStartPos = ftell(fid);
firstDataLine = '';
while true
    currentPos = ftell(fid);
    line = fgetl(fid);
    if ~ischar(line)
        break;
    end
    trimmed = strtrim(line);
    if isempty(trimmed)
        continue;
    end
    if startsWith(trimmed, '%')
        continue;
    end
    dataStartPos = currentPos;
    firstDataLine = line;
    break;
end

if isempty(firstDataLine)
    error('No numeric data rows found in %s.', filePath);
end

if numel(headerText) < numel(firstDataLine)
    headerText(numel(firstDataLine)) = ' ';
end

[tokenStarts, tokenEnds] = regexp(firstDataLine, '[+-]?\d*\.?\d+(?:[eEdD][+-]?\d+)?');
numVars = numel(tokenStarts);
if numVars == 0
    error('No numeric columns detected in %s.', filePath);
end

[defaultNames, defaultRawNames] = defaultComsolVarNames();
canonicalFromDefaults = detectCanonicalOrderFromHeader(headerText, defaultRawNames, defaultNames, numVars);
useDefaultOrder = numel(canonicalFromDefaults) == numVars;

rawNames = cell(numVars, 1);
if ~useDefaultOrder
    for ii = 1:numVars
        startIdx = tokenStarts(ii);
        if ii < numVars
            endIdx = tokenStarts(ii+1) - 1;
        else
            endIdx = numel(headerText);
        end
        endIdx = min(endIdx, numel(headerText));
        if startIdx > numel(headerText)
            segment = '';
        else
            segment = headerText(startIdx:endIdx);
        end
        segment = strtrim(segment);
        if isempty(segment)
            fallbackEnd = min(numel(headerText), max(tokenEnds(ii), startIdx));
            if fallbackEnd >= startIdx && startIdx <= numel(headerText)
                segment = strtrim(headerText(startIdx:fallbackEnd));
            end
        end
        if isempty(segment)
            segment = sprintf('Column%d', ii);
        end
        rawNames{ii} = segment;
    end
end

fseek(fid, dataStartPos, 'bof');
formatSpec = repmat('%f', 1, numVars);
dataArray = textscan(fid, formatSpec, 'Delimiter', {'\t', ' '}, ...
    'MultipleDelimsAsOne', true, 'CollectOutput', true, ...
    'ReturnOnError', false, 'CommentStyle', '%');

dataMatrix = dataArray{1};
if isempty(dataMatrix)
    error('No numeric data could be read from %s.', filePath);
end

numCols = size(dataMatrix, 2);
if numCols ~= numVars
    warning('Column count mismatch in %s (headers: %d, data columns: %d). Truncating to min.', ...
        filePath, numVars, numCols);
    useCount = min(numVars, numCols);
    if useDefaultOrder
        canonicalFromDefaults = canonicalFromDefaults(1:useCount);
    else
        rawNames = rawNames(1:useCount);
    end
    dataMatrix = dataMatrix(:, 1:useCount);
end

if useDefaultOrder
    mappedNames = canonicalFromDefaults(:);
else
    mappedNames = mapHeadersToDefaults(rawNames, defaultRawNames, defaultNames);
    fallbackNames = sanitizeVarNames(rawNames);
    emptyIdx = cellfun(@isempty, mappedNames);
    mappedNames(emptyIdx) = fallbackNames(emptyIdx);
end
mappedNames = matlab.lang.makeUniqueStrings(mappedNames, {}, namelengthmax);
T = array2table(dataMatrix, 'VariableNames', mappedNames);

clear cleanupObj;
end

    function mappedNames = mapHeadersToDefaults(rawNames, defaultRaw, canonical)
    mappedNames = repmat({''}, size(rawNames));
    if isempty(rawNames)
        return;
    end

    aliasGroups = buildDefaultAliasGroups(defaultRaw);

    for ii = 1:numel(rawNames)
        candidate = strtrim(rawNames{ii});
        if isempty(candidate)
            continue;
        end
        for jj = 1:numel(aliasGroups)
            if any(strcmpi(candidate, aliasGroups{jj}))
                mappedNames{ii} = canonical{jj};
                break;
            end
        end
    end
    end

    function canonicalOrder = detectCanonicalOrderFromHeader(headerLine, defaultRaw, canonical, expectedCount)
    canonicalOrder = {};
    if nargin < 4 || expectedCount <= 0 || isempty(headerLine)
        return;
    end

    aliasGroups = buildDefaultAliasGroups(defaultRaw);
    headerLower = lower(headerLine);
    positions = inf(numel(canonical), 1);
    for jj = 1:numel(aliasGroups)
        variants = aliasGroups{jj};
        for kk = 1:numel(variants)
            aliasLower = lower(variants{kk});
            if isempty(aliasLower)
                continue;
            end
            hit = strfind(headerLower, aliasLower);
            if isempty(hit)
                continue;
            end
            pos = hit(1);
            if pos < positions(jj)
                positions(jj) = pos;
            end
        end
    end

    validMask = isfinite(positions);
    if nnz(validMask) < expectedCount
        canonicalOrder = {};
        return;
    end

    [~, orderIdx] = sort(positions, 'ascend');
    orderIdx = orderIdx(1:expectedCount);
    canonicalOrder = canonical(orderIdx);
    end

    function aliasGroups = buildDefaultAliasGroups(defaultRaw)
    aliasGroups = cell(size(defaultRaw));
    for jj = 1:numel(defaultRaw)
        entry = strtrim(defaultRaw{jj});
        parts = strsplit(entry, ',');
        parts = cellfun(@(s) strtrim(s), parts, 'UniformOutput', false);
        combined = [{entry}, parts(:)'];
        combined = combined(~cellfun(@isempty, combined));
        aliasGroups{jj} = unique(combined, 'stable');
    end
    end

function data = getColumn(T, varNames, pattern)
idx = findVarName(varNames, pattern);
if isempty(idx)
    warning('import_prl_sweep:MissingColumn', ...
        'Column matching pattern "%s" not found. Filling with NaNs.', pattern);
    data = nan(height(T), 1);
    return;
end

data = T{:, idx};
if ~isnumeric(data)
    data = double(data);
end
end

function idx = findVarName(varNames, pattern)
idx = find(contains(varNames, pattern, 'IgnoreCase', true), 1);
end

function cleanNames = sanitizeVarNames(varNames)
if isstring(varNames)
    varNames = cellstr(varNames);
end
numNames = numel(varNames);
tokens = cell(numNames, 1);
for ii = 1:numNames
    name = varNames{ii};
    if isempty(name)
        tokens{ii} = sprintf('Var%d', ii);
        continue;
    end
    token = regexp(name, '^\S+', 'match', 'once');
    if isempty(token)
        tokens{ii} = sprintf('Var%d', ii);
    else
        tokens{ii} = token;
    end
end

valid = matlab.lang.makeValidName(tokens);
cleanNames = matlab.lang.makeUniqueStrings(valid, {}, namelengthmax);
end

function [names, raw] = defaultComsolVarNames()
raw = {
    'period (nm)'
    'particle_r (nm)'
    'lambda0 (nm)'
    'E_vol (V/m), <E>vol'
    'E_surf (V/m), <E>surf'
    'M_vol (1), <M>vol'
    'M_surf (1), <M>surf'
    'M2_vol (1), <M2>vol'
    'M2_surf (1), <M2>surf'
    'EF_vol (1), <EF>vol'
    'EF_surf (1), <EF>surf'
    'intW_vol (neV), <W>vol'
    'intW_t (neV), intW'
    'Absorptance (%), Absorptance'
    'Reflectance (%), Reflectance'
    'Ttransmittance (%), Transmittance'
    'Skin depth (nm), Skin depth'
    'Energy Conservation Check (%), EC Check'
    'Wavelength in free space (nm), Wavelength'
    };
names = {
    'period'
    'radius'
    'lambda'
    'E_vol'
    'E_surf'
    'M_vol'
    'M_surf'
    'M2_vol'
    'M2_surf'
    'EF_vol'
    'EF_surf'
    'intW_vol'
    'intW_t'
    'Absorptance'
    'Reflectance'
    'Transmittance'
    'SkinDepth'
    'ECCheck'
    'Wavelength'
    };
end

    function entry = extractEntryStruct(S, idx)
    % extractEntryStruct  Return a single-row struct for row idx from SoA dataset.

    entry = struct();
    if isempty(S) || ~isstruct(S)
        return;
    end
    flds = fieldnames(S);
    for k = 1:numel(flds)
        fn = flds{k};
        val = S.(fn);
        if isnumeric(val) || islogical(val) || isstring(val)
            subs = repmat({':'}, 1, ndims(val));
            subs{1} = idx;
            slice = val(subs{:});
            entry.(fn) = slice;
        elseif iscell(val)
            entry.(fn) = val(idx, :);
        else
            subs = repmat({':'}, 1, ndims(val));
            subs{1} = idx;
            entry.(fn) = val(subs{:});
        end
    end
    end

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
        'Transmittance','ECCheck','SkinDepth'};

    oldLambdaRow = ensureRowVector(getFieldSafe(oldEntry, 'lambda'));
    oldMask = ~isnan(oldLambdaRow);
    idxOldValid = find(oldMask);

    newLambdaRow = ensureRowVector(getFieldSafe(newEntry, 'lambda'));
    newMask = ~isnan(newLambdaRow);
    idxNewValid = find(newMask);

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
            combinedLambda(end+1) = lam; %#ok<*AGROW>
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
    laserLambda_m = min(lambdaSorted_m);
    lambda_exc = laserLambda_m * 1e9;
    RamanShift_cm = (1./laserLambda_m - 1./lambdaSorted_m) / 100;
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

    % Derived spectral combinations
    M_vol_laser = M_vol_sorted(laserIdx);
    M_surf_laser = M_surf_sorted(laserIdx);
    Abs_laser = absorptance_sorted(laserIdx);
    EF_vol_M_sorted = (M_vol_laser .* M_vol_sorted(:))';
    EF_surf_M_sorted = (M_surf_laser .* M_surf_sorted(:))';
    EF_Abs_sorted = (Abs_laser .* absorptance_sorted(:))';

    shiftMin = max(ramanWindow(1), RamanShift_cm(1));
    shiftMax = min(ramanWindow(2), RamanShift_cm(end));

    EF_vol_avg = NaN;
    EF_surf_avg = NaN;
    Abs_avg = NaN;
    EF_vol_M_avg = NaN;
    EF_surf_M_avg = NaN;
    EF_Abs_avg = NaN;
    if shiftMax - shiftMin > 0
        shiftDense = linspace(shiftMin, shiftMax, interpSamples);
        ev_dense = pchip(RamanShift_cm, EF_vol_sorted, shiftDense);
        es_dense = pchip(RamanShift_cm, EF_surf_sorted, shiftDense);
        EF_vol_avg = trapz(shiftDense, ev_dense) / (shiftDense(end) - shiftDense(1));
        EF_surf_avg = trapz(shiftDense, es_dense) / (shiftDense(end) - shiftDense(1));
        abs_dense = pchip(RamanShift_cm, absorptance_sorted, shiftDense);
        Abs_avg = trapz(shiftDense, abs_dense) / (shiftDense(end) - shiftDense(1));
        evm_dense = pchip(RamanShift_cm, EF_vol_M_sorted, shiftDense);
        esm_dense = pchip(RamanShift_cm, EF_surf_M_sorted, shiftDense);
        eabs_dense = pchip(RamanShift_cm, EF_Abs_sorted, shiftDense);
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
    mergedEntry.lambda = lambdaSorted_m(:)';
    mergedEntry.lambda = lambdaSorted(:)';
    mergedEntry.f = f_sorted(:)';
    mergedEntry.RamanShift = RamanShift_cm(:)';
    mergedEntry.LaserWl = laserLambda_m;
    mergedEntry.lambda_exc = lambda_exc;
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
    mergedEntry.EF_vol_approx = EF_vol_sorted(laserIdx);
    mergedEntry.EF_surf_approx = EF_surf_sorted(laserIdx);
    mergedEntry.M_vol_laser = M_vol_laser;
    mergedEntry.M_surf_laser = M_surf_laser;
    mergedEntry.Abs_laser = Abs_laser;
    mergedEntry.EF_vol_M = EF_vol_M_sorted;
    mergedEntry.EF_surf_M = EF_surf_M_sorted;
    mergedEntry.EF_Abs = EF_Abs_sorted;
    mergedEntry.Abs_avg = Abs_avg;
    mergedEntry.EF_vol_avg = EF_vol_avg;
    mergedEntry.EF_surf_avg = EF_surf_avg;
    mergedEntry.EF_vol_M_avg = EF_vol_M_avg;
    mergedEntry.EF_surf_M_avg = EF_surf_M_avg;
    mergedEntry.EF_Abs_avg = EF_Abs_avg;
    end

    function lambdaVals = sanitizeLambdaVector(entry)
    if ~isstruct(entry) || ~isfield(entry, 'lambda') || isempty(entry.lambda)
        lambdaVals = [];
        return;
    end
    vec = ensureRowVector(entry.lambda);
    lambdaVals = vec(~isnan(vec));
    end

    function vec = ensureRowVector(val)
    if isnumeric(val) || islogical(val)
        vec = double(val(:)');
    elseif isstring(val)
        vec = double(str2double(val(:)'));
    elseif ischar(val)
        vec = double(str2double(string(val(:)')));
    else
        vec = [];
    end
    end

    function data = getFieldSafe(entry, fieldName)
    if isstruct(entry) && isfield(entry, fieldName)
        data = entry.(fieldName);
    else
        data = [];
    end
    end

    function row = padRowToLength(row, targetLen)
    row = double(row(:)');
    if numel(row) < targetLen
        row(end+1:targetLen) = NaN;
    else
        row = row(1:targetLen);
    end
    end

function idx = findExistingRows(dataStruct, periodVal, radiusVal)
idx = [];
if isempty(dataStruct) || ~isstruct(dataStruct)
    return;
end
periodVals = extractGeometryField(dataStruct, {'period','p'});
radiusVals = extractGeometryField(dataStruct, {'radius','particle_r','r'});
if isempty(periodVals) || isempty(radiusVals)
    return;
end
finitePeriod = periodVals(isfinite(periodVals));
finiteRadius = radiusVals(isfinite(radiusVals));
if isempty(finitePeriod) || isempty(finiteRadius)
    return;
end
tolP = max(1e-12, eps(max(abs(finitePeriod))));
tolR = max(1e-12, eps(max(abs(finiteRadius))));
idx = find(abs(periodVals - double(periodVal)) <= tolP & abs(radiusVals - double(radiusVal)) <= tolR);
end

function S = removeRowsFromStruct(S, idx)
if isempty(idx) || ~isstruct(S)
    return;
end
idx = unique(idx(:));
flds = fieldnames(S);
for k = 1:numel(flds)
    fn = flds{k};
    val = S.(fn);
    if isempty(val)
        continue;
    end
    if iscell(val)
        val(idx, :) = [];
    else
        subs = repmat({':'}, 1, ndims(val));
        subs{1} = idx;
        val(subs{:}) = [];
    end
    S.(fn) = val;
end
end

function N = structRowCount(S)
N = 0;
if isempty(S) || ~isstruct(S)
    return;
end
flds = fieldnames(S);
for k = 1:numel(flds)
    val = S.(flds{k});
    if isempty(val)
        continue;
    end
    N = size(val, 1);
    return;
end
end

function S = normalizeGeometryFields(S)
if isempty(S) || ~isstruct(S)
    return;
end
S = ensureFieldFromSources(S, 'period', {'p'});
S = ensureFieldFromSources(S, 'radius', {'r','particle_r'});
legacyFields = intersect(fieldnames(S), {'p','r','particle_r'});
if ~isempty(legacyFields)
    S = rmfield(S, legacyFields);
end
end

function S = ensureFieldFromSources(S, targetField, sourceFields)
if isempty(sourceFields) || ~isstruct(S)
    return;
end
if isfield(S, targetField)
    targetVals = S.(targetField);
else
    targetVals = [];
end
for k = 1:numel(sourceFields)
    srcName = sourceFields{k};
    if ~isfield(S, srcName)
        continue;
    end
    srcVals = S.(srcName);
    if isempty(targetVals)
        S.(targetField) = srcVals;
        targetVals = S.(targetField);
    else
        if isnumeric(targetVals) && isnumeric(srcVals) && isequal(size(targetVals), size(srcVals))
            mask = isnan(targetVals) & ~isnan(srcVals);
            if any(mask, 'all')
                targetVals(mask) = srcVals(mask);
                S.(targetField) = targetVals;
            end
        end
    end
end
end

function values = extractGeometryField(S, candidateFields)
values = [];
if isempty(candidateFields) || ~isstruct(S)
    return;
end
for k = 1:numel(candidateFields)
    fn = candidateFields{k};
    if isfield(S, fn)
        data = S.(fn);
        if isnumeric(data) || islogical(data)
            values = double(data(:));
            return;
        end
    end
end
end
