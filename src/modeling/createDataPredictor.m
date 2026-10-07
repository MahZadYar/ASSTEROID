function predictor = createDataPredictor(allData, options)
    %createDataPredictor  Build a spatial+spectral interpolation predictor from raw SoA data.
    %
    %   predictor = createDataPredictor(allData) creates a predictor struct that
    %   uses Delaunay triangulation + barycentric weights for spatial (p, r)
    %   interpolation and 1D makima (or chosen method) along the spectral axis.
    %   For "nearest" mode, knnsearch provides zero-overhead lookup.
    %   No scatteredInterpolant objects are created or cached.
    %
    %   Heterogeneous wavelength grids:  Simulation data (db.Sim) stores each
    %   geometry's own spectral sampling in its lambda row — rows can differ in
    %   number of points, wavelength range, and spacing.  On construction, this
    %   function builds a common union wavelength grid from all rows and pre-
    %   resamples every sim point so that column k always maps to the same
    %   wavelength for every row.  Prediction functions then use the pre-
    %   resampled data for spatial interpolation, ensuring consistent column
    %   semantics across geometries.
    %
    %   The predictor struct exposes:
    %       .mode           "interpolation"
    %       .targetNames    Cell array of target metric names found in data
    %       .predictSpectral Function handle: @(p, r, lambdaVec) -> [Nl x T]
    %       .predictGrid    Function handle: @(pVec, rVec, lambdaVec) -> SoA struct
    %       .pGrid          Unique period values from data (nm)
    %       .rGrid          Unique radius values from data (nm)
    %       .lambdaGrid     Common union wavelength grid (nm, ascending)
    %
    %   Input:
    %       allData — SoA struct with fields: period, radius, lambda, plus
    %                 spectral metric fields (EF_vol, EF_surf, Absorptance, etc.)
    %                 lambda can be [N x L] with per-row sampling (NaN-padded).
    %
    %   Name-Value Arguments:
    %       TargetNames    (1,:) string — Metrics to interpolate.
    %                      Default: auto-detect spectral [N x L] fields.
    %       ExtrapMethod   (1,1) string — Extrapolation method (default: "none")
    %       InterpMethod   (1,1) string — 2D spatial interp method (default: "natural")
    %       SpectralMethod (1,1) string — 1D spectral interp method (default: "makima")
    %       LaserWavelength (1,1) double — Laser wavelength in nm; 0 = not specified.
    %
    %   Output:
    %       predictor — Unified predictor struct
    %
    %   Example:
    %       loaded = load("prl_sweep.mat", "allData");
    %       pred = createDataPredictor(loaded.allData);
    %       spectrum = pred.predictSpectral(850, 200, 780:1:1100);
    %
    %   See also: createModelPredictor, buildPredictorFromConfig, reshapeSoAToVolume

    arguments
        allData (1,1) struct
        options.TargetNames (1,:) string = string.empty
        options.ExtrapMethod (1,1) string {mustBeMember(options.ExtrapMethod, ...
            ["none", "nearest", "linear"])} = "none"
        options.InterpMethod (1,1) string {mustBeMember(options.InterpMethod, ...
            ["natural", "linear", "nearest"])} = "natural"
        options.SpectralMethod (1,1) string {mustBeMember(options.SpectralMethod, ...
            ["makima", "pchip", "linear", "spline"])} = "makima"
        options.LaserWavelength (1,1) double = 0  % nm; 0 = not specified
    end

    %% Validate SoA structure
    if ~isfield(allData, "period") || ~isfield(allData, "radius") || ~isfield(allData, "lambda")
        error("createDataPredictor:MissingSoA", ...
            "allData must contain period, radius, and lambda fields.");
    end

    %% Detect spectral targets
    if isempty(options.TargetNames)
        targetNames = detectSpectralTargets(allData);
    else
        targetNames = cellstr(options.TargetNames);
    end

    if isempty(targetNames)
        error("createDataPredictor:NoTargets", ...
            "No spectral [N x L] metric fields found in data.");
    end

    %% Extract sample points and wavelength vector from SoA
    pVals = unique(allData.period(:), "sorted");
    rVals = unique(allData.radius(:), "sorted");

    lambdaAll = double(allData.lambda);  % [N x L] — per-row, may differ
    N_sim = size(lambdaAll, 1);

    % Unit detection: if the largest finite value across all rows is < 10, assume µm
    allFiniteVals = lambdaAll(isfinite(lambdaAll));
    if ~isempty(allFiniteVals) && max(allFiniteVals) < 10
        lambdaAll = lambdaAll * 1e3;  % µm → nm
    end

    %% Build common union wavelength grid
    %  db.Sim.lambda is [N×L] with per-row spectral sampling — each COMSOL sweep
    %  can have a different number of points, wavelength range, or spacing.
    %  We build the union of all finite wavelengths and pre-resample every sim
    %  point to this common grid so that column k always maps to lambdaVals(k).
    perRowLambda = cell(N_sim, 1);
    uniqueWls = [];
    for i = 1:N_sim
        rowLam = sort(lambdaAll(i, isfinite(lambdaAll(i, :))), "ascend");
        perRowLambda{i} = rowLam;
        uniqueWls = union(uniqueWls, rowLam);
    end
    lambdaVals = uniqueWls(:)';  % common grid (nm, ascending)

    % Find the laser wavelength column in the common grid.
    if options.LaserWavelength > 0
        [~, laserRawCol] = min(abs(lambdaVals - options.LaserWavelength));
    else
        laserRawCol = 0;
    end

    if numel(pVals) < 2 || numel(rVals) < 2
        error("createDataPredictor:InsufficientGrid", ...
            "Need at least 2 unique values for period (%d) and radius (%d).", ...
            numel(pVals), numel(rVals));
    end

    %% Extract raw sample coordinates [N x 1]
    pSamples = double(allData.period(:));
    rSamples = double(allData.radius(:));

    %% Pre-resample each target to the common union grid
    numTargets = numel(targetNames);
    rawSpectra = cell(1, numTargets);  % each cell: [N_sim x numLcommon]
    numLcommon = numel(lambdaVals);

    interpMethod = char(options.InterpMethod);
    spectralMethod = char(options.SpectralMethod);

    for t = 1:numTargets
        tName = targetNames{t};
        if ~isfield(allData, tName)
            error("createDataPredictor:MissingField", ...
                "Target field '%s' not found in allData.", tName);
        end
        rawFull = double(allData.(tName));  % [N x Lpadded]
        resampled = zeros(N_sim, numLcommon);

        for i = 1:N_sim
            rowLam = perRowLambda{i};
            % Extract valid (non-NaN) portion of this row, sorted by wavelength
            finMask = isfinite(lambdaAll(i, :));
            rowLam = lambdaAll(i, finMask);
            rowVals = rawFull(i, finMask);
            [rowLam, sIdx] = sort(rowLam, "ascend");
            rowVals = rowVals(sIdx);

            % Filter to mutually finite wavelength and value pairs
            valMask = isfinite(rowLam) & isfinite(rowVals);
            vLam = rowLam(valMask);
            vVal = rowVals(valMask);
            if ~isempty(vLam)
                [vLam, uIdx] = unique(vLam, "sorted");
                vVal = vVal(uIdx);
            end

            if numel(vLam) >= 2
                % Clamp common grid to this row's range (no extrapolation)
                lambdaClamped = max(min(lambdaVals, vLam(end)), vLam(1));
                resampled(i, :) = interp1(vLam(:), vVal(:), lambdaClamped(:), spectralMethod)';

                % Inject exact raw value at laser wavelength to avoid interp artefact
                if laserRawCol > 0
                    [minDist, srcLaserIdx] = min(abs(vLam - options.LaserWavelength));
                    if minDist < 0.5  % within 0.5 nm
                        resampled(i, laserRawCol) = vVal(srcLaserIdx);
                    end
                end
            elseif numel(vLam) == 1
                resampled(i, :) = vVal;
            else
                validIdx = find(isfinite(rawFull(i, :)), 1);
                if ~isempty(validIdx)
                    resampled(i, :) = rawFull(i, validIdx);
                else
                    resampled(i, :) = 0;
                end
            end
        end

        resampled(~isfinite(resampled)) = 0;
        rawSpectra{t} = resampled;
    end

    %% Pre-compute spatial lookup structure
    samplePts = [pSamples(:), rSamples(:)];
    if ismember(interpMethod, {'linear', 'natural'})
        DT = delaunayTriangulation(pSamples(:), rSamples(:));
    else
        DT = [];  % knnsearch used directly for "nearest"
    end

    %% Build predictor struct
    predictor = struct();
    predictor.mode = "interpolation";
    predictor.targetNames = targetNames;
    predictor.pGrid = pVals(:)';
    predictor.rGrid = rVals(:)';
    predictor.lambdaGrid = lambdaVals(:)';

    predictor.predictSpectral = @(p, r, lambdaVec) ...
        predictSpectralInterp(p, r, lambdaVec, ...
        samplePts, DT, rawSpectra, lambdaVals, interpMethod, spectralMethod);

    predictor.predictGrid = @(pVec, rVec, lambdaVec, varargin) ...
        predictGridInterp(pVec, rVec, lambdaVec, ...
        targetNames, rawSpectra, pSamples, rSamples, lambdaVals, ...
        samplePts, DT, interpMethod, spectralMethod, varargin{:});

    predictor.predictPointsBatch = @(pArr, rArr, lambdaVec, varargin) ...
        predictPointsBatchInterp(pArr, rArr, lambdaVec, ...
        samplePts, DT, rawSpectra, lambdaVals, interpMethod, spectralMethod, laserRawCol, varargin{:});
end

%% ========================================================================
function result = predictSpectralInterp(pVal, rVal, lambdaVec, ...
        samplePts, DT, rawSpectraCell, lambdaVals, interpMethod, spectralMethod)
    %predictSpectralInterp  Single-point prediction using DT + barycentric or kNN.
    %
    %   Returns [Nl x T] matrix where Nl = numel(lambdaVec), T = numTargets.

    lambdaVec = double(lambdaVec(:));
    pVal = double(pVal);
    rVal = double(rVal);
    numLout = numel(lambdaVec);
    numT = numel(rawSpectraCell);

    result = zeros(numLout, numT);

    if strcmp(interpMethod, "nearest")
        % Nearest-neighbour: find closest sample, copy+resample its spectrum.
        [idx, ~] = knnsearch(samplePts, [pVal, rVal]);
        for t = 1:numT
            rawSpec = rawSpectraCell{t}(idx, :);  % [1 x numLraw]
            result(:, t) = resampleSpectrum1D(rawSpec, lambdaVals, lambdaVec, spectralMethod);
        end
    else
        % Linear (barycentric): locate enclosing triangle, compute weights.
        [triIdx, bary] = pointLocation(DT, pVal, rVal);
        if isnan(triIdx)
            % Outside convex hull — fall back to nearest.
            [idx, ~] = knnsearch(samplePts, [pVal, rVal]);
            for t = 1:numT
                rawSpec = rawSpectraCell{t}(idx, :);
                result(:, t) = resampleSpectrum1D(rawSpec, lambdaVals, lambdaVec, spectralMethod);
            end
        else
            vIds = DT.ConnectivityList(triIdx, :);  % [1 x 3] vertex indices
            b = bary;  % [1 x 3] barycentric weights
            for t = 1:numT
                M = rawSpectraCell{t};  % [Nsamp x numLraw]
                % Resample each vertex spectrum first, then blend — matches
                % the grid-path order and avoids makima nonlinearity artefacts.
                s1 = resampleSpectrum1D(M(vIds(1), :), lambdaVals, lambdaVec, spectralMethod);
                s2 = resampleSpectrum1D(M(vIds(2), :), lambdaVals, lambdaVec, spectralMethod);
                s3 = resampleSpectrum1D(M(vIds(3), :), lambdaVals, lambdaVec, spectralMethod);
                result(:, t) = b(1)*s1 + b(2)*s2 + b(3)*s3;
            end
        end
    end

    result(~isfinite(result)) = 0;
end

%% ========================================================================
function allData = predictGridInterp(pVec, rVec, lambdaVec, ...
        targetNames, rawSpectra, pSamples, rSamples, ...
        lambdaVals, samplePts, DT, interpMethod, spectralMethod, varargin)
    %predictGridInterp  Dense grid prediction via DT + barycentric.
    %   Processes one target at a time with geometry batching to stay within
    %   available memory. Reports progress via the optional ProgressFcn callback.

    opts = parseGridOpts(varargin{:});
    batchSize  = opts.BatchSize;
    progressFcn = opts.ProgressFcn;
    hasProgress = ~isempty(progressFcn);

    pVec = double(pVec(:));
    rVec = double(rVec(:));
    lambdaVec = double(lambdaVec(:)');

    numT = numel(targetNames);

    % Build full meshgrid and mask invalid (r >= p/2) combos
    [RMesh, PMesh] = ndgrid(rVec, pVec);
    geomMask = RMesh < PMesh / 2;
    numGeom = sum(geomMask(:));
    numLout = numel(lambdaVec);

    pFlat = PMesh(geomMask);
    rFlat = RMesh(geomMask);

    % Unit detection and conversion to nm for spatial/spectral queries
    isUm = max(lambdaVec) < 10;
    if isUm
        lambdaTarget_nm = lambdaVec * 1e3;
        pQuery = pFlat * 1e3;
        rQuery = rFlat * 1e3;
    else
        lambdaTarget_nm = lambdaVec;
        pQuery = pFlat;
        rQuery = rFlat;
    end

    % Find the laser column in source (raw, sorted, nm) and dest (output, nm) grids.
    % opts.LaserWavelength is always in nm (from computeDenseGridParams.lambdaLaser).
    % lambdaVals is sorted ascending in nm (from createDataPredictor).
    laserRawCol = 0;
    laserOutCol = 0;
    if opts.LaserWavelength > 0
        [~, laserRawCol] = min(abs(lambdaVals - opts.LaserWavelength));
        [~, laserOutCol] = min(abs(lambdaTarget_nm - opts.LaserWavelength));
    end

    %% Pre-compute spatial lookup ONCE for all geometry points (shared across targets)
    useNearest = strcmp(interpMethod, "nearest");
    if useNearest
        nearIdxFull = knnsearch(samplePts, [pQuery, rQuery]);
        triIdxAll   = [];
        baryAll     = [];
    else
        [triIdxAll, baryAll] = pointLocation(DT, pQuery, rQuery);
        outsideAll = isnan(triIdxAll);
        % Build a full-size nearest-fallback index (0 = inside hull)
        nearIdxFull = zeros(numGeom, 1, "uint32");
        if any(outsideAll)
            outsidePos = find(outsideAll);
            nearIdxFull(outsidePos) = knnsearch(samplePts, [pQuery(outsidePos), rQuery(outsidePos)]);
        end
    end

    %% Build output SoA coords
    allData = struct();
    if isUm
        allData.period = pFlat * 1e3;
        allData.radius = rFlat * 1e3;
        allData.lambda = lambdaVec(:)' * 1e3;  % [1×Nlambda] — shared grid
    else
        allData.period = pFlat;
        allData.radius = rFlat;
        allData.lambda = lambdaVec(:)';         % [1×Nlambda] — shared grid
    end

    % RamanShift needed by recomputeDerivedMetrics (called after this function)
    if opts.LaserWavelength > 0
        laserNm = opts.LaserWavelength;
        allData.LaserWl    = laserNm;
        lambdaNm1 = allData.lambda;  % already [1×Nlambda] in nm or µm
        % lambda in output SoA may be in nm or µm depending on OutputUnit;
        % convert to nm for the Raman shift formula.
        if isUm
            lambdaNm1 = lambdaNm1 * 1e3;
        end
        allData.RamanShift = (1/laserNm - 1./lambdaNm1) * 1e7; % [1×Nlambda] — shared grid
    end
    if ~isempty(opts.RamanWindow)
        allData.RamanWindow = opts.RamanWindow;
    end

    numBatches = ceil(numGeom / batchSize);
    totalSteps = numT * numBatches;
    stepsDone  = 0;

    %% Process targets one at a time — avoids holding all dense spectra simultaneously
    Nsamp = numel(pSamples);
    for t = 1:numT
        tName = char(targetNames{t});

        % Step 1: Densify this target's raw sim points to the output lambda grid
        %         [Nsamp x numLout] — small (raw_pts × output_wavelengths)
        rawMat   = rawSpectra{t};  % [Nsamp x numLraw]
        denseMat = NaN(Nsamp, numLout);
        for ii = 1:Nsamp
            denseMat(ii, :) = resampleSpectrum1D( ...
                rawMat(ii, :), lambdaVals, lambdaTarget_nm, spectralMethod);
        end
        % Override laser column: inject exact raw-data value to avoid any spectral
        % interpolation artifact at the laser wavelength.
        if laserRawCol > 0
            denseMat(:, laserOutCol) = rawMat(:, laserRawCol);
        end

        % Step 2: Preallocate output for this target; fill in geometry batches
        %         [numGeom x numLout] — the largest single allocation per target
        tMat = NaN(numGeom, numLout);

        for bIdx = 1:numBatches
            bStart = (bIdx - 1) * batchSize + 1;
            bEnd   = min(bIdx * batchSize, numGeom);
            bRange = bStart:bEnd;

            if useNearest
                tMat(bRange, :) = denseMat(nearIdxFull(bRange), :);
            else
                triB  = triIdxAll(bRange);
                baryB = baryAll(bRange, :);
                outside = isnan(triB);

                insideLocal = find(~outside);
                if ~isempty(insideLocal)
                    insideGlobal = bRange(insideLocal);
                    vIds = DT.ConnectivityList(triB(insideLocal), :);
                    bW   = baryB(insideLocal, :);
                    tMat(insideGlobal, :) = bW(:,1) .* denseMat(vIds(:,1), :) ...
                                          + bW(:,2) .* denseMat(vIds(:,2), :) ...
                                          + bW(:,3) .* denseMat(vIds(:,3), :);
                end

                outsideLocal = find(outside);
                if ~isempty(outsideLocal)
                    outsideGlobal = bRange(outsideLocal);
                    tMat(outsideGlobal, :) = denseMat(nearIdxFull(outsideGlobal), :);
                end
            end

            stepsDone = stepsDone + 1;
            if hasProgress
                progressFcn(stepsDone / totalSteps, ...
                    sprintf("Interpolating '%s' (%d/%d), batch %d/%d — rows %d–%d of %d", ...
                        tName, t, numT, bIdx, numBatches, bStart, bEnd, numGeom));
            end
            drawnow limitrate nocallbacks;
        end

        tMat(~isfinite(tMat)) = 0;
        allData.(tName) = tMat;
        % Release working arrays before next target to keep peak memory low
        clear denseMat tMat;
    end
end

%% ========================================================================
function result = predictPointsBatchInterp(pArr, rArr, lambdaVec, ...
        samplePts, DT, rawSpectraCell, lambdaVals, ...
        interpMethod, spectralMethod, laserRawCol, progressCb)
    %predictPointsBatchInterp  Batch prediction using DT + barycentric (no scatteredInterpolant).
    %
    %   "nearest":  knnsearch → gather all rows → ONE vectorised interp1 per target.
    %   "linear":   resample all sim spectra to output grid → barycentric weighted sum.
    %
    %   The linear path resamples BEFORE spatial blending to match the grid-
    %   path order of operations and avoid nonlinear artefacts from makima.
    %   Returns [N × Lout × T].

    if nargin < 11, progressCb = []; end
    hasCb = ~isempty(progressCb);

    pArr = double(pArr(:));
    rArr = double(rArr(:));
    lambdaVec = double(lambdaVec(:)');
    N = numel(pArr);
    numLout = numel(lambdaVec);
    numT = numel(rawSpectraCell);
    numLraw = numel(lambdaVals);

    result = zeros(N, numLout, numT);

    % Clamp destination wavelengths once (shared across all targets/methods)
    lB1 = min(lambdaVals);
    lB2 = max(lambdaVals);
    lambdaClamped = min(max(lambdaVec(:), lB1), lB2);  % [numLout x 1]

    % Find the laser output column: use the exact raw-data value at the laser
    % wavelength (already found in createDataPredictor as laserRawCol) rather
    % than relying on spectral interpolation at that single query point.
    laserOutCol = 0;
    if laserRawCol > 0
        laserWlNm = lambdaVals(laserRawCol);  % nm (sorted, unit-corrected)
        % lambdaVec from buildPointPredictionSoA is always in nm
        [~, laserOutCol] = min(abs(lambdaVec - laserWlNm));
    end

    if strcmp(interpMethod, "nearest")
        %% Nearest-neighbour path — fully vectorised per target
        nearIdx = knnsearch(samplePts, [pArr, rArr]);

        for t = 1:numT
            if hasCb, progressCb(t, numT, numLraw); end
            M = rawSpectraCell{t};             % [Nsamp x numLraw]
            rawRows = M(nearIdx, :);           % [N x numLraw] — gather all at once
            result(:, :, t) = resampleMatrix(rawRows, lambdaVals, lambdaClamped, spectralMethod);
            % Override laser column with the exact raw value — no spectral interpolation
            % artifact at the laser wavelength (index found in createDataPredictor).
            if laserOutCol > 0
                result(:, laserOutCol, t) = rawRows(:, laserRawCol);
            end
            drawnow limitrate nocallbacks;
        end
    else
        %% Linear / barycentric path — resample first, then spatial blend
        %  Resample every sim-point spectrum to the output grid before
        %  barycentric blending.  makima slope estimation is non-linear
        %  in Y, so blend(resample(Y)) ≠ resample(blend(Y)).

        % ONE pointLocation call for all query points — shared across targets.
        [triIdx, bary] = pointLocation(DT, pArr, rArr);
        outsideHull = isnan(triIdx);
        insideIdx = find(~outsideHull);

        % Vertex indices for inside points [Ninside x 3]
        vIds = DT.ConnectivityList(triIdx(insideIdx), :);
        baryW = bary(insideIdx, :);  % [Ninside x 3]

        % Nearest-neighbour fallback for outside-hull points
        outsideFallbackIdx = [];
        outsidePos = [];
        if any(outsideHull)
            outsideFallbackIdx = knnsearch(samplePts, [pArr(outsideHull), rArr(outsideHull)]);
            outsidePos = find(outsideHull);
        end

        for t = 1:numT
            if hasCb, progressCb(t, numT, numLout); end

            M = rawSpectraCell{t};  % [Nsamp x numLraw]

            % Step 1: Resample every sim-point spectrum to the output λ grid.
            denseSim = resampleMatrix(M, lambdaVals, lambdaClamped, spectralMethod);
            if laserOutCol > 0
                denseSim(:, laserOutCol) = M(:, laserRawCol);
            end

            % Step 2: Barycentric weighted sum on dense spectra
            if ~isempty(insideIdx)
                result(insideIdx, :, t) = baryW(:, 1) .* denseSim(vIds(:, 1), :) ...
                                        + baryW(:, 2) .* denseSim(vIds(:, 2), :) ...
                                        + baryW(:, 3) .* denseSim(vIds(:, 3), :);
            end
            if ~isempty(outsideFallbackIdx)
                result(outsidePos, :, t) = denseSim(outsideFallbackIdx, :);
            end
            clear denseSim;
            drawnow limitrate nocallbacks;
        end
    end

    result(~isfinite(result)) = 0;
end

%% ========================================================================
function out = resampleMatrix(rawRows, lambdaSrc, lambdaDstClamped, method)
    %resampleMatrix  Vectorised 1-D spectral resampling for all N rows at once.
    %   Uses interp1 matrix-Y form: one call per target instead of N calls.
    %
    %   rawRows:          [N x numLraw]  — raw spectral matrix (may contain NaN)
    %   lambdaSrc:        [1 x numLraw]  — source wavelength grid (sorted ascending)
    %   lambdaDstClamped: [numLout x 1]  — destination grid already clamped to src range
    %   out:              [N x numLout]

    % Keep only columns where the source wavelength axis is finite.
    % Padded SoA rows use NaN to fill short spectra; interp1 rejects NaN x-values.
    finiteCol = isfinite(lambdaSrc(:));
    if ~all(finiteCol)
        lambdaSrc = lambdaSrc(finiteCol);
        rawRows   = rawRows(:, finiteCol);
        % Re-clamp destination to the now-narrower source range
        lB1 = min(lambdaSrc);
        lB2 = max(lambdaSrc);
        lambdaDstClamped = min(max(lambdaDstClamped, lB1), lB2);
    end

    rawRows(~isfinite(rawRows)) = 0;

    % Belt-and-suspenders: ensure source λ is sorted ascending and deduplicated.
    % interp1 requires monotonically increasing sample points.
    lambdaSrcVec = lambdaSrc(:);
    if ~issorted(lambdaSrcVec)
        [lambdaSrcVec, sIdx] = sort(lambdaSrcVec, "ascend");
        rawRows = rawRows(:, sIdx);
    end
    [lambdaSrcVec, uIdx] = unique(lambdaSrcVec, "sorted");
    rawRows = rawRows(:, uIdx);

    if numel(lambdaSrcVec) < 2
        if numel(lambdaSrcVec) == 1
            out = repmat(rawRows, 1, numel(lambdaDstClamped));
        else
            out = zeros(size(rawRows, 1), numel(lambdaDstClamped));
        end
        out(~isfinite(out)) = 0;
        return;
    end

    try
        % interp1(x[Lr×1], Y[Lr×N], xi[Lo×1]) → [Lo×N]; transpose → [N×Lo]
        out = interp1(lambdaSrcVec, rawRows', lambdaDstClamped(:), method)';
    catch
        % Fallback: per-row when interp1 matrix-Y is unavailable for this method
        N = size(rawRows, 1);
        numLout = numel(lambdaDstClamped);
        out = zeros(N, numLout);
        for i = 1:N
            out(i, :) = interp1(lambdaSrcVec, rawRows(i, :)', ...
                lambdaDstClamped(:), method, 0)';
        end
    end
    out(~isfinite(out)) = 0;
end

%% ========================================================================
function out = resampleSpectrum1D(spec, lambdaSrc, lambdaDst, spectralMethod)
    %resampleSpectrum1D  1D spectral interpolation from raw λ grid to target.
    spec = spec(:)';
    lambdaDst = lambdaDst(:)';
    valid = isfinite(spec) & isfinite(lambdaSrc(:)');
    if nnz(valid) >= 2
        lR = lambdaSrc(valid);
        vR = spec(valid);
        [lR, uIdx] = unique(lR(:), "sorted");
        vR = vR(uIdx);
        if numel(lR) >= 2
            lC = max(min(lambdaDst, max(lR)), min(lR));
            switch spectralMethod
                case "makima"
                    out = makima(lR(:), vR(:), lC(:))';
                case "pchip"
                    out = pchip(lR(:), vR(:), lC(:))';
                case "spline"
                    out = spline(lR(:), vR(:), lC(:))';
                otherwise
                    out = interp1(lR(:), vR(:), lC(:), "linear", NaN)';
            end
        elseif numel(lR) == 1
            out = repmat(vR, 1, numel(lambdaDst));
        else
            out = zeros(1, numel(lambdaDst));
        end
    elseif nnz(valid) == 1
        out = repmat(spec(find(valid, 1)), 1, numel(lambdaDst));
    else
        out = zeros(1, numel(lambdaDst));
    end
end

%% ========================================================================
function targets = detectSpectralTargets(allData)
    %detectSpectralTargets  Find [N x L] spectral fields in SoA struct.

    exclude = ["period", "radius", "lambda", "lambda_nm", "RamanShift", ...
               "LaserWl", "lambda_exc_nm", "RamanWindow", "RamanWindowEffective", ...
               "p", "r", "particle_r", "f"];
    flds = fieldnames(allData);
    N = numel(allData.period);
    L = size(allData.lambda, 2);
    targets = {};

    for i = 1:numel(flds)
        fn = string(flds{i});
        if ismember(fn, exclude), continue; end
        if contains(fn, "_avg"), continue; end
        v = allData.(fn);
        if isnumeric(v) && isequal(size(v), [N, L])
            targets{end+1} = fn; %#ok<AGROW>
        end
    end
end

%% ========================================================================
function opts = parseGridOpts(varargin)
    %parseGridOpts  Parse optional name-value pairs for grid prediction.
    opts = struct("LaserWavelength", 0, "RamanWindow", [], ...
                  "BatchSize", 1000, "ProgressFcn", []);
    for i = 1:2:numel(varargin)
        key = lower(string(varargin{i}));
        val = varargin{i+1};
        switch key
            case "laserwavelength",  opts.LaserWavelength = val;
            case "ramanwindow",      opts.RamanWindow = val;
            case "batchsize",        opts.BatchSize = max(100, double(val));
            case "progressfcn",      opts.ProgressFcn = val;
        end
    end
end