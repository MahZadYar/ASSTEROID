%% Test script: Verify default RI and analyte spectrum functions
clear; setup_project;

fprintf("=== Testing Default RI and Analyte Spectrum Functions ===\n\n");

%% Test 1: getDefaultRefractiveIndex
fprintf("Test 1: getDefaultRefractiveIndex\n");
try
    ri = getDefaultRefractiveIndex();
    fprintf("  ✓ Default RI loaded successfully\n");
    fprintf("    - Wavelengths: %.2f - %.2f µm\n", min(ri.lambda), max(ri.lambda));
    fprintf("    - Fields: %s\n", strjoin(fieldnames(ri)', ", "));
    
    % Test interpolation
    lambda_test = 0.8;  % 800 nm
    n_test = ri.nFunc(lambda_test);
    k_test = ri.kFunc(lambda_test);
    fprintf("    - At λ = %.2f µm: n=%.3f, k=%.3f\n", lambda_test, n_test, k_test);
catch ME
    fprintf("  ✗ FAILED: %s\n", ME.message);
end

%% Test 2: getDefaultAnalyteSpectrum
fprintf("\nTest 2: getDefaultAnalyteSpectrum\n");
try
    analyteSpec = getDefaultAnalyteSpectrum();
    fprintf("  ✓ Default analyte spectrum loaded successfully\n");
    fprintf("    - Shift range: %.0f - %.0f cm⁻¹\n", min(analyteSpec.shift_cm), max(analyteSpec.shift_cm));
    fprintf("    - Intensity integral: %.4f (should be ~1.0)\n", trapz(analyteSpec.shift_cm, analyteSpec.intensity));
    fprintf("    - Fields: %s\n", strjoin(fieldnames(analyteSpec)', ", "));
catch ME
    fprintf("  ✗ FAILED: %s\n", ME.message);
end

%% Test 3: Import config with empty analyte spectrum
fprintf("\nTest 3: importSweepConfig with empty analyte spectrum\n");
try
    cfg = importSweepConfig(LaserWavelength=785);
    if strcmp(cfg.analyteSpectrumFile, "")
        fprintf("  ✓ Empty analyte spectrum preserved in config\n");
    else
        fprintf("  ✗ FAILED: Analyte spectrum file should be empty\n");
    end
catch ME
    fprintf("  ✗ FAILED: %s\n", ME.message);
end

%% Test 4: Training config with empty RI
fprintf("\nTest 4: trainingConfig with empty RI\n");
try
    cfg = trainingConfig(RawDataFiles="test.mat");
    if cfg.riCsvFile == ""
        fprintf("  ✓ Empty RI CSV preserved in config\n");
    else
        fprintf("  ✗ FAILED: RI CSV file should be empty, got: %s\n", cfg.riCsvFile);
    end
catch ME
    fprintf("  ✗ FAILED: %s\n", ME.message);
end

fprintf("\n=== All Basic Tests Complete ===\n");
