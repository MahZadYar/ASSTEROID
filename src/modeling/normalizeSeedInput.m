function seeds = normalizeSeedInput(seedInput)
%normalizeSeedInput Normalize uihtml seed payloads into canonical struct array.
%   Accepts struct array, scalar struct, or cell array and returns a
%   canonical struct array with fields Tag, P, R, Value.
%
%   seeds = normalizeSeedInput(seedInput)
%
%   Input:
%       seedInput - Struct array, scalar struct, or cell array of structs.
%
%   Output:
%       seeds - Struct array with fields Tag, P, R, Value (1-based, nm).

    seeds = struct("Tag", {}, "P", {}, "R", {}, "Value", {});
    if isempty(seedInput)
        return;
    end

    if isstruct(seedInput)
        rawEntries = num2cell(seedInput(:));
    elseif iscell(seedInput)
        rawEntries = seedInput(:);
    else
        return;
    end

    for i = 1:numel(rawEntries)
        entry = rawEntries{i};
        if ~isstruct(entry)
            continue;
        end

        entryItems = num2cell(entry(:));
        for k = 1:numel(entryItems)
            row = entryItems{k};

            seed = struct("Tag", "", "P", NaN, "R", NaN, "Value", NaN);
            if isfield(row, "Tag")
                seed.Tag = string(row.Tag);
            end
            if isfield(row, "P")
                seed.P = double(row.P);
            elseif isfield(row, "Period")
                seed.P = double(row.Period);
            end
            if isfield(row, "R")
                seed.R = double(row.R);
            elseif isfield(row, "Radius")
                seed.R = double(row.Radius);
            end
            if isfield(row, "Value")
                seed.Value = double(row.Value);
            end

            if isfinite(seed.P) && isfinite(seed.R)
                if strlength(string(seed.Tag)) == 0
                    seed.Tag = "Point " + string(numel(seeds) + 1);
                end
                seeds(end + 1) = seed; %#ok<AGROW>
            end
        end
    end
end
