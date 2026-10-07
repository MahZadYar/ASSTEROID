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
    metricVariant = "";
    if isfield(cfg, "metricVariant"), metricVariant = string(cfg.metricVariant); end
    if metricVariant == "weighted"
        variantForField = "analyte";
    elseif metricVariant == "laser"
        variantForField = "laser";
    else
        variantForField = "avg";
    end
    stokesLimits = [0, 0];
    lambdaLaser = 785;
    if isfield(cfg, "stokesShiftLimits"), stokesLimits = cfg.stokesShiftLimits; end
    if isfield(cfg, "lambdaLaser"), lambdaLaser = cfg.lambdaLaser; end

    for i = 1:numel(seeds)
        pNm = double(seeds(i).P);
        rNm = double(seeds(i).R);
        if ~isfinite(pNm) || ~isfinite(rNm)
            continue;
        end
        try
            if metricVariant == "weighted"
                analyteSpecEval = getDefaultAnalyteSpectrum();
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
            end
        catch
        end
    end
end
