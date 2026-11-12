function [filtered, includedFields] = selectPredictionFieldsCanonical(allData, selectedFields)
%selectPredictionFieldsCanonical Select requested metric fields in canonical naming.
%   Filters a SoA struct to include only base geometry/wavelength fields
%   and the requested metric/variant fields.
%
%   [filtered, includedFields] = selectPredictionFieldsCanonical(allData, selectedFields)
%
%   Inputs:
%       allData        - Full SoA struct with all fields.
%       selectedFields - String array of requested field names (canonical).
%                        If empty, uses default set of common SERS metrics.
%
%   Outputs:
%       filtered       - SoA struct with base fields + matched metric fields.
%       includedFields - String array of actually included metric field names.

    arguments
        allData struct
        selectedFields string = string.empty
    end

    if isempty(selectedFields)
        baseMetrics = discoverSimSpectralMetrics(allData);
        if isempty(baseMetrics)
            baseMetrics = ["Abs", "EF_max", "EE_V", "EE_S"];
        end
        suffixes = ["", "_laser", "_broad", "_analyte"];
        selectedFields = strings(1, 0);
        for bi = 1:numel(baseMetrics)
            for si = 1:numel(suffixes)
                selectedFields(end+1) = baseMetrics(bi) + suffixes(si); %#ok<AGROW>
            end
        end
    end

    filtered = struct();
    includedFields = string.empty;

    % Always copy scalar geometry and metadata fields.
    % lambda / RamanShift ([N×L]) are added only if at least one selected
    % field is itself spectral — skipped when only scalar variants are selected.
    scalarBaseFields  = ["period", "radius", "LaserWl", "lambda_exc_nm", ...
                         "RamanWindow", "RamanWindowEffective", "MetricsRamanWindow", ...
                         "kappa_V", "kappa_S"];
    spectralBaseFields = ["lambda", "RamanShift"];

    for i = 1:numel(scalarBaseFields)
        fn = scalarBaseFields(i);
        if isfield(allData, char(fn))
            filtered.(fn) = allData.(fn);
        end
    end

    for i = 1:numel(selectedFields)
        req = string(selectedFields(i));
        srcName = resolveFieldInData(allData, req);
        if srcName == ""
            continue;
        end

        filtered.(req) = allData.(srcName);
        includedFields(end + 1) = req; %#ok<AGROW>
    end

    % Add lambda / RamanShift only when at least one saved field is [N×L] spectral.
    N = size(allData.period, 1);
    anySpectral = false;
    for i = 1:numel(includedFields)
        fn = char(includedFields(i));
        if isfield(filtered, fn)
            v = filtered.(fn);
            if isnumeric(v) && ismatrix(v) && size(v, 1) == N && size(v, 2) > 1
                anySpectral = true;
                break;
            end
        end
    end
    if anySpectral
        for i = 1:numel(spectralBaseFields)
            fn = spectralBaseFields(i);
            if isfield(allData, char(fn))
                filtered.(fn) = allData.(fn);
            end
        end
    end
end

function srcName = resolveFieldInData(allData, req)
    if isfield(allData, char(req))
        srcName = req;
        return;
    end
    candidates = string.empty;
    candidates = [candidates, localVariantSynonyms(req)];

    % Cross-base aliases (EE_V <-> EF_vol, EE_S <-> EF_surf, Abs <-> Absorptance,
    % EF_max <-> E4_max <-> M2_max, ECC <-> ECCheck)
    altReqs = expandAliasCandidates(req);
    for a = 1:numel(altReqs)
        altReq = altReqs(a);
        if altReq == req, continue; end
        candidates(end+1) = altReq; %#ok<AGROW>
        candidates = [candidates, localVariantSynonyms(altReq)]; %#ok<AGROW>
    end

    srcName = "";
    for k = 1:numel(candidates)
        if isfield(allData, char(candidates(k)))
            srcName = candidates(k);
            return;
        end
    end
end

function syns = localVariantSynonyms(name)
    syns = string.empty;
    if endsWith(name, "_broad")
        syns(end+1) = replace(name, "_broad", "_avg");
    elseif endsWith(name, "_avg")
        syns(end+1) = replace(name, "_avg", "_broad");
    elseif endsWith(name, "_laser")
        syns(end+1) = replace(name, "_laser", "_approx");
    end
end

function alts = expandAliasCandidates(name)
    aliasGroups = { ...
        ["EE_V", "EF_vol"], ...
        ["EE_S", "EF_surf"], ...
        ["Abs", "Absorptance"], ...
        ["EF_max", "E4_max", "M2_max", "E4"], ...
        ["ECC", "ECCheck"]};

    suffixes = ["_laser", "_broad", "_avg", "_analyte", "_approx"];
    base = name;
    sfx = "";
    for s = suffixes
        if endsWith(name, s)
            base = extractBefore(name, strlength(name) - strlength(s) + 1);
            sfx = s;
            break;
        end
    end

    alts = name;
    for g = 1:numel(aliasGroups)
        grp = aliasGroups{g};
        if any(strcmp(base, grp))
            alts = grp + sfx;
            return;
        end
    end
end
