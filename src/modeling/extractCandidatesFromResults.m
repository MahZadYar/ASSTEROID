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
%       candidates - Struct array with fields P, R, Value, Tag (nm units).

    arguments
        results struct
        topN (1,1) double = Inf
        prominenceThreshold (1,1) double = 0
    end

    candidates = struct("P", {}, "R", {}, "Value", {}, "Tag", {});
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
    candidates = struct("P", {}, "R", {}, "Value", {}, "Tag", {});
    if isempty(candidateTable) || height(candidateTable) == 0
        return;
    end
    hasGridValue = any(strcmp(candidateTable.Properties.VariableNames, "GridValue"));
    hasTag = any(strcmp(candidateTable.Properties.VariableNames, "Tag"));
    for i = 1:height(candidateTable)
        candidates(i).P = candidateTable.P_um(i) * 1e3;
        candidates(i).R = candidateTable.R_um(i) * 1e3;
        if hasGridValue
            candidates(i).Value = candidateTable.GridValue(i);
        else
            candidates(i).Value = NaN;
        end
        if hasTag && strlength(candidateTable.Tag(i)) > 0
            candidates(i).Tag = char(candidateTable.Tag(i));
        else
            candidates(i).Tag = sprintf("Seed %d", i);
        end
    end
end
