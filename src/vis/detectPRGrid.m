function [isGrid, pU, rU, linIdx] = detectPRGrid(p, r, options)
%detectPRGrid  Detect whether (period, radius) samples form a complete grid.
%
%   [isGrid, pU, rU, linIdx] = detectPRGrid(p, r)
%   [...] = detectPRGrid(p, r, RelTol=1e-6)
%
%   A sample set is treated as a grid when every sample sits on the lattice
%   spanned by the unique period and radius values, no lattice cell is
%   occupied twice, and at least MinFill of the lattice is populated.
%   Spacing does not need to be uniform, and missing cells are allowed
%   (dense Pred/Interp grids omit non-physical r >= p/2 geometries).
%   Scattered samples have ~N unique values per axis, so their fill ratio
%   is ~1/N and they are rejected.
%
%   Inputs:
%       p, r - [N x 1] period and radius values (nm)
%
%   Name-Value Arguments:
%       RelTol  - relative tolerance for merging coordinate values (1e-6)
%       MinFill - minimum populated fraction of the lattice (0.25)
%
%   Outputs:
%       isGrid - logical scalar
%       pU     - [1 x Np] unique periods (ascending)
%       rU     - [1 x Nr] unique radii (ascending)
%       linIdx - [N x 1] linear indices into an [Nr x Np] array (empty when
%                isGrid is false), so that Z(linIdx) = v maps samples to the grid
%
%   See also: plotScatteredMap2D, reshapeSoAToVolume

    arguments
        p (:,1) double
        r (:,1) double
        options.RelTol (1,1) double {mustBePositive} = 1e-6
        options.MinFill (1,1) double {mustBeInRange(options.MinFill, 0, 1)} = 0.25
    end

    isGrid = false; linIdx = [];
    pU = zeros(1, 0); rU = zeros(1, 0);
    if numel(p) ~= numel(r) || isempty(p) || any(~isfinite(p)) || any(~isfinite(r))
        return;
    end

    tolP = options.RelTol * max(1, max(abs(p)));
    tolR = options.RelTol * max(1, max(abs(r)));
    pU = reshape(uniquetol(p, tolP, "DataScale", 1), 1, []);
    rU = reshape(uniquetol(r, tolR, "DataScale", 1), 1, []);
    if numel(pU) < 2 || numel(rU) < 2 || numel(p) < options.MinFill * numel(pU) * numel(rU)
        return;
    end

    ip = interp1(pU(:), (1:numel(pU))', p, "nearest", "extrap");
    ir = interp1(rU(:), (1:numel(rU))', r, "nearest", "extrap");
    lin = sub2ind([numel(rU), numel(pU)], ir, ip);
    if numel(unique(lin)) ~= numel(lin)
        return;   % duplicated cells -> not a clean grid
    end
    isGrid = true;
    linIdx = lin;
end
