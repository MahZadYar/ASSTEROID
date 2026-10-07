function out = buildSpectralVolume(x, y, z, v, varargin)
% buildSpectralVolume  Interpolate 2D grid per z-slice and stack into a volume.
%
% out = buildSpectralVolume(x, y, z, v, ...) takes:
%   x [N x 1] x-coordinates
%   y [N x 1] y-coordinates
%   z either:
%       - [1 x M] (or [M x 1]) spectral axis if v is [N x M]
%       - [N x 1] per-point z values if v is [N x 1] with repeated z levels
%   v either [N x M] (spectra vs z) or [N x 1] (single value per point)
%
% Behavior:
%   - If v is [N x M] and numel(z)==M: for each k, interpolate v(:,k) over (x,y)
%     onto a regular X-Y grid; stack slices into Volume(:,:,k).
%   - If v is [N x 1] and z is [N x 1]: group by unique z (with tolerance) and
%     interpolate each group's values onto the same X-Y grid; stack by ascending z.
%
% Name-Value options:
%   'XGrid'           explicit x vector (overrides XResolution)
%   'YGrid'           explicit y vector (overrides YResolution)
%   'ZGrid'           explicit z vector for output ordering (spectral mode only; must match length M)
%   'ZResolution'     # z samples to resample spectra before XY interpolation (default [])
%   'ZInterpMethod'   interp1 method for spectral resampling: 'linear' (default) | 'pchip' | ...
%   'XResolution'     # x samples (default 80)
%   'YResolution'     # y samples (default 80)
%   'InterpMethod'    griddata method: 'natural' (default) | 'linear' | 'cubic' | 'nearest'
%   'FillMethod'      'none' (default) | 'nearest' | 'inpaint' (2D simple)
%   'FillValue'       scalar fill if keeping NaNs is undesirable (default NaN)
%   'Normalize'       true/false scale volume to [0,1] using robust percentiles (default true)
%   'ClipPercentiles' [low high] percentiles for normalization (default [1 99])
%   'ZTolerance'      tolerance for grouping z levels in per-point mode (default 0)
%   'Progress'        true/false textual progress (default true)
%   'Debug'           true/false print diagnostics (default false)
%
% Output fields:
%   Volume  [Ny x Nx x Nz]
%   X,Y,Z   grid vectors (Z corresponds to spectral axis or grouped z levels)
%   Method  interpolation method used
%   NormInfo normalization metadata
%   Options  options struct actually used
%
% Name-Value pairs:
%   'XGrid'          explicit vector of x samples (overrides XResolution)
%   'YGrid'          explicit vector of y samples (overrides YResolution)
%   'XResolution'    number of grid points in x (default 60)
%   'YResolution'    number of grid points in y (default 60)
%   'InterpMethod'   griddata method: 'natural' (default) | 'linear' | 'cubic' | 'nearest'
%   'FillMethod'     how to fill NaNs after interpolation: 'none' (default) | 'nearest' | 'inpaint'
%   'FillValue'      scalar fill value if FillMethod = 'none' and NaNs remain (default NaN)
%   'Normalize'      true/false normalize volume to [0,1] (default true)
%   'ClipPercentiles' [pLow pHigh] percentiles for robust normalization (default [1 99])
%   'Progress'       true/false show textual progress (default true)
%
% Output struct fields:
%   Volume   [Ny x Nx x M] interpolated volume (y first dimension)
%   X        [1 x Nx] x grid vector
%   Y        [1 x Ny] y grid vector
%   Lambda   [1 x M] wavelength vector (copy of input)
%   NormInfo struct with normalization metadata
%   Method   interpolation method used
%   Options  struct of options actually used
%
% Example:
%   out = buildSpectralVolume(p,r,lambda,EF_vol,'XResolution',80,'YResolution',80);
%   volshow(out.Volume,'Colormap',parula(256),'Alphamap',linspace(0,1,256));
%
% GitHub Copilot

% ---------- Input normalization ----------
x = double(x(:));
y = double(y(:));
if numel(x) ~= numel(y)
    error('buildSpectralVolume:SizeMismatch','x and y must have same length.');
end
N = numel(x);
v = double(v);
zVec = double(z(:));

% Determine mode: spectral matrix vs per-point values
[nr, nc] = size(v);
spectralMode = false;
if nr == N && nc > 1 && numel(zVec) == nc
    spectralMode = true; % v: [N x M], z: length M
elseif nr == N && nc == 1 && numel(zVec) == N
    spectralMode = false; % per-point z with repeated levels expected
else
    % Try transpose if needed
    if nc == N && nr > 1 && numel(zVec) == nr
        v = v.'; [nr, nc] = size(v); spectralMode = true;
    else
        error('buildSpectralVolume:ShapeUnrecognized','Expected v as [N x M] with z length M, or v as [N x 1] with z length N.');
    end
end

% Defaults
opt = struct( ...
    'XGrid', [], ...
    'YGrid', [], ...
    'ZGrid', [], ...
    'ZResolution', [], ...
    'XResolution', 80, ...
    'YResolution', 80, ...
    'InterpMethod', 'cubic', ... % 'linear' | 'cubic' | 'nearest' | 'natural' | 'v4'
    'FillMethod', 'none', ...
    'FillValue', NaN, ...
    'Normalize', true, ...
    'ClipPercentiles', [0 100], ...
    'ZTolerance', 0, ...
    'Progress', true, ...
    'Debug', false, ...
    'ZInterpMethod', 'makima' ... % options: 'linear' | 'pchip' | ...
    );

opt = parseOpts(opt, varargin{:});

% Choose grid vectors
% Build XY grid
if isempty(opt.XGrid)
    Xvec = linspace(min(x), max(x), opt.XResolution);
else
    Xvec = opt.XGrid(:)';
end
if isempty(opt.YGrid)
    Yvec = linspace(min(y), max(y), opt.YResolution);
else
    Yvec = opt.YGrid(:)';
end
Nx = numel(Xvec); Ny = numel(Yvec);
[Xg, Yg] = meshgrid(Xvec, Yvec); % Ny x Nx

% Determine Z slices
% Suppress duplicate-point averaging warnings from griddata/scatteredInterpolant
dupWarnCleanup = silenceDupPointWarnings(); %#ok<NASGU>
if spectralMode
    [ZorigSorted, sortIdx] = sort(zVec(:));
    ZorigSorted = ZorigSorted';
    sortIdx = sortIdx';
    if any(sortIdx ~= 1:numel(sortIdx))
        v = v(:, sortIdx);
    end
    Zcandidate = ZorigSorted;
    if ~isempty(opt.ZGrid)
        Zcandidate = opt.ZGrid(:)';
    elseif ~isempty(opt.ZResolution) && isnumeric(opt.ZResolution) && opt.ZResolution > 1 && numel(ZorigSorted) > 1
        Zcandidate = linspace(min(ZorigSorted), max(ZorigSorted), round(opt.ZResolution));
    end
    if numel(Zcandidate) ~= numel(ZorigSorted) || any(abs(Zcandidate - ZorigSorted) > eps(max(abs(ZorigSorted))))
        v = interpSpectraRows(v, ZorigSorted, Zcandidate, opt.ZInterpMethod);
    end
    Zvec = Zcandidate;
    Nz = numel(Zvec);
    Volume = nan(Ny, Nx, Nz, 'like', v);
    showProg = opt.Progress && Nz > 4;
    if showProg, fprintf('Interpolating %d slices (%s) ...\n', Nz, opt.InterpMethod); end
    for k = 1:Nz
        vals = v(:,k);
        Vk = griddata(x, y, vals, Xg, Yg, opt.InterpMethod);
        Vk = fill2d(Vk, opt);
        % enforce NaN outside convex hull for this slice (use only valid points)
        idxk = ~isnan(vals);
        if nnz(idxk) >= 3
            outsideMask_k = computeOutsideMask2D(x(idxk), y(idxk), Xg, Yg);
            Vk(outsideMask_k) = 0;
        end
        Volume(:,:,k) = Vk;
        if showProg && (mod(k, max(1,round(Nz/10)))==0 || k==Nz)
            fprintf('  %d / %d (%.0f%%)\n', k, Nz, k/Nz*100);
        end
    end
else
    % Per-point mode: group by z values (with tolerance)
    if opt.ZTolerance > 0
        [Zgroups,~,ic] = uniquetol(zVec, opt.ZTolerance);
    else
        [Zgroups,~,ic] = unique(zVec,'stable');
    end
    % Sort groups ascending and remap sample group ids to sorted positions
    [Zvec, order] = sort(Zgroups);
    map = zeros(numel(Zgroups),1);
    map(order) = 1:numel(Zgroups);
    ic_sorted = map(ic);
    Nz = numel(Zvec);
    Volume = nan(Ny, Nx, Nz, 'like', v);
    showProg = opt.Progress && Nz > 4;
    if showProg, fprintf('Interpolating %d grouped z slices (%s) ...\n', Nz, opt.InterpMethod); end
    for kk = 1:Nz
        mask = (ic_sorted == kk); % samples belonging to kth sorted z-group
        xi = x(mask); yi = y(mask); vi = v(mask);
        if numel(vi) >= 3
            Vk = griddata(xi, yi, vi, Xg, Yg, opt.InterpMethod);
            Vk = fill2d(Vk, opt);
        else
            Vk = nan(Ny, Nx);
        end
        % enforce NaN outside this group's convex hull
        outsideMask = computeOutsideMask2D(xi, yi, Xg, Yg);
        Vk(outsideMask) = 0;
        Volume(:,:,kk) = Vk;
        if showProg && (mod(kk, max(1,round(Nz/10)))==0 || kk==Nz)
            fprintf('  %d / %d (%.0f%%)\n', kk, Nz, kk/Nz*100);
        end
    end
end

% Normalization
normInfo = struct('Applied',false);
if opt.Normalize
    dv = Volume(~isnan(Volume));
    if ~isempty(dv)
        pLow = prctile(dv, opt.ClipPercentiles(1));
        pHigh = prctile(dv, opt.ClipPercentiles(2));
        if pHigh <= pLow
            pLow = min(dv); pHigh = max(dv);
        end
        Volume = (Volume - pLow) / (pHigh - pLow);
        Volume = max(0, min(1, Volume));
        normInfo = struct('Applied',true,'ClipPercentiles',opt.ClipPercentiles,'pLow',pLow,'pHigh',pHigh);
    end
end

if opt.Debug
    modeStr = ifelse(spectralMode, 'spectral', 'grouped');
    fprintf('[buildSpectralVolume] mode=%s, grid=%dx%dx%d, method=%s\n', modeStr, Ny, Nx, Nz, opt.InterpMethod);
end

out = struct();
out.Volume = Volume;   % Ny x Nx x Nz
out.X = Xvec;          % 1 x Nx
out.Y = Yvec;          % 1 x Ny
out.Z = Zvec(:)';      % 1 x Nz
out.Method = opt.InterpMethod;
out.NormInfo = normInfo;
out.Options = opt;

end

function vOut = interpSpectraRows(vIn, zOrig, zTarget, method)
if nargin < 4 || isempty(method)
    method = 'linear';
end
zOrig = zOrig(:)'; % ensure row
nPts = size(vIn,1);
nZ = numel(zTarget);
vOut = nan(nPts, nZ, 'like', vIn);
for ii = 1:nPts
    spec = vIn(ii, :);
    mask = ~isnan(spec);
    if nnz(mask) >= 2
        switch method
            case 'linear'
                vOut(ii, :) = interp1(zOrig(mask), spec(mask), zTarget, 'linear', NaN);
            case 'pchip'
                vOut(ii, :) = interp1(zOrig(mask), spec(mask), zTarget, 'pchip', NaN);
            case 'makima'
                vOut(ii, :) = makima(zOrig(mask), spec(mask), zTarget);
            case 'spline'
                vOut(ii, :) = spline(zOrig(mask), spec(mask), zTarget);
            otherwise
                error('interpSpectraRows:BadMethod','Unknown method %s', method);
        end
    elseif nnz(mask) == 1
        vOut(ii, :) = spec(find(mask,1));
    else
        % leave as NaN row
    end
end
end

function y = ifelse(cond, a, b)
if cond, y = a; else, y = b; end
end

function V = fill2d(V, opt)
switch opt.FillMethod
    case 'nearest'
        nanMask = isnan(V);
        if any(nanMask(:))
            % Approximate nearest fill by dilating known values; fallback: set to FillValue
            V(nanMask) = opt.FillValue;
        end
    case 'inpaint'
        V = inpaint_nans2d(V);
    case 'none'
        if ~isnan(opt.FillValue)
            V(isnan(V)) = opt.FillValue;
        end
end
end

function A = inpaint_nans2d(A)
% Simple NaN inpainting via local neighborhood mean, two passes
for pass = 1:2
    nanMask = isnan(A);
    if ~any(nanMask(:)), break; end
    [iy, ix] = find(nanMask);
    for j = 1:numel(ix)
        x = ix(j); y = iy(j);
        y1 = max(1,y-1); y2 = min(size(A,1), y+1);
        x1 = max(1,x-1); x2 = min(size(A,2), x+1);
        neigh = A(y1:y2, x1:x2);
        m = mean(neigh(~isnan(neigh)),'omitnan');
        if ~isnan(m), A(y,x) = m; end
    end
end
end

function outside = computeOutsideMask2D(x, y, Xg, Yg)
% Compute a logical mask of query grid points outside the convex hull of (x,y)
% Method: build scatteredInterpolant and sample a constant field; outside returns NaN
try
    F = scatteredInterpolant(x, y, ones(numel(x),1), 'linear', 'none');
    tmp = F(Xg, Yg);
    outside = isnan(tmp);
catch
    % Fallback: convhull-based containment test (slower for many points)
    k = convhull(x, y);
    outside = ~inpolygon(Xg, Yg, x(k), y(k));
end
end

function opt = parseOpts(opt, varargin)
if mod(numel(varargin),2)~=0
    error('buildSpectralVolume:Args','Name-value arguments must come in pairs.');
end
for i=1:2:numel(varargin)
    name = varargin{i}; val = varargin{i+1};
    if ~isfield(opt, name)
        error('buildSpectralVolume:BadOption','Unknown option %s', name);
    end
    opt.(name) = val;
end
end

% (No inpaint function needed for 3D mode)

function c = silenceDupPointWarnings()
% Temporarily suppress duplicate data point warnings raised by griddata/scatteredInterpolant
ids = { ...
    'MATLAB:scatteredInterpolant:DupPtsAvValuesWarnId', ...
    'MATLAB:griddata:DuplicateDataPoints' ...
    };
prev = cell(numel(ids),1);
for i = 1:numel(ids)
    try
        prev{i} = warning('query', ids{i});
        warning('off', ids{i});
    catch
        prev{i} = [];
    end
end
c = onCleanup(@() restoreWarnings(ids, prev));
end

function restoreWarnings(ids, prev)
for i = 1:numel(ids)
    p = prev{i};
    if ~isempty(p)
        warning(p.state, p.identifier);
    end
end
end
