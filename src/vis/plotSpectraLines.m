function info = plotSpectraLines(ax, traces, options)
%plotSpectraLines  Plot spectral metric traces against wavelength or Raman shift.
%
%   info = plotSpectraLines(ax, traces, Name=Value)
%
%   Draws each trace as a line, data points, or both (PlotStyle). Colors are
%   assigned deterministically by metric name from the OKHSL scientific palette
%   (so a given metric keeps the same color regardless of how many metrics are
%   selected). Held trace batches (trace.group = 1, 2, ...) reuse the metric's
%   color while cycling line and marker styles (-/o, --/s, :/^, -./d, ...).
%
%   With a logarithmic y-axis, smoothing is carried out in log10 space so that
%   makima/spline overshoot cannot produce non-positive values.
%
%   Inputs:
%       ax     - target axes (axes or uiaxes)
%       traces - struct array with fields:
%                  lambda  [1 x L] wavelength nodes (nm)
%                  y       [1 x L] metric values
%                  label   legend text
%                  isDense (optional) true -> no smoothing
%                  metric  (optional) metric identifier for fixed palette color
%                  group   (optional) integer render-batch index for line/marker style
%
%   Name-Value Arguments:
%       XAxis            - "lambda" (default) | "shift"
%       LaserWavelength  - excitation wavelength in nm (785); used for the
%                          Raman-shift transform and the laser marker
%       LogY             - logarithmic y-axis (true)
%       Smoothing        - "makima" (default) | "pchip" | "spline" | "linear" | "none"
%       SmoothPoints     - samples of the smoothed curve (600)
%       PlotStyle        - "both" (default) | "line" | "points"
%       Normalize        - divide each trace by its maximum (false)
%       Title            - axes title ("")
%
%   Output:
%       info - struct: nTraces, xLabel, yLabel
%
%   Raman shift (cm^-1) = 1e7 * (1/lambda_laser - 1/lambda), lambda in nm.
%
%   See also: lookupSpectrum1D, interp1, makima

    arguments
        ax
        traces struct
        options.XAxis (1,1) string {mustBeMember(options.XAxis, ["lambda", "shift"])} = "lambda"
        options.LaserWavelength (1,1) double {mustBePositive} = 785
        options.LogY (1,1) logical = true
        options.Smoothing (1,1) string {mustBeMember(options.Smoothing, ...
            ["makima", "pchip", "spline", "linear", "none"])} = "makima"
        options.SmoothPoints (1,1) double {mustBePositive, mustBeInteger} = 600
        options.PlotStyle (1,1) string {mustBeMember(options.PlotStyle, ["both", "line", "points"])} = "both"
        options.Normalize (1,1) logical = false
        options.Title (1,1) string = ""
    end

    % Preserve uiaxes geometry across cla("reset") so it never shrinks to bottom-left
    savedUnits = ax.Units;
    savedPos = ax.Position;
    cla(ax, "reset");
    ax.Units = savedUnits;
    ax.Position = savedPos;

    localStyleAxes(ax);
    hold(ax, "on");

    lamL = options.LaserWavelength;
    toX = @(lam) lam;
    if options.XAxis == "shift"
        toX = @(lam) 1e7 * (1 ./ lamL - 1 ./ lam);
    end

    lineStyles = ["-", "--", ":", "-.", "-", "--", ":", "-."];
    markers    = ["o", "s", "^", "d", "v", "p", "h", "x"];
    edgeCol    = [0.05, 0.08, 0.12];

    metricCounts = containers.Map("KeyType", "char", "ValueType", "double");
    nDrawn = 0;
    for t = 1:numel(traces)
        lam = double(traces(t).lambda(:)');
        y = double(traces(t).y(:)');
        ok = isfinite(lam) & isfinite(y);
        if options.LogY
            ok = ok & y > 0;
        end
        lam = lam(ok); y = y(ok);
        if numel(lam) < 2
            continue;
        end
        [lam, order] = sort(lam);
        y = y(order);
        [lam, iu] = unique(lam, "stable");
        y = y(iu);

        if options.Normalize
            y = y ./ max(y);
        end

        isDense = isfield(traces, "isDense") && logical(traces(t).isDense);
        metricKey = localExtractMetricKey(traces(t));
        color = localMetricColor(metricKey);

        % Determine style group: explicit trace.group if provided, else occurrence count per metric
        if isKey(metricCounts, char(metricKey))
            occ = metricCounts(char(metricKey)) + 1;
        else
            occ = 1;
        end
        metricCounts(char(metricKey)) = occ;

        grp = occ;
        if isfield(traces, "group") && ~isempty(traces(t).group) && isfinite(double(traces(t).group)) && double(traces(t).group) >= 1
            grp = round(double(traces(t).group));
        end
        styleIdx = mod(grp - 1, numel(lineStyles)) + 1;
        ls = char(lineStyles(styleIdx));
        mk = char(markers(styleIdx));

        if ~isDense && options.Smoothing ~= "none" && numel(lam) >= 3
            lq = linspace(lam(1), lam(end), options.SmoothPoints);
            if options.LogY
                yq = 10 .^ interp1(lam, log10(y), lq, char(options.Smoothing));
            else
                yq = interp1(lam, y, lq, char(options.Smoothing));
            end
        else
            lq = lam; yq = y;
        end

        xCurve = toX(lq);
        xPts   = toX(lam);
        ptSize = 5.2;
        if numel(lam) > 120
            ptSize = 3.4;
        end
        isUnfilledMarker = ismember(mk, {'x', '+', '*'});
        faceCol = color;
        mkEdge  = edgeCol;
        if isUnfilledMarker
            faceCol = "none";
            mkEdge  = color;
        end

        switch options.PlotStyle
            case "line"
                plot(ax, xCurve, yq, "LineStyle", ls, "Color", color, "LineWidth", 1.7, ...
                    "DisplayName", char(traces(t).label));

            case "points"
                plot(ax, xPts, y, "LineStyle", "none", "Marker", mk, ...
                    "Color", color, "MarkerFaceColor", faceCol, "MarkerEdgeColor", mkEdge, ...
                    "MarkerSize", ptSize, "LineWidth", 0.7, ...
                    "DisplayName", char(traces(t).label));

            otherwise % "both"
                plot(ax, xCurve, yq, "LineStyle", ls, "Color", color, "LineWidth", 1.7, ...
                    "HandleVisibility", "off");
                plot(ax, xPts, y, "LineStyle", "none", "Marker", mk, ...
                    "Color", color, "MarkerFaceColor", faceCol, "MarkerEdgeColor", mkEdge, ...
                    "MarkerSize", ptSize, "LineWidth", 0.6, ...
                    "HandleVisibility", "off");
                % Combined legend entry displaying both line style and marker style
                plot(ax, NaN, NaN, "LineStyle", ls, "Marker", mk, ...
                    "Color", color, "MarkerFaceColor", faceCol, "MarkerEdgeColor", mkEdge, ...
                    "MarkerSize", 5.5, "LineWidth", 1.7, ...
                    "DisplayName", char(traces(t).label));
        end
        nDrawn = nDrawn + 1;
    end

    if options.XAxis == "lambda"
        xline(ax, lamL, "--", sprintf("λ_{laser} = %.0f nm", lamL), ...
            "Color", [190, 190, 190]/255, "LabelOrientation", "horizontal", ...
            "LabelVerticalAlignment", "bottom", "HandleVisibility", "off", ...
            "FontName", "Fira Sans", "FontSize", 7, "FontWeight", "bold");
        xLabel = "Wavelength " + pubAssteroidMath("\lambda", Weight="bold") + " (nm)";
    else
        xLabel = "Raman shift (" + pubAssteroidMath("cm^{-1}", Weight="bold") + ")";
    end
    hold(ax, "off");

    if options.LogY
        ax.YScale = "log";
    else
        ax.YScale = "linear";
    end
    if options.Normalize
        yLabel = "Normalized metric (a.u.)";
    else
        yLabel = "Metric value";
    end
    xlabel(ax, xLabel, "Color", [248, 248, 248]/255, "FontWeight", "bold");
    ylabel(ax, yLabel, "Color", [248, 248, 248]/255, "FontWeight", "bold");
    if strlength(options.Title) > 0
        title(ax, options.Title, "Color", [248, 248, 248]/255, "Interpreter", "none");
    end

    if nDrawn == 0
        text(ax, 0.5, 0.5, "No finite data to plot.", "Units", "normalized", ...
            "HorizontalAlignment", "center", "Color", [248, 248, 248]/255);
    else
        lg = legend(ax, "Location", "best", "Interpreter", "none");
        lg.TextColor = [248, 248, 248]/255;
        lg.Color = [3, 0, 51]/255;
        lg.EdgeColor = [72, 72, 72]/255;
        axis(ax, "tight");
    end

    applyAssteroidPlotStyle(ax, Theme="dark", ApplyColors=false);
    info = struct("nTraces", nDrawn, "xLabel", xLabel, "yLabel", yLabel);
end

%% ========================================================================
function localStyleAxes(ax)
    ax.Color = [0.06 0.10 0.16];
    ax.XColor = [167, 187, 249]/255;
    ax.YColor = [167, 187, 249]/255;
    ax.GridColor = [56, 74, 224]/255;
    ax.GridAlpha = 0.28;
    ax.MinorGridColor = [56, 74, 224]/255;
    ax.Box = "on";
    ax.XGrid = "on"; ax.YGrid = "on";
    applyAssteroidPlotStyle(ax, Theme="dark", ApplyColors=false);
end

function key = localExtractMetricKey(tr)
%localExtractMetricKey Canonical metric identifier from trace.metric or trace.label.
    raw = "";
    if isfield(tr, "metric") && ~isempty(tr.metric)
        raw = strtrim(string(tr.metric));
    elseif isfield(tr, "label") && ~isempty(tr.label)
        lbl = string(tr.label);
        parts = split(lbl, "|");
        raw = strtrim(parts(1));
    end
    low = lower(raw);
    if any(low == ["abs", "absorptance"])
        key = "Abs";
    elseif any(low == ["ef_max", "e4_max", "m2_max", "e4"])
        key = "EF_max";
    elseif any(low == ["ee_v", "ef_vol"])
        key = "EE_V";
    elseif any(low == ["ee_s", "ef_surf"])
        key = "EE_S";
    elseif any(low == ["ecc", "eccheck"])
        key = "ECC";
    else
        key = raw;
    end
end

function c = localMetricColor(metricKey)
%localMetricColor Deterministic OKHSL scientific palette color per metric (dark-bg tuned).
%   4 primary anchors (Rule 05 OKHSL hue families A/B/C/D):
%     Abs     -> Series A Blue   (A60 #5d78da)
%     EF_max  -> Series D Gold   (D70 #c9942c)
%     EE_V    -> Series C Teal   (C70 #48b2ac)
%     EE_S    -> Series B Purple (B60 #994ef3)
    switch lower(string(metricKey))
        case {"abs", "absorptance"}
            c = [ 93, 120, 218] / 255;   % A60 Blue   (#5d78da)
        case {"ef_max", "e4_max", "m2_max", "e4"}
            c = [201, 148,  44] / 255;   % D70 Gold   (#c9942c)
        case {"ee_v", "ef_vol"}
            c = [ 72, 178, 172] / 255;   % C70 Teal   (#48b2ac)
        case {"ee_s", "ef_surf"}
            c = [153,  78, 243] / 255;   % B60 Purple (#994ef3)
        case {"ecc", "eccheck"}
            c = [235, 179,  79] / 255;   % D80 Light Gold (#ebb34f)
        case {"reflectance", "r"}
            c = [167, 187, 249] / 255;   % A80 Sky Blue   (#a7bbf9)
        case {"transmittance", "t"}
            c = [107, 209, 203] / 255;   % C80 Bright Teal (#6bd1cb)
        case {"m_vol", "m2_vol", "e_vol"}
            c = [ 39, 146, 141] / 255;   % C60 Deep Teal  (#27928d)
        case {"m_surf", "m2_surf", "e_surf"}
            c = [203, 165, 255] / 255;   % B80 Lavender   (#cba5ff)
        otherwise
            % Deterministic hash into secondary OKHSL tones so unknown metrics stay consistent
            extras = [ ...
                167, 187, 249; ... % A80
                235, 179,  79; ... % D80
                107, 209, 203; ... % C80
                203, 165, 255; ... % B80
                190, 190, 190; ... % G80
                128, 154, 236] / 255; % A70
            ch = double(char(lower(string(metricKey))));
            idx = mod(sum(ch .* (1:numel(ch))), size(extras, 1)) + 1;
            c = extras(idx, :);
    end
end
