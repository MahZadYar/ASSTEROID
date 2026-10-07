% test_pipeline - Test script to run pipeline with error handling
try
    fprintf('Starting DNN pipeline test...\n');
    run_dnn_pipeline;
    fprintf('\n✓ Pipeline completed successfully!\n');
catch ME
    fprintf('\n✗ Pipeline failed with error:\n');
    fprintf('  Error: %s\n', ME.message);
    fprintf('  Stack:\n');
    for i = 1:length(ME.stack)
        st = ME.stack(i);
        fprintf('    %s (line %d)\n', st.name, st.line);
    end
end
