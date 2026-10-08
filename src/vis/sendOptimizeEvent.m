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
end
