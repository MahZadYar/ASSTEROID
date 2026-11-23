function keys = knownAnalyteKeysRegistry(action, newKeys)
%knownAnalyteKeysRegistry Session registry of built-in and custom analyte keys.
%
%   keys = knownAnalyteKeysRegistry()                % list all known keys
%   keys = knownAnalyteKeysRegistry("list")          % list all known keys
%   keys = knownAnalyteKeysRegistry("add", newKeys)  % register custom key(s)
%   keys = knownAnalyteKeysRegistry("clear")         % reset custom keys

    arguments
        action (1,1) string {mustBeMember(action, ["list", "add", "clear"])} = "list"
        newKeys string = string.empty
    end

    persistent customKeys
    if isempty(customKeys)
        customKeys = strings(1, 0);
    end

    builtIns = ["CH4", "C2H4", "H2S", "NH3", "C2H2", "H2O"];

    switch action
        case "clear"
            customKeys = strings(1, 0);
        case "add"
            arr = strtrim(string(newKeys(:)'));
            arr = arr(strlength(arr) > 0);
            for i = 1:numel(arr)
                k = arr(i);
                if ~any(strcmpi(k, builtIns)) && ~any(strcmpi(k, customKeys))
                    customKeys(end+1) = k; %#ok<AGROW>
                end
            end
    end

    keys = unique([builtIns, customKeys], "stable");
end
