function values = evaluateMetricAtPoints(results, baseMetric, seeds)
%evaluateMetricAtPoints Evaluate metric at seed coordinates.
%   Uses DNN predictor (exact) if available; falls back to grid interpolation.
%
%   values = evaluateMetricAtPoints(results, baseMetric, seeds)
%
%   Inputs:
%       results    - Localization workflow results struct (with .predictor, .cfg, .metrics).
%       baseMetric - String name of the base metric.
%       seeds      - Struct array with .P, .R fields (nm).
%
%   Output:
%       values - [numel(seeds) × 1] metric values at each seed location.

    arguments
        results struct
        baseMetric string
        seeds struct
    end

    values = NaN(numel(seeds), 1);
    if isempty(seeds)
        return;
    end

    % --- Model path: use predictor when available ---
    predictor = [];
    lambdaSamples = [];
    evalCfg = struct("stokesShiftLimits", [0, 0], "lambdaLaser", 785);

    if isfield(results, "predictor") && isstruct(results.predictor) && ...
            isfield(results.predictor, "predictGrid")
        predictor = results.predictor;
    end
    if isfield(results, "cfg") && isstruct(results.cfg)
        evalCfg = results.cfg;
    end
    if isfield(results, "metrics") && ~isempty(results.metrics)
        for mi = 1:numel(results.metrics)
            mr = results.metrics{mi};
            if isstruct(mr) && isfield(mr, "lambdaSamples") && ~isempty(mr.lambdaSamples)
                lambdaSamples = mr.lambdaSamples;  % µm
                break;
            end
        end
    end

    if ~isempty(predictor) && ~isempty(lambdaSamples)
        values = evaluateFromModel(predictor, baseMetric, seeds, lambdaSamples, evalCfg);
        return;
    end

    % --- Grid fallback (interpolation mode) ---
    if ~isfield(results, "metrics") || isempty(results.metrics)
        return;
    end
    metricRes = [];
    for i = 1:numel(results.metrics)
        if isstruct(results.metrics{i}) && isfield(results.metrics{i}, "metricName") && ...
                results.metrics{i}.metricName == string(baseMetric)
            metricRes = results.metrics{i};
            break;
        end
    end
    if isempty(metricRes) || ~isfield(metricRes, "avgMetricGrid") || isempty(metricRes.avgMetricGrid)
        % Fallback: reconstruct 2D grid from allData SoA directly
        if isfield(results, "allData") && isstruct(results.allData)
            allData = results.allData;
            variant = "broad";
            if isfield(evalCfg, "metricVariant"), variant = string(evalCfg.metricVariant); end
            parsedVar = parseMetricVariantName(variant);
            if strlength(parsedVar.variant) > 0 && parsedVar.variantKind ~= "spectral"
                vField = parsedVar.variant;
            else
                vField = "broad";
            end
            avgFieldName = char(resolveDerivedMetricField(baseMetric, vField, allData));
            if isfield(allData, avgFieldName) && isfield(allData, "period") && isfield(allData, "radius")
                P = double(allData.period(:));
                R = double(allData.radius(:));
                V = double(allData.(avgFieldName)(:));
                pUniq = unique(P);
                rUniq = unique(R);
                if numel(pUniq) >= 2 && numel(rUniq) >= 2
                    [pGrid, rGrid] = meshgrid(pUniq, rUniq);
                    zGrid = NaN(size(pGrid));
                    for k = 1:numel(P)
                        pi = find(abs(pUniq - P(k)) < 1e-6, 1);
                        ri = find(abs(rUniq - R(k)) < 1e-6, 1);
                        if ~isempty(pi) && ~isempty(ri)
                            zGrid(ri, pi) = V(k);
                        end
                    end
                    pVals = arrayfun(@(s) double(s.P), seeds(:));
                    rVals = arrayfun(@(s) double(s.R), seeds(:));
                    values = interp2(pGrid, rGrid, zGrid, pVals, rVals, "linear", NaN);
                    return;
                end
            end
        end
        return;
    end
    pSamplesNm = metricRes.pSamples * 1e3;
    rSamplesNm = metricRes.rSamples * 1e3;
    avgGrid = metricRes.avgMetricGrid;
    if numel(pSamplesNm) < 2 || numel(rSamplesNm) < 2
        return;
    end
    pVals = arrayfun(@(s) double(s.P), seeds(:));
    rVals = arrayfun(@(s) double(s.R), seeds(:));
    values = interp2(pSamplesNm, rSamplesNm, avgGrid, pVals, rVals, "linear", NaN);
end

function values = evaluateFromModel(predictor, baseMetric, seeds, lambdaSamples, cfg)
%evaluateFromModel Evaluate metric at each seed via DNN predictor.
%   seeds.P / seeds.R in nm; lambdaSamples in µm.
    values = NaN(numel(seeds), 1);
    metricVariant = "broad";
    if isfield(cfg, "metricVariant"), metricVariant = string(cfg.metricVariant); end
    parsedVar = parseMetricVariantName(metricVariant, IsVariantToken=true);
    if strlength(parsedVar.variant) > 0 && parsedVar.variantKind ~= "spectral"
        variantForField = parsedVar.variant;
    else
        variantForField = "broad";
    end
    stokesLimits = [0, 0];
    lambdaLaser = 785;
    if isfield(cfg, "stokesShiftLimits"), stokesLimits = cfg.stokesShiftLimits; end
    if isfield(cfg, "lambdaLaser"), lambdaLaser = cfg.lambdaLaser; end

    analyteSpecEval = struct();
    if parsedVar.variantKind == "analyte"
        explicitFile = "";
        if isfield(cfg, "analyteSpectrumFile"), explicitFile = string(cfg.analyteSpectrumFile); end
        cachedSpec = struct();
        if isfield(cfg, "analyteSpectrum") && isstruct(cfg.analyteSpectrum), cachedSpec = cfg.analyteSpectrum; end
        libCtx = struct();
        if isfield(cfg, "analyteLibrary") && isstruct(cfg.analyteLibrary) && ~isempty(cfg.analyteLibrary)
            libCtx.Global = struct("AnalyteLibrary", cfg.analyteLibrary);
        end
        if strlength(parsedVar.analyteKey) > 0
            matched = resolveAnalyteLibrary(libCtx, Keys=parsedVar.analyteKey, ...
                ExplicitFile=explicitFile, CachedSpectrum=cachedSpec, FallbackToDefault=false);
            if ~isempty(matched)
                analyteSpecEval = matched(1).spectrum;
            end
        end
        if ~isstruct(analyteSpecEval) || ~isfield(analyteSpecEval, "shift_cm") || isempty(analyteSpecEval.shift_cm)
            analyteSpecEval = resolveAnalyteSpectrum(libCtx, ...
                ExplicitFile=explicitFile, CachedSpectrum=cachedSpec, FallbackToDefault=true);
        end
    end

    for i = 1:numel(seeds)
        pNm = double(seeds(i).P);
        rNm = double(seeds(i).R);
        if ~isfinite(pNm) || ~isfinite(rNm)
            continue;
        end
        try
            if parsedVar.variantKind == "analyte"
                soa = predictor.predictGrid(pNm * 1e-3, rNm * 1e-3, lambdaSamples, ...
                    "LaserWavelength", lambdaLaser, "RamanWindow", stokesLimits, ...
                    "AnalyteSpectrum", analyteSpecEval);
            else
                soa = predictor.predictGrid(pNm * 1e-3, rNm * 1e-3, lambdaSamples, ...
                    "LaserWavelength", lambdaLaser, "RamanWindow", stokesLimits);
            end
            avgFieldName = char(resolveDerivedMetricField(baseMetric, variantForField, soa));
            if isfield(soa, avgFieldName) && ~isempty(soa.(avgFieldName))
                values(i) = double(soa.(avgFieldName)(1));
            elseif parsedVar.variantKind == "analyte"
                % predictGrid populated <baseMetric>_analyte using analyteSpecEval
                fallbackField = char(resolveDerivedMetricField(baseMetric, "analyte", soa));
                if isfield(soa, fallbackField) && ~isempty(soa.(fallbackField))
                    values(i) = double(soa.(fallbackField)(1));
                end
            end
        catch
        end
    end
end
