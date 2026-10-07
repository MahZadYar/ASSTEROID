function varargout = train_sers_dnn(varargin)
%TRAIN_SERS_DNN  (Deprecated) Backward-compatibility forwarder to train_surrogate_dnn.
%
%   Please use train_surrogate_dnn directly:
%       model = train_surrogate_dnn(dataset, options)
%
%   See also: train_surrogate_dnn, runTrainingWorkflow

    [varargout{1:nargout}] = train_surrogate_dnn(varargin{:});
end
