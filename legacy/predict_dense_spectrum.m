function predictions = predict_dense_spectrum(model, pVec, rVec, lambdaVec, ri, varargin)
% predict_dense_spectrum  Evaluate trained model on a dense (p,r,lambda) grid.
%
% predictions = predict_dense_spectrum(model, pVec, rVec, lambdaVec, ri)
% returns a struct containing volumetric predictions for each target metric.
% ri is a refractive index struct as returned by load_gold_refractive_index.
% Name-value arguments:
%   'ChunkSize'  controls max batch size (default 200000 rows)
%
% Output fields:
%   Absorptance, M_vol, M_surf, EF_vol, EF_surf: Ny x Nx x Nz volumes
%   grids: PGrid, RGrid, Lambda (nm), Lambda_um (micrometers)
%
% Any (p,r) combination where r >= p/2 is considered invalid and reported as NaN.

opts = struct('ChunkSize', 200000, 'Verbose', true);
if mod(numel(varargin), 2) ~= 0
    error('predict_dense_spectrum:Args', 'Name-value pairs expected.');
end
for i = 1:2:numel(varargin)
    name = varargin{i};
    val = varargin{i+1};
    if ~isfield(opts, name)
        error('predict_dense_spectrum:BadOption', 'Unknown option: %s', name);
    end
    opts.(name) = val;
end

pVec = double(pVec(:)');
rVec = double(rVec(:)');
lambdaVec = double(lambdaVec(:)');
lambdaVecUm = lambdaVec; % expect caller to supply micrometers

[Nr, Np, Nlambda] = deal(numel(rVec), numel(pVec), numel(lambdaVec));
[Pg, Rg] = meshgrid(pVec, rVec);
invalidMask = Rg >= (Pg / 2);
validMask = ~invalidMask;
hasValid = any(validMask(:));
numValid = nnz(validMask);

if hasValid
    PgValid = Pg(validMask);
    RgValid = Rg(validMask);
else
    PgValid = [];
    RgValid = [];
end

targetNames = model.targetNames;
numTargets = numel(targetNames);
volumes = NaN(Nr, Np, Nlambda, numTargets);

chunkSize = opts.ChunkSize;

if ~hasValid
    warning('predict_dense_spectrum:NoValidCombos', ...
        'No valid (p, r) combinations found; returning NaN volumes.');
end

if hasValid
    PgValidCol = PgValid(:);
    RgValidCol = RgValid(:);
    lambdaVals = repelem(lambdaVecUm(:), numValid, 1);
    PgStack = repmat(PgValidCol, Nlambda, 1);
    RgStack = repmat(RgValidCol, Nlambda, 1);
    nVals = ri.nFunc(lambdaVals);
    kVals = ri.kFunc(lambdaVals);
    featuresAll = double([PgStack, RgStack, lambdaVals, nVals, kVals]);

    predsAll = runBatchedPredict(model, featuresAll, chunkSize, opts.Verbose);
    predsAll = reshape(predsAll, numValid, Nlambda, numTargets);

    for lamIdx = 1:Nlambda
        predsLam = reshape(predsAll(:,lamIdx,:), numValid, numTargets);
        for t = 1:numTargets
            volumeSlice = volumes(:,:,lamIdx,t);
            volumeSlice(validMask) = predsLam(:,t);
            volumes(:,:,lamIdx,t) = volumeSlice;
        end
    end
end

predictions = struct();
for t = 1:numTargets
    targetName = char(targetNames{t});
    targetVolume = volumes(:,:,:,t);
    predictions.(targetName) = targetVolume;

    avgField = matlab.lang.makeValidName([targetName, '_avg']);
    avgSlice = mean(targetVolume, 3, 'omitnan');
    predictions.(avgField) = avgSlice;
end
predictions.PGrid = pVec;
predictions.RGrid = rVec;
predictions.Lambda = lambdaVec;
predictions.Lambda_um = lambdaVecUm;
end

function preds = runBatchedPredict(model, features, chunkSize, verbose)
% Batched prediction helper with optional chunking and progress reporting.
if nargin < 4
    verbose = false;
end
numRows = size(features, 1);
numTargets = numel(model.targetNames);
preds = zeros(numRows, numTargets);
if numRows == 0
    return;
end
startIdx = 1;
totalBatches = max(1, ceil(numRows / chunkSize));
batchIdx = 0;
while startIdx <= numRows
    stopIdx = min(startIdx + chunkSize - 1, numRows);
    batch = features(startIdx:stopIdx, :);
    batchNorm = model.normalize(batch);
    miniBatchSize = min(chunkSize, size(batchNorm, 1));
    miniBatchSize = max(miniBatchSize, 1);
    batchPred = minibatchpredict(model.net, batchNorm, MiniBatchSize=miniBatchSize);
    batchPred = model.denormalize(batchPred);
    preds(startIdx:stopIdx, :) = batchPred;
    batchIdx = batchIdx + 1;
    if verbose
        pct = (batchIdx / totalBatches) * 100;
    fprintf('Batch %d/%d (%.1f%% complete)\n', batchIdx, totalBatches, pct);
    end
    startIdx = stopIdx + 1;
end
end
