function panels = getOptimizePanels(fig, src)
%getOptimizePanels Return unique valid optimize uihtml handles.
%   panels = getOptimizePanels(fig, src)

    candidates = gobjects(0);
    if nargin >= 2 && ~isempty(src) && isvalid(src)
        candidates(end+1) = src;
    end
    if nargin >= 1 && ~isempty(fig) && isvalid(fig) && isstruct(fig.UserData) && isfield(fig.UserData, "handles")
        h = fig.UserData.handles;
        if isfield(h, "optimizeHtml") && ~isempty(h.optimizeHtml) && isvalid(h.optimizeHtml)
            candidates(end+1) = h.optimizeHtml;
        end
        if isfield(h, "optimizeLeft") && ~isempty(h.optimizeLeft) && isvalid(h.optimizeLeft)
            candidates(end+1) = h.optimizeLeft;
        end
        if isfield(h, "optimizeRight") && ~isempty(h.optimizeRight) && isvalid(h.optimizeRight)
            candidates(end+1) = h.optimizeRight;
        end
    end

    panels = gobjects(0);
    for i = 1:numel(candidates)
        c = candidates(i);
        if isvalid(c) && ~ismember(c, panels)
            panels(end+1) = c; %#ok<AGROW>
        end
    end
end
