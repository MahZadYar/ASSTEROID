% test_nan_points_extraction.m - Unit tests for NaN finding and COMSOL point generation
setup_project;

testDir = fullfile(tempdir, "test_nan_export");
if ~isfolder(testDir), mkdir(testDir); end

%% 1. Test with synthetic dataset containing controlled NaNs
fprintf("=== Test 1: Synthetic Dataset with Controlled NaNs ===\n");
synthetic = struct();
synthetic.period = [500; 500; 600; 700; 800];
synthetic.radius = [100; 100; 150; 200; 250];
synthetic.EF_vol_avg = [10; 10; NaN; 40; 50];       % Row 3 has NaN
synthetic.Absorptance_avg = [5; 5; 15; NaN; 25];     % Row 4 has NaN
synthetic.ECC_avg = [1e-5; 1e-5; 1e-5; 1e-5; 1e-5]; % No NaNs

res = findNanSamplingPoints(synthetic);
assert(res.hasNans, "Should detect NaNs in synthetic data");
assert(res.count == 2, sprintf("Expected 2 unique NaN points, got %d", res.count));
assert(res.totalNanRows == 2, sprintf("Expected 2 total NaN rows, got %d", res.totalNanRows));
assert(numel(res.metricsWithNan) == 2, sprintf("Expected 2 metrics with NaNs, got %d", numel(res.metricsWithNan)));

% Verify points: (600, 150) and (700, 200)
pts = res.uniquePoints;
assert(any(pts(:,1) == 600 & pts(:,2) == 150), "Should find point (600, 150)");
assert(any(pts(:,1) == 700 & pts(:,2) == 200), "Should find point (700, 200)");
fprintf("Synthetic test PASSED.\n");

%% 2. Test COMSOL Export Formats
fprintf("\n=== Test 2: COMSOL Export Formats ===\n");

% Format A: Parametric sweep format (param "v1 v2..." [unit])
paramOut = fullfile(testDir, "comsol_params.txt");
exportNanPointsToComsol(res, OutputFile=paramOut, Format="param");
assert(isfile(paramOut), "Param export file should exist");
contentParam = fileread(paramOut);
fprintf("Exported Param Content:\n%s\n", contentParam);
assert(contains(contentParam, 'period "600 700" [nm]'), "Param file must contain period list");
assert(contains(contentParam, 'radius "150 200" [nm]'), "Param file must contain radius list");

% Format B: Table format (% p\tr \n v1\tv2)
tableOut = fullfile(testDir, "comsol_table.txt");
exportNanPointsToComsol(res, OutputFile=tableOut, Format="table");
assert(isfile(tableOut), "Table export file should exist");
contentTable = fileread(tableOut);
fprintf("Exported Table Content:\n%s\n", contentTable);
assert(contains(contentTable, '% period [nm]	radius [nm]'), "Table must contain header");
assert(contains(contentTable, sprintf('600\t150')), "Table must contain row 600, 150");
assert(contains(contentTable, sprintf('700\t200')), "Table must contain row 700, 200");
fprintf("COMSOL export format tests PASSED.\n");

%% 3. Test with actual project dataset (prl_sweep.mat if available)
prlFile = "d:/OneDrive - Kaunas University of Technology/~Science Projects/NanoTRAACES/WP01 Design/Data/Raw/prl_sweep.mat";
if isfile(prlFile)
    fprintf("\n=== Test 3: Real Dataset (prl_sweep.mat) ===\n");
    resReal = findNanSamplingPoints(prlFile);
    assert(resReal.hasNans, "Real data should have NaNs");
    assert(resReal.count == 140 || resReal.count == 123, sprintf("Expected 123 or 140 unique NaN points in prl_sweep.mat, got %d", resReal.count));
    fprintf("Found %d unique failed geometries across %d entries.\n", resReal.count, resReal.totalRows);
    for k = 1:numel(resReal.metricsWithNan)
        fprintf("  Metric: %-20s  NaNs: %d\n", resReal.metricsWithNan(k).name, resReal.metricsWithNan(k).nanCount);
    end
    realOut = fullfile(testDir, "real_nan_sweep.txt");
    exportNanPointsToComsol(resReal, OutputFile=realOut, Format="param");
    assert(isfile(realOut), "Real NaN sweep file should exist");
    fprintf("Exported %d points to: %s\n", resReal.count, realOut);
    fprintf("Real dataset test PASSED.\n");
end

fprintf("\nAll NaN sampling tests PASSED successfully!\n");
