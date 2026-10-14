function refinedSeeds = extractRefinedSeeds(results, baseMetric, seeds)
%extractRefinedSeeds Extract refined optima from localization maximaResults.
%   Robust single-metric extraction with tag inheritance from original seeds.
%
%   refinedSeeds = extractRefinedSeeds(results, baseMetric, seeds)
%
%   Inputs:
%       results    - Localization workflow results struct.
%       baseMetric - String name of the base metric (e.g., "EF_vol").
%       seeds      - (optional) Original seeds struct array for tag inheritance.
%
%   Output:
%       refinedSeeds - Struct array with fields Tag, P, R, Value (nm units).

    arguments
        results struct
        baseMetric string
        seeds = []
    end

    refinedSeeds = struct("Tag", {}, "P", {}, "R", {}, "Value", {});
    if isempty(results) || ~isfield(results, "metrics") || isempty(results.metrics)
        return;
    end

    metricIdx = [];
    for i = 1:numel(results.metrics)
        mr = results.metrics{i};
        if isstruct(mr) && isfield(mr, "metricName") && string(mr.metricName) == string(baseMetric)
            metricIdx = i;
            break;
        end
    end
    % Fallback: use first non-empty maxima table if metric-name lookup misses
    if isempty(metricIdx)
        for i = 1:numel(results.metrics)
            mr = results.metrics{i};
            if isstruct(mr) && isfield(mr, "maximaResults") && ~isempty(mr.maximaResults)
                metricIdx = i;
                break;
            end
        end
    end
    if isempty(metricIdx)
        return;
    end

    metricRes = results.metrics{metricIdx};
    if ~isfield(metricRes, "maximaResults") || isempty(metricRes.maximaResults)
        return;
    end
    tbl = metricRes.maximaResults;
    varNames = tbl.Properties.VariableNames;  % cell of chars
    if ~all(ismember({'P_um', 'R_um'}, varNames))
        return;
    end

    metricKey = string(baseMetric);
    if isfield(metricRes, "metricName") && strlength(string(metricRes.metricName)) > 0
        metricKey = string(metricRes.metricName);
    end
    % Try all three variant suffixes so the displayed value is never NaN
    % regardless of which metric variant was used during optimization.
    valueField = '';
    for vs = {'_avg', '_laser', '_analyte'}
        candidate = matlab.lang.makeValidName(char(metricKey + vs{1}));
        if any(strcmp(varNames, candidate))
            valueField = candidate;
            break;
        end
    end
    n = height(tbl);
    refinedSeeds = repmat(struct("Tag", "", "P", NaN, "R", NaN, "Value", NaN, ...
        "BasinId", NaN, "Depth", NaN, "Status", ""), n, 1);
    hasSeedIdx = any(strcmp(varNames, 'SeedIndex'));
    hasBasin = any(strcmp(varNames, 'BasinId'));
    hasStatus = any(strcmp(varNames, 'Status'));
    hasSpread = any(strcmp(varNames, 'Spread_nm'));
    hasFallback = any(strcmp(varNames, 'IsFallback'));
    for j = 1:n
        refinedSeeds(j).P = double(tbl.P_um(j)) * 1e3;
        refinedSeeds(j).R = double(tbl.R_um(j)) * 1e3;
        if ~isempty(valueField)
            refinedSeeds(j).Value = double(tbl.(valueField)(j));
        end
        refinedSeeds(j).Tag = sprintf("Optimum %d", j);
        if hasBasin
            refinedSeeds(j).BasinId = double(tbl.BasinId(j));
        end
        if hasStatus
            st = string(tbl.Status(j));
            if hasSpread && isfinite(tbl.Spread_nm(j)) && any(st == ["ridge", "multi"])
                st = st + sprintf(" (%.1f nm)", tbl.Spread_nm(j));
            end
            refinedSeeds(j).Status = st;
        elseif hasFallback && logical(tbl.IsFallback(j))
            refinedSeeds(j).Status = "fallback";
        end
    end

    if ~isempty(seeds) && isstruct(seeds)
        seedP = arrayfun(@(s) double(s.P), seeds(:));
        seedR = arrayfun(@(s) double(s.R), seeds(:));
        for j = 1:numel(refinedSeeds)
            srcIdx = [];
            if hasSeedIdx
                k = double(tbl.SeedIndex(j));
                if isfinite(k) && k >= 1 && k <= numel(seeds)
                    srcIdx = k;
                end
            end
            if isempty(srcIdx)
                dP = seedP - refinedSeeds(j).P;
                dR = seedR - refinedSeeds(j).R;
                [~, srcIdx] = min(dP.^2 + dR.^2);
            end
            if isempty(srcIdx)
                continue;
            end
            src = seeds(srcIdx);
            if isfield(src, "Tag")
                refinedSeeds(j).Tag = string(src.Tag);
            end
            if ~isfinite(refinedSeeds(j).BasinId) && isfield(src, "BasinId")
                refinedSeeds(j).BasinId = double(src.BasinId);
            end
            if isfield(src, "Depth")
                refinedSeeds(j).Depth = double(src.Depth);
            end
        end
    end
end
