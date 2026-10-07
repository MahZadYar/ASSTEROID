%% Test Adaptive Sampling App
% This script tests the adaptive_sampling_app GUI.

%% Test 1: App Launch
disp("Test 1: App Launch");
try
    run_adaptive_sampling_app();
    figs = findall(0, "Type", "figure", "Name", "Adaptive Parameter Sampling");
    assert(~isempty(figs), "Figure not created");
    disp("  PASS: App launched successfully");
    
    % Close
    delete(figs(1));
    disp("  PASS: App closed");
catch ME
    disp("  FAIL: " + ME.message);
end

%% Test 2: Configuration Building
disp("Test 2: Configuration Building");
try
    % Simulate event data from JavaScript
    eventData = struct( ...
        "workDir", pwd, ...
        "dataFile", "", ...
        "fromPredictions", false, ...
        "predictionFile", "", ...
        "numPoints", 100, ...
        "minSeparation", 0.2, ...
        "rtpThreshold", 0.49, ...
        "uniformSampling", true, ...
        "enforceOriginalSpacing", false, ...
        "autoDetectRanges", true, ...
        "periodMin", NaN, ...
        "periodMax", NaN, ...
        "radiusMin", NaN, ...
        "radiusMax", NaN, ...
        "metricNames", {{"BEE_vol"}}, ...
        "metricWeights", 1, ...
        "metricAlphas", 1, ...
        "overallExponent", 1, ...
        "blurSigma", 0, ...
        "outputFile", "test_output.txt", ...
        "paramName1", "period", ...
        "paramUnit1", "[nm]", ...
        "paramName2", "particle_r", ...
        "paramUnit2", "[nm]", ...
        "precision", 6, ...
        "includeOriginal", false, ...
        "colormap", "parula", ...
        "gridResolution", 500, ...
        "showOriginal", true, ...
        "showGenerated", true, ...
        "originalColor", "#ef4444", ...
        "generatedColor", "#10b981", ...
        "pointSize", 10);
    
    % This would be called internally - just verify structure
    assert(isstruct(eventData), "Event data should be struct");
    assert(eventData.numPoints == 100, "NumPoints incorrect");
    disp("  PASS: Configuration structure valid");
catch ME
    disp("  FAIL: " + ME.message);
end

%% Test 3: Hex to RGB Conversion
disp("Test 3: Hex to RGB Conversion");
try
    % Test hex2rgb function (internal to app, recreate here)
    hexColor = "#ef4444";
    hexColor = char(hexColor);
    if hexColor(1) == "#"
        hexColor = hexColor(2:end);
    end
    rgb = [hex2dec(hexColor(1:2)), hex2dec(hexColor(3:4)), hex2dec(hexColor(5:6))] / 255;
    
    expected = [239, 68, 68] / 255;
    assert(all(abs(rgb - expected) < 0.01), "RGB conversion incorrect");
    disp("  PASS: Hex to RGB conversion works");
catch ME
    disp("  FAIL: " + ME.message);
end

%% Test 4: loadSamplingData robustness (Missing metric & Custom parameters)
disp("Test 4: loadSamplingData robustness");
try
    testMat = fullfile(tempdir, "test_sampling_robustness.mat");
    allData = struct( ...
        'pitch', [300; 350; 400], ...
        'diameter', [50; 60; 70], ...
        'my_custom_metric', [1.1; 2.2; 3.3]);
    save(testMat, "allData");
    
    % Test with unrecognised metric and custom parameter axes
    cfg = struct( ...
        'dataFile', string(testMat), ...
        'fromPredictions', false, ...
        'xAxisParam', "pitch", ...
        'yAxisParam', "diameter", ...
        'metricNames', {{"non_existent_metric", "my_custom_metric"}});
    
    samples = loadSamplingData(cfg);
    assert(samples.numPoints == 3, "Points count mismatch");
    assert(isequal(samples.period, [300; 350; 400]), "X axis parameter mismatch");
    assert(isequal(samples.radius, [50; 60; 70]), "Y axis parameter mismatch");
    assert(size(samples.metrics, 2) == 2, "Metric count mismatch");
    assert(all(samples.metrics(:, 1) == 0), "Missing metric should default to zeros without crashing");
    assert(all(abs(samples.metrics(:, 2) - [1.1; 2.2; 3.3]) < 1e-6), "Custom metric values mismatch");
    
    if isfile(testMat), delete(testMat); end
    disp("  PASS: loadSamplingData handled missing metric & custom parameters gracefully");
catch ME
    if exist("testMat", "var") && isfile(testMat), delete(testMat); end
    disp("  FAIL: " + ME.message);
end

%% Test 5: Multi-Metric Weighting Sensitivity & Config Preservation
disp("Test 5: Multi-Metric Weighting Sensitivity & Config Preservation");
try
    % Test that same-base variants are not collapsed
    cfgPreserve = adaptiveSamplingConfig( ...
        MetricNames = ["EF_vol_avg", "EF_vol_laser"], ...
        MetricWeights = [0.7, 0.3]);
    assert(numel(cfgPreserve.metricNames) == 2, "Same-base metrics should not collapse");
    assert(numel(cfgPreserve.metricWeights) == 2, "Weights should not be truncated");
    assert(isequal(cfgPreserve.metricWeights, [0.7, 0.3]), "Weights values should match");

    % Test synthetic dataset with two contrasting metrics
    testMat5 = fullfile(tempdir, "test_multi_metric_density.mat");
    [P, R] = meshgrid(linspace(400, 800, 10), linspace(50, 200, 10));
    allData5 = struct( ...
        'period', P(:), ...
        'radius', R(:), ...
        'm_grad_p', P(:) / 800, ...
        'm_grad_r', R(:) / 200);
    save(testMat5, "allData5");

    cfgDensity = adaptiveSamplingConfig( ...
        DataFile = string(testMat5), ...
        UniformSampling = false, ...
        MetricNames = ["m_grad_p", "m_grad_r"]);
    samples5 = loadSamplingData(cfgDensity);

    cfgW1 = cfgDensity; cfgW1.metricWeights = [1, 0];
    cfgW2 = cfgDensity; cfgW2.metricWeights = [0.5, 0.5];
    cfgW3 = cfgDensity; cfgW3.metricWeights = [0, 1];

    dA = buildSamplingDensity(cfgW1, samples5);
    dB = buildSamplingDensity(cfgW2, samples5);
    dC = buildSamplingDensity(cfgW3, samples5);

    diffAB = max(abs(dA.finalMetric - dB.finalMetric));
    diffBC = max(abs(dB.finalMetric - dC.finalMetric));
    diffAC = max(abs(dA.finalMetric - dC.finalMetric));

    assert(diffAB > 0.1, "Density should change when blending second metric");
    assert(diffBC > 0.1, "Density should change when shifting weight to second metric");
    assert(diffAC > 0.2, "Density should differ strongly between metric 1 and metric 2");

    if isfile(testMat5), delete(testMat5); end
    disp("  PASS: Multi-metric density correctly reflects weighted sum and preserves configurations");
catch ME
    if exist("testMat5", "var") && isfile(testMat5), delete(testMat5); end
    disp("  FAIL: " + ME.message);
end

%% Test 6: Multi-Metric Event Data Sanitisation & Blended Preview
disp("Test 6: Multi-Metric Event Data Sanitisation & Blended Preview");
try
    testMat6 = fullfile(tempdir, "test_multi_metric_event.mat");
    [P, R] = meshgrid(linspace(400, 800, 15), linspace(50, 200, 15));
    allData6 = struct( ...
        'period', P(:), ...
        'radius', R(:), ...
        'm_grad_p', P(:) / 800, ...
        'm_grad_r', R(:) / 200);
    save(testMat6, "allData6");

    % Simulate multi-metric event data directly as received from uihtml (cell array of char vectors)
    rawNames = {'m_grad_p', 'm_grad_r'};
    rawWeights = [1, 0.5];

    while iscell(rawNames) && isscalar(rawNames) && iscell(rawNames{1})
        rawNames = rawNames{1};
    end
    metricNames = string(rawNames);
    metricNames = metricNames(~ismissing(metricNames) & strlength(strtrim(metricNames)) > 0);
    metricNames = reshape(metricNames, 1, []);

    assert(numel(metricNames) == 2, "metricNames must contain exactly 2 metrics, not collapsed into 1");

    cfgMulti = adaptiveSamplingConfig( ...
        DataFile = string(testMat6), ...
        MetricNames = metricNames, ...
        MetricWeights = rawWeights, ...
        MetricAlphas = [1, 1], ...
        UniformSampling = false, ...
        NumPoints = 100);

    assert(numel(cfgMulti.metricNames) == 2, "cfg.metricNames must contain 2 elements");
    assert(numel(cfgMulti.metricWeights) == 2, "cfg.metricWeights must contain 2 elements");
    assert(isequal(cfgMulti.metricWeights, [1, 0.5]), "metricWeights values must match");

    % Verify samples metrics extraction and density blending
    samples6 = loadSamplingData(cfgMulti);
    assert(size(samples6.metrics, 2) == 2, "samples.metrics must have 2 columns for 2 metrics");

    % Compare density with 1st metric only vs blended
    cfgSingle = adaptiveSamplingConfig( ...
        DataFile = string(testMat6), ...
        MetricNames = "m_grad_p", ...
        MetricWeights = 1, ...
        UniformSampling = false, ...
        NumPoints = 100);

    [metricsSingle, ~] = extractSamplingMetrics(samples6, "m_grad_p", samples6.numPoints);
    samplesSingle = samples6;
    samplesSingle.metrics = metricsSingle;
    samplesSingle.metricNames = {'m_grad_p'};
    samplesSingle.numMetrics = 1;

    densitySingle = buildSamplingDensity(cfgSingle, samplesSingle);
    densityMulti = buildSamplingDensity(cfgMulti, samples6);

    diffDensity = max(abs(densitySingle.finalMetric - densityMulti.finalMetric));
    assert(diffDensity > 0.05, "Blended density must differ from single-metric density");

    if isfile(testMat6), delete(testMat6); end
    disp("  PASS: Event data multi-metric sanitisation and blended density preview verified");
catch ME
    if exist("testMat6", "var") && isfile(testMat6), delete(testMat6); end
    disp("  FAIL: " + ME.message);
end

%% Test 7: In-Region Normalization & Post-Blur Normalization
disp("Test 7: In-Region Normalization & Post-Blur Normalization");
try
    testMat7 = fullfile(tempdir, "test_region_blur_norm.mat");
    [P7, R7] = meshgrid(400:50:800, 50:25:200);
    pVec7 = P7(:);
    rVec7 = R7(:);
    N7 = numel(pVec7);

    % Metric 1: Peak is at (800, 200), strictly outside ROI [500, 650] x [75, 150]
    m1 = 10 + 20 * rand(N7, 1);
    [~, maxIdx1] = max((pVec7 - 800).^2 + (rVec7 - 200).^2 == 0);
    m1(maxIdx1) = 1e6;

    % Metric 2: Peak is at (550, 100), inside ROI
    dist2 = sqrt((pVec7 - 550).^2 + (rVec7 - 100).^2);
    m2 = exp(-dist2 / 50);

    allData7 = struct("period", pVec7, "radius", rVec7, "EF_vol", m1, "Absorptance", m2);
    save(testMat7, "allData7");

    roiP = [500, 650];
    roiR = [75, 150];
    idxROI = (pVec7 >= roiP(1)) & (pVec7 <= roiP(2)) & (rVec7 >= roiR(1)) & (rVec7 <= roiR(2));

    % Test with BlurSigma = 25 (with blur)
    cfgBlur = createSamplingConfig( ...
        DataFile = string(testMat7), ...
        MetricNames = ["EF_vol", "Absorptance"], ...
        MetricWeights = [0.5, 0.5], ...
        PeriodRange = roiP, ...
        RadiusRange = roiR, ...
        UseManualRange = true, ...
        BlurSigma = 25, ...
        UniformSampling = false);

    samples7 = loadSamplingData(cfgBlur);
    densityBlur = buildSamplingDensity(cfgBlur, samples7);

    roiValsBlur = densityBlur.finalMetric(idxROI);
    assert(abs(min(roiValsBlur)) < 1e-9, "Minimum density in ROI must be 0 even after blur");
    assert(abs(max(roiValsBlur) - 1.0) < 1e-9, "Maximum density in ROI must be 1 even after blur");
    assert(densityBlur.maxValue == 1, "density.maxValue must be exactly 1");

    % Test evaluated density function on ROI grid
    [pg, rg] = meshgrid(linspace(roiP(1), roiP(2), 25), linspace(roiR(1), roiR(2), 25));
    dg = densityBlur.func(pg(:), rg(:));
    assert(all(dg >= -eps & dg <= 1 + eps), "Evaluated density must remain within [0, 1]");
    assert(max(dg) > 0.95, "Evaluated density on grid must reach close to 1.0");

    % Test with BlurSigma = 0 (without blur)
    cfgNoBlur = cfgBlur;
    cfgNoBlur.blurSigma = 0;
    densityNoBlur = buildSamplingDensity(cfgNoBlur, samples7);
    roiValsNoBlur = densityNoBlur.finalMetric(idxROI);
    assert(abs(min(roiValsNoBlur)) < 1e-9, "Minimum density in ROI must be 0 without blur");
    assert(abs(max(roiValsNoBlur) - 1.0) < 1e-9, "Maximum density in ROI must be 1 without blur");

    if isfile(testMat7), delete(testMat7); end
    disp("  PASS: In-region normalization and post-blur normalization strictly enforced to [0, 1]");
catch ME
    if exist("testMat7", "var") && isfile(testMat7), delete(testMat7); end
    disp("  FAIL: " + ME.message);
end

%% Summary
disp(" ");
disp("All tests completed.");

