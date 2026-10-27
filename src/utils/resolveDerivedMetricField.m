function fieldName = resolveDerivedMetricField(baseMetric, variant, soaData)
% resolveDerivedMetricField  Resolve derived metric field name with fallback.
%
%   fieldName = resolveDerivedMetricField(baseMetric, variant)
%   fieldName = resolveDerivedMetricField(baseMetric, variant, soaData)
%
%   Given a base spectral metric (e.g., "EE_V", "EE_S", "EF_max", "Abs")
%   and a variant type, returns the canonical derived field name. If soaData
%   is provided, checks field existence and falls back across both new and
%   legacy field names.
%
%   Canonical mapping:
%       <base> + "laser"   -> "<base>_laser"
%       <base> + "broad"   -> "<base>_broad"
%       <base> + "analyte" -> "<base>_analyte"
%       <base> + "avg"     -> "<base>_avg" (legacy alias for "_broad")
%
%   Cross-generation fallbacks accepted when soaData is provided:
%       EE_V_broad     <-> EF_vol_broad <-> EF_vol_avg <-> BEE_vol
%       EE_S_broad     <-> EF_surf_broad <-> EF_surf_avg <-> BEE_surf
%       EE_V_analyte   <-> EF_vol_analyte <-> AEE_vol
%       EE_S_analyte   <-> EF_surf_analyte <-> AEE_surf
%       EE_V_laser     <-> EF_vol_laser <-> EF_vol_approx
%       EE_S_laser     <-> EF_surf_laser <-> EF_surf_approx
%       Abs_laser      <-> Absorptance_laser <-> Abs_approx
%       Abs_broad      <-> Abs_avg <-> Absorptance_broad <-> Absorptance_avg
%       EF_max_laser   <-> EF_laser_max <-> EF_max_approx
%
%   Inputs:
%       baseMetric - string: canonical base metric name
%       variant    - string: "broad", "broadband", "avg", "analyte", "weighted", or "laser"
%       soaData    - (optional) struct: SoA data to check field existence
%
%   Output:
%       fieldName  - string: resolved field name
%
%   See also: normalizeMetricNames, canonicalMetricName

    arguments
        baseMetric (1,1) string
        variant (1,1) string {mustBeMember(variant, ["broad", "broadband", "avg", "analyte", "weighted", "laser"])}
        soaData struct = struct()
    end

    bMetric = baseMetric;
    v = lower(variant);
    if v == "broadband"
        v = "broad";
    elseif v == "weighted"
        v = "analyte";
    end

    % Build canonical name and candidate list in priority order
    switch v
        case {"broad", "avg"}
            if v == "broad"
                newName = bMetric + "_broad";
            else
                newName = bMetric + "_avg";
            end
            switch char(bMetric)
                case {"Abs", "Absorptance"}
                    if v == "broad"
                        candidates = ["Abs_broad", "Absorptance_broad", "Abs_avg", "Absorptance_avg"];
                    else
                        candidates = ["Abs_avg", "Absorptance_avg", "Abs_broad", "Absorptance_broad"];
                    end
                case {"EE_V", "EF_vol"}
                    if bMetric == "EE_V" || v == "broad"
                        candidates = ["EE_V_broad", "EE_V_avg", "EF_vol_broad", "EF_vol_avg", "BEE_vol"];
                    else
                        candidates = ["EF_vol_avg", "EF_vol_broad", "EE_V_broad", "EE_V_avg", "BEE_vol"];
                    end
                case {"EE_S", "EF_surf"}
                    if bMetric == "EE_S" || v == "broad"
                        candidates = ["EE_S_broad", "EE_S_avg", "EF_surf_broad", "EF_surf_avg", "BEE_surf"];
                    else
                        candidates = ["EF_surf_avg", "EF_surf_broad", "EE_S_broad", "EE_S_avg", "BEE_surf"];
                    end
                case "EF_max"
                    if v == "broad"
                        candidates = ["EF_max_broad", "EF_max_avg", "M2_max_broad", "M2_max_avg"];
                    else
                        candidates = ["EF_max_avg", "EF_max_broad", "M2_max_avg", "M2_max_broad"];
                    end
                otherwise
                    if v == "broad"
                        candidates = [newName, bMetric + "_avg", baseMetric + "_broad", baseMetric + "_avg"];
                    else
                        candidates = [newName, bMetric + "_broad", baseMetric + "_avg", baseMetric + "_broad"];
                    end
            end

        case "analyte"
            newName = bMetric + "_analyte";
            switch char(bMetric)
                case {"Abs", "Absorptance"}
                    candidates = ["Abs_analyte", "Absorptance_analyte", "Abs_broad", "Abs_avg", "Absorptance_avg"];
                case {"EE_V", "EF_vol"}
                    if bMetric == "EE_V"
                        candidates = ["EE_V_analyte", "EF_vol_analyte", "AEE_vol", "EE_V_broad", "EF_vol_avg"];
                    else
                        candidates = ["EF_vol_analyte", "EE_V_analyte", "AEE_vol", "EF_vol_avg", "EE_V_broad"];
                    end
                case {"EE_S", "EF_surf"}
                    if bMetric == "EE_S"
                        candidates = ["EE_S_analyte", "EF_surf_analyte", "AEE_surf", "EE_S_broad", "EF_surf_avg"];
                    else
                        candidates = ["EF_surf_analyte", "EE_S_analyte", "AEE_surf", "EF_surf_avg", "EE_S_broad"];
                    end
                case "EF_max"
                    candidates = ["EF_max_analyte", "M2_max_analyte", "EF_max_broad", "EF_max_avg"];
                otherwise
                    candidates = [newName, baseMetric + "_analyte"];
            end

        case "laser"
            newName = bMetric + "_laser";
            switch char(bMetric)
                case {"Abs", "Absorptance"}
                    candidates = ["Abs_laser", "Absorptance_laser", "Abs_approx", "Absorptance_approx"];
                case {"EE_V", "EF_vol"}
                    if bMetric == "EE_V"
                        candidates = ["EE_V_laser", "EF_vol_laser", "EF_vol_approx", "EE_V_approx"];
                    else
                        candidates = ["EF_vol_approx", "EF_vol_laser", "EE_V_laser", "EE_V_approx"];
                    end
                case {"EE_S", "EF_surf"}
                    if bMetric == "EE_S"
                        candidates = ["EE_S_laser", "EF_surf_laser", "EF_surf_approx", "EE_S_approx"];
                    else
                        candidates = ["EF_surf_approx", "EF_surf_laser", "EE_S_laser", "EE_S_approx"];
                    end
                case "EF_max"
                    candidates = ["EF_max_laser", "EF_laser_max", "EF_max_approx", "M2_max_laser"];
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
                vData = soaData.(cName);
                if isnumeric(vData)
                    validCount = nnz(isfinite(vData));
                else
                    validCount = numel(vData);
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
