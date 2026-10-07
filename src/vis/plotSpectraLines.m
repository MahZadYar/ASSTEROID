function info = plotSpectraLines(ax, traces, options)
%plotSpectraLines  Plot spectral metric traces against wavelength or Raman shift.
%
%   info = plotSpectraLines(ax, traces, Name=Value)
%
%   Each trace is drawn as an optionally smoothed line; sparse traces (raw
%   simulation samples or interpolated simulation nodes) additionally show
%   their nodes as filled markers. With a logarithmic y-axis, smoothing is
%   carried out in log10 space so that makima/spline overshoot cannot
%   produce non-positive values.
%
%   Inputs:
%       ax     - target axes (axes or uiaxes)
%       traces - struct array with fields:
%                  lambda  [1 x L] wavelength nodes (nm)
%                  y       [1 x L] metric values
%                  label   legend text
%                  isDense true -> no node markers, no smoothing
%
%   Name-Value Arguments:
%       XAxis            - "lambda" (default) | "shift"
%       LaserWavelength  - excitation wavelength in nm (785); used for the
%                          Raman-shift transform and the laser marker
%       LogY             - logarithmic y-axis (true)
%       Smoothing        - "makima" (default) | "pchip" | "spline" | "linear" | "none"
%       SmoothPoints     - samples of the smoothed curve (600)
%       Normalize        - divide each trace by its maximum (false)
%       Title            - axes title ("")
%
%   Output:
%       info - struct: nTraces, xLabel, yLabel
%
%   Raman shift (cm^-1) = 1e7 * (1/λ_laser - 1/λ), λ in nm.
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
        options.Normalize (1,1) logical = false
        options.Title (1,1) string = ""
    end

    cla(ax, "reset");
    localStyleAxes(ax);
    hold(ax, "on");

    palette = localPalette();
    lamL = options.LaserWavelength;
    toX = @(lam) lam;
    if options.XAxis == "shift"
        toX = @(lam) 1e7 * (1 ./ lamL - 1 ./ lam);
    end

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
        color = palette(mod(nDrawn, size(palette, 1)) + 1, :);

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

        plot(ax, toX(lq), yq, "-", "Color", color, "LineWidth", 1.6, ...
            "DisplayName", char(traces(t).label));
        if ~isDense
            scatter(ax, toX(lam), y, 22, color, "filled", ...
                "MarkerEdgeColor", [0.05 0.08 0.10], "LineWidth", 0.4, ...
                "HandleVisibility", "off");
        end
        nDrawn = nDrawn + 1;
    end

    if options.XAxis == "lambda"
        xline(ax, lamL, "--", sprintf("λ_{laser} = %.0f nm", lamL), ...
            "Color", [0.85 0.85 0.85], "LabelOrientation", "horizontal", ...
            "LabelVerticalAlignment", "bottom", "HandleVisibility", "off", ...
            "FontSize", 9);
        xLabel = "Wavelength λ (nm)";
    else
        xLabel = "Raman shift (cm^{-1})";
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
    xlabel(ax, xLabel, "Color", [0.9 0.92 0.95], "FontWeight", "bold");
    ylabel(ax, yLabel, "Color", [0.9 0.92 0.95], "FontWeight", "bold");
    if strlength(options.Title) > 0
        title(ax, options.Title, "Color", [0.9 0.92 0.95], "FontSize", 13, "Interpreter", "none");
    end

    if nDrawn == 0
        text(ax, 0.5, 0.5, "No finite data to plot.", "Units", "normalized", ...
            "HorizontalAlignment", "center", "Color", "w");
    else
        lg = legend(ax, "Location", "best", "Interpreter", "none");
        lg.TextColor = [0.9 0.92 0.95];
        lg.Color = [0.08 0.12 0.18];
        lg.EdgeColor = [0.3 0.35 0.4];
        axis(ax, "tight");
    end

    info = struct("nTraces", nDrawn, "xLabel", xLabel, "yLabel", yLabel);
end

%% ========================================================================
function localStyleAxes(ax)
    ax.Color = [0.06 0.10 0.16];
    ax.XColor = [0.7 0.75 0.8];
    ax.YColor = [0.7 0.75 0.8];
    ax.GridColor = [0.3 0.35 0.4];
    ax.GridAlpha = 0.5;
    ax.MinorGridColor = [0.25 0.3 0.35];
    ax.Box = "on";
    ax.XGrid = "on"; ax.YGrid = "on";
end

function c = localPalette()
%localPalette  High-contrast colours for a dark background.
    c = [ ...
        0.00 0.91 1.00;   % cyan
        1.00 0.72 0.30;   % amber
        0.40 0.87 0.47;   % green
        1.00 0.42 0.42;   % coral
        0.75 0.60 1.00;   % lavender
        1.00 0.92 0.35;   % yellow
        0.35 0.70 1.00;   % sky
        0.95 0.55 0.85];  % pink
end
