function summary = run_all_tests()
%RUN_ALL_TESTS  Execute all unit and integration test scripts in the tests directory.
%
%   summary = run_all_tests() executes all test_*.m scripts in tests/ sequentially,
%   reporting individual execution status, elapsed duration, and aggregate statistics.
%   Each test runs in isolated scope to prevent workspace pollution or 'clear' side-effects.

    setup_project;
    testDir = fileparts(mfilename('fullpath'));
    testFiles = dir(fullfile(testDir, "test_*.m"));
    
    numTests = numel(testFiles);
    testNames = strings(numTests, 1);
    passedStatus = false(numTests, 1);
    durations = zeros(numTests, 1);
    errorMsgs = strings(numTests, 1);
    
    fprintf("=========================================================================\n");
    fprintf("              ☄️  ASSTEROID AUTOMATED TEST SUITE RUNNER                   \n");
    fprintf("=========================================================================\n");
    fprintf("Found %d test scripts in %s\n\n", numTests, testDir);
    
    suiteTimer = tic;
    
    for i = 1:numTests
        [~, name] = fileparts(testFiles(i).name);
        testNames(i) = string(name);
        filePath = fullfile(testFiles(i).folder, testFiles(i).name);
        
        fprintf("[%2d/%2d] Running %-35s ... ", i, numTests, name);
        
        [passedStatus(i), durations(i), errorMsgs(i)] = runSingleTest(filePath);
        
        if passedStatus(i)
            fprintf("PASSED (%.2f s)\n", durations(i));
        else
            fprintf("FAILED (%.2f s)\n", durations(i));
            fprintf("       Error: %s\n", errorMsgs(i));
        end
    end
    
    totalDuration = toc(suiteTimer);
    
    summary = table(testNames, passedStatus, durations, errorMsgs, ...
        'VariableNames', {'TestScript', 'Passed', 'Duration_s', 'ErrorMessage'});
    
    totalPassed = sum(passedStatus);
    totalFailed = numTests - totalPassed;
    
    fprintf("\n=========================================================================\n");
    fprintf("                              TEST SUMMARY                              \n");
    fprintf("=========================================================================\n");
    fprintf("Total Executed : %d\n", numTests);
    fprintf("Passed         : %d\n", totalPassed);
    fprintf("Failed         : %d\n", totalFailed);
    fprintf("Total Duration : %.2f s\n", totalDuration);
    fprintf("=========================================================================\n\n");
    
    if totalFailed > 0
        warning("run_all_tests:FailedTests", "%d of %d tests failed.", totalFailed, numTests);
    else
        fprintf(">>> ALL TESTS PASSED CLEANLY! <<<\n\n");
    end
end

function [passed, dur, errMsg] = runSingleTest(targetFile)
    t0 = tic;
    try
        % Execute in base workspace so test script's internal 'clear' cannot clear t0
        evalin('base', sprintf('run(''%s'');', targetFile));
        dur = toc(t0);
        passed = true;
        errMsg = "";
    catch ME
        dur = toc(t0);
        passed = false;
        errMsg = string(ME.message);
    end
end
