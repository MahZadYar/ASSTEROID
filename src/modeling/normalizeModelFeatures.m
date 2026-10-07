function normFeatures = normalizeModelFeatures(rawFeatures, model)
%normalizeModelFeatures Normalize model inputs with flag-aware preprocessing.
%
% normFeatures = normalizeModelFeatures(rawFeatures, model)
%
% rawFeatures must be [N x 5] with columns [p, r, lambda, n, k] in micrometers.
% This function computes ratio features if needed, then calls model.normalize.
% 
% The model's normalize function handles log transforms internally based on
% featureLogMask, so we do NOT apply log transforms here. We only add ratios
% in linear (or log-difference) space, and model.normalize will handle everything.
%
% v2 physics-schema models (isPhysicsSchemaModel): ensureModelFlags sets
% IncludeRatios=false and rebinds model.normalize to standardizeModelFeatures,
% which builds the full physics feature set from the same 5 raw columns.

arguments
    rawFeatures (:,5) double
    model (1,1) struct
end

model = ensureModelFlags(model);
featuresForNormalize = rawFeatures;

% If model requires ratio features, compute them in the appropriate domain
if model.IncludeRatios
    p = rawFeatures(:, 1);
    r = rawFeatures(:, 2);
    lambda = rawFeatures(:, 3);
    
    % CRITICAL: Ratios must be computed as LINEAR divisions to match training
    % During training (prepare_training_dataset.m), ratios are always computed as:
    %   ratio_PL = pCol ./ lambdaCol
    %   ratio_RL = rCol ./ lambdaCol  
    %   ratio_PR = pCol ./ rCol
    % These are NOT log-transformed in featureLogMask (set to false for ratio columns)
    % Therefore, prediction MUST use the same linear ratios
    
    ratioPLambda = p ./ lambda;
    ratioRLambda = r ./ lambda;
    ratioPR = p ./ r;
    
    % Append ratios to the 5 base features
    % model.normalize will:
    %   1. Log-transform ONLY [p, r, lambda] if featureLogMask(1:3) = true
    %   2. Leave ratios untransformed (featureLogMask(6:8) = false)
    %   3. Z-score normalize all 8 features
    featuresForNormalize = [rawFeatures, ratioPLambda, ratioRLambda, ratioPR];
end

% Call model.normalize which internally:
% 1. Log-transforms first 3 columns if featureLogMask indicates so
% 2. Z-score normalizes all columns using precomputed center and scale
normFeatures = model.normalize(featuresForNormalize);

expectedSize = model.inputSize;
if ~isempty(expectedSize) && size(normFeatures, 2) ~= expectedSize
    error("normalizeModelFeatures:InputSizeMismatch", ...
        "Normalized features have %d columns but model expects %d.", ...
        size(normFeatures, 2), expectedSize);
end
end
