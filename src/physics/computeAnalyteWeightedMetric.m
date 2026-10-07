function metric = computeAnalyteWeightedMetric(shiftDense, efDense, analyteSpec)
% computeAnalyteWeightedMetric  Compute inner product of EF spectrum with normalized analyte Raman spectrum.
%
% Input:
%   shiftDense: Raman shift grid (cm^-1, row vector)
%   efDense: Interpolated EF spectrum on shiftDense (row vector, same length)
%   analyteSpec: Struct with .shift_cm and .intensity (normalized)
%
% Output:
%   metric: Inner product (scalar); NaN if analyte spectrum not available

metric = NaN;

if isempty(analyteSpec) || ~isstruct(analyteSpec)
    return;
end

if ~isfield(analyteSpec, 'shift_cm') || ~isfield(analyteSpec, 'intensity')
    return;
end

analyteShift = analyteSpec.shift_cm;
analyteIntensity = analyteSpec.intensity;

if isempty(analyteShift) || isempty(analyteIntensity) || numel(analyteShift) ~= numel(analyteIntensity)
    return;
end

% Ensure vectors are row vectors
shiftDense = reshape(shiftDense, 1, []);
efDense = reshape(efDense, 1, []);
analyteShift = reshape(analyteShift, 1, []);
analyteIntensity = reshape(analyteIntensity, 1, []);

% Interpolate analyte spectrum to match EF spectrum's grid (shiftDense)
try
    analyteInterp = interp1(analyteShift, analyteIntensity, shiftDense, 'linear', 0);
    analyteInterp = max(0, analyteInterp);
    
    % Renormalize on the dataset grid so integral equals 1 over [min,max]
    totalOnGrid = trapz(shiftDense, analyteInterp);
    if totalOnGrid > 0
        analyteInterp = analyteInterp / totalOnGrid;
    else
        metric = NaN; return;
    end
    
    % Compute inner product: integral of EF * analyte over shift range
    metric = trapz(shiftDense, efDense .* analyteInterp);
catch
    metric = NaN;
end
end