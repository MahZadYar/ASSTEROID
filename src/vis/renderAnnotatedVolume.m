function hVol = renderAnnotatedVolume(viewer, volData, pVec, rVec, lambdaVec, options)
%renderAnnotatedVolume  Render a (p, r, λ) metric volume with annotated axes.
%
%   hVol = renderAnnotatedVolume(viewer, volData, pVec, rVec, lambdaVec)
%   hVol = renderAnnotatedVolume(..., Name=Value)
%
%   Renders a gridded spectral metric volume with volshow inside an existing
%   viewer3d, using physical (nm) voxel spacing, a logarithmic alphamap and
%   gradient-opacity rendering. The three volume edges meeting at the
%   (p_min, r_min, λ_min) corner are annotated with labelled
%   images.ui.graphics.roi.Line objects, and the origin and axis end points
%   carry images.ui.graphics.roi.Point labels with the coordinate ranges
%   (method adapted from legacy/volumeVisualizer.m).
%
%   Inputs:
%       viewer    - viewer3d object (target container).
%       volData   - [Nr x Np x Nl] metric volume (rows = radius,
%                   columns = period, pages = wavelength). NaN = no data.
%       pVec      - [1 x Np] period samples (nm, ascending).
%       rVec      - [1 x Nr] radius samples (nm, ascending).
%       lambdaVec - [1 x Nl] wavelength samples (nm, ascending).
%
%   Name-Value Arguments:
%       Colormap      - [M x 3] colormap (default: AuroraAustralis, inverted).
%       LogScale      - log10-transform values before normalisation (false).
%       MetricLabel   - Metric name shown in the range annotation ("").
%       OverlayMask   - [Nr x Np x Nl] logical mask rendered as a label
%                       overlay (e.g. simulation-sample columns) ([]).
%       OverlayColor  - [1 x 3] RGB overlay colour ([1 1 1]).
%       OverlayAlpha  - Overlay opacity in [0, 1] (0.25).
%       AxisLabels    - [1 x 3] axis titles
%                       (["Lattice Period", "Particle Radius", "Wavelength"]).
%       AxisSymbols   - [1 x 3] symbols used in range labels (["p", "r", "λ"]).
%       FlipLambda    - Map increasing λ to negative world-z, so the
%                       short-wavelength end sits at the origin corner as in
%                       the legacy visualizer (true).
%
%   Output:
%       hVol - images.ui.graphics.Volume handle.
%
%   Example:
%       v = viewer3d(BackgroundColor="black");
%       [vol, p, r, lam] = reshapeSoAToVolume(db.Interp, "EF_vol");
%       renderAnnotatedVolume(v, vol, p, r, lam, MetricLabel="EF_vol", LogScale=true);
%
%   See also: volshow, viewer3d, reshapeSoAToVolume, plotScatteredMap2D

    arguments
        viewer
        volData {mustBeNumeric}
        pVec (1,:) double
        rVec (1,:) double
        lambdaVec (1,:) double
        options.Colormap double = []
        options.LogScale (1,1) logical = false
        options.MetricLabel (1,1) string = ""
        options.OverlayMask = []
        options.OverlayColor (1,3) double = [1 1 1]
        options.OverlayAlpha (1,1) double {mustBeInRange(options.OverlayAlpha, 0, 1)} = 0.25
        options.AxisLabels (1,3) string = ["Lattice Period", "Particle Radius", "Wavelength"]
        options.AxisSymbols (1,3) string = ["p", "r", "λ"]
        options.FlipLambda (1,1) logical = true
    end

    volData = double(volData);
    [Nr, Np, Nl] = size(volData);
    if numel(pVec) ~= Np || numel(rVec) ~= Nr || numel(lambdaVec) ~= Nl
        error("renderAnnotatedVolume:SizeMismatch", ...
            "Volume size [%d %d %d] does not match axis vectors (r=%d, p=%d, λ=%d).", ...
            Nr, Np, Nl, numel(rVec), numel(pVec), numel(lambdaVec));
    end
    if min([Nr, Np, Nl]) < 2
        error("renderAnnotatedVolume:Degenerate", ...
            "Each volume dimension needs at least 2 samples (got [%d %d %d]).", Nr, Np, Nl);
    end

    %% Value transform + normalisation to 12-bit range
    rawMin = min(volData(:), [], "omitnan");
    rawMax = max(volData(:), [], "omitnan");
    vals = volData;
    if options.LogScale
        vals(vals <= 0) = NaN;
        vals = log10(vals);
    end
    vMin = min(vals(:), [], "omitnan");
    vMax = max(vals(:), [], "omitnan");
    if isfinite(vMin) && isfinite(vMax) && vMax > vMin
        volN = (vals - vMin) / (vMax - vMin);
    else
        volN = zeros(size(vals));
    end
    volN(~isfinite(volN)) = 0;   % NaN / no-data voxels -> fully transparent

    nLevels = 4095;
    cmap = options.Colormap;
    if isempty(cmap)
        cmap = localDefaultColormap(nLevels);
    end
    epsA = 1e-4;
    aMap = log(linspace(epsA, 1, nLevels));
    aMap = 1 - aMap / min(aMap);           % 0 at the lowest level, 1 at the top

    %% Physical voxel spacing (nm). Voxel centres sit at intrinsic 1..N,
    %  so the span between first and last centre equals the data range.
    lx = pVec(end) - pVec(1);
    ly = rVec(end) - rVec(1);
    lzAbs = lambdaVec(end) - lambdaVec(1);
    sx = lx / (Np - 1);
    sy = ly / (Nr - 1);
    sz = lzAbs / (Nl - 1);
    if options.FlipLambda
        sz = -sz;
    end
    lz = sz * (Nl - 1);
    tform = affinetform3d([sx 0 0 0; 0 sy 0 0; 0 0 sz 0; 0 0 0 1]);

    %% Clear previous content
    localClearViewer(viewer);

    volArgs = { ...
        "Parent", viewer, ...
        "DisplayRangeMode", "12-bit", ...
        "RenderingStyle", "GradientOpacity", ...
        "GradientOpacityValue", 0.2, ...
        "Colormap", cmap, ...
        "Alphamap", aMap, ...
        "Transformation", tform, ...
        "Interpolation", "bilinear"};

    mask = options.OverlayMask;
    if ~isempty(mask)
        if ~isequal(size(mask), size(volData))
            error("renderAnnotatedVolume:OverlaySize", ...
                "OverlayMask must match the volume size [%d %d %d].", Nr, Np, Nl);
        end
        volArgs = [volArgs, { ...
            "OverlayData", uint8(logical(mask)), ...
            "OverlayRenderingStyle", "LabelOverlay", ...
            "OverlayColormap", [0 0 0; options.OverlayColor], ...
            "OverlayAlphamap", options.OverlayAlpha}];
    end

    hVol = volshow(round(volN * nLevels), volArgs{:});

    %% Viewer styling (as legacy volumeVisualizer)
    viewer.Lighting = "off";
    viewer.Box = "off";
    viewer.ScaleBar = "on";
    viewer.ScaleBarStyle = "measure";
    viewer.BackgroundColor = "black";
    viewer.BackgroundGradient = "off";
    viewer.SpatialUnits = "nm";
    viewer.RenderingQuality = "high";
    viewer.OrientationAxes = "off";

    %% Axis annotations
    origin = [sx, sy, sz];                       % world position of voxel (1,1,1)
    ex = origin + [lx 0 0];
    ey = origin + [0 ly 0];
    ez = origin + [0 0 lz];
    sym = options.AxisSymbols;
    lbl = options.AxisLabels;

    xAxis = images.ui.graphics.roi.Line(Position=[origin; ex]);
    xAxis.Label = char(lbl(1));
    yAxis = images.ui.graphics.roi.Line(Position=[origin; ey]);
    yAxis.Label = char(lbl(2));
    zAxis = images.ui.graphics.roi.Line(Position=[origin; ez]);
    zAxis.Label = char(lbl(3));

    pOrig = images.ui.graphics.roi.Point(Position=origin);
    pOrig.Label = sprintf('%s = %0.0f nm\n%s = %0.0f nm\n%s = %0.0f nm', ...
        sym(1), pVec(1), sym(2), rVec(1), sym(3), lambdaVec(1));
    pX = images.ui.graphics.roi.Point(Position=ex);
    pX.Label = sprintf('%s = %0.0f nm', sym(1), pVec(end));
    pY = images.ui.graphics.roi.Point(Position=ey);
    pY.Label = sprintf('%s = %0.0f nm', sym(2), rVec(end));
    pZ = images.ui.graphics.roi.Point(Position=ez);
    pZ.Label = sprintf('%s = %0.0f nm', sym(3), lambdaVec(end));

    annotations = [xAxis yAxis zAxis pOrig pX pY pZ];

    if strlength(options.MetricLabel) > 0
        rangeStr = sprintf('%s\n%.3g – %.3g', options.MetricLabel, rawMin, rawMax);
        if options.LogScale
            rangeStr = rangeStr + " (log colour scale)";
        end
        pM = images.ui.graphics.roi.Point(Position=origin + [lx ly 0]);
        pM.Label = char(rangeStr);
        annotations = [annotations pM];
    end
    viewer.Annotations = annotations;

    %% Isometric camera at 3π/4 around the volume centre (world units)
    center = origin + [lx, ly, lz] / 2;
    dist = norm([lx, ly, lz]);
    viewer.CameraTarget = center;
    viewer.CameraPosition = center + [cos(3*pi/4), sin(3*pi/4), 1] * dist;
    viewer.CameraUpVector = [0 1 0];
end

%% ========================================================================
function localClearViewer(viewer)
%localClearViewer  Remove existing volumes/annotations from a viewer3d.
    try
        viewer.Annotations = [];
    catch
    end
    kids = viewer.Children;
    for k = numel(kids):-1:1
        try
            delete(kids(k));
        catch
        end
    end
end

function cmap = localDefaultColormap(n)
%localDefaultColormap  AuroraAustralis (inverted) with turbo fallback.
    cmap = [];
    try
        cmap = flipud(loadColormap("AuroraAustralis.txt", n));
    catch
    end
    if isempty(cmap) || size(cmap, 2) ~= 3
        cmap = turbo(n);
    end
end
