% Comprehensive test script for DNN pipeline
% This script runs the full pipeline with detailed error reporting

% clear all;
clc;

fprintf('========================================\n');
fprintf('SERS DNN Pipeline - Comprehensive Test\n');
fprintf('========================================\n\n');

% Change to work directory
workDir = pwd;
fprintf('Working directory: %s\n\n', workDir);

% Step 1: Check raw data file
fprintf('Step 1: Checking raw data files...\n');
rawDataFile = fullfile(pwd, 'prl_sweep_cylinder15_h150_532.mat');
if ~isfile(rawDataFile)
    fprintf('  (Benchmark dataset prl_sweep_cylinder15_h150_532.mat not found locally; skipping.)\n');
    return;
end
fprintf('  ✓ Found: %s\n', rawDataFile);

% Load and inspect raw data
load(rawDataFile, 'allData');
fprintf('  - Rows: %d\n', size(allData.period, 1));
fprintf('  - Period range: [%.6e, %.6e] nm\n', min(allData.period), max(allData.period));
fprintf('  - Radius range: [%.6e, %.6e] nm\n', min(allData.radius), max(allData.radius));

% Check for non-positive values
nNegPeriod = sum(allData.period <= 0);
nNegRadius = sum(allData.radius <= 0);
fprintf('  - Non-positive periods: %d\n', nNegPeriod);
fprintf('  - Non-positive radii: %d\n', nNegRadius);

% Check wavelength data
lambdaData = allData.lambda;
fprintf('  - Wavelength shape: [%d × %d]\n', size(lambdaData, 1), size(lambdaData, 2));
fprintf('  - Lambda range: [%.1f, %.1f] nm (excluding NaN)\n', ...
    min(lambdaData(~isnan(lambdaData))), max(lambdaData(~isnan(lambdaData))));

% Step 2: Check refractive index file
fprintf('\nStep 2: Checking refractive index file...\n');
riFile = fullfile(pwd, 'McPeak.csv');
if ~isfile(riFile)
    error('Refractive index file not found: %s', riFile);
end
fprintf('  ✓ Found: %s\n', riFile);

% Step 3: Run pipeline
fprintf('\nStep 3: Running DNN pipeline...\n\n');
try
    run_dnn_pipeline;
    fprintf('\n✓ Pipeline completed successfully!\n');
catch ME
    fprintf('\n✗ Pipeline failed with error:\n\n');
    fprintf('Error: %s\n', ME.message);
    fprintf('\nStack trace:\n');
    for i = 1:length(ME.stack)
        st = ME.stack(i);
        fprintf('  %s at line %d\n', st.name, st.line);
    end
    rethrow(ME);
end

fprintf('\n========================================\n');
fprintf('Test Complete\n');
fprintf('========================================\n');
