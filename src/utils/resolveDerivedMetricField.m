function fieldName = resolveDerivedMetricField(baseMetric, variant, soaData)
% resolveDerivedMetricField  Resolve derived metric field name with fallback.
%
%   fieldName = resolveDerivedMetricField(baseMetric, variant)
%   fieldName = resolveDerivedMetricField(baseMetric, variant, soaData)
%
%   Given a base spectral metric (e.g., "EF_vol") and a variant type,
%   returns the canonical derived field name. If soaData is provided,
%   checks field existence and falls back to legacy names.
%
%   Canonical mapping:
%       <base> + "avg"     -> "<base>_avg"
%       <base> + "analyte" -> "<base>_analyte"
%       <base> + "laser"   -> "<base>_laser"
%
%   Legacy fallbacks are still accepted when soaData is provided:
%       EF_vol_avg   <-> BEE_vol
%       EF_surf_avg  <-> BEE_surf
%       EF_vol_analyte <-> AEE_vol
%       EF_surf_analyte <-> AEE_surf
%       EF_vol_laser <-> EF_vol_approx
%       EF_surf_laser <-> EF_surf_approx
%
%   Inputs:
%       baseMetric - string: canonical base metric name
%       variant    - string: "avg", "analyte", or "laser"
%       soaData    - (optional) struct: SoA data to check field existence
%
%   Output:
%       fieldName  - string: resolved field name
%
%   See also: normalizeMetricNames

    arguments
        baseMetric (1,1) string
        variant (1,1) string {mustBeMember(variant, ["avg", "analyte", "laser"])}
        soaData struct = struct()
    end

    % Normalize base metric aliases
    bMetric = baseMetric;
    if bMetric == "Abs"
        bMetric = "Absorptance";
    end

    % Build canonical name and candidate list in priority order
    switch variant
        case "avg"
            newName = bMetric + "_avg";
            switch char(bMetric)
                case "Absorptance"
                    candidates = ["Abs_avg", "Absorptance_avg"];
                case "EF_vol"
                    candidates = ["EF_vol_avg", "BEE_vol"];
                case "EF_surf"
                    candidates = ["EF_surf_avg", "BEE_surf"];
                otherwise
                    candidates = [newName, baseMetric + "_avg"];
            end

        case "analyte"
            newName = bMetric + "_analyte";
            switch char(bMetric)
                case "EF_vol"
                    candidates = ["EF_vol_analyte", "AEE_vol", "EF_vol_avg"];
                case "EF_surf"
                    candidates = ["EF_surf_analyte", "AEE_surf", "EF_surf_avg"];
                otherwise
                    candidates = [newName, baseMetric + "_analyte"];
            end

        case "laser"
            newName = bMetric + "_laser";
            switch char(bMetric)
                case "Absorptance"
                    candidates = ["Abs_laser", "Absorptance_laser", "Abs_approx", "Absorptance_approx"];
                case "EF_vol"
                    candidates = ["EF_vol_approx", "EF_vol_laser"];
                case "EF_surf"
                    candidates = ["EF_surf_approx", "EF_surf_laser"];
                otherwise
                    candidates = [newName, baseMetric + "_laser", baseMetric + "_approx"];
            end
    end

    candidates = unique(candidates, 'stable');

    % Resolve with fallback if soaData provided
    if ~isempty(fieldnames(soaData))
        bestCandidate = "";
        maxValidCount = -1;

        % Choose the candidate that exists and has the most finite non-NaN data
        for i = 1:numel(candidates)
            cName = candidates(i);
            if isfield(soaData, cName)
                v = soaData.(cName);
                if isnumeric(v)
                    validCount = nnz(isfinite(v));
                else
                    validCount = numel(v);
                end
                if validCount > maxValidCount
                    maxValidCount = validCount;
                    bestCandidate = cName;
                end
            end
        end

        if bestCandidate ~= "" && maxValidCount > 0
            fieldName = bestCandidate;
        elseif isfield(soaData, newName)
            fieldName = newName;
        else
            fieldName = candidates(1);
            for i = 1:numel(candidates)
                if isfield(soaData, candidates(i))
                    fieldName = candidates(i);
                    break;
                end
            end
        end
    else
        fieldName = newName;
    end
end
