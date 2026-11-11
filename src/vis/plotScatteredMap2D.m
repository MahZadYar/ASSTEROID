function info = plotScatteredMap2D(ax, p, r, v, options)
%plotScatteredMap2D  Render a scalar metric over the (period, radius) plane.
%
%   info = plotScatteredMap2D(ax, p, r, v)
%   info = plotScatteredMap2D(ax, p, r, v, Name=Value)
%
%   Chooses the rendering path from the sample layout:
%     * Regular (p, r) grid  -> direct mapping, pcolor with interpolated shading.
%     * Scattered samples    ->
%         "triangulated"  (default) Exact unstructured points: Delaunay mesh
%                          drawn with patch(FaceColor="interp"); shades each
%                          triangle by barycentric interpolation (zero gridding).
%         "voronoi"       Exact unstructured points: bounded Voronoi cells
%                          drawn with patch(FaceColor="flat"); shades each
%                          cell with its exact uninterpolated value.
%         "natural" | "linear" | "nearest"
%                         Interpolated onto a transient regular raster via
%                          scatteredInterpolant, masked to the convex hull,
%                          and rendered with pcolor.
%
%   Inputs:
%       ax - target axes (axes or uiaxes)
%       p  - [N x 1] period (nm)
%       r  - [N x 1] radius (nm)
%       v  - [N x 1] metric values
%
%   Name-Value Arguments:
%       Method           - "triangulated" (default) | "voronoi" | "nearest" | "natural" | "linear" | "grid"
%       Colormap         - [M x 3] colormap (default parula(256))
%       LogScale         - plot log10(v); non-positive values become NaN (false)
%       Title            - axes title ("")
%       ColorbarLabel    - colorbar label ("")
%       ShowPoints       - overlay sample locations (false)
%       PointsP, PointsR - explicit overlay coordinates (default: p, r)
%       OptimaP, OptimaR - optional optima markers ([])
%       RasterSize       - display raster size when SpatialResolution is unset (300)
%       SpatialResolution - spatial resolution in nm (e.g. 2 nm) for gridded raster
%
%   Output:
%       info - struct: isGridded, method, nValid, gridSize, resolution, valueRange
%
%   See also: patch, delaunay, voronoiDiagram, pcolor, scatteredInterpolant, renderAnnotatedVolume

    arguments
        ax
        p (:,1) double
        r (:,1) double
        v (:,1) double
        options.Method (1,1) string {mustBeMember(options.Method, ["triangulated", "voronoi", "nearest", "natural", "linear", "grid"])} = "triangulated"
        options.Colormap double = parula(256)
        options.LogScale (1,1) logical = false
        options.Title (1,1) string = ""
        options.ColorbarLabel (1,1) string = ""
        options.ShowPoints (1,1) logical = false
        options.PointsP (:,1) double = []
        options.PointsR (:,1) double = []
        options.OptimaP (:,1) double = []
        options.OptimaR (:,1) double = []
        options.RasterSize (1,1) double {mustBePositive, mustBeInteger} = 300
        options.SpatialResolution double = NaN
    end

    if numel(p) ~= numel(r) || numel(p) ~= numel(v)
        error("plotScatteredMap2D:SizeMismatch", "p, r and v must have the same length.");
    end

    if options.LogScale
        v(v <= 0) = NaN;
        v = log10(v);
    end
    valid = isfinite(p) & isfinite(r) & isfinite(v);
    pV = p(valid); rV = r(valid); vV = v(valid);

    info = struct("isGridded", false, "method", "", "nValid", nnz(valid), ...
        "gridSize", [0 0], "resolution", [NaN NaN], "valueRange", [NaN NaN]);

    cla(ax, "reset");
    localStyleAxes(ax);
    hold(ax, "on");

    if numel(vV) < 3
        text(ax, 0.5, 0.5, "Not enough finite samples to render.", ...
            "Units", "normalized", "HorizontalAlignment", "center", "Color", "w");
        hold(ax, "off");
        return;
    end
    info.valueRange = [min(vV), max(vV)];

    validPR = isfinite(p) & isfinite(r);
    [isGrid, pU, rU, linIdx] = detectPRGrid(p(validPR), r(validPR));
    useNativeGrid = isGrid && (options.Method == "grid" || options.Method == "triangulated");
    if useNativeGrid
        Z = NaN(numel(rU), numel(pU));
        Z(linIdx) = v(validPR);
        info.isGridded = true;
        info.method = "grid";
        info.gridSize = [numel(rU), numel(pU)];
        if numel(pU) > 1 && numel(rU) > 1
            info.resolution = [(max(pU)-min(pU))/(numel(pU)-1), (max(rU)-min(rU))/(numel(rU)-1)];
        end
        hS = pcolor(ax, pU, rU, Z);
        hS.EdgeColor = "none";
        hS.FaceColor = "interp";
    elseif options.Method == "triangulated"
        info.method = "triangulated";
        [pU_pts, rU_pts, vU_pts] = localDeduplicatePoints(pV, rV, vV);
        if numel(vU_pts) >= 3
            try
                tri = delaunay(pU_pts, rU_pts);
                patch(ax, "Faces", tri, "Vertices", [pU_pts, rU_pts], ...
                    "FaceVertexCData", vU_pts, "FaceColor", "interp", "EdgeColor", "none");
            catch
                scatter(ax, pU_pts, rU_pts, 28, vU_pts, "filled");
                info.method = "scatter";
            end
        else
            scatter(ax, pU_pts, rU_pts, 28, vU_pts, "filled");
            info.method = "scatter";
        end
    elseif options.Method == "voronoi"
        info.method = "voronoi";
        rendered = localPlotVoronoiPatch(ax, pV, rV, vV);
        if ~rendered
            scatter(ax, pV, rV, 28, vV, "filled");
            info.method = "scatter";
        end
    else
        interpType = options.Method;
        if ~ismember(interpType, ["nearest", "linear", "natural"])
            interpType = "natural";
        end
        info.method = interpType;

        pMin = min(pV); pMax = max(pV);
        rMin = min(rV); rMax = max(rV);
        sRes = options.SpatialResolution;
        if isfinite(sRes) && sRes > 0
            nP = max(2, round((pMax - pMin) / sRes) + 1);
            nR = max(2, round((rMax - rMin) / sRes) + 1);
        else
            nP = options.RasterSize;
            nR = options.RasterSize;
        end
        pq = linspace(pMin, pMax, nP);
        rq = linspace(rMin, rMax, nR);
        dp = (pMax - pMin) / max(1, nP - 1);
        dr = (rMax - rMin) / max(1, nR - 1);
        info.gridSize = [nR nP];
        info.resolution = [dp dr];

        [Pq, Rq] = meshgrid(pq, rq);
        warnState = warning("off", "MATLAB:scatteredInterpolant:DupPtsAvValuesWarnId");
        restoreWarn = onCleanup(@() warning(warnState));
        F = scatteredInterpolant(pV, rV, vV, interpType, "none");
        Zq = F(Pq, Rq);
        try
            k = convhull(pV, rV);
            Zq(~inpolygon(Pq, Rq, pV(k), rV(k))) = NaN;
        catch
        end
        hS = pcolor(ax, Pq, Rq, Zq);
        hS.EdgeColor = "none";
        if interpType == "nearest"
            hS.FaceColor = "flat";
        else
            hS.FaceColor = "interp";
        end
    end

    colormap(ax, options.Colormap);
    cb = colorbar(ax, "Color", [0.9 0.92 0.95]);
    cbLabel = options.ColorbarLabel;
    if options.LogScale && strlength(cbLabel) > 0
        cbLabel = "log_{10}(" + cbLabel + ")";
    end
    if strlength(cbLabel) > 0
        cb.Label.String = cbLabel;
        cb.Label.Color = [0.9 0.92 0.95];
        cb.Label.Interpreter = "tex";
    end
    if diff(info.valueRange) > 0
        clim(ax, info.valueRange);
    end

    %% Overlays
    if options.ShowPoints
        sp = options.PointsP; sr = options.PointsR;
        if isempty(sp), sp = p; sr = r; end
        % High-contrast outlined markers stay visible over both dark basins and bright cream optima.
        scatter(ax, sp, sr, 7, [1 1 1], "filled", ...
            "MarkerFaceAlpha", 0.78, "MarkerEdgeColor", [0 0 0], ...
            "MarkerEdgeAlpha", 0.55, "LineWidth", 0.35, ...
            "DisplayName", "Simulation samples");
    end
    if ~isempty(options.OptimaP)
        scatter(ax, options.OptimaP, options.OptimaR, 90, [1 0.85 0.2], "p", "filled", ...
            "MarkerEdgeColor", [0 0 0], "LineWidth", 0.8, "DisplayName", "Saved optima");
    end
    hold(ax, "off");

    xlabel(ax, "Period (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");
    ylabel(ax, "Radius (nm)", "Color", [0.9 0.92 0.95], "FontWeight", "bold");
    if strlength(options.Title) > 0
        title(ax, options.Title, "Color", [0.9 0.92 0.95], "FontSize", 13, "Interpreter", "none");
    end
    axis(ax, "tight");
    ax.Layer = "top";
end

%% ========================================================================
function [pOut, rOut, vOut] = localDeduplicatePoints(pIn, rIn, vIn)
% Average metric values across near-coincident (p, r) points so vertex counts match triangulations.
    scale = max([1; abs(pIn); abs(rIn)]);
    [uPts, ~, ic] = uniquetol([pIn, rIn], 1e-9 * scale, "ByRows", true, "DataScale", 1);
    if size(uPts, 1) < numel(pIn)
        pOut = uPts(:, 1);
        rOut = uPts(:, 2);
        vOut = accumarray(ic, vIn, [size(uPts, 1), 1], @mean);
    else
        pOut = pIn;
        rOut = rIn;
        vOut = vIn;
    end
end

function ok = localPlotVoronoiPatch(ax, pV, rV, vV)
% Render bounded 2D Voronoi cells using a single NaN-padded patch call (zero rasterization).
    ok = false;
    [pUse, rUse, vUse] = localDeduplicatePoints(pV, rV, vV);
    n = numel(pUse);
    if n < 3
        return;
    end

    try
        k = convhull(pUse, rUse);
    catch
        return;
    end

    hv = [pUse(k(1:end-1)), rUse(k(1:end-1))];
    warnPoly = warning("off", "MATLAB:polyshape:repairedBySimplify");
    restorePoly = onCleanup(@() warning(warnPoly));
    hullPoly = polyshape(hv(:, 1), hv(:, 2), "Simplify", true);
    if hullPoly.NumRegions < 1
        return;
    end

    cx = mean(pUse);
    cy = mean(rUse);
    span = 5 * max(max(pUse) - min(pUse), max(rUse) - min(rUse));
    if span <= 0, span = 1; end
    theta = linspace(0, 2 * pi, 65)';
    theta(end) = [];
    ghostPts = [cx + span * cos(theta), cy + span * sin(theta)];

    [V, C] = voronoiDiagram(delaunayTriangulation([pUse, rUse; ghostPts]));
    inHullV = inpolygon(V(:, 1), V(:, 2), hv(:, 1), hv(:, 2));

    polysX = cell(n, 1);
    polysY = cell(n, 1);
    keepCell = false(n, 1);
    maxVerts = 0;

    for i = 1:n
        idx = C{i};
        idx = idx(idx > 1);
        if numel(idx) < 3, continue; end

        if all(inHullV(idx))
            vx = V(idx, 1);
            vy = V(idx, 2);
        else
            cellPoly = polyshape(V(idx, 1), V(idx, 2), "Simplify", true);
            clipped = intersect(cellPoly, hullPoly);
            if clipped.NumRegions < 1, continue; end
            [vx, vy] = boundary(clipped, 1);
        end

        finV = isfinite(vx) & isfinite(vy);
        vx = vx(finV);
        vy = vy(finV);
        if numel(vx) >= 3
            polysX{i} = vx(:);
            polysY{i} = vy(:);
            keepCell(i) = true;
            maxVerts = max(maxVerts, numel(vx));
        end
    end

    if ~any(keepCell) || maxVerts < 3
        return;
    end

    polysX = polysX(keepCell);
    polysY = polysY(keepCell);
    cellVals = vUse(keepCell);
    nCells = numel(polysX);
    totVerts = sum(cellfun(@numel, polysX));

    allVerts = zeros(totVerts, 2);
    faces = NaN(nCells, maxVerts);
    offset = 0;
    for i = 1:nCells
        nv = numel(polysX{i});
        allVerts(offset + (1:nv), 1) = polysX{i};
        allVerts(offset + (1:nv), 2) = polysY{i};
        faces(i, 1:nv) = offset + (1:nv);
        offset = offset + nv;
    end

    patch(ax, "Faces", faces, "Vertices", allVerts, ...
        "FaceVertexCData", cellVals, "FaceColor", "flat", "EdgeColor", "none");
    ok = true;
end

function localStyleAxes(ax)
    ax.Color = [0.06 0.10 0.16];
    ax.XColor = [0.7 0.75 0.8];
    ax.YColor = [0.7 0.75 0.8];
    ax.GridColor = [0.3 0.35 0.4];
    ax.GridAlpha = 0.5;
    ax.Box = "on";
    ax.XGrid = "on"; ax.YGrid = "on";
end
