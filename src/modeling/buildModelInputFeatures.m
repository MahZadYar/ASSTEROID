function [normFeatures, rawFeatures] = buildModelInputFeatures(pVals, rVals, lambdaVals, ri, model)
%buildModelInputFeatures Build model-ready input features with flags.
%
% [normFeatures, rawFeatures] = buildModelInputFeatures(pVals, rVals, lambdaVals, ri, model)
%
% Inputs are in micrometers. Returns raw feature matrix [p, r, lambda, n, k]
% and normalized features suitable for the model.

arguments
    pVals (:,1) double
    rVals (:,1) double
    lambdaVals (:,1) double
    ri (1,1) struct
    model (1,1) struct
end

if ~isfield(ri, "nFunc") || ~isfield(ri, "kFunc")
    error("buildModelInputFeatures:InvalidRI", "RI struct must have nFunc and kFunc.");
end

% µm query; evalRefractiveIndex adapts to nm- or µm-gridded RI structs.
[nVals, kVals] = evalRefractiveIndex(ri, double(lambdaVals));
nVals = nVals(:);
kVals = kVals(:);
rawFeatures = [double(pVals), double(rVals), double(lambdaVals), nVals, kVals];

normFeatures = normalizeModelFeatures(rawFeatures, model);
end
