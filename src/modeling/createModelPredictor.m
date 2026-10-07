function predictor = createModelPredictor(model, ri, options)
    %createModelPredictor  Wrap a trained DNN model into a unified predictor struct.
    %
    %   predictor = createModelPredictor(model, ri) creates a predictor struct
    %   that evaluates the DNN at arbitrary (p, r, lambda) coordinates. The
    %   predictor can be passed to find_local_maxima, loadOrGeneratePredictions,
    %   and other functions that accept the unified predictor interface.
    %
    %   predictor = createModelPredictor(model, ri, MiniBatchSize=2048)
    %   overrides the default batch size for minibatchpredict.
    %
    %   The predictor struct exposes:
    %       .mode           "model"
    %       .targetNames    Cell array of target metric names
    %       .predictSpectral Function handle: @(p, r, lambdaVec) -> [Nl x T]
    %       .predictGrid    Function handle: @(pVec, rVec, lambdaVec) -> SoA struct
    %       .model          Original model struct (for backward compat)
    %       .ri             Original RI struct (for backward compat)
    %
    %   Input:
    %       model — Trained regression model struct with fields:
    %               net, targetNames, normalize, denormalize
    %       ri    — Refractive index struct with nFunc, kFunc interpolants
    %
    %   Name-Value Arguments:
    %       MiniBatchSize (1,1) double — Batch size for predict (default: 2048)
    %
    %   Output:
    %       predictor — Unified predictor struct
    %
    %   Example:
    %       [model, ri] = loadAndValidateModel(ModelFile="model.mat");
    %       pred = createModelPredictor(model, ri);
    %       spectrum = pred.predictSpectral(0.85, 0.2, 0.78:0.001:1.1);
    %
    %   See also: createDataPredictor, buildPredictorFromConfig,
    %             find_local_maxima, loadOrGeneratePredictions

    arguments
        model (1,1) struct
        ri (1,1) struct
        options.MiniBatchSize (1,1) double {mustBePositive, mustBeInteger} = 2048
        options.ExecutionEnvironment (1,1) string {mustBeMember(options.ExecutionEnvironment, ["auto", "gpu", "cpu"])} = "auto"
    end

    %% Validate model
    requiredFields = ["net", "targetNames", "normalize", "denormalize"];
    for i = 1:numel(requiredFields)
        if ~isfield(model, requiredFields(i))
            error("createModelPredictor:InvalidModel", ...
                "Model missing required field: %s", requiredFields(i));
        end
    end
    if ~isfield(ri, "nFunc") || ~isfield(ri, "kFunc")
        error("createModelPredictor:InvalidRI", ...
            "RI struct must have nFunc and kFunc interpolants.");
    end

    batchSize = options.MiniBatchSize;

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

    % Rebuild schema-dependent handles (v2 physics models) once up front.
    model = ensureModelFlags(model);

    %% Build predictor struct
    predictor = struct();
    predictor.mode = "model";
    predictor.targetNames = model.targetNames;
    predictor.model = model;
    predictor.ri = ri;
    predictor.executionEnvironment = execEnv;

    predictor.predictSpectral = @(p, r, lambdaVec) ...
        predictSpectralModel(p, r, lambdaVec, model, ri, batchSize, execEnv);

    predictor.predictGrid = @(pVec, rVec, lambdaVec, varargin) ...
        predictGridModel(pVec, rVec, lambdaVec, model, ri, execEnv, varargin{:});

    predictor.predictPointsBatch = @(pArr, rArr, lambdaVec, varargin) ...
        predictPointsBatchModel(pArr, rArr, lambdaVec, model, ri, execEnv, varargin{:});
end

%% ========================================================================
function result = predictSpectralModel(pVal, rVal, lambdaVec, model, ri, batchSize, execEnv)
    %predictSpectralModel  Evaluate DNN at a single (p, r) over all wavelengths.
    %
    %   Returns [Nl x T] matrix where Nl = numel(lambdaVec), T = numTargets.

    lambdaVec = double(lambdaVec(:));
    numLambda = numel(lambdaVec);

    pVec = repmat(double(pVal), numLambda, 1);
    rVec = repmat(double(rVal), numLambda, 1);
    [normFeatures, ~] = buildModelInputFeatures(pVec, rVec, lambdaVec, ri, model);

    bs = min(max(1, round(batchSize)), size(normFeatures, 1));
    predNorm = minibatchpredict(model.net, single(normFeatures), ...
        MiniBatchSize=bs, ExecutionEnvironment=execEnv);
    predNorm = double(gather(predNorm));
    result = double(gather(model.denormalize(predNorm)));
end

%% ========================================================================
function allData = predictGridModel(pVec, rVec, lambdaVec, model, ri, execEnv, varargin)
    %predictGridModel  Full grid prediction delegating to predict_dense_spectrum.

    allData = predict_dense_spectrum(model, pVec, rVec, lambdaVec, ri, ...
        "ExecutionEnvironment", execEnv, varargin{:});
end

%% ========================================================================
function Y = predictPointsBatchModel(pArr, rArr, lambdaVec, model, ri, execEnv, varargin)
    %predictPointsBatchModel Fully vectorized evaluation for point coordinates.
    %   pArr and rArr are expected in micrometers (consistent with buildPointPredictionSoA).

    % Filter out non-key-value or callback arguments if passed from progress reporting
    cleanArgs = {};
    if ~isempty(varargin)
        for k = 1:2:numel(varargin)
            if k + 1 <= numel(varargin) && (ischar(varargin{k}) || isstring(varargin{k}))
                cleanArgs = [cleanArgs, varargin(k:k+1)]; %#ok<AGROW>
            end
        end
    end
    Y = predictSurrogateSpectrum(model, double(pArr(:)), double(rArr(:)), ...
        double(lambdaVec(:)), ri, "ExecutionEnvironment", execEnv, cleanArgs{:});
end