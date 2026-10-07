function exportModelToOnnx(model, onnxFile)
% exportModelToOnnx  Export trained SERS DNN model to ONNX format.
%
%   exportModelToOnnx(model, onnxFile)
%
%   Exports the dlnetwork object from the model struct to an ONNX file
%   for use in Python, C++, or other environments.
%
%   Input:
%       model    - struct containing the trained dlnetwork (.net)
%       onnxFile - string, path to output .onnx file
%
%   Example:
%       exportModelToOnnx(model, "sers_model_v1.onnx");
%
%   See also: exportDatabaseToHDF5, train_sers_dnn

    arguments
        model (1,1) struct
        onnxFile (1,1) string
    end

    if ~isfield(model, 'net') || ~isa(model.net, 'dlnetwork')
        error('exportModelToOnnx:InvalidModel', 'Model struct must contain a dlnetwork object in the .net field.');
    end

    % Delete existing file if it exists
    if isfile(onnxFile)
        delete(onnxFile);
    end

    % Export to ONNX
    try
        exportONNXNetwork(model.net, char(onnxFile));
        fprintf('Successfully exported model to %s\n', onnxFile);
    catch ME
        error('exportModelToOnnx:ExportFailed', 'Failed to export model to ONNX: %s', ME.message);
    end
end
