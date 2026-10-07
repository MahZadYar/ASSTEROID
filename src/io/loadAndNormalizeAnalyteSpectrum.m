function analyteSpec = loadAndNormalizeAnalyteSpectrum(filePath, options)
% loadAndNormalizeAnalyteSpectrum  Load analyte Raman spectrum, baseline-correct, normalize, optional plot.
%
% Input:
%   filePath: Path to file with two columns: Stokes Shift (cm^-1), Intensity (arb. units)
%
% Output:
%   analyteSpec: Struct with fields:
%     .shift_cm: Raman shifts in cm^-1 (sorted, row vector)
%     .intensity: Processed+normalized intensity (row, integrates to ~1)
%     .raw_intensity: Raw intensity (row)
%     .baseline: Estimated background/baseline (row)
%     .processed_intensity: Background-removed, nonnegative, optionally smoothed (row)

    arguments
        filePath (1,:) char
        options.doBackgroundRemoval (1,1) logical = true
        options.useMorphBaseline (1,1) logical = false
        options.morphWindowPts (1,1) double = 150
        options.aslsLambda (1,1) double = 1000
        options.aslsP (1,1) double = 0.001
        options.aslsMaxIter (1,1) double = 10
        options.doSmoothing (1,1) logical = true
        options.smoothMethod (1,:) char = 'movmean'
        options.smoothWindow (1,1) double = 5
        options.doNormalization (1,1) logical = true
        options.normTargetArea (1,1) double = 1.0
        options.showPlot (1,1) logical = false
    end
    
    doBackgroundRemoval = options.doBackgroundRemoval;
    useMorphBaseline = options.useMorphBaseline;
    morphWindowPts = options.morphWindowPts;
    aslsLambda = options.aslsLambda;
    aslsP = options.aslsP;
    aslsMaxIter = options.aslsMaxIter;
    doSmoothing = options.doSmoothing;
    smoothMethod = options.smoothMethod;
    smoothWindow = options.smoothWindow;
    doNormalization = options.doNormalization;
    normTargetArea = options.normTargetArea;
    showPlot = options.showPlot;

analyteSpec = struct('shift_cm', [], 'intensity', [], ...
    'raw_intensity', [], 'baseline', [], 'processed_intensity', []);

if ~isfile(filePath)
    warning('Analyte spectrum file not found: %s', filePath);
    return;
end

try
    data = readmatrix(filePath, 'Delimiter', {' ', '\t', ','}, 'TreatAsEmpty', {'NA', 'NaN'});
    if isempty(data) || size(data, 2) < 2
        warning('Analyte spectrum file must have at least 2 columns. File: %s', filePath);
        return;
    end
    
    shift = data(:, 1);  % Column 1: Stokes Shift (cm^-1)
    intensity = data(:, 2);  % Column 2: Intensity (arb. units)
    
    % Remove any NaN entries
    validIdx = ~isnan(shift) & ~isnan(intensity) & isfinite(shift) & isfinite(intensity);
    shift = shift(validIdx);
    intensity = intensity(validIdx);
    
    if isempty(shift) || isempty(intensity)
        warning('No valid data in analyte spectrum file: %s', filePath);
        return;
    end
    
    % Sort by shift (ascending)
    [shift, sortIdx] = sort(shift);
    intensity = intensity(sortIdx);
    
    % Ensure row vectors for downstream processing
    shift = reshape(shift, 1, []);
    raw = reshape(intensity, 1, []);

    % --- Baseline estimation and removal ---
    if doBackgroundRemoval
        if useMorphBaseline
            win = max(5, min(numel(raw), morphWindowPts));
            se = strel('line', win, 0);
            base = imopen(raw, se);
        else
            base = asls_baseline(raw, aslsLambda, aslsP, aslsMaxIter);
        end
        proc = raw - base;
    else
        base = zeros(size(raw));
        proc = raw;
    end
    % Nonnegative constraint after baseline removal
    proc(proc < 0) = 0;

    % --- Optional smoothing ---
    if doSmoothing && numel(proc) >= 3
        proc = smoothdata(proc, smoothMethod, smoothWindowPts);
    end

    % --- Normalization ---
    switch lower(normalization)
        case 'area'
            areaVal = trapz(shift, proc);
            if areaVal > 0
                proc = proc / areaVal;
            else
                % fallback to max normalization
                mx = max(proc);
                if mx > 0, proc = proc / mx; end
            end
        case 'max'
            mx = max(proc);
            if mx > 0, proc = proc / mx; end
        case 'zscore'
            mu = mean(proc);
            sig = std(proc);
            if sig > 0
                proc = (proc - mu) / sig;
                % Shift to nonnegative and renormalize area to 1
                mmin = min(proc);
                if mmin < 0, proc = proc - mmin; end
                areaVal = trapz(shift, proc);
                if areaVal > 0, proc = proc / areaVal; end
            end
        otherwise
            % default to area
            areaVal = trapz(shift, proc);
            if areaVal > 0, proc = proc / areaVal; end
    end

    % Populate output
    analyteSpec.shift_cm = shift;
    analyteSpec.raw_intensity = raw;
    analyteSpec.baseline = base;
    analyteSpec.processed_intensity = proc;
    analyteSpec.intensity = proc;  % canonical field used elsewhere

    % Optional debug plot
    if showPlot
        figure('Name','Analyte Spectrum Processing','Color','w');
        % Left axis: raw and baseline
        yyaxis left
        hRaw = plot(shift, raw, 'Color', [0.2 0.2 0.8], 'LineWidth', 1.2); hold on;
        hBase = plot(shift, base, 'Color', [0.85 0.33 0.1], 'LineWidth', 1.2);
        ylabel('Intensity (arb.)');
        % Right axis: processed (normalized)
        yyaxis right
        hProc = plot(shift, proc, 'Color', [0.1 0.6 0.1], 'LineWidth', 1.4);
        ylabel('Processed (normalized)');
        % Common decorations
        grid on; box on;
        xlabel('Raman Shift (cm^{-1})');
        title('Analyte Spectrum: Raw/Baseline (left) vs Processed (right)');
        % Legend with explicit handles (across both axes)
        legend([hRaw, hBase, hProc], {'Raw','Estimated baseline','Processed'}, 'Location','best');
    end
    
catch ME
    warning('Error loading analyte spectrum file: %s. Error: %s', filePath, ME.message);
end
end

% ---------------------------- Local helpers -----------------------------
function baseline = asls_baseline(y, lambda, p, niter)
% Asymmetric Least Squares baseline correction
% Eilers & Boelens (2005). Baseline Correction with Asymmetric Least Squares Smoothing.
% y: row vector
% lambda: smoothness (typ ~1e5-1e7)
% p: asymmetry (0<p<1)
% niter: iterations
    y = y(:);
    m = numel(y);
    D = diff(speye(m), 2);
    w = ones(m,1);
    for i=1:niter
        W = spdiags(w, 0, m, m);
        C = W + lambda*(D'*D);
        z = C \ (w .* y);
        w = p*(y > z) + (1-p)*(y <= z);
    end
    baseline = reshape(z, 1, []);
end