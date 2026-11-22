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

%% Test 2: getDefaultAnalyteSpectrum & built-in 5-analyte fingerprint library
fprintf("\nTest 2: getDefaultAnalyteSpectrum (5-analyte built-in library)\n");
try
    expectedPeaks = struct( ...
        "CH4",  2917, ...
        "C2H4", 3021, ...
        "NH3",  3337, ...
        "C2H2", 1974, ...
        "H2O",  3657);
    presetList = ["CH4", "C2H4", "NH3", "C2H2", "H2O"];
    for k = 1:numel(presetList)
        key = presetList(k);
        analyteSpec = getDefaultAnalyteSpectrum(key);
        [~, peakIdx] = max(analyteSpec.intensity);
        peakShift = analyteSpec.shift_cm(peakIdx);
        areaVal = trapz(analyteSpec.shift_cm, analyteSpec.intensity);
        assert(numel(analyteSpec.shift_cm) == 4101 && ...
            min(analyteSpec.shift_cm) == 100 && max(analyteSpec.shift_cm) == 4200, ...
            "Unexpected grid for %s.", key);
        assert(abs(areaVal - 1.0) < 1e-9, "Area normalization failed for %s: %.12g", key, areaVal);
        assert(peakShift == expectedPeaks.(key), ...
            "Dominant peak mismatch for %s: got %.1f, expected %.1f.", ...
            key, peakShift, expectedPeaks.(key));
        fprintf("  ✓ %-4s loaded: %.0f - %.0f cm⁻¹ (%d pts), peak %.0f cm⁻¹, area=%.6f\n", ...
            key, min(analyteSpec.shift_cm), max(analyteSpec.shift_cm), ...
            numel(analyteSpec.shift_cm), peakShift, areaVal);
    end

    % Default no-arg call must equal CH4, and aliases/"default:" tokens must resolve cleanly
    specNoArg = getDefaultAnalyteSpectrum();
    specCh4   = getDefaultAnalyteSpectrum("CH4");
    assert(isequal(specNoArg.intensity, specCh4.intensity), "Default preset should be CH4.");
    for alias = ["methane", "ethylene", "ammonia", "acetylene", "water", "default:NH3"]
        sAlias = getDefaultAnalyteSpectrum(alias);
        assert(abs(trapz(sAlias.shift_cm, sAlias.intensity) - 1.0) < 1e-9, ...
            "Alias '%s' failed area check.", alias);
    end
    didFailUnknown = false;
    try
        getDefaultAnalyteSpectrum("UNKNOWN_GAS_XYZ");
    catch
        didFailUnknown = true;
    end
    assert(didFailUnknown, "Unknown preset should throw descriptive error.");
    fprintf("  ✓ Aliases and unknown-preset error check passed\n");
catch ME
    fprintf("  ✗ FAILED: %s\n", ME.message);
    rethrow(ME);
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
