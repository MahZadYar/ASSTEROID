function [weights, shiftVecOut] = computeAnalyteGridWeights(shiftVec, analyteInput, method)
%computeAnalyteGridWeights Normalized spectral weights for one or more analytes.
%
%   weights = computeAnalyteGridWeights(shiftVec, analyteSpec)
%   weights = computeAnalyteGridWeights(shiftVec, analyteLibrary, method)
%
%   Interpolates each analyte spectrum (.shift_cm, .intensity) onto shiftVec
%   (cm^-1), clamps negative values to zero, and normalizes each column so
%   its discrete sum equals 1 (ready for stokesMat * weights matrix multiply).
%
%   Inputs:
%       shiftVec     - [1 x L] or [L x 1] Raman shift grid (cm^-1).
%       analyteInput - Either a single spectrum struct (.shift_cm, .intensity)
%                      or a library struct array whose entries contain
%                      .spectrum (.shift_cm, .intensity) or direct fields.
%       method       - Interpolation method (default: "makima").
%
%   Output:
%       weights      - [L x K] double matrix of non-negative unit-sum columns
%                      (all zeros for any invalid/non-overlapping entry).
%
%   See also: computeAnalyteWeightedMetric, resolveAnalyteLibrary, predict_dense_spectrum

    arguments
        shiftVec double
        analyteInput
        method (1,1) string = "makima"
    end

    shiftVecOut = double(shiftVec(:)');
    nShift = numel(shiftVecOut);

    if isempty(analyteInput) || ~isstruct(analyteInput) || nShift == 0
        weights = zeros(nShift, 0);
        return;
    end

    nEntries = numel(analyteInput);
    weights = zeros(nShift, nEntries);
    mChar = char(method);

    for k = 1:nEntries
        entry = analyteInput(k);
        if isfield(entry, "spectrum") && isstruct(entry.spectrum)
            spec = entry.spectrum;
        else
            spec = entry;
        end
        if ~isstruct(spec) || ~isfield(spec, "shift_cm") || ~isfield(spec, "intensity") ...
                || isempty(spec.shift_cm) || isempty(spec.intensity)
            continue;
        end
        try
            aw = interp1(double(spec.shift_cm(:)), double(spec.intensity(:)), shiftVecOut, mChar, 0);
            aw = max(0, aw(:));
            aw(~isfinite(aw)) = 0;
            s = sum(aw);
            if s > 0
                weights(:, k) = aw ./ s;
            end
        catch
            weights(:, k) = 0;
        end
    end
end
