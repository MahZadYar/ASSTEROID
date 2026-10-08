function v = padVec(v, n)
% PADVEC Ensure row vector of length n, padded with ones or truncated.
%
%   v = padVec(v, n) formats input v into a 1-by-n numeric double vector.
%   If v has fewer than n elements, it is padded with 1.
%   If v has more than n elements, it is truncated to n.
%   If v is empty, ones(1, n) is returned.
%
%   See also: RESHAPE, ONES

    if isempty(v), v = ones(1, n); return; end
    if iscell(v)
        while isscalar(v) && iscell(v{1})
            v = v{1};
        end
        try
            v = cell2mat(v);
        catch
            v = cellfun(@double, v);
        end
    end
    if ischar(v) || isstring(v)
        v = str2double(v);
    end
    v = double(v(:)');
    v(isnan(v)) = 1;
    if numel(v) < n
        v = [v, ones(1, n - numel(v))];
    elseif numel(v) > n
        v = v(1:n);
    end
end
