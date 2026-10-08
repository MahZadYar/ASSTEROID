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

    ax.Color = [12, 16, 32]/255;
    ax.XColor = [160, 178, 214]/255;
    ax.YColor = [160, 178, 214]/255;
    ax.GridColor = [46, 62, 98]/255;
    ax.GridAlpha = 0.6;
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
        title(ax, titleStr, "Color", [248, 248, 248]/255);
    end
end
