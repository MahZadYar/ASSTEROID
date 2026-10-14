function basinIds = assignSeedsToBasins(basinMap, P_nm, R_nm)
%assignSeedsToBasins  Look up the watershed basin that contains each seed.
%
%   basinIds = assignSeedsToBasins(basinMap, P_nm, R_nm)
%
%   Each (P, R) point is snapped to the nearest grid cell of the basin map
%   and the territory label of that cell is returned. Points outside the
%   grid extent (beyond half a grid step) or on masked cells return 0.
%
%   Inputs:
%       basinMap  Struct from detect_watershed_basins (fields labels,
%                 pAxis_nm, rAxis_nm).
%       P_nm      Period coordinates in nm (vector).
%       R_nm      Radius coordinates in nm (same size as P_nm).
%
%   Output:
%       basinIds  Column vector of basin labels (0 = no basin).
%
%   See also: detect_watershed_basins

    P_nm = double(P_nm(:));
    R_nm = double(R_nm(:));
    basinIds = zeros(numel(P_nm), 1);
    if isempty(P_nm) || ~isstruct(basinMap) || ~isfield(basinMap, "labels") ...
            || isempty(basinMap.labels)
        return;
    end

    pAxis = double(basinMap.pAxis_nm(:));
    rAxis = double(basinMap.rAxis_nm(:));
    labels = basinMap.labels;

    pTol = localHalfStep(pAxis);
    rTol = localHalfStep(rAxis);

    for i = 1:numel(P_nm)
        if ~isfinite(P_nm(i)) || ~isfinite(R_nm(i))
            continue;
        end
        [dp, ip] = min(abs(pAxis - P_nm(i)));
        [dr, ir] = min(abs(rAxis - R_nm(i)));
        if dp > pTol || dr > rTol
            continue;
        end
        basinIds(i) = double(labels(ir, ip));
    end
end

function h = localHalfStep(ax)
    if numel(ax) > 1
        h = 0.5 * max(abs(diff(ax))) + 1e-9;
    else
        h = Inf;
    end
end
