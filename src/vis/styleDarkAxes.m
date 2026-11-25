function styleDarkAxes(ax, xLabel, yLabel, titleStr)
%styleDarkAxes Apply the app's dark axes styling and labels.
%   styleDarkAxes(ax, xLabel, yLabel, titleStr)
%
%   Sets dark background, border, grid colors, and font styling for UI plots.

    if nargin < 2, xLabel = ""; end
    if nargin < 3, yLabel = ""; end
    if nargin < 4, titleStr = ""; end

    if isempty(ax) || ~isvalid(ax)
        return;
    end

    ax.Color     = [4, 2, 58]/255;       % OKHSL A15-A20 midnight cobalt
    ax.XColor    = [167, 187, 249]/255;  % OKHSL A80 tick/axis labels
    ax.YColor    = [167, 187, 249]/255;
    ax.GridColor = [56, 74, 224]/255;    % OKHSL A50 subtle blue grid
    ax.GridAlpha = 0.28;
    ax.Box = "on";
    ax.XGrid = "on";
    ax.YGrid = "on";
    if xLabel ~= ""
        xlabel(ax, xLabel, "Color", [248, 248, 248]/255, "FontWeight", "bold");
    end
    if yLabel ~= ""
        ylabel(ax, yLabel, "Color", [248, 248, 248]/255, "FontWeight", "bold");
    end
    if titleStr ~= ""
        title(ax, titleStr, "Color", [107, 209, 203]/255, "FontWeight", "bold"); % OKHSL C80 highlight
    end
    applyAssteroidPlotStyle(ax, Theme="dark", ApplyColors=false);
end
