function [candidateTable, basePeakMask, gradMagnitude, laplacianField, divergenceField] = ...
    detect_maxima_candidates(avgMetricGrid, pSamples, rSamples, ratioLimit, cfg)
% detect_maxima_candidates  Analyze sensitivity grid to find candidate maxima.
%
%   [candidateTable, gradMag, lapField, divField] = detect_maxima_candidates( ...
%       avgMetricGrid, pSamples, rSamples, ratioLimit, cfg)
%
%   Inputs:
%       avgMetricGrid   - [Nr x Np] matrix of metric values
%       pSamples        - [1 x Np] vector of Period values
%       rSamples        - [1 x Nr] vector of Radius values
%       ratioLimit      - [min, max] ratio limits (can be 0/inf)
%       cfg             - Struct with fields:
%                           gradientPercentile
%                           laplacianFactor
%                           neighborTolerance
%                           neighborSuppressionRadius
%
%   Outputs:
%       candidateTable  - Table with columns: CandidateIndex, P_um, R_um,
%                         Ratio, GridValue, GradMag, Laplacian, Divergence
%       basePeakMask    - Logical mask of local maxima prior to filtering
%
%   See also: runLocalizationWorkflow

    arguments
        avgMetricGrid double
        pSamples (1,:) double
        rSamples (1,:) double
        ratioLimit (1,2) double
        cfg (1,1) struct
    end

    dpSpacing = localGridSpacing(pSamples);
    drSpacing = localGridSpacing(rSamples);
    
    if dpSpacing <= 0 || drSpacing <= 0
        % Fail gracefully if grid is degenerate
        candidateTable = table();
        basePeakMask = false(size(avgMetricGrid));
        gradMagnitude = zeros(size(avgMetricGrid));
        laplacianField = zeros(size(avgMetricGrid));
        divergenceField = zeros(size(avgMetricGrid));
        return;
    end

    [dFdR, dFdP] = gradient(avgMetricGrid, drSpacing, dpSpacing);
    gradMagnitude = hypot(dFdP, dFdR);

    [pMesh, rMesh] = meshgrid(pSamples, rSamples);
    divergenceField = divergence(pMesh, rMesh, dFdP, dFdR);
    laplacianField = del2(avgMetricGrid, drSpacing, dpSpacing);

    finiteMask = isfinite(avgMetricGrid);
    gradFinite = gradMagnitude(finiteMask);

    % Gradient threshold
    if isempty(gradFinite)
        gradThreshold = inf;
    else
        gradSorted = sort(gradFinite(:));
        % If cfg.gradientPercentile is e.g. 5, we keep the bottom 5% of gradients
        pct = max(0, min(100, cfg.gradientPercentile));
        idx = max(1, round(numel(gradSorted) * pct / 100));
        gradThreshold = max(1e-6, gradSorted(idx));
    end

    % Laplacian threshold (expect negative or zero)
    laplaceFinite = laplacianField(finiteMask);
    if isempty(laplaceFinite) || cfg.laplacianFactor <= 0
        laplacianThreshold = 0;
    else
        laplaceMin = min(laplaceFinite);
        if laplaceMin < 0
            laplacianThreshold = -max(1e-6, cfg.laplacianFactor * abs(laplaceMin));
        else
            laplacianThreshold = 0;
        end
    end

    % Find local maxima (8-connected neighborhood)
    basePeakMask = localFindGridLocalMaxima(avgMetricGrid, finiteMask, cfg.neighborTolerance);
    
    % Filter by Gradient (candidate must be flat-ish)
    peakMask = basePeakMask & (gradMagnitude <= gradThreshold);
    
    % Filter by Laplacian (candidate must be convex down)
    if laplacianThreshold < 0
        peakMask = peakMask & (laplacianField <= laplacianThreshold);
    else
        peakMask = peakMask & (laplacianField < 0);
    end

    % Ratio constraint
    ratioMask = true(size(avgMetricGrid));
    ratioLowerVal = ratioLimit(1);
    ratioUpperVal = ratioLimit(2);
    if ratioUpperVal == 0, ratioUpperVal = inf; end
    
    if ratioLowerVal > 0 || isfinite(ratioUpperVal)
        ratioGrid = rMesh ./ pMesh;
        if ratioLowerVal > 0
            ratioMask = ratioMask & (ratioGrid >= ratioLowerVal);
        end
        if isfinite(ratioUpperVal)
            ratioMask = ratioMask & (ratioGrid <= ratioUpperVal);
        end
    end
    peakMask = peakMask & ratioMask;

    % Fallback if too restrictive: Just use local maxima + ratio
    if ~any(peakMask(:))
        peakMask = basePeakMask & ratioMask;
    end

    % Exclude boundaries (often artifacts)
    peakMask(1,:) = false; peakMask(end,:) = false;
    peakMask(:,1) = false; peakMask(:,end) = false;

    % Sort by descending value
    [candRows, candCols] = find(peakMask);
    candidateIdx = sub2ind(size(avgMetricGrid), candRows, candCols);
    candidateValues = avgMetricGrid(candidateIdx);
    [candidateValues, sortOrder] = sort(candidateValues, 'descend');
    candRows = candRows(sortOrder);
    candCols = candCols(sortOrder);
    candidateIdx = candidateIdx(sortOrder);

    % Suppress neighbors
    keepMask = localSuppressCandidates(candRows, candCols, ...
        cfg.neighborSuppressionRadius, size(avgMetricGrid));
    candRows = candRows(keepMask);
    candCols = candCols(keepMask);
    candidateIdx = candidateIdx(keepMask);
    candidateValues = candidateValues(keepMask);

    candidateCount = numel(candidateValues);
    candP = pSamples(candCols);
    candR = rSamples(candRows);
    candRatio = candR ./ candP;
    candGrad = gradMagnitude(candidateIdx);
    candLap = laplacianField(candidateIdx);
    candDiv = divergenceField(candidateIdx);

    candidateTable = table( ...
        (1:candidateCount)', candP(:), candR(:), candRatio(:), candidateValues(:), ...
        candGrad(:), candLap(:), candDiv(:), ...
        'VariableNames', ...
        {'CandidateIndex','P_um','R_um','Ratio','GridValue','GradMag','Laplacian','Divergence'});
end

function peakMask = localFindGridLocalMaxima(grid, finiteMask, tol)
    gridSize = size(grid);
    gridClean = grid;
    gridClean(~finiteMask) = -inf;
    gridPadded = -inf(gridSize(1) + 2, gridSize(2) + 2);
    gridPadded(2:end-1, 2:end-1) = gridClean;
    center = gridPadded(2:end-1, 2:end-1);
    peakMask = finiteMask;
    offsets = [-1 -1; -1 0; -1 1; 0 -1; 0 1; 1 -1; 1 0; 1 1];
    for k = 1:size(offsets, 1)
        dy = offsets(k, 1);
        dx = offsets(k, 2);
        neighbor = gridPadded((2+dy):(end-1+dy), (2+dx):(end-1+dx));
        peakMask = peakMask & (center >= neighbor - tol);
    end
    peakMask(~finiteMask) = false;
end

function keepMask = localSuppressCandidates(rows, cols, radius, gridSize)
    numCandidates = numel(rows);
    keepMask = false(numCandidates, 1);
    if numCandidates == 0, return; end
    
    selected = false(gridSize);
    for idx = 1:numCandidates
        r = rows(idx);
        c = cols(idx);
        
        % Check if any neighbor in radius is already selected
        % Creating a bounding box for speed
        rMin = max(1, r - radius); rMax = min(gridSize(1), r + radius);
        cMin = max(1, c - radius); cMax = min(gridSize(2), c + radius);
        
        if any(selected(rMin:rMax, cMin:cMax), 'all')
            continue;
        end
        
        keepMask(idx) = true;
        selected(rMin:rMax, cMin:cMax) = true;
    end
end

function h = localGridSpacing(samples)
    samples = double(samples(:)');
    if numel(samples) < 2
        h = 0;
    else
        diffs = diff(samples);
        h = median(abs(diffs));
    end
end
