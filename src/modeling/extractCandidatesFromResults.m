function candidates = extractCandidatesFromResults(results, topN, prominenceThreshold)
%extractCandidatesFromResults Extract top candidate seeds from localization results.
%
%   candidates = extractCandidatesFromResults(results, topN, prominenceThreshold)
%
%   Inputs:
%       results              - Localization workflow results struct.
%       topN                 - Maximum number of candidates to return.
%       prominenceThreshold  - Minimum GridValue as fraction of max (0-1).
%
%   Output:
%       candidates - Struct array with fields P, R, Value, Tag (nm units) and
%                    watershed metadata BasinId, Depth, Area, PeakOnEdge,
%                    Status (NaN / false / "" when not available).

    arguments
        results struct
        topN (1,1) double = Inf
        prominenceThreshold (1,1) double = 0
    end

    candidates = localEmpty();
    if isempty(results) || ~isfield(results, "metrics") || isempty(results.metrics)
        return;
    end
    metricRes = results.metrics{1};
    if ~isstruct(metricRes) || ~isfield(metricRes, "candidateTable")
        return;
    end
    candidateTable = metricRes.candidateTable;
    if isempty(candidateTable) || height(candidateTable) == 0
        return;
    end

    if ~isfinite(topN) || topN <= 0
        topN = height(candidateTable);
    end

    if prominenceThreshold > 0 && any(strcmp(candidateTable.Properties.VariableNames, "GridValue"))
        maxVal = max(candidateTable.GridValue, [], "omitnan");
        if isfinite(maxVal) && maxVal > 0
            candidateTable = candidateTable(candidateTable.GridValue >= maxVal * prominenceThreshold, :);
        end
    end

    if height(candidateTable) > topN
        candidateTable = candidateTable(1:topN, :);
    end

    candidates = candidateTableToStruct(candidateTable);
end

function candidates = candidateTableToStruct(candidateTable)
    candidates = localEmpty();
    if isempty(candidateTable) || height(candidateTable) == 0
        return;
    end
    vn = candidateTable.Properties.VariableNames;
    hasGridValue = any(strcmp(vn, "GridValue"));
    hasTag = any(strcmp(vn, "Tag"));
    for i = 1:height(candidateTable)
        c = struct("P", candidateTable.P_um(i) * 1e3, "R", candidateTable.R_um(i) * 1e3, ...
            "Value", NaN, "Tag", sprintf("Seed %d", i), "BasinId", NaN, "Depth", NaN, ...
            "Area", NaN, "PeakOnEdge", false, "Status", "");
        if hasGridValue
            c.Value = candidateTable.GridValue(i);
        end
        if hasTag && strlength(candidateTable.Tag(i)) > 0
            c.Tag = char(candidateTable.Tag(i));
        end
        if any(strcmp(vn, "BasinId")), c.BasinId = double(candidateTable.BasinId(i)); end
        if any(strcmp(vn, "Depth")), c.Depth = double(candidateTable.Depth(i)); end
        if any(strcmp(vn, "BasinArea")), c.Area = double(candidateTable.BasinArea(i)); end
        if any(strcmp(vn, "PeakOnEdge")), c.PeakOnEdge = logical(candidateTable.PeakOnEdge(i)); end
        if c.PeakOnEdge
            c.Status = "edge";
        end
        candidates(i) = c;
    end
end

function s = localEmpty()
    s = struct("P", {}, "R", {}, "Value", {}, "Tag", {}, "BasinId", {}, ...
        "Depth", {}, "Area", {}, "PeakOnEdge", {}, "Status", {});
end
