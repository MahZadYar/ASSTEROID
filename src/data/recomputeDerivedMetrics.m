function [simData, updatedCount] = recomputeDerivedMetrics(simData, cfg, analyteSpectrum, reporter)
%recomputeDerivedMetrics Recompute *_laser, *_avg, *_analyte for all base metrics.
%   Iterates over rows of a SoA struct and derives laser-line, spectral average, and
%   analyte-weighted average for each base metric field present.
%
%   [simData, updatedCount] = recomputeDerivedMetrics(simData, cfg, analyteSpectrum, reporter)
%
%   Inputs:
%       simData         - SoA struct with spectral fields [N x L].
%       cfg             - Config struct with fields: laserWavelength, ramanWindow,
%                         detectShiftWindow, interpResolution, spectralInterpMethod.
%       analyteSpectrum - Struct with shift_cm, intensity for analyte weighting.
%       reporter        - ProgressReporter instance.
%
%   Outputs:
%       simData      - Updated SoA struct with derived metric fields.
%       updatedCount - Number of rows successfully updated.

    arguments
        simData struct
        cfg struct
        analyteSpectrum struct = struct()
        reporter = ProgressReporter.console()
    end

    if isempty(reporter)
        reporter = ProgressReporter.console();
    end

    baseMetrics = ["EF_vol", "EF_surf", "Absorptance", "M_vol", "M_surf", "EF_vol_M", "EF_surf_M", "EF_Abs"];
    nRows = structRowCount(simData);
    updatedCount = 0;

    present = false(size(baseMetrics));
    metricVariants = getConfigField(cfg, "metricVariants", struct());

    % Only create _analyte fields when a valid analyte spectrum is provided.
    % Without an analyte spectrum the field would stay NaN, misleading callers.
    hasValidAnalyte = isstruct(analyteSpectrum) && ...
        isfield(analyteSpectrum, 'shift_cm') && ...
        ~isempty(analyteSpectrum.shift_cm);

    for m = 1:numel(baseMetrics)
        metric = baseMetrics(m);
        if isfield(simData, metric)
            data = simData.(metric);
            present(m) = isnumeric(data) && ndims(data) == 2 && size(data, 1) >= nRows;
        end
        if present(m)
            if isVariantEnabled(metricVariants, metric + "_laser")
                simData.(metric + "_laser") = nan(nRows, 1);
            end
            if isVariantEnabled(metricVariants, metric + "_avg")
                simData.(metric + "_avg") = nan(nRows, 1);
            end
            if hasValidAnalyte && isVariantEnabled(metricVariants, metric + "_analyte")
                simData.(metric + "_analyte") = nan(nRows, 1);
            end
        end
    end

    hasLambda = isfield(simData, "lambda") && isnumeric(simData.lambda);
    hasShift = isfield(simData, "RamanShift") && isnumeric(simData.RamanShift);

    % Extract config values using safe field access
    laserWavelength = getConfigField(cfg, "laserWavelength", 785);
    ramanWindow = getConfigField(cfg, "ramanWindow", [100 3600]);
    detectShiftWindow = getConfigField(cfg, "detectShiftWindow", false);
    interpResolution = getConfigField(cfg, "interpResolution", 1);
    spectralInterpMethod = getConfigField(cfg, "spectralInterpMethod", "makima");

    reporter.start("RecalculateDerived", sprintf("Recomputing derived metrics for %d rows...", nRows));
    for i = 1:nRows
        if mod(i, max(1, round(nRows / 20))) == 0 || i == nRows
            reporter.progress("RecalculateDerived", i / nRows, sprintf("Row %d/%d", i, nRows));
        end

        lambdaRow = [];
        if hasLambda
            lambdaRow = extractRow(simData.lambda, i);
        end
        shiftRow = [];
        if hasShift
            shiftRow = extractRow(simData.RamanShift, i);
        elseif ~isempty(lambdaRow)
            shiftRow = (1 ./ laserWavelength - 1 ./ lambdaRow) * 1e7;
        end
        if isempty(shiftRow)
            continue;
        end

        [~, laserIdx] = min(abs(shiftRow));
        if detectShiftWindow
            stokes = shiftRow(shiftRow > 0);
            if isempty(stokes)
                continue;
            end
            shiftMin = min(stokes);
            shiftMax = max(stokes);
        else
            shiftMin = ramanWindow(1);
            shiftMax = ramanWindow(2);
        end

        mask = (shiftRow > 0) & (shiftRow >= shiftMin) & (shiftRow <= shiftMax);
        canAvg = nnz(mask) >= 2 && (shiftMax - shiftMin) > 0;
        if canAvg
            interpSamples = max(2, round((shiftMax - shiftMin) / interpResolution));
            shiftDense = linspace(shiftMin, shiftMax, interpSamples);
            rs = shiftRow(mask);
            [rs, ord] = sort(rs);
        end

        for m = 1:numel(baseMetrics)
            if ~present(m)
                continue;
            end
            metric = baseMetrics(m);
            values = extractRow(simData.(metric), i);
            if isempty(values)
                continue;
            end
            % Interpolate at exactly shift=0 (laser wavelength) for sub-grid accuracy.
            % Falls back to nearest-neighbor when laser WL is outside the simulated range.
            if isVariantEnabled(metricVariants, metric + "_laser")
                validMask = isfinite(shiftRow) & isfinite(values);
                if nnz(validMask) >= 2
                    vs = shiftRow(validMask);
                    vv = values(validMask);
                    [vs, sOrd] = sort(vs);
                    vv = vv(sOrd);
                    % Deduplicate shifts (can occur when laser wavelength appears
                    % twice in the grid, e.g. when shift grid spans 0).
                    [vs, uid] = unique(vs, "last");
                    vv = vv(uid);
                    if numel(vs) >= 2 && vs(1) <= 0 && vs(end) >= 0
                        simData.(metric + "_laser")(i) = interp1(vs, vv, 0, "linear");
                    else
                        [~, laserIdx] = min(abs(shiftRow));
                        simData.(metric + "_laser")(i) = values(min(max(laserIdx, 1), numel(values)));
                    end
                else
                    simData.(metric + "_laser")(i) = values(min(max(laserIdx, 1), numel(values)));
                end
            end

            if canAvg
                mv = values(mask);
                mv = mv(ord);
                mvDense = interpolateSpectral(rs, mv, shiftDense, spectralInterpMethod);
                if ~all(isnan(mvDense))
                    if isVariantEnabled(metricVariants, metric + "_avg")
                        simData.(metric + "_avg")(i) = trapz(shiftDense, mvDense) / (shiftDense(end) - shiftDense(1));
                    end
                    if hasValidAnalyte && isVariantEnabled(metricVariants, metric + "_analyte")
                        simData.(metric + "_analyte")(i) = computeAnalyteWeightedMetric(shiftDense, mvDense, analyteSpectrum);
                    end
                end
            end
        end
        updatedCount = updatedCount + 1;
    end
    reporter.complete("RecalculateDerived", sprintf("Updated %d rows.", updatedCount));
end

%% --- Internal helpers ---
function row = extractRow(array2d, i)
    if isempty(array2d) || ~isnumeric(array2d)
        row = [];
        return;
    end
    if isvector(array2d)
        row = array2d(:)';
        return;
    end
    if size(array2d, 1) < i
        row = [];
        return;
    end
    row = array2d(i, :);
end

function yq = interpolateSpectral(x, y, xq, method)
    try
        valid = isfinite(x) & isfinite(y);
        x = x(valid);
        y = y(valid);
        [x, uIdx] = unique(x(:), "sorted");
        y = y(uIdx);
        if numel(x) < 2
            if isscalar(x)
                yq = repmat(y, size(xq));
            else
                yq = nan(size(xq));
            end
            return;
        end
        switch lower(string(method))
            case "makima"
                yq = makima(x, y, xq);
            case "pchip"
                yq = pchip(x, y, xq);
            case "linear"
                yq = interp1(x, y, xq, "linear", "extrap");
            case "spline"
                yq = spline(x, y, xq);
            otherwise
                yq = makima(x, y, xq);
        end
    catch
        yq = nan(size(xq));
    end
end

function val = getConfigField(cfg, fieldName, defaultVal)
    if isfield(cfg, fieldName)
        val = cfg.(fieldName);
    else
        val = defaultVal;
    end
end

function enabled = isVariantEnabled(metricVariants, key)
    %isVariantEnabled Return true if the given metric+variant key is enabled.
    %   Missing keys default to true (compute all) for backward compatibility.
    key = char(key);
    if isfield(metricVariants, key)
        enabled = logical(metricVariants.(key));
    else
        enabled = true;
    end
end
