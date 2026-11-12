function [allMetrics, defaultTargets] = discoverSimSpectralMetrics(simData, options)
%discoverSimSpectralMetrics Discover 2D spectral metric fields in an SoA struct.
%
%   [allMetrics, defaultTargets] = discoverSimSpectralMetrics(simData) inspects a
%   Structure-of-Arrays simulation struct (e.g., db.Sim or allData) and returns:
%     allMetrics     - 1xK string array of all [N x L] (L > 1) spectral metric
%                      fields present, excluding coordinate/metadata columns and
%                      scalar derived summaries (*_laser, *_broad, *_avg, *_analyte).
%     defaultTargets - 1xM string array of recommended supervised training
%                      targets present in simData (prioritising physical targets
%                      Abs/EF_max/EE_V/EE_S when present, excluding diagnostic
%                      error-check columns such as ECC unless nothing else exists).
%
%   Options:
%     IncludeLogical (logical, default false) - include 2D logical masks as metrics.
%
%   See also: prepare_training_dataset, recomputeDerivedMetrics, validateSoAStructure

    arguments
        simData
        options.IncludeLogical (1,1) logical = false
    end

    allMetrics = strings(1, 0);
    defaultTargets = strings(1, 0);

    if ~isstruct(simData) || isempty(simData) || isempty(fieldnames(simData))
        return;
    end

    nRows = structRowCount(simData);
    if nRows <= 0
        return;
    end

    reservedFields = ["period", "radius", "p", "r", "lambda", "lambda_nm", "lambda0", ...
                      "f", "RamanShift", "RamanWindow", "RamanWindowEffective", ...
                      "LaserWl", "lambda_exc_nm", "kappa_V", "kappa_S", "VolCorr", "SurfCorr", ...
                      "Source", "Parent", "Method", "ModelRef", "StokesWindow", "Shifts"];
    derivedSuffixes = ["_laser", "_broad", "_avg", "_analyte"];

    rawFields = string(fieldnames(simData));
    discovered = strings(1, 0);
    for i = 1:numel(rawFields)
        fn = rawFields(i);
        if ismember(fn, reservedFields) || endsWith(fn, derivedSuffixes)
            continue;
        end
        val = simData.(char(fn));
        isValidType = isnumeric(val) || (options.IncludeLogical && islogical(val));
        if isValidType && ismatrix(val) && size(val, 1) >= nRows && size(val, 2) > 1
            discovered(end+1) = fn; %#ok<AGROW>
        end
    end

    if isempty(discovered)
        return;
    end

    % Canonical ordering: primary SERS physics targets -> secondary physical ->
    % custom/user fields -> diagnostic check fields.
    primaryPriority = ["Abs", "Absorptance", "EF_max", "M2_max", "E4_max", ...
                       "EE_V", "EF_vol", "EE_S", "EF_surf"];
    secondaryPriority = ["M_vol", "M_surf", "M2_vol", "M2_surf", ...
                         "E_vol", "E_surf", "intW_vol", "intW_t", ...
                         "Reflectance", "Transmittance", "ResistiveLoss"];
    diagnosticFields = ["ECC", "ECCheck", "SkinDepth"];

    allMetrics = strings(1, 0);
    for p = [primaryPriority, secondaryPriority]
        if ismember(p, discovered) && ~ismember(p, allMetrics)
            allMetrics(end+1) = p; %#ok<AGROW>
        end
    end

    remaining = discovered(~ismember(discovered, allMetrics) & ~ismember(discovered, diagnosticFields));
    allMetrics = [allMetrics, remaining];

    for d = diagnosticFields
        if ismember(d, discovered) && ~ismember(d, allMetrics)
            allMetrics(end+1) = d; %#ok<AGROW>
        end
    end

    % Recommended default training targets: prefer core SERS targets that exist
    % in simData; fall back to all non-diagnostic spectral fields if custom.
    defaultTargets = primaryPriority(ismember(primaryPriority, allMetrics));
    if isempty(defaultTargets)
        defaultTargets = allMetrics(~ismember(allMetrics, diagnosticFields));
    end
    if isempty(defaultTargets)
        defaultTargets = allMetrics;
    end
end

