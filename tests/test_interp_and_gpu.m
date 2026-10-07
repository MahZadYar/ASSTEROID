%% TEST_INTERP_AND_GPU
% Unit tests verifying fixes for:
% 1. Degenerate grid error prevention during interpolation (NaN rows, scalar/duplicate lambda).
% 2. GPU execution and single-precision acceleration in Model (DNN) mode.
% 3. Vectorized point evaluation for model predictors.

addpath(pwd);
setup_project;
fprintf("=== Starting test_interp_and_gpu ===\n");

%% Test 1: createDataPredictor resilience with NaN rows and duplicate wavelengths
fprintf("[1] Testing createDataPredictor with degenerate rows & NaNs...\n");
N = 10;
L = 15;
p = linspace(750, 950, N)';
r = linspace(50, 450, N)';
lam = linspace(785, 1050, L);

simData = struct();
simData.period = p;
simData.radius = r;
simData.lambda = repmat(lam, N, 1);
simData.EF_vol = rand(N, L);
simData.Absorptance = rand(N, L);

% Inject edge cases:
% Row 2 has all NaNs in EF_vol
simData.EF_vol(2, :) = NaN;
% Row 3 has only 1 finite value in EF_vol
simData.EF_vol(3, 2:end) = NaN;
% Row 4 has duplicate wavelength values
simData.lambda(4, 2) = simData.lambda(4, 1);

% Should not throw DegenerateGridErrId
try
    predictor = createDataPredictor(simData, InterpMethod="linear", SpectralMethod="makima", LaserWavelength=785);
    fprintf("    ✓ createDataPredictor built successfully with degenerate rows\n");
catch ME
    error("test_interp_and_gpu:DegenerateFailed", "createDataPredictor failed: %s", ME.message);
end

% Test grid prediction with degenerate rows
gp = computeDenseGridParams(LambdaLaser=785, PLimits=[800, 900], RLimits=[100, 300], ...
    StokesShiftLimits=[100, 2000], Resolution=20, StokesShiftResolution=50);
try
    outGrid = predictor.predictGrid(gp.pSamples, gp.rSamples, gp.lambdaSamples, ...
        "LaserWavelength", gp.lambdaLaser, "RamanWindow", gp.stokesShiftLimits);
    assert(isfield(outGrid, "EF_vol"), "EF_vol missing in outGrid");
    fprintf("    ✓ predictor.predictGrid completed successfully\n");
catch ME
    error("test_interp_and_gpu:GridFailed", "predictGrid failed: %s", ME.message);
end

%% Test 2: GPU acceleration & execution environment
fprintf("[2] Testing GPU acceleration in predictSurrogateSpectrum...\n");
gpuAvail = canUseGPU() && gpuDeviceCount() > 0;
if gpuAvail
    g = gpuDevice();
    fprintf("    Detected GPU: %s (%.1f GB VRAM)\n", g.Name, g.TotalMemory / 1e9);
else
    fprintf("    No GPU detected; running CPU fallback verification\n");
end

% Create synthetic v2 model
net = dlnetwork(layerGraph([ ...
    featureInputLayer(5, "Name", "in"), ...
    fullyConnectedLayer(32, "Name", "fc1"), ...
    reluLayer("Name", "r1"), ...
    fullyConnectedLayer(2, "Name", "fc2")]));

model = struct();
model.net = net;
model.targetNames = {'EF_vol', 'Absorptance'};
model.IncludeRatios = false;
model.featureLogMask = false(1, 5);
model.featureCenter = zeros(1, 5);
model.featureScale = ones(1, 5);
model.inputSize = 5;
model.normalize = @(X) (X - model.featureCenter) ./ model.featureScale;
model.denormalize = @(Y) exp(Y);

ri = struct();
ri.lambda = [700, 800, 900, 1000, 1100];
ri.n = [1.5, 1.4, 1.3, 1.2, 1.1];
ri.k = [0.1, 0.2, 0.3, 0.4, 0.5];
Fn = griddedInterpolant(ri.lambda, ri.n, 'linear', 'nearest');
Fk = griddedInterpolant(ri.lambda, ri.k, 'linear', 'nearest');
ri.nFunc = @(l) Fn(l * 1e3);
ri.kFunc = @(l) Fk(l * 1e3);

pUm = [0.85; 0.90];
rUm = [0.20; 0.25];
lamUm = (0.785:0.01:0.95)';

% Test execution with auto/gpu/cpu
Y_cpu = predictSurrogateSpectrum(model, pUm, rUm, lamUm, ri, ExecutionEnvironment="cpu");
assert(all(isfinite(Y_cpu(:))), "CPU predictions must be finite");

if gpuAvail
    Y_gpu = predictSurrogateSpectrum(model, pUm, rUm, lamUm, ri, ExecutionEnvironment="gpu");
    assert(all(isfinite(Y_gpu(:))), "GPU predictions must be finite");
    maxDiff = max(abs(Y_cpu(:) - Y_gpu(:)));
    assert(maxDiff < 1e-4, sprintf("GPU and CPU predictions must match closely (diff=%.2e)", maxDiff));
    fprintf("    ✓ GPU and CPU predictions matched within %.2e\n", maxDiff);
end

%% Test 3: createModelPredictor batch points evaluation
fprintf("[3] Testing createModelPredictor.predictPointsBatch...\n");
mPred = createModelPredictor(model, ri);
assert(isfield(mPred, "predictPointsBatch"), "predictPointsBatch must be exposed on mPred");

ptsY = mPred.predictPointsBatch(pUm, rUm, lamUm);
assert(isequal(size(ptsY), [numel(pUm), numel(lamUm), 2]), "Shape must be [Np x Nl x Nt]");
fprintf("    ✓ predictPointsBatch evaluated [2 x %d x 2] in single call\n", numel(lamUm));

fprintf("=== test_interp_and_gpu PASSED successfully! ===\n");
