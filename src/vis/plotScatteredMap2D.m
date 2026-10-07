function info = plotScatteredMap2D(ax, p, r, v, options)
%plotScatteredMap2D  Render a scalar metric over the (period, radius) plane.
%
%   info = plotScatteredMap2D(ax, p, r, v)
%   info = plotScatteredMap2D(ax, p, r, v, Name=Value)
%
%   Chooses the rendering path from the sample layout:
%     * Regular (p, r) grid  -> direct mapping, pcolor with interpolated shading.
%     * Scattered samples    -> no stored grid is produced:
%         "triangulated"  Delaunay mesh drawn with patch(FaceColor="interp");
%                          the graphics pipeline shades each triangle by
%                          barycentric (piecewise-linear) interpolation.
%         "nearest"       Nearest-sample ("staircase") rendering on a
%                          transient display raster, masked to the convex hull.
%
%   Inputs:
%       ax - target axes (axes or uiaxes)
%       p  - [N x 1] period (nm)
%       r  - [N x 1] radius (nm)
%       v  - [N x 1] metric values
%
%   Name-Value Arguments:
%       Method         - "triangulated" (default) | "nearest"  (scattered data only)
%       Colormap       - [M x 3] colormap (default parula(256))
%       LogScale       - plot log10(v); non-positive values become NaN (false)
%       Title          - axes title ("")
%       ColorbarLabel  - colorbar label ("")
%       ShowPoints     - overlay sample locations (false)
%       PointsP, PointsR - explicit overlay coordinates (default: p, r)
%       OptimaP, OptimaR - optional optima markers ([])
%       RasterSize     - display raster size for "nearest" (300)
%
%   Output:
%       info - struct: isGridded, method, nValid, gridSize, valueRange
%
%   See also: patch, delaunay, scatteredInterpolant, renderAnnotatedVolume

    arguments
        ax
        p (:,1) double
        r (:,1) double
        v (:,1) double
        options.Method (1,1) string {mustBeMember(options.Method, ["triangulated", "nearest"])} = "triangulated"
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
        "gridSize", [0 0], "valueRange", [NaN NaN]);

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
    if isGrid
        Z = NaN(numel(rU), numel(pU));
        Z(linIdx) = v(validPR);
        info.isGridded = true;
        info.method = "grid";
        info.gridSize = [numel(rU), numel(pU)];
        hS = pcolor(ax, pU, rU, Z);
        hS.EdgeColor = "none";
        hS.FaceColor = "interp";
    elseif options.Method == "triangulated"
        info.method = "triangulated";
        tri = delaunay(pV, rV);
        patch(ax, "Faces", tri, "Vertices", [pV, rV], ...
            "FaceVertexCData", vV, "FaceColor", "interp", "EdgeColor", "none");
    else
        info.method = "nearest";
        n = options.RasterSize;
        pq = linspace(min(pV), max(pV), n);
        rq = linspace(min(rV), max(rV), n);
        [Pq, Rq] = meshgrid(pq, rq);
        warnState = warning("off", "MATLAB:scatteredInterpolant:DupPtsAvValuesWarnId");
        restoreWarn = onCleanup(@() warning(warnState));
        F = scatteredInterpolant(pV, rV, vV, "nearest", "none");
        Zq = F(Pq, Rq);
        k = convhull(pV, rV);
        Zq(~inpolygon(Pq, Rq, pV(k), rV(k))) = NaN;
        info.gridSize = [n n];
        imagesc(ax, pq, rq, Zq, "AlphaData", isfinite(Zq));
        ax.YDir = "normal";
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
        scatter(ax, sp, sr, 6, [1 1 1], "filled", ...
            "MarkerFaceAlpha", 0.55, "MarkerEdgeColor", "none", ...
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
function localStyleAxes(ax)
    ax.Color = [0.06 0.10 0.16];
    ax.XColor = [0.7 0.75 0.8];
    ax.YColor = [0.7 0.75 0.8];
    ax.GridColor = [0.3 0.35 0.4];
    ax.GridAlpha = 0.5;
    ax.Box = "on";
    ax.XGrid = "on"; ax.YGrid = "on";
end
