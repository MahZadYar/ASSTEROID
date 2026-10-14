function [candidateTable, basinMap] = detect_watershed_basins(metricGrid, pSamples, rSamples, options)
%detect_watershed_basins  Partition a 2-D metric map into catchment basins of its maxima.
%
%   [candidateTable, basinMap] = detect_watershed_basins(metricGrid, pSamples, rSamples)
%   [candidateTable, basinMap] = detect_watershed_basins(..., Name=Value)
%
%   Each local maximum of the metric surface owns a catchment basin: the
%   set of grid cells from which steepest ascent ends at that maximum. The
%   basins are found with a marker-controlled watershed (Image Processing
%   Toolbox):
%
%       1. imextendedmax(F, H)   regional maxima of the H-maxima transform.
%                                Ripples with dynamic <= H are merged into
%                                their parent peak; shoulder maxima with
%                                dynamic > H are kept as separate markers.
%       2. imimposemin(-F, M)    forces the markers to be the only regional
%                                minima of the inverted surface, so every
%                                basin contains exactly one marker.
%       3. watershed(...)        catchment basins + 1-pixel ridge lines (L=0).
%       4. bwdist(L > 0)         assigns ridge-line pixels to the nearest
%                                basin so the territories tile the domain.
%       5. regionprops / bwboundaries  per-basin peak, area, bounding box,
%                                outline polygon.
%
%   The saddle level of a basin is the highest metric value on its
%   watershed ridge (the lowest pass into a neighbouring basin). Depth is
%   peak value minus saddle level.
%
%   Inputs:
%       metricGrid  [Nr x Np] metric values (rows = radius, cols = period).
%                   NaN/Inf cells are treated as outside the domain.
%       pSamples    [1 x Np] period axis (any length unit, typically µm).
%       rSamples    [1 x Nr] radius axis (same unit as pSamples).
%
%   Name-Value Arguments:
%       Sensitivity  Merge threshold H as a fraction of the finite metric
%                    range (default 0.005 = 0.5 %). Lower values resolve more
%                    shoulder maxima; higher values merge them.
%       RatioLimit   [min, max] allowed r/p ratio (max = 0 or Inf disables).
%       MinArea      Minimum basin size in grid cells (default 4).
%       MaxBasins    Maximum number of basins returned, highest peaks first
%                    (default Inf). The label map keeps all basins.
%       Connectivity 4 or 8 (default 8).
%       AxisToNm     Scale factor from axis unit to nm, used for the stored
%                    nm axes and outline polygons (default 1e3, µm → nm).
%
%   Outputs:
%       candidateTable  Table sorted by descending peak value with columns
%                       CandidateIndex, P_um, R_um, Ratio, GridValue, Tag,
%                       BasinId, BasinArea, Saddle, Depth, PeakOnEdge,
%                       PMin_um, PMax_um, RMin_um, RMax_um.
%                       (P/R columns are in the axis unit of pSamples.)
%       basinMap        Struct with fields:
%                         labels     [Nr x Np] uint32 territory labels (0 = outside)
%                         values     [Nr x Np] metric grid
%                         pAxis, rAxis        axes in input unit
%                         pAxis_nm, rAxis_nm  axes in nm
%                         basinIds   BasinId per candidateTable row
%                         saddle, peakValue   per candidateTable row
%                         polygons   struct array (BasinId, P_nm, R_nm)
%                         sensitivity, hThreshold, connectivity
%
%   Example:
%       [cands, bmap] = detect_watershed_basins(F, pUm, rUm, Sensitivity=0.005);
%
%   See also: imextendedmax, imimposemin, watershed, regionprops,
%             bwboundaries, assignSeedsToBasins, runLocalizationWorkflow

    arguments
        metricGrid double
        pSamples (1,:) double
        rSamples (1,:) double
        options.Sensitivity (1,1) double {mustBeNonnegative} = 0.005
        options.RatioLimit (1,2) double = [0, Inf]
        options.MinArea (1,1) double {mustBePositive} = 4
        options.MaxBasins (1,1) double {mustBePositive} = Inf
        options.Connectivity (1,1) double {mustBeMember(options.Connectivity, [4, 8])} = 8
        options.AxisToNm (1,1) double {mustBePositive} = 1e3
    end

    [nR, nP] = size(metricGrid);
    if nR ~= numel(rSamples) || nP ~= numel(pSamples)
        error("detect_watershed_basins:SizeMismatch", ...
            "metricGrid is %dx%d but axes have %d radius and %d period samples.", ...
            nR, nP, numel(rSamples), numel(pSamples));
    end

    conn = options.Connectivity;
    candidateTable = localEmptyTable();
    basinMap = localEmptyMap(metricGrid, pSamples, rSamples, options);

    %% Domain mask: finite values within the r/p ratio window
    [pMesh, rMesh] = meshgrid(pSamples, rSamples);
    validMask = isfinite(metricGrid);
    ratioLo = options.RatioLimit(1);
    ratioHi = options.RatioLimit(2);
    if ratioHi <= 0, ratioHi = Inf; end
    if ratioLo > 0 || isfinite(ratioHi)
        ratioGrid = rMesh ./ pMesh;
        validMask = validMask & ratioGrid >= ratioLo & ratioGrid <= ratioHi;
    end
    if ~any(validMask, "all")
        return;
    end

    vMin = min(metricGrid(validMask));
    vMax = max(metricGrid(validMask));
    vRange = vMax - vMin;
    if ~(vRange > 0)
        return;   % flat surface: no maxima to separate
    end

    % Cells outside the domain are pushed below every valid value so they
    % act as deep valleys (barriers) and can never host a marker.
    filled = metricGrid;
    filled(~validMask) = vMin - vRange;

    hThreshold = max(options.Sensitivity * vRange, 10 * eps(vMax));
    basinMap.hThreshold = hThreshold;

    %% Markers → imposed minima → watershed
    markers = imextendedmax(filled, hThreshold, conn) & validMask;
    if ~any(markers, "all")
        return;
    end
    inverted = imimposemin(-filled, markers, conn);
    rawLabels = watershed(inverted, conn);
    rawLabels(~validMask) = 0;

    % Assign 1-pixel ridge lines to the nearest basin so territories tile
    % the domain (needed for seed lookup and for drawing adjacent patches).
    territory = rawLabels;
    if any(rawLabels(:) > 0)
        [~, nearestIdx] = bwdist(rawLabels > 0);
        territory = rawLabels(nearestIdx);
        territory(~validMask) = 0;
    end

    %% Per-basin properties
    stats = regionprops(territory, metricGrid, "Area", "PixelIdxList");
    nLabels = numel(stats);
    if nLabels == 0
        return;
    end

    rows = repmat(struct("BasinId", 0, "P", NaN, "R", NaN, "Value", NaN, ...
        "Area", 0, "Saddle", NaN, "Depth", NaN, "PeakOnEdge", false, ...
        "PMin", NaN, "PMax", NaN, "RMin", NaN, "RMax", NaN), nLabels, 1);
    keep = false(nLabels, 1);
    neighborhood = true(3);
    if conn == 4
        neighborhood = logical([0 1 0; 1 1 1; 0 1 0]);
    end

    for k = 1:nLabels
        pix = stats(k).PixelIdxList;
        if numel(pix) < options.MinArea
            continue;
        end
        [peakVal, iMax] = max(metricGrid(pix));
        [rIdx, pIdx] = ind2sub([nR, nP], pix(iMax));
        [rAll, pAll] = ind2sub([nR, nP], pix);

        % Saddle level: highest value on the raw watershed ridge around k.
        ownRaw = rawLabels == k;
        ring = imdilate(ownRaw, neighborhood) & ~ownRaw & validMask & rawLabels == 0;
        if any(ring, "all")
            saddleVal = max(metricGrid(ring));
        else
            saddleVal = min(metricGrid(pix));   % isolated basin: drop to its own floor
        end

        onEdge = rIdx == 1 || rIdx == nR || pIdx == 1 || pIdx == nP;
        if ~onEdge
            % Peak touching the ratio-mask boundary is also an edge peak.
            nbr = validMask(max(rIdx-1,1):min(rIdx+1,nR), max(pIdx-1,1):min(pIdx+1,nP));
            onEdge = ~all(nbr, "all");
        end

        rows(k).BasinId = k;
        rows(k).P = pSamples(pIdx);
        rows(k).R = rSamples(rIdx);
        rows(k).Value = peakVal;
        rows(k).Area = numel(pix);
        rows(k).Saddle = saddleVal;
        rows(k).Depth = peakVal - saddleVal;
        rows(k).PeakOnEdge = onEdge;
        rows(k).PMin = pSamples(min(pAll));
        rows(k).PMax = pSamples(max(pAll));
        rows(k).RMin = rSamples(min(rAll));
        rows(k).RMax = rSamples(max(rAll));
        keep(k) = true;
    end

    rows = rows(keep);
    if isempty(rows)
        return;
    end

    [~, order] = sort([rows.Value], "descend");
    rows = rows(order);
    nKeep = min(numel(rows), options.MaxBasins);
    rows = rows(1:nKeep);

    %% Outline polygons (nm) for display
    polygons = repmat(struct("BasinId", 0, "P_nm", [], "R_nm", []), nKeep, 1);
    pAxisNm = pSamples * options.AxisToNm;
    rAxisNm = rSamples * options.AxisToNm;
    for i = 1:nKeep
        bw = territory == rows(i).BasinId;
        B = bwboundaries(bw, conn, "noholes");
        polygons(i).BasinId = rows(i).BasinId;
        if isempty(B)
            continue;
        end
        [~, longest] = max(cellfun(@(b) size(b, 1), B));
        b = B{longest};
        polygons(i).P_nm = pAxisNm(b(:, 2));
        polygons(i).R_nm = rAxisNm(b(:, 1));
    end

    %% Assemble outputs
    pCol = [rows.P]';
    rCol = [rows.R]';
    candidateTable = table( ...
        (1:nKeep)', pCol, rCol, rCol ./ pCol, [rows.Value]', ...
        localBasinTags(nKeep), [rows.BasinId]', [rows.Area]', ...
        [rows.Saddle]', [rows.Depth]', [rows.PeakOnEdge]', ...
        [rows.PMin]', [rows.PMax]', [rows.RMin]', [rows.RMax]', ...
        'VariableNames', {'CandidateIndex', 'P_um', 'R_um', 'Ratio', 'GridValue', ...
        'Tag', 'BasinId', 'BasinArea', 'Saddle', 'Depth', 'PeakOnEdge', ...
        'PMin_um', 'PMax_um', 'RMin_um', 'RMax_um'});

    basinMap.labels = uint32(territory);
    basinMap.basinIds = [rows.BasinId]';
    basinMap.peakValue = [rows.Value]';
    basinMap.saddle = [rows.Saddle]';
    basinMap.polygons = polygons;
end

%% ========================================================================
function tags = localBasinTags(n)
%localBasinTags  Numerical seed labels: Seed 1, Seed 2, ...
    tags = strings(n, 1);
    for i = 1:n
        tags(i) = sprintf("Seed %d", i);
    end
end

function T = localEmptyTable()
    T = table('Size', [0, 15], ...
        'VariableTypes', {'double', 'double', 'double', 'double', 'double', ...
        'string', 'double', 'double', 'double', 'double', 'logical', ...
        'double', 'double', 'double', 'double'}, ...
        'VariableNames', {'CandidateIndex', 'P_um', 'R_um', 'Ratio', 'GridValue', ...
        'Tag', 'BasinId', 'BasinArea', 'Saddle', 'Depth', 'PeakOnEdge', ...
        'PMin_um', 'PMax_um', 'RMin_um', 'RMax_um'});
end

function m = localEmptyMap(metricGrid, pSamples, rSamples, options)
    m = struct();
    m.labels = zeros(size(metricGrid), "uint32");
    m.values = metricGrid;
    m.pAxis = pSamples;
    m.rAxis = rSamples;
    m.pAxis_nm = pSamples * options.AxisToNm;
    m.rAxis_nm = rSamples * options.AxisToNm;
    m.basinIds = zeros(0, 1);
    m.peakValue = zeros(0, 1);
    m.saddle = zeros(0, 1);
    m.polygons = struct("BasinId", {}, "P_nm", {}, "R_nm", {});
    m.sensitivity = options.Sensitivity;
    m.hThreshold = NaN;
    m.connectivity = options.Connectivity;
end
