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
            "Absorptance", "Absorptance_laser", ...
            "EF_vol", "EF_vol_laser", "EF_vol_avg", "EF_vol_analyte", ...
            "EF_surf", "EF_surf_laser", "EF_surf_avg", "EF_surf_analyte"];
    end

    filtered = struct();
    includedFields = string.empty;

    % Always copy scalar geometry and metadata fields.
    % lambda / RamanShift ([N×L]) are added only if at least one selected
    % field is itself spectral — skipped when only scalar variants are selected.
    scalarBaseFields  = ["period", "radius", "LaserWl", "lambda_exc_nm", ...
                         "RamanWindow", "RamanWindowEffective"];
    spectralBaseFields = ["lambda", "RamanShift"];

    for i = 1:numel(scalarBaseFields)
        fn = scalarBaseFields(i);
        if isfield(allData, char(fn))
            filtered.(fn) = allData.(fn);
        end
    end

    for i = 1:numel(selectedFields)
        req = string(selectedFields(i));
        srcName = req;
        if isfield(allData, char(req))
            srcName = req;
        elseif endsWith(req, "_laser")
            approxName = replace(req, "_laser", "_approx");
            if isfield(allData, char(approxName))
                srcName = approxName;
            else
                continue
            end
        else
            continue
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
