function totalCount = countMaximaResults(results)
%countMaximaResults Count total maxima across all metric results.
%   totalCount = countMaximaResults(results) sums the number of rows in
%   maximaResults tables across all metric entries.
%
%   Input:
%       results - Localization workflow results struct with .metrics cell array.
%
%   Output:
%       totalCount - Total number of maxima found.

    arguments
        results struct
    end

    totalCount = 0;
    if ~isfield(results, "metrics") || isempty(results.metrics)
        return;
    end
    for i = 1:numel(results.metrics)
        metricRes = results.metrics{i};
        if isstruct(metricRes) && isfield(metricRes, "maximaResults") && ~isempty(metricRes.maximaResults)
            totalCount = totalCount + height(metricRes.maximaResults);
        end
    end
end
