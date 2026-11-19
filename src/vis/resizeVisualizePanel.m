function resizeVisualizePanel(fig)
%resizeVisualizePanel Resize the Stage 6 Visualize tab group to fill its panel.
%   resizeVisualizePanel(fig)
%
%   Computes current dimensions of visualizePanel and updates the position
%   of visualizeTabGroup to cleanly fit within.

    if isempty(fig) || ~isvalid(fig) || ~isstruct(fig.UserData) || ~isfield(fig.UserData, "handles")
        return;
    end
    h = fig.UserData.handles;
    if ~isfield(h, "visualizePanel") || ~isfield(h, "visualizeTabGroup")
        return;
    end
    p = h.visualizePanel;
    tg = h.visualizeTabGroup;
    if isempty(p) || ~isvalid(p) || isempty(tg) || ~isvalid(tg)
        return;
    end
    w = max(10, round(p.Position(3)));
    h_ = max(10, round(p.Position(4)));
    tg.Position = [1, 1, w, h_];

    % Keep 1D and 2D uiaxes anchored to normalized full-tab coordinates
    % (prevents MATLAB cla('reset') / uitab deferred-layout shrinking to bottom-left)
    for axKey = ["visualizeAx1D", "visualizeAx2D"]
        if isfield(h, axKey)
            ax = h.(axKey);
            if ~isempty(ax) && isvalid(ax)
                ax.Units = "normalized";
                ax.Position = [0.05, 0.05, 0.90, 0.90];
            end
        end
    end
end
