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
        selectedFields = [ ...
            "Abs", "Abs_laser", "Abs_broad", "Abs_analyte", ...
            "EF_max", "EF_max_laser", "EF_max_broad", "EF_max_analyte", ...
            "EE_V", "EE_V_laser", "EE_V_broad", "EE_V_analyte", ...
            "EE_S", "EE_S_laser", "EE_S_broad", "EE_S_analyte", ...
            "Absorptance", "Absorptance_laser", "Absorptance_avg", ...
            "EF_vol", "EF_vol_laser", "EF_vol_avg", "EF_vol_analyte", ...
            "EF_surf", "EF_surf_laser", "EF_surf_avg", "EF_surf_analyte"];
    end

    filtered = struct();
    includedFields = string.empty;

    % Always copy scalar geometry and metadata fields.
    % lambda / RamanShift ([N×L]) are added only if at least one selected
    % field is itself spectral — skipped when only scalar variants are selected.
    scalarBaseFields  = ["period", "radius", "LaserWl", "lambda_exc_nm", ...
                         "RamanWindow", "RamanWindowEffective", ...
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
    if endsWith(req, "_broad")
        candidates(end+1) = replace(req, "_broad", "_avg");
    elseif endsWith(req, "_avg")
        candidates(end+1) = replace(req, "_avg", "_broad");
    elseif endsWith(req, "_laser")
        candidates(end+1) = replace(req, "_laser", "_approx");
    end

    % Cross-base aliases (EE_V <-> EF_vol, EE_S <-> EF_surf, Abs <-> Absorptance)
    altReq = swapBaseAlias(req);
    if altReq ~= req
        candidates(end+1) = altReq;
        if endsWith(altReq, "_broad")
            candidates(end+1) = replace(altReq, "_broad", "_avg");
        elseif endsWith(altReq, "_avg")
            candidates(end+1) = replace(altReq, "_avg", "_broad");
        elseif endsWith(altReq, "_laser")
            candidates(end+1) = replace(altReq, "_laser", "_approx");
        end
    end

    srcName = "";
    for k = 1:numel(candidates)
        if isfield(allData, char(candidates(k)))
            srcName = candidates(k);
            return;
        end
    end
end

function alt = swapBaseAlias(name)
    alt = name;
    if startsWith(name, "EE_V")
        alt = replaceBetween(name, 1, 4, "EF_vol");
    elseif startsWith(name, "EF_vol")
        alt = replaceBetween(name, 1, 6, "EE_V");
    elseif startsWith(name, "EE_S")
        alt = replaceBetween(name, 1, 4, "EF_surf");
    elseif startsWith(name, "EF_surf")
        alt = replaceBetween(name, 1, 7, "EE_S");
    elseif startsWith(name, "Absorptance")
        alt = replaceBetween(name, 1, 11, "Abs");
    elseif name == "Abs" || startsWith(name, "Abs_")
        alt = replaceBetween(name, 1, 3, "Absorptance");
    end
end
