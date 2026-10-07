function Y = predictSurrogateSpectrum(model, pUm, rUm, lambdaUm, ri, options)
%predictSurrogateSpectrum Evaluate the surrogate on a (geometry x wavelength) grid.
%
%   Y = predictSurrogateSpectrum(model, pUm, rUm, lambdaUm, ri)
%
%   Inputs:
%       model    - trained model struct (v1 legacy or v2_physics schema)
%       pUm, rUm - [nG x 1] geometry periods and radii in µm (paired)
%       lambdaUm - [nL x 1] wavelengths in µm (any density; the network is
%                  a continuous function of lambda, so the grid need not
%                  coincide with the COMSOL sampling)
%       ri       - refractive-index struct (nm- or µm-gridded; see
%                  evalRefractiveIndex)
%
%   Name-Value:
%       ChunkSize (default 200000) - rows per minibatchpredict call
%
%   Output:
%       Y - [nG x nL x nTargets] predictions in physical units
%           (after model.denormalize).
%
%   The feature pipeline is normalizeModelFeatures, which dispatches on the
%   model schema (v1: log/ratio features; v2: buildPhysicsFeatures + z-score),
%   so training and inference share one code path.
%
%   See also: predict_dense_spectrum, normalizeModelFeatures, evalRefractiveIndex

arguments
    model (1,1) struct
    pUm (:,1) double
    rUm (:,1) double
    lambdaUm (:,1) double
    ri (1,1) struct
    options.ChunkSize (1,1) double {mustBePositive} = 200000
    options.ExecutionEnvironment (1,1) string {mustBeMember(options.ExecutionEnvironment, ["auto", "gpu", "cpu"])} = "auto"
    options.MiniBatchSize (1,1) double {mustBePositive} = 32768
end

if numel(pUm) ~= numel(rUm)
    error("predictSurrogateSpectrum:SizeMismatch", ...
        "pUm and rUm must have the same number of elements (%d vs %d).", numel(pUm), numel(rUm));
end

model = ensureModelFlags(model);
nG = numel(pUm);
nL = numel(lambdaUm);
nT = numel(model.targetNames);
Y = zeros(nG, nL, nT);
if nG == 0 || nL == 0
    return;
end

% Determine execution environment (GPU if available)
execEnv = options.ExecutionEnvironment;
if execEnv == "auto"
    try
        if canUseGPU() && gpuDeviceCount() > 0
            execEnv = "gpu";
        else
            execEnv = "cpu";
        end
    catch
        execEnv = "cpu";
    end
end

% Row ordering: geometry index varies fastest, wavelength slowest, so the
% result reshapes directly to [nG x nL x nT].
[nLam, kLam] = evalRefractiveIndex(ri, lambdaUm);
lamStack = repelem(lambdaUm, nG, 1);
features = [repmat(pUm, nL, 1), repmat(rUm, nL, 1), lamStack, ...
            repelem(nLam(:), nG, 1), repelem(kLam(:), nG, 1)];

numRows = size(features, 1);
preds = zeros(numRows, nT);
chunk = max(1, round(options.ChunkSize));
miniBatch = min(max(1, round(options.MiniBatchSize)), chunk);

for startIdx = 1:chunk:numRows
    stopIdx = min(startIdx + chunk - 1, numRows);
    Xn = normalizeModelFeatures(features(startIdx:stopIdx, :), model);
    % Single precision input maximizes GPU memory throughput and tensor performance
    bs = min(miniBatch, size(Xn, 1));
    Z = minibatchpredict(model.net, single(Xn), ...
        MiniBatchSize=bs, ...
        ExecutionEnvironment=execEnv);
    preds(startIdx:stopIdx, :) = model.denormalize(double(gather(Z)));
end

Y = reshape(preds, nG, nL, nT);
end
