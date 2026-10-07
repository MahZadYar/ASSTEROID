function lambdaVals = sanitizeLambdaVector(entry)
if ~isstruct(entry) || ~isfield(entry, 'lambda') || isempty(entry.lambda)
    lambdaVals = [];
    return;
end
vec = ensureRowVector(entry.lambda);
lambdaVals = vec(~isnan(vec));
end