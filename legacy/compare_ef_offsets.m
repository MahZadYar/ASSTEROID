%% compare_ef_offsets
% Analyze EF_{vol} offsets between two mesh refinement datasets.
% The script loads `allData_1.mat` (assumed high-fidelity) and
% `allData_2.mat` (lower refinement), interpolates both onto a shared
% (p,r) grid, and estimates offsets and ratios in EF_vol.
%
% Requirements:
%   - Each MAT-file contains a structure-of-arrays variable `allData`
%     with fields at least {p, r, EF_vol} and optionally {lambda, f,
%     RamanShift} to identify the spectral axis.
%
% Outputs:
%   - Summary statistics printed to the command window, including mean and
%     median offsets and ratios (coarse - fine).
%   - A least-squares fit of EF_vol^coarse ≈ scale * EF_vol^fine + offset
%     on the overlapping domain.
%   - Optional surface plots that visualize the offset and ratio per
%     frequency index (disabled by default; enable via flags below).
%
% Note: The interpolation uses scatteredInterpolant with linear
% interpolation and no extrapolation. Regions outside the convex hull of
% each dataset remain NaN in the shared grid.

clear; clc;

%% User configuration
fileFine   = 'allData_op2.mat';  % higher fidelity / refined mesh
fileCoarse = 'allData_op1.mat';  % lower fidelity / coarse mesh
interpMethod = 'linear';       % 'linear', 'natural', etc.
plotDiagnostics = false;       % set true to generate figures per frequency

epsFloor = 1e-12;              % guard for ratio denominator

%% Load datasets
S1 = load(fileFine);
S2 = load(fileCoarse);
assert(isfield(S1, 'allData'), 'File %s must contain variable allData.', fileFine);
assert(isfield(S2, 'allData'), 'File %s must contain variable allData.', fileCoarse);
D1 = S1.allData;
D2 = S2.allData;

requiredFields = {'p','r','EF_vol'};
for k = 1:numel(requiredFields)
    fld = requiredFields{k};
    assert(isfield(D1, fld), 'Field "%s" missing from %s.', fld, fileFine);
    assert(isfield(D2, fld), 'Field "%s" missing from %s.', fld, fileCoarse);
end

%% Extract parameter coordinates
p1 = double(D1.p(:)); r1 = double(D1.r(:));
p2 = double(D2.p(:)); r2 = double(D2.r(:));
assert(numel(p1) == numel(r1), 'allData_1: p and r lengths differ.');
assert(numel(p2) == numel(r2), 'allData_2: p and r lengths differ.');

%% Extract EF_vol arrays and align dimensions
EF1 = double(D1.EF_vol);
EF2 = double(D2.EF_vol);
numSamples1 = numel(p1);
numSamples2 = numel(p2);
if size(EF1,1) ~= numSamples1
    if size(EF1,2) == numSamples1
        EF1 = EF1.';
    else
        error('EF_vol dimensions in %s do not match number of samples.', fileFine);
    end
end
if size(EF2,1) ~= numSamples2
    if size(EF2,2) == numSamples2
        EF2 = EF2.';
    else
        error('EF_vol dimensions in %s do not match number of samples.', fileCoarse);
    end
end

% Extract spectral axes (RamanShift, f, or lambda) and resample to shared range
axisInfo1 = extract_spectral_axis(D1, numSamples1, size(EF1,2), fileFine);
axisInfo2 = extract_spectral_axis(D2, numSamples2, size(EF2,2), fileCoarse);
assert(~isempty(axisInfo1.values) && ~isempty(axisInfo2.values), ...
    'Unable to determine spectral axis for one of the datasets.');

[axisCommon, axisLabel] = compute_common_axis(axisInfo1, axisInfo2);
EF1 = resample_spectral_values(EF1, axisInfo1.matrix, axisCommon);
EF2 = resample_spectral_values(EF2, axisInfo2.matrix, axisCommon);

nf = numel(axisCommon);
fprintf('Spectral axis: %s with %d points (shared range %.6g to %.6g)\n', ...
    axisLabel, nf, axisCommon(1), axisCommon(end));

%% Construct shared (p,r) grid
pGrid = unique([p1; p2]);
rGrid = unique([r1; r2]);
[np, nr] = deal(numel(pGrid), numel(rGrid));
[Pgrid, Rgrid] = ndgrid(pGrid, rGrid);

%% Helper to interpolate dataset onto shared grid
interpolateDataset = @(p, r, values) interpolate_to_grid(p, r, values, Pgrid, Rgrid, interpMethod);
EF1_grid = interpolateDataset(p1, r1, EF1);
EF2_grid = interpolateDataset(p2, r2, EF2);

%% Compute offsets and ratios on overlapping domain
maskOverlap = isfinite(EF1_grid) & isfinite(EF2_grid);

Delta = EF2_grid - EF1_grid;  % additive offset (coarse - fine)
Ratio = nan(size(Delta));
Ratio(maskOverlap & abs(EF1_grid) > epsFloor) = EF2_grid(maskOverlap & abs(EF1_grid) > epsFloor) ./ EF1_grid(maskOverlap & abs(EF1_grid) > epsFloor);

% Aggregate statistics (all frequencies combined)
DeltaVals = Delta(maskOverlap);
RatioVals = Ratio(maskOverlap & isfinite(Ratio));

deltaMean = mean(DeltaVals, 'omitnan');
deltaMedian = median(DeltaVals, 'omitnan');
deltaStd = std(DeltaVals, 0, 'omitnan');
ratioMean = mean(RatioVals, 'omitnan');
ratioMedian = median(RatioVals, 'omitnan');
ratioStd = std(RatioVals, 0, 'omitnan');

%% Per-frequency summaries
DeltaMeanFreq = nan(nf,1);
DeltaMedianFreq = nan(nf,1);
RatioMeanFreq = nan(nf,1);
RatioMedianFreq = nan(nf,1);
for k = 1:nf
    mk = maskOverlap(:,:,k);
    if any(mk(:))
        dv = Delta(:,:,k);
        rv = Ratio(:,:,k);
        DeltaMeanFreq(k) = mean(dv(mk), 'omitnan');
        DeltaMedianFreq(k) = median(dv(mk), 'omitnan');
        validRatio = mk & isfinite(rv);
        if any(validRatio(:))
            RatioMeanFreq(k) = mean(rv(validRatio), 'omitnan');
            RatioMedianFreq(k) = median(rv(validRatio), 'omitnan');
        end
    end
end

%% Least-squares fit (coarse ≈ scale * fine + offset)
vecFine = EF1_grid(maskOverlap);
vecCoarse = EF2_grid(maskOverlap);
A = [vecFine(:), ones(numel(vecFine),1)];
params = A \ vecCoarse(:);
scaleLS = params(1);
offsetLS = params(2);
fitResiduals = vecCoarse(:) - (scaleLS .* vecFine(:) + offsetLS);
rmseLS = sqrt(mean(fitResiduals.^2, 'omitnan'));

%% Display summary
fprintf('EF_{vol} comparison between %s (fine) and %s (coarse)\n', fileFine, fileCoarse);
fprintf('Points on shared grid: %d (p) x %d (r) x %d (freq)\n', np, nr, nf);
fprintf('Overlap coverage: %d voxels (%.1f%% of grid)\n', nnz(maskOverlap), 100*nnz(maskOverlap)/numel(maskOverlap));

fprintf('\nAdditive offset (coarse - fine):\n');
fprintf('  Mean   : %.6g\n', deltaMean);
fprintf('  Median : %.6g\n', deltaMedian);
fprintf('  StdDev : %.6g\n', deltaStd);

fprintf('\nMultiplicative ratio (coarse / fine):\n');
fprintf('  Mean   : %.6g\n', ratioMean);
fprintf('  Median : %.6g\n', ratioMedian);
fprintf('  StdDev : %.6g\n', ratioStd);

fprintf('\nLeast-squares fit (coarse ≈ scale * fine + offset):\n');
fprintf('  scale  : %.6g\n', scaleLS);
fprintf('  offset : %.6g\n', offsetLS);
fprintf('  RMSE   : %.6g\n', rmseLS);

%% Optional: per-frequency printout (first few entries)
maxPrint = min(5, nf);
if maxPrint > 0
    fprintf('\nFirst %d spectral samples (median offset / ratio):\n', maxPrint);
    for k = 1:maxPrint
        fprintf('  k=%d (axis=%.6g): Δmedian=%.6g, ratioMedian=%.6g\n', ...
            k, axisCommon(k), DeltaMedianFreq(k), RatioMedianFreq(k));
    end
    if nf > maxPrint
        fprintf('  ... (%d more frequencies)\n', nf - maxPrint);
    end
end

%% Optional diagnostics (set plotDiagnostics=true)
if plotDiagnostics %#ok<UNRCH>
    for k = 1:nf %#ok<UNRCH>
        mk = maskOverlap(:,:,k);
        if ~any(mk(:))
            continue;
        end
        figure('Name', sprintf('EF offset freq %d', k)); %#ok<LFIG>
        surf(Rgrid, Pgrid, Delta(:,:,k), 'EdgeColor','none');
        xlabel('r'); ylabel('p'); zlabel('\Delta EF_{vol}');
        title(sprintf('Additive offset (freq %d)', k));
        colorbar; view(2);

        figure('Name', sprintf('EF ratio freq %d', k)); %#ok<LFIG>
        surf(Rgrid, Pgrid, Ratio(:,:,k), 'EdgeColor','none');
        xlabel('r'); ylabel('p'); zlabel('Ratio');
        title(sprintf('Multiplicative ratio (freq %d)', k));
        colorbar; view(2);
    end
end

%% Save results for reuse (optional)
results = struct();
results.pGrid = pGrid;
results.rGrid = rGrid;
results.maskOverlap = maskOverlap;
results.Delta = Delta;
results.Ratio = Ratio;
results.DeltaMean = deltaMean;
results.DeltaMedian = deltaMedian;
results.DeltaStd = deltaStd;
results.RatioMean = ratioMean;
results.RatioMedian = ratioMedian;
results.RatioStd = ratioStd;
results.DeltaMeanFreq = DeltaMeanFreq;
results.DeltaMedianFreq = DeltaMedianFreq;
results.RatioMeanFreq = RatioMeanFreq;
results.RatioMedianFreq = RatioMedianFreq;
results.scaleLS = scaleLS;
results.offsetLS = offsetLS;
results.rmseLS = rmseLS;
results.fileFine = fileFine;
results.fileCoarse = fileCoarse;
results.axisLabel = axisLabel;
results.axisCommon = axisCommon;

save('ef_offset_comparison.mat', 'results');
fprintf('\nSaved detailed results to ef_offset_comparison.mat\n');

%% --- Helper function (local) ---
function gridVals = interpolate_to_grid(p, r, values, Pgrid, Rgrid, method)
% Interpolate EF_vol values from scattered (p,r) points onto the provided grid.
% values is size [N x nf]. Returns [numel(pGrid) x numel(rGrid) x nf].
    N = numel(p);
    assert(size(values,1) == N, 'Value count must match coordinate length.');
    nfLoc = size(values,2);
    gridVals = nan([size(Pgrid), nfLoc]);
    for kk = 1:nfLoc
        v = values(:, kk);
        F = scatteredInterpolant(p, r, v, method, 'none');
        gridVals(:,:,kk) = F(Pgrid, Rgrid);
    end
end

function info = extract_spectral_axis(dataStruct, numSamples, freqCount, fileLabel)
% Determine the spectral axis (RamanShift, f, or lambda) for a dataset.
% Returns struct with fields: name, matrix (numSamples x nFreq) and values (1 x nFreq).
    fields = {'RamanShift','f','lambda'};
    info = struct('name', '', 'matrix', [], 'values', []);
    for idx = 1:numel(fields)
        fld = fields{idx};
        if ~isfield(dataStruct, fld) || isempty(dataStruct.(fld))
            continue;
        end
        raw = double(dataStruct.(fld));
        if isvector(raw) && numel(raw) == freqCount
            row = reshape(raw, 1, []);
            info.matrix = repmat(row, numSamples, 1);
        elseif size(raw,1) == numSamples
            info.matrix = raw;
        elseif size(raw,2) == numSamples && size(raw,1) == freqCount
            info.matrix = raw.';
        elseif size(raw,2) == freqCount
            info.matrix = repmat(raw(1,:), numSamples, 1);
        else
            error('Axis field "%s" in %s has incompatible dimensions.', fld, fileLabel);
        end

        info.name = fld;
        info.values = info.matrix(1,:);
        return;
    end
    warning('No spectral axis (RamanShift/f/lambda) found in %s.', fileLabel);
end

function [axisCommon, label] = compute_common_axis(info1, info2)
% Build a shared spectral axis spanning the overlap between datasets.
    vals1 = info1.matrix(:);
    vals2 = info2.matrix(:);
    vals1 = vals1(isfinite(vals1));
    vals2 = vals2(isfinite(vals2));
    assert(~isempty(vals1) && ~isempty(vals2), 'Spectral axis contains no finite values.');

    minCommon = max(min(vals1), min(vals2));
    maxCommon = min(max(vals1), max(vals2));
    assert(minCommon < maxCommon, 'No overlapping spectral range between datasets.');

    mask1 = vals1 >= minCommon & vals1 <= maxCommon;
    mask2 = vals2 >= minCommon & vals2 <= maxCommon;
    axisCommon = unique([vals1(mask1); vals2(mask2)]);
    axisCommon = sort(axisCommon(:).');

    if strcmp(info1.name, info2.name)
        label = info1.name;
    else
        label = sprintf('%s/%s', info1.name, info2.name);
    end
end

function valuesOut = resample_spectral_values(valuesIn, axisMatrix, axisCommon)
% Resample EF values along spectral axis to the shared axis using linear interpolation.
    [numSamples, ~] = size(valuesIn);
    axisCommon = axisCommon(:).';
    nCommon = numel(axisCommon);
    valuesOut = nan(numSamples, nCommon);
    for ii = 1:numSamples
        axisRow = axisMatrix(ii,:);
        dataRow = valuesIn(ii,:);
        valid = isfinite(axisRow) & isfinite(dataRow);
        axisRow = axisRow(valid);
        dataRow = dataRow(valid);
        if numel(axisRow) < 2
            continue;
        end
        [axisRow, ord] = sort(axisRow);
        dataRow = dataRow(ord);
        [axisRow, uniqIdx] = unique(axisRow);
        dataRow = dataRow(uniqIdx);
        if numel(axisRow) < 2
            continue;
        end
        valuesOut(ii,:) = interp1(axisRow, dataRow, axisCommon, 'linear', NaN);
    end
end
