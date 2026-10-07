%% TEST_FEATURE_CONSISTENCY  Verify training vs prediction feature computation matches.
%
%   This test checks that the feature preprocessing pipeline produces identical
%   results during training (prepare_training_dataset.m) and prediction
%   (normalizeModelFeatures.m).
%
%   The test verifies:
%     1. Ratio computation: linear divisions in both training and prediction
%     2. Log transform: applied only to [p, r, lambda], not ratios
%     3. Feature ordering and values match exactly
%
%   Example:
%       test_feature_consistency
%
%   See also: prepare_training_dataset, normalizeModelFeatures

%% Setup
clear; clc;
fprintf('=== Testing Feature Preprocessing Consistency ===\n\n');

%% Test Parameters
% Use realistic SERS geometry values (in micrometers)
p_um = 0.860;      % 860 nm period
r_um = 0.280;      % 280 nm radius
lambda_um = 0.785; % 785 nm wavelength (Ti:Sapphire laser)
n_val = 0.1;       % Real part of refractive index
k_val = 5.1;       % Imaginary part of refractive index

fprintf('Test geometry:\n');
fprintf('  Period:      %.4f µm (%.1f nm)\n', p_um, p_um * 1e3);
fprintf('  Radius:      %.4f µm (%.1f nm)\n', r_um, r_um * 1e3);
fprintf('  Wavelength:  %.4f µm (%.1f nm)\n', lambda_um, lambda_um * 1e3);
fprintf('  n:           %.4f\n', n_val);
fprintf('  k:           %.4f\n\n', k_val);

%% 1. Compute Features as in Training (prepare_training_dataset.m)
fprintf('1. Computing features as in TRAINING pipeline...\n');

% Training uses linear divisions for ratios (lines 281-284)
ratio_PL_training = p_um / lambda_um;
ratio_RL_training = r_um / lambda_um;
ratio_PR_training = p_um / r_um;

% Assemble feature vector (before log transform)
features_training_linear = [p_um, r_um, lambda_um, n_val, k_val, ...
                            ratio_PL_training, ratio_RL_training, ratio_PR_training];

% Apply log transform to first 3 columns (as per featureLogMask)
featureLogMask = [true, true, true, false, false, false, false, false];
features_training_transformed = features_training_linear;
features_training_transformed(featureLogMask) = log(features_training_linear(featureLogMask));

fprintf('  Linear features:      [%.4f, %.4f, %.4f, %.4f, %.4f, %.4f, %.4f, %.4f]\n', ...
    features_training_linear);
fprintf('  After log transform:  [%.4f, %.4f, %.4f, %.4f, %.4f, %.4f, %.4f, %.4f]\n', ...
    features_training_transformed);
fprintf('  Ratios (linear):      p/λ=%.4f, r/λ=%.4f, p/r=%.4f\n\n', ...
    ratio_PL_training, ratio_RL_training, ratio_PR_training);

%% 2. Compute Features as in Prediction (normalizeModelFeatures.m)
fprintf('2. Computing features as in PREDICTION pipeline...\n');

% Create mock model with necessary flags
model = struct();
model.FeatureLogTransform = true;
model.IncludeRatios = true;
model.TargetLogTransform = true;
model.inputSize = 8;
model.featureNames = {'p_um', 'r_um', 'lambda_um', 'n', 'k', ...
                      'p_over_lambda', 'r_over_lambda', 'p_over_r'};

% Mock normalize function that applies log transform + passthrough
model.normalize = @(X) applyTransform(X, featureLogMask);

% Build raw features as in buildModelInputFeatures
rawFeatures = [p_um, r_um, lambda_um, n_val, k_val];

% Call normalizeModelFeatures (should match training)
features_prediction = normalizeModelFeatures(rawFeatures, model);

fprintf('  Predicted features:   [%.4f, %.4f, %.4f, %.4f, %.4f, %.4f, %.4f, %.4f]\n', ...
    features_prediction);

% Extract ratios from prediction
ratio_PL_prediction = features_prediction(6);
ratio_RL_prediction = features_prediction(7);
ratio_PR_prediction = features_prediction(8);
fprintf('  Ratios (from pred):   p/λ=%.4f, r/λ=%.4f, p/r=%.4f\n\n', ...
    ratio_PL_prediction, ratio_RL_prediction, ratio_PR_prediction);

%% 3. Compare Results
fprintf('3. Comparing training vs prediction features...\n');

tolerance = 1e-10;
maxDiff = max(abs(features_training_transformed - features_prediction));

fprintf('  Max absolute difference: %.3e\n', maxDiff);

if maxDiff < tolerance
    fprintf('  ✓ SUCCESS: Features match within tolerance (%.3e)\n', tolerance);
    allPassed = true;
else
    fprintf('  ✗ FAILURE: Features differ by %.3e (tolerance: %.3e)\n', maxDiff, tolerance);
    fprintf('  Column-wise differences:\n');
    for i = 1:8
        diff = abs(features_training_transformed(i) - features_prediction(i));
        if diff > tolerance
            fprintf('    Column %d (%s): %.6e\n', i, model.featureNames{i}, diff);
        end
    end
    allPassed = false;
end

%% 4. Verify Ratio Computation Method
fprintf('\n4. Verifying ratio computation method...\n');

% Check that ratios are LINEAR divisions, not log-differences
expected_p_lambda = p_um / lambda_um;
expected_r_lambda = r_um / lambda_um;
expected_p_r = p_um / r_um;

% These would be the wrong values if using log-differences
wrong_p_lambda = log(p_um) - log(lambda_um);  % = log(p/λ)
wrong_r_lambda = log(r_um) - log(lambda_um);
wrong_p_r = log(p_um) - log(r_um);

fprintf('  Expected (linear):    p/λ=%.4f, r/λ=%.4f, p/r=%.4f\n', ...
    expected_p_lambda, expected_r_lambda, expected_p_r);
fprintf('  Wrong (log-diff):     %.4f, %.4f, %.4f\n', ...
    wrong_p_lambda, wrong_r_lambda, wrong_p_r);
fprintf('  Prediction gave:      %.4f, %.4f, %.4f\n', ...
    ratio_PL_prediction, ratio_RL_prediction, ratio_PR_prediction);

ratioTest = abs(ratio_PL_prediction - expected_p_lambda) < tolerance && ...
            abs(ratio_RL_prediction - expected_r_lambda) < tolerance && ...
            abs(ratio_PR_prediction - expected_p_r) < tolerance;

if ratioTest
    fprintf('  ✓ Ratios are LINEAR divisions (correct)\n');
else
    fprintf('  ✗ Ratios are NOT linear divisions (BUG!)\n');
    allPassed = false;
end

%% Summary
fprintf('\n=== TEST SUMMARY ===\n');
if allPassed
    fprintf('✓ ALL TESTS PASSED: Feature preprocessing is consistent.\n');
    fprintf('  Your model predictions should now match the training data distribution.\n');
else
    fprintf('✗ TESTS FAILED: Feature preprocessing mismatch detected!\n');
    fprintf('  This explains why model predictions differ from raw data visualization.\n');
end

%% Helper Function
function Xtrans = applyTransform(X, logMask)
    % Mock normalize function: applies log transform then returns
    Xtrans = X;
    Xtrans(:, logMask) = log(X(:, logMask));
end
