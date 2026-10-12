function sendOptimizeEvent(fig, eventName, payload, src)
%sendOptimizeEvent Broadcast optimize events to optimize panels.
%   sendOptimizeEvent(fig, eventName, payload, src)
%
%   Dispatches the HTML event to all active optimize UI HTML panels.
%
%   See also: getOptimizePanels

    if nargin < 4, src = []; end
    panels = getOptimizePanels(fig, src);
    for i = 1:numel(panels)
        try
            sendEventToHTMLSource(panels(i), eventName, payload);
        catch
        end
    end

    if ~isempty(fig) && isvalid(fig) && isfield(fig.UserData, "app")
        if strcmp(eventName, "Progress") && isstruct(payload)
            pct = 0;
            if isfield(payload, "fraction") && ~isempty(payload.fraction), pct = payload.fraction * 100;
            elseif isfield(payload, "percent") && ~isempty(payload.percent), pct = payload.percent; end
            msg = ""; if isfield(payload, "message"), msg = payload.message; end
            try fig.UserData.app.updateProgress(pct, msg, "Stage 5 — Optimize"); catch; end
        elseif strcmp(eventName, "OptimizeError") || strcmp(eventName, "OptimizeComplete")
            lvl = "info";
            if strcmp(eventName, "OptimizeError"), lvl = "error";
            elseif strcmp(eventName, "OptimizeComplete"), lvl = "success"; end
            try fig.UserData.app.logMessage(string(payload), lvl, "Stage 5 — Optimize"); catch; end
        end
    end
end
