function predictions = predict_dense_spectrum(model, pVec, rVec, lambdaVec, ri, varargin)
% predict_dense_spectrum  Evaluate trained model on a dense (p,r,lambda) grid.
%
% predictions = predict_dense_spectrum(model, pVec, rVec, lambdaVec, ri)
% returns a struct in SoA format containing predictions for each target metric.
% ri is a refractive index struct as returned by load_gold_refractive_index.
%
% Name-value arguments:
%   'ChunkSize'        - max batch size for prediction (default: 200000)
%   'Verbose'          - show progress output (default: true)
%   'LaserWavelength'  - laser wavelength in nm (default: first lambda * 1e3)
%   'RamanWindow'      - [min, max] Raman shift in cm^-1 (default: [100, 3500])
%   'AnalyteSpectrum'  - struct with .shift_cm and .intensity for analyte-weighted metrics
%   'InterpResolution' - interpolation resolution in 1/cm for averaging (default: 1)
%
% Output:
%   predictions - struct in SoA format with fields:
%     period      [N × 1] geometry periods (nanometers)
%     radius      [N × 1] geometry radii (nanometers)
%     lambda      [N × L] wavelengths (nanometers)
%     RamanShift  [N × L] Raman shift (cm^-1)
%     LaserWl     [N × 1] laser wavelength (nanometers)
%     lambda_exc_nm [N × 1] laser wavelength (nm, for compatibility)
%     RamanWindow [N × 2] Raman window (cm^-1)
%     <metric>    [N × L] metric spectra (e.g., EE_V, EE_S, EF_max, Abs)
%     *_broad     [N × 1] broadband spectral averages (plus *_avg alias)
%     *_analyte   [N × 1] analyte-weighted spectral averages (if AnalyteSpectrum provided)
%     *_laser     [N × 1] value at laser wavelength
%
% Any (p,r) combination where r >= p/2 is considered invalid and excluded.
%
% See also: convertGridToSoA, reshapeSoAToVolume

opts = struct('ChunkSize', 200000, 'Verbose', true, 'LaserWavelength', [], ...
    'RamanWindow', [100, 3500], 'MetricsRamanWindow', [], ...
    'AnalyteSpectrum', struct(), 'InterpResolution', 1, 'BatchSize', 2000, ...
    'ProgressFcn', [], 'ExecutionEnvironment', "auto", 'MiniBatchSize', 32768);
if mod(numel(varargin), 2) ~= 0
    error('predict_dense_spectrum:Args', 'Name-value pairs expected.');
end
for i = 1:2:numel(varargin)
    name = varargin{i};
    val = varargin{i+1};
    if ~isfield(opts, name)
        error('predict_dense_spectrum:BadOption', 'Unknown option: %s', name);
    end
    opts.(name) = val;
end

pVec = double(pVec(:)');
rVec = double(rVec(:)');
lambdaVec = double(lambdaVec(:)');
lambdaVecUm = lambdaVec; % expect caller to supply micrometers

[Nr, Np, Nlambda] = deal(numel(rVec), numel(pVec), numel(lambdaVec));
[Pg, Rg] = meshgrid(pVec, rVec);
invalidMask = Rg >= (Pg / 2);
validMask = ~invalidMask;
hasValid = any(validMask(:));
numValid = nnz(validMask);

if hasValid
    PgValid = Pg(validMask);
    RgValid = Rg(validMask);
else
    PgValid = [];
    RgValid = [];
end

targetNames = model.targetNames;
numTargets  = numel(targetNames);
chunkSize   = opts.ChunkSize;
batchSize   = max(1, opts.BatchSize);
progressFcn = opts.ProgressFcn;

%% Output coordinate setup (µm → nm)
laserWlNm     = opts.LaserWavelength;
if isempty(laserWlNm)
    laserWlNm = lambdaVecUm(1) * 1e3;
end
laserWlUm     = laserWlNm * 1e-3;
lambdaNm      = lambdaVecUm * 1e3;
ramanShiftRow = (1/laserWlUm - 1./lambdaVecUm) * 1e4;   % [1×Nlambda] cm⁻¹

if ~hasValid
    warning('predict_dense_spectrum:NoValidCombos', ...
        'No valid (p,r) combinations found; returning empty SoA.');
    predictions = struct('period', zeros(0,1), 'radius', zeros(0,1), ...
        'lambda', lambdaNm(:)', 'RamanShift', ramanShiftRow(:)');
    for t = 1:numTargets
        predictions.(targetNames{t}) = zeros(0, Nlambda);
    end
    return;
end

PgValidCol = PgValid(:);
RgValidCol = RgValid(:);

%% Pre-allocate SoA output directly — no 4D volumes grid, no full featuresAll
predictions            = struct();
predictions.period     = PgValidCol * 1e3;                      % [numValid×1] nm
predictions.radius     = RgValidCol * 1e3;                      % [numValid×1] nm
predictions.lambda     = lambdaNm(:)';      % [1×Nlambda] nm   — shared grid
predictions.RamanShift = ramanShiftRow(:)'; % [1×Nlambda] cm⁻¹ — shared grid
predictions.LaserWl    = repmat(laserWlNm, numValid, 1);
predictions.lambda_exc_nm = predictions.LaserWl;
predictions.RamanWindow   = opts.RamanWindow(:)';               % [1×2] metadata (grid generation)
if ~isempty(opts.MetricsRamanWindow)
    predictions.MetricsRamanWindow = opts.MetricsRamanWindow(:)'; % [1×2] metrics window
end

for t = 1:numTargets
    predictions.(targetNames{t}) = NaN(numValid, Nlambda);
end

%% Geometry-batched DNN inference
numBatches = ceil(numValid / batchSize);
for batchNum = 1:numBatches
    bStart   = (batchNum - 1) * batchSize + 1;
    bEnd     = min(batchNum   * batchSize, numValid);
    bRange   = bStart:bEnd;

    Pb       = PgValidCol(bRange);
    Rb       = RgValidCol(bRange);

    % Shared inference path (RI unit handling + schema-aware features).
    preds_b = predictSurrogateSpectrum(model, Pb, Rb, lambdaVecUm(:), ri, ...
        ChunkSize=chunkSize, ...
        ExecutionEnvironment=opts.ExecutionEnvironment, ...
        MiniBatchSize=opts.MiniBatchSize);                     % [nInBatch x Nlambda x numTargets]

    for t = 1:numTargets
        predictions.(targetNames{t})(bRange, :) = preds_b(:, :, t);
    end
    clear preds_b;

    if ~isempty(progressFcn)
        progressFcn(bEnd / numValid, sprintf( ...
            "Predicting batch %d/%d — geometries %d–%d of %d", ...
            batchNum, numBatches, bStart, bEnd, numValid));
    elseif opts.Verbose
        fprintf("predict_dense_spectrum: batch %d/%d (%d–%d / %d geometries)\n", ...
            batchNum, numBatches, bStart, bEnd, numValid);
    end
end

%% Vectorised scalar derivation (_laser, _broad / _avg, _analyte)
[~, laserIdx] = min(abs(ramanShiftRow));

% Use MetricsRamanWindow if provided; otherwise fall back to RamanWindow
metricsWindow = opts.MetricsRamanWindow;
if isempty(metricsWindow)
    metricsWindow = opts.RamanWindow;
end

stokesMask    = (ramanShiftRow > 0) & ...
                (ramanShiftRow >= metricsWindow(1)) & ...
                (ramanShiftRow <= metricsWindow(2));
shiftVec  = ramanShiftRow(stokesMask);   % [1×nStokes]
canAvg    = numel(shiftVec) >= 2;
shiftRange = 0;
if canAvg
    shiftRange = shiftVec(end) - shiftVec(1);
end

% Analyte weights
analyteSpec = opts.AnalyteSpectrum;
hasAnalyte  = isstruct(analyteSpec) && isfield(analyteSpec, 'shift_cm') && ...
              ~isempty(analyteSpec.shift_cm) && canAvg;
analyteWeights = [];
if hasAnalyte
    aw = interp1(analyteSpec.shift_cm(:), analyteSpec.intensity(:), ...
                 shiftVec(:)', 'makima', 0);
    aw = max(0, aw(:)');
    if sum(aw) > 0
        analyteWeights = aw / sum(aw);
    else
        hasAnalyte = false;
    end
end

for t = 1:numTargets
    tName   = targetNames{t};
    specMat = predictions.(tName);          % [numValid×Nlambda]

    % _laser: column at Raman shift ≈ 0
    predictions.([tName, '_laser']) = specMat(:, laserIdx);

    if canAvg && shiftRange > 0
        stokesMat = specMat(:, stokesMask); % [numValid×nStokes]
        broadVal = trapz(shiftVec, stokesMat, 2) ./ shiftRange;
        % _broad (canonical) and _avg (backward-compatible alias)
        predictions.([tName, '_broad']) = broadVal;
        predictions.([tName, '_avg'])   = broadVal;
        % _analyte: analyte-spectrum-weighted average
        if hasAnalyte
            predictions.([tName, '_analyte']) = stokesMat * analyteWeights(:);
        end
    else
        predictions.([tName, '_broad']) = specMat(:, laserIdx);
        predictions.([tName, '_avg'])   = specMat(:, laserIdx);
    end
end

% Cross-aliases and legacy field aliases so downstream callers keep working
if isfield(predictions, 'EF_vol_avg')
    predictions.BEE_vol      = predictions.EF_vol_avg;
    predictions.EE_V_broad   = predictions.EF_vol_avg;
end
if isfield(predictions, 'EE_V_broad')
    predictions.BEE_vol      = predictions.EE_V_broad;
    predictions.EF_vol_avg   = predictions.EE_V_broad;
    predictions.EF_vol_broad = predictions.EE_V_broad;
end
if isfield(predictions, 'EF_surf_avg')
    predictions.BEE_surf     = predictions.EF_surf_avg;
    predictions.EE_S_broad   = predictions.EF_surf_avg;
end
if isfield(predictions, 'EE_S_broad')
    predictions.BEE_surf     = predictions.EE_S_broad;
    predictions.EF_surf_avg  = predictions.EE_S_broad;
    predictions.EF_surf_broad = predictions.EE_S_broad;
end
if isfield(predictions, 'Absorptance_avg')
    predictions.Abs_avg      = predictions.Absorptance_avg;
    predictions.Abs_broad    = predictions.Absorptance_avg;
end
if isfield(predictions, 'Abs_broad')
    predictions.Abs_avg          = predictions.Abs_broad;
    predictions.Absorptance_avg  = predictions.Abs_broad;
    predictions.Absorptance_broad = predictions.Abs_broad;
end
if isfield(predictions, 'Absorptance_laser')
    predictions.Abs_laser = predictions.Absorptance_laser;
elseif isfield(predictions, 'Abs_laser')
    predictions.Absorptance_laser = predictions.Abs_laser;
end
if isfield(predictions, 'EF_vol_laser') && ~isfield(predictions, 'EE_V_laser')
    predictions.EE_V_laser = predictions.EF_vol_laser;
elseif isfield(predictions, 'EE_V_laser') && ~isfield(predictions, 'EF_vol_laser')
    predictions.EF_vol_laser = predictions.EE_V_laser;
end
if isfield(predictions, 'EF_surf_laser') && ~isfield(predictions, 'EE_S_laser')
    predictions.EE_S_laser = predictions.EF_surf_laser;
elseif isfield(predictions, 'EE_S_laser') && ~isfield(predictions, 'EF_surf_laser')
    predictions.EF_surf_laser = predictions.EE_S_laser;
end
if isfield(predictions, 'EF_vol_analyte')
    predictions.AEE_vol      = predictions.EF_vol_analyte;
    predictions.EE_V_analyte = predictions.EF_vol_analyte;
elseif isfield(predictions, 'EE_V_analyte')
    predictions.AEE_vol        = predictions.EE_V_analyte;
    predictions.EF_vol_analyte = predictions.EE_V_analyte;
end
if isfield(predictions, 'EF_surf_analyte')
    predictions.AEE_surf     = predictions.EF_surf_analyte;
    predictions.EE_S_analyte = predictions.EF_surf_analyte;
elseif isfield(predictions, 'EE_S_analyte')
    predictions.AEE_surf        = predictions.EE_S_analyte;
    predictions.EF_surf_analyte = predictions.EE_S_analyte;
end
end
