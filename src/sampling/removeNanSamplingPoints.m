function [cleanData, removedCount, removedIdx, report] = removeNanSamplingPoints(dataSource, options)
% removeNanSamplingPoints  Remove entries with NaN metric values from dataset.
%
%   cleanData = removeNanSamplingPoints(dataSource)
%   [cleanData, removedCount, removedIdx, report] = removeNanSamplingPoints(dataSource, Name=Value)
%
%   Thin wrapper and sampling-pipeline companion to removeNanEntriesFromBranch.
%   Cleans dataset by pruning rows where any metric or geometry parameter has NaNs.
%
%   See also: removeNanEntriesFromBranch, findNanSamplingPoints, exportNanPointsToComsol

arguments
    dataSource
    options.MetricNames cell = {}
    options.InputNames cell = {}
    options.CheckInputs (1,1) logical = true
    options.Verbose (1,1) logical = false
end

    args = namedargs2cell(options);
    [cleanData, removedCount, removedIdx, report] = removeNanEntriesFromBranch(dataSource, args{:});
end
