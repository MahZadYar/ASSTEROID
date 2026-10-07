%% Test SoA Conversion Utilities
% Validates convertGridToSoA, reshapeSoAToVolume, and validateSoAStructure.

%% Setup Test Data
fprintf("=== SoA Conversion Tests ===\n\n");

% Create synthetic grid data (mimics predict_dense_spectrum output)
Nr = 10;  % number of radius values
Np = 8;   % number of period values
Nlambda = 50;

rVec = linspace(30, 80, Nr)' * 1e-9;   % radius in meters
pVec = linspace(100, 250, Np)' * 1e-9; % period in meters
lambdaVec = linspace(400, 900, Nlambda)' * 1e-9; % wavelength in meters

% Build 3D grids
[RGrid, PGrid, LambdaGrid] = ndgrid(rVec, pVec, lambdaVec);

% Create synthetic EF_vol (Gaussian-like response)
EF_vol_grid = exp(-((LambdaGrid - 650e-9).^2) / (2 * (100e-9)^2)) .* ...
              (1 + 0.5 * sin(2*pi * RGrid / 50e-9));

% Physical constraint: r < p/2 (valid combinations only)
validMask = RGrid(:,:,1) < PGrid(:,:,1) / 2;

% Simulation parameters
LaserWl = 785;  % nm
RamanShift = [100, 3500];  % cm^-1
RamanWindow = 300;  % cm^-1

%% Test 1: convertGridToSoA
fprintf("Test 1: convertGridToSoA...\n");

allData = convertGridToSoA(EF_vol_grid, rVec, pVec, lambdaVec, ...
    "Fields", "EF_vol", ...
    "LaserWl", LaserWl, ...
    "RamanShift", RamanShift, ...
    "RamanWindow", RamanWindow);

% Count expected valid combinations
expectedN = sum(validMask(:));
actualN = size(allData.period, 1);

assert(actualN == expectedN, ...
    sprintf("Row count mismatch: expected %d, got %d", expectedN, actualN));

assert(isfield(allData, "period") && isfield(allData, "radius"), ...
    "Missing geometry fields");
assert(isfield(allData, "lambda") && isfield(allData, "EF_vol"), ...
    "Missing spectral fields");
assert(isfield(allData, "LaserWl") && all(allData.LaserWl == LaserWl), ...
    "LaserWl metadata mismatch");
assert(isfield(allData, "RamanShift") && isequal(allData.RamanShift, RamanShift), ...
    "RamanShift metadata mismatch");

fprintf("  PASSED: %d valid geometries extracted\n", actualN);
fprintf("  PASSED: All required fields present\n");
fprintf("  PASSED: Metadata correctly stored\n\n");

%% Test 2: validateSoAStructure
fprintf("Test 2: validateSoAStructure...\n");

[isValid, issues] = validateSoAStructure(allData);
assert(isValid, sprintf("Validation failed: %s", strjoin(issues, ", ")));
fprintf("  PASSED: Structure validation successful\n");

% Test with invalid structure
badStruct.period = [1; 2; 3];
badStruct.radius = [1; 2];  % Wrong size
badStruct.lambda = rand(3, 10);
badStruct.EF_vol = rand(3, 10);

[isValid, issues] = validateSoAStructure(badStruct);
assert(~isValid, "Should detect size mismatch");
fprintf("  PASSED: Detected invalid structure (%d issues)\n\n", numel(issues));

%% Test 3: reshapeSoAToVolume
fprintf("Test 3: reshapeSoAToVolume...\n");

[EF_vol_rebuilt, pUnique, rUnique, lambda] = reshapeSoAToVolume(allData, "EF_vol");

% Check dimensions
assert(numel(rUnique) == Nr, "Radius vector length mismatch");
assert(numel(pUnique) == Np, "Period vector length mismatch");
assert(numel(lambda) == Nlambda, "Lambda vector length mismatch");
assert(isequal(size(EF_vol_rebuilt), [Nr, Np, Nlambda]), ...
    sprintf("Grid size mismatch: expected [%d,%d,%d], got [%d,%d,%d]", ...
    Nr, Np, Nlambda, size(EF_vol_rebuilt, 1), size(EF_vol_rebuilt, 2), size(EF_vol_rebuilt, 3)));

fprintf("  PASSED: Reconstructed grid size [%d × %d × %d]\n", Nr, Np, Nlambda);

%% Test 4: Round-trip Conversion (Grid → SoA → Grid)
fprintf("Test 4: Round-trip conversion...\n");

% Compare original vs reconstructed at valid positions
[R_check, P_check] = ndgrid(rUnique, pUnique);
validCheck = R_check < P_check / 2;

% Extract valid values from both
origValid = EF_vol_grid(repmat(validCheck, 1, 1, Nlambda));
reconValid = EF_vol_rebuilt(repmat(validCheck, 1, 1, Nlambda));

% Check numeric equality (within tolerance)
maxError = max(abs(origValid - reconValid));
assert(maxError < 1e-10, sprintf("Round-trip error %g exceeds tolerance", maxError));

fprintf("  PASSED: Round-trip max error = %.2e\n\n", maxError);

%% Test 5: Multiple Fields
fprintf("Test 5: Multiple field conversion...\n");

% Create M_vol and Absorptance grids
M_vol_grid = sqrt(EF_vol_grid);
Abs_grid = 1 - exp(-0.1 * EF_vol_grid);

% Stack into cell array for conversion
allFields = cat(4, EF_vol_grid, M_vol_grid, Abs_grid);
fieldNames = ["EF_vol", "M_vol", "Absorptance"];

% Convert each field
multiData = convertGridToSoA(EF_vol_grid, rVec, pVec, lambdaVec, ...
    "Fields", "EF_vol");

% Add additional fields manually (simulating multi-field scenario)
multiData.M_vol = convertGridToSoA(M_vol_grid, rVec, pVec, lambdaVec, ...
    "Fields", "M_vol").M_vol;
multiData.Absorptance = convertGridToSoA(Abs_grid, rVec, pVec, lambdaVec, ...
    "Fields", "Absorptance").Absorptance;

% Validate multi-field structure
[isValid, ~] = validateSoAStructure(multiData);
assert(isValid, "Multi-field structure invalid");

% Reconstruct each field
for i = 1:numel(fieldNames)
    [rebuilt, ~, ~, ~] = reshapeSoAToVolume(multiData, fieldNames(i));
    assert(~isempty(rebuilt), sprintf("Failed to rebuild %s", fieldNames(i)));
end

fprintf("  PASSED: All %d fields converted and validated\n\n", numel(fieldNames));

%% Test 6: Edge Cases
fprintf("Test 6: Edge cases...\n");

% Single geometry point
singleData.period = 200e-9;
singleData.radius = 50e-9;
singleData.lambda = lambdaVec';
singleData.EF_vol = rand(1, Nlambda);

[isValid, ~] = validateSoAStructure(singleData);
assert(isValid, "Single geometry validation failed");
fprintf("  PASSED: Single geometry case\n");

% Empty structure
emptyData.period = [];
emptyData.radius = [];
emptyData.lambda = [];
emptyData.EF_vol = [];

[isValid, issues] = validateSoAStructure(emptyData);
assert(~isValid, "Should reject empty data");
fprintf("  PASSED: Empty data rejection\n\n");

%% Summary
fprintf("=== ALL TESTS PASSED ===\n");
fprintf("SoA conversion utilities are working correctly.\n");
fprintf("  - convertGridToSoA: Grid → SoA conversion\n");
fprintf("  - reshapeSoAToVolume: SoA → Grid reconstruction\n");
fprintf("  - validateSoAStructure: Structure validation\n");
