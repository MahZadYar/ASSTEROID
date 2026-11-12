function baseTargets = deriveBaseTargetsFromSelection(selectedFields, simData)
%deriveBaseTargetsFromSelection Reduce selected UI fields to base [N x L] targets in simData.
%
%   baseTargets = deriveBaseTargetsFromSelection(selectedFields, simData)
%   strips derived suffixes (_laser, _broad, _avg, _analyte, _approx) from
%   the UI-selected prediction/interpolation fields and resolves each base name
%   (including canonical/legacy aliases such as EE_V <-> EF_vol,
%   EE_S <-> EF_surf, Abs <-> Absorptance, EF_max <-> E4_max <-> M2_max)
%   against actual [N x L] spectral fields present in simData.
%
%   If no matches remain (or selectedFields is empty), falls back to
%   discoverSimSpectralMetrics(simData).
%
%   See also: discoverSimSpectralMetrics, selectPredictionFieldsCanonical

    arguments
        selectedFields string = string.empty
        simData        struct = struct()
    end

    derivedSuffixes = ["_laser", "_broad", "_avg", "_analyte", "_approx"];
    selectedFields = strtrim(string(selectedFields(:)));
    selectedFields = selectedFields(strlength(selectedFields) > 0);

    bases = string.empty;
    for i = 1:numel(selectedFields)
        f = selectedFields(i);
        base = f;
        for s = derivedSuffixes
            if endsWith(f, s)
                base = extractBefore(f, strlength(f) - strlength(s) + 1);
                break;
            end
        end
        if startsWith(base, "BEE_")
            base = replaceBetween(base, 1, 4, "EE_");
        elseif startsWith(base, "AEE_")
            base = replaceBetween(base, 1, 4, "EE_");
        end
        bases(end+1) = base; %#ok<AGROW>
    end
    bases = unique(bases, "stable");

    hasSim = ~isempty(simData) && isstruct(simData) && ~isempty(fieldnames(simData));
    if ~hasSim
        baseTargets = bases;
        return;
    end

    [N, L] = localSimDimensions(simData);
    resolved = string.empty;
    for i = 1:numel(bases)
        hit = localResolveSpectralField(simData, bases(i), N, L);
        if hit ~= "" && ~ismember(hit, resolved)
            resolved(end+1) = hit; %#ok<AGROW>
        end
    end

    if ~isempty(resolved)
        baseTargets = resolved;
        return;
    end

    % Fallback: dynamically discover available spectral targets in simData
    [allDiscovered, defTargets] = discoverSimSpectralMetrics(simData);
    if ~isempty(defTargets)
        baseTargets = defTargets;
    else
        baseTargets = allDiscovered;
    end
end

function [N, L] = localSimDimensions(simData)
    N = structRowCount(simData);
    L = 0;
    if isfield(simData, "lambda") && ~isempty(simData.lambda)
        L = size(simData.lambda, 2);
    end
end

function resolved = localResolveSpectralField(simData, baseName, N, L)
    resolved = "";
    candidates = localAliasGroup(baseName);
    for k = 1:numel(candidates)
        fn = char(candidates(k));
        if isfield(simData, fn)
            v = simData.(fn);
            isSpec = isnumeric(v) && ismatrix(v) && size(v, 1) >= N && size(v, 2) > 1;
            if isSpec && (L <= 1 || size(v, 2) == L)
                resolved = string(fn);
                return;
            end
        end
    end
end

function grp = localAliasGroup(baseName)
    groups = { ...
        ["EE_V", "EF_vol"], ...
        ["EE_S", "EF_surf"], ...
        ["Abs", "Absorptance"], ...
        ["EF_max", "E4_max", "M2_max", "E4"], ...
        ["ECC", "ECCheck"]};
    for g = 1:numel(groups)
        if any(strcmp(baseName, groups{g}))
            grp = unique([baseName, groups{g}], "stable");
            return;
        end
    end
    grp = baseName;
end
