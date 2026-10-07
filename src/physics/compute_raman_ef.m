function out = compute_raman_ef(M, grid, f, LaserWl, RamanStart, RamanEnd, opts)
% compute_raman_ef
% MATLAB EF pipeline starting from M = |E|^2, with optional GPU support.
%
% Inputs:
%   M         : intensity array |E|^2 on grid [nx,ny,nz,nf]
%   grid      : struct with fields:
%                 - ID: [nx*ny*nz x 1] or [nx,ny,nz] material IDs
%                 - x : [nx x 1] (meters)
%                 - y : [ny x 1] (meters)
%                 - z : [nz x 1] (meters)
%               Largest ID is selected for averaging
%   f         : frequency array [nf] (Hz)
%   LaserWl   : laser wavelength (m)
%   RamanStart/RamanEnd : cm^-1 Raman window
%   opts: struct fields
%       - useGPU (default true)
%       - unfoldX/Y/Z (default false)
%       - returnEF (default false)
%
% Output fields:
%   lambda, f, RamanShift, EF_vol, EF_vol_avg, M_vol, M2_vol,
%   EF_surf, EF_surf_avg, M_surf, M2_surf,
%   E_vol, E_surf, E_vol_avg, E_surf_avg, (optional) EF
arguments
    M (:,:,:,:) {mustBeFloat}
    grid (1,1) struct
    f (:,1)     {mustBeFloat}
    LaserWl (1,1) {mustBeFloat}
    RamanStart (1,1) {mustBeFloat}
    RamanEnd (1,1) {mustBeFloat}
    opts.useGPU (1,1) logical = true
    opts.unfoldX (1,1) logical = false
    opts.unfoldY (1,1) logical = false
    opts.unfoldZ (1,1) logical = false
    opts.returnEF (1,1) logical = false
end

c = 299792458; % m/s
[nx,ny,nz,nf] = size(M);

% Extract coordinates from grid struct
assert(isfield(grid,'x') && isfield(grid,'y') && isfield(grid,'z'), 'grid must contain fields x,y,z');
x = grid.x; y = grid.y; z = grid.z;
assert(numel(x)==nx && numel(y)==ny && numel(z)==nz && numel(f)==nf, 'Grid vector lengths mismatch');

% Extract/reshape material IDs
assert(isfield(grid,'ID'), 'grid must contain field ID');
if isequal(size(grid.ID), [nx,ny,nz])
    gridID = grid.ID;
elseif isvector(grid.ID) && numel(grid.ID)==nx*ny*nz
    gridID = reshape(grid.ID, [nx,ny,nz]);
else
    error('grid.ID must be [nx,ny,nz] or vector of length nx*ny*nz');
end

useGPU = opts.useGPU && (gpuDeviceCount>0);
if useGPU
    try
        M = gpuArray(M);
        % move arrays to GPU
        gridID = gpuArray(gridID);
        x = gpuArray(x); y = gpuArray(y); z = gpuArray(z);
        f = gpuArray(f);
    catch
        useGPU = false;
    end
end

% after GPU setup, create a no-op that references useGPU to avoid linter warnings
if useGPU && isnumeric(f) %#ok<*NASGU>
    % no-op; referencing useGPU ensures variable is used
end

% Optional unfolding for symmetry (apply same mirroring to gridID)
if isfield(opts,'unfoldX') && opts.unfoldX
    x_new = [-flip(x - x(1)) + x(1); x(2:end)];
    Mold = M;  G = gridID;
    M = zeros([2*nx-1, ny, nz, nf], 'like', Mold);
    gridID = zeros([2*nx-1, ny, nz], 'like', G);
    M(1:nx-1,:,:,:) = Mold(nx:-1:2,:,:,:);
    M(nx:end,:,:,:)  = Mold;
    gridID(1:nx-1,:,:) = G(nx:-1:2,:,:);
    gridID(nx:end,:,:)  = G;
    x = x_new; nx = numel(x);
end
if isfield(opts,'unfoldY') && opts.unfoldY
    y_new = [-flip(y - y(1)) + y(1); y(2:end)];
    Mold = M;  G = gridID;
    M = zeros([nx, 2*ny-1, nz, nf], 'like', Mold);
    gridID = zeros([nx, 2*ny-1, nz], 'like', G);
    M(:,1:ny-1,:,:) = Mold(:,ny:-1:2,:,:);
    M(:,ny:end,:,:)  = Mold;
    gridID(:,1:ny-1,:) = G(:,ny:-1:2,:);
    gridID(:,ny:end,:)  = G;
    y = y_new; ny = numel(y);
end
if isfield(opts,'unfoldZ') && opts.unfoldZ
    z_new = [-flip(z - z(1)) + z(1); z(2:end)];
    Mold = M;  G = gridID;
    M = zeros([nx, ny, 2*nz-1, nf], 'like', Mold);
    gridID = zeros([nx, ny, 2*nz-1], 'like', G);
    M(:,:,1:nz-1,:) = Mold(:,:,nz:-1:2,:);
    M(:,:,nz:end,:)  = Mold;
    gridID(:,:,1:nz-1) = G(:,:,nz:-1:2);
    gridID(:,:,nz:end)  = G;
    z = z_new; nz = numel(z);
end

% Build EF(lambda_s) = M(lambda_s) .* M(lambda_laser)
[~, laserIdx] = min(abs(f - c / LaserWl));
M_laser = M(:,:,:,laserIdx);
EF = M .* reshape(M_laser, [nx, ny, nz, 1]);

% Mask: select largest material ID voxels only
maxID = max(gridID(:));
mask3 = (gridID == maxID); % keep logical for robust GPU support
mask3 = mask3/sum(mask3(:)); % normalize mask

% volshow(double(gather(mask3))); % reference mask3 to avoid linter warning
mask4 = reshape(mask3, [nx, ny, nz, 1]); % for broadcasting with M,EF
mask4 = cast(mask4, 'like', M); % cast to numeric type for multiplication


% Build boundary mask (6-neighborhood) on maxID region
mask3surf = false(nx,ny,nz);
% X- neighbors
if nx>1
    tmp = false(nx,ny,nz);
    tmp(2:end,:,:) = mask3(2:end,:,:) & ~mask3(1:end-1,:,:);
    mask3surf = mask3surf | tmp;
    tmp = false(nx,ny,nz);
    tmp(1:end-1,:,:) = mask3(1:end-1,:,:) & ~mask3(2:end,:,:);
    mask3surf = mask3surf | tmp;
end
% Y- neighbors
if ny>1
    tmp = false(nx,ny,nz);
    tmp(:,2:end,:) = mask3(:,2:end,:) & ~mask3(:,1:end-1,:);
    mask3surf = mask3surf | tmp;
    tmp = false(nx,ny,nz);
    tmp(:,1:end-1,:) = mask3(:,1:end-1,:) & ~mask3(:,2:end,:);
    mask3surf = mask3surf | tmp;
end
% Z- neighbors
if nz>1
    tmp = false(nx,ny,nz);
    tmp(:,:,2:end) = mask3(:,:,2:end) & ~mask3(:,:,1:end-1);
    mask3surf = mask3surf | tmp;
    tmp = false(nx,ny,nz);
    tmp(:,:,1:end-1) = mask3(:,:,1:end-1) & ~mask3(:,:,2:end);
    mask3surf = mask3surf | tmp;
end

% Gaussian smoothing of surface mask to reduce voxel noise
% (requires Image Processing Toolbox)
if exist('imgaussfilt3','file')==2
    fwhm = 4; % desired averaging width in pixels (FWHM)
    sigma = fwhm / (2*sqrt(2*log(2))); % convert FWHM to sigma
    try
        mask3surf = imgaussfilt3(cast(mask3surf,'like',M), sigma) > 0.1;
    catch
        % if imgaussfilt3 doesn't accept the array type (e.g. gpuArray), skip smoothing
        warning('imgaussfilt3 failed; skipping surface mask smoothing');
    end
end
mask3surf = mask3surf/sum(mask3surf(:)); % normalize surface mask
mask4surf = reshape(mask3surf, [nx, ny, nz, 1]); % for broadcasting with M,EF
mask4surf = cast(mask4surf, 'like', M); % cast to numeric type for multiplication
% volshow(double(gather(mask3surf))); % reference mask3surf to avoid linter warning

% Compute voxel volume weights from non-uniform x,y,z (after unfolding)
dx = local_widths_from_coords(x);
dy = local_widths_from_coords(y);
dz = local_widths_from_coords(z);
volW = reshape(dx, [nx 1 1]) .* reshape(dy, [1 ny 1]) .* reshape(dz, [1 1 nz]);
volW = cast(volW, 'like', M);
volW = volW / sum(volW(:)); % normalize weights to sum to 1

% Volume-averaged EF, M, M^2 over masked region using voxel weights
volDen = sum(volW .* mask3, 'all');
volDen = gather(volDen); volDen = double(volDen);
EF_vol = mask4 .* EF; % apply surface mask to EF
M_vol  = mask4 .* M;  % apply surface mask to M
M2_vol = mask4 .* (M.^2); % apply surface mask to M^2
% integrate over spatial volume (x,y,z) for each frequency
volW4 = reshape(volW, [nx, ny, nz, 1]); % expand to broadcast over f

EF_vol = squeeze(sum(sum(sum(EF_vol .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / volDen; % [nf x 1]
M_vol = squeeze(sum(sum(sum(M_vol .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / volDen;
M2_vol = squeeze(sum(sum(sum(M2_vol .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / volDen;

% Volume-averaged E = |E| over masked region (per frequency)
E = M.^0.5;
E_vol = mask4 .* E;
E_vol = squeeze(sum(sum(sum(E_vol .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / volDen; % [nf x 1]

% Surface-averaged EF, M, M^2 over boundary voxels (weighted by voxel volume)
surfDen = sum(volW .* mask3surf, 'all');
surfDen = gather(surfDen); surfDen = double(surfDen);
EF_surf = mask4surf .* EF; % apply surface mask to EF
M_surf  = mask4surf .* M;  % apply surface mask to M
M2_surf = mask4surf .* (M.^2); % apply surface mask to M^2
% integrate over spatial volume (x,y,z) for each frequency
EF_surf = squeeze(sum(sum(sum(EF_surf .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / surfDen; % [nf x 1]
M_surf = squeeze(sum(sum(sum(M_surf .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / surfDen;
M2_surf = squeeze(sum(sum(sum(M2_surf .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / surfDen;

% Surface-averaged E = |E| over boundary voxels (per frequency)
E_surf = mask4surf .* E;
E_surf = squeeze(sum(sum(sum(E_surf .* volW4,1,'omitnan'),2,'omitnan'),3,'omitnan')) / surfDen; % [nf x 1]

% Extract EF at laser wavelength
EF_vol_laser = EF_vol(laserIdx);
EF_surf_laser = EF_surf(laserIdx);

% Spatial Correlation (SpCr) using corrcoef on GPU (fallback to CPU)
% Correlate |E| across voxels between laserIdx and all frequencies,
% restricted to largest-ID voxels.
maskSel = (gridID == maxID);
Vall = reshape(M, nx*ny*nz, nf);   % [nvox_total x nf]
% Vall = Vall.^0.5;                  % use |E| instead of |E|^2
Vsel = Vall(maskSel(:), :);        % observations: voxels; variables: freq

if size(Vsel,1) < 2
    SpCr = NaN(nf,1);
else
    try
        C = corrcoef(Vsel, 'Rows','pairwise');   % GPU if Vsel is gpuArray
    catch
        C = corrcoef(gather(Vsel), 'Rows','pairwise'); % CPU fallback
    end
    SpCr = C(:, laserIdx);
end

% Spectral averaging over Raman shift window (excluding laser wavelength)
RamanShift = (1./LaserWl - f./c)./100; % cm^-1
% Exclude laser line (near zero Raman shift) from averaging, UNLESS RamanStart is zero
if RamanStart > 0
    mask = (RamanShift > 0.1) & (RamanShift >= RamanStart) & (RamanShift <= RamanEnd);
else
    % Include laser wavelength when RamanStart = 0 (zero-width window requested)
    mask = (RamanShift >= RamanStart) & (RamanShift <= RamanEnd);
end

if nnz(mask) >= 2
    rs = RamanShift(mask);
    ev = EF_vol(mask);
    [rs_sorted, ord] = sort(gather(rs));
    ev_sorted = gather(ev); ev_sorted = ev_sorted(ord);
    EF_vol_avg = trapz(rs_sorted, ev_sorted) / (rs_sorted(end) - rs_sorted(1));

    evs = EF_surf(mask);
    evs_sorted = gather(evs); evs_sorted = evs_sorted(ord);
    EF_surf_avg = trapz(rs_sorted, evs_sorted) / (rs_sorted(end) - rs_sorted(1));

    SpCr_avg = double(gather(mean(SpCr(mask))));
elseif nnz(mask) == 1
    % Single point case: just use that value (no integration needed)
    EF_vol_avg = double(gather(EF_vol(mask)));
    EF_surf_avg = double(gather(EF_surf(mask)));
    SpCr_avg = double(gather(SpCr(mask)));
else
    EF_vol_avg = NaN;
    EF_surf_avg = NaN;
    SpCr_avg = NaN;
end

% Outputs
out = struct();
out.LaserWl = LaserWl;
out.lambda = gather(c ./ f);
out.f = gather(f);
out.RamanShift = gather(RamanShift);
out.EF_vol = gather(EF_vol);
out.E_vol = gather(E_vol);
out.M_vol = gather(M_vol);
out.M2_vol = gather(M2_vol);
out.EF_vol_avg = EF_vol_avg;
out.EF_vol_laser = gather(EF_vol_laser);
out.EF_surf = gather(EF_surf);
out.E_surf = gather(E_surf);
out.M_surf = gather(M_surf);
out.M2_surf = gather(M2_surf);
out.EF_surf_avg = EF_surf_avg;
out.EF_surf_laser = gather(EF_surf_laser);
out.SpCr = gather(SpCr);
out.SpCr_avg = SpCr_avg;


if isfield(opts,'returnEF') && opts.returnEF
    out.EF = gather(EF);
end
end

function mustBeFloat(a)
if ~isfloat(a)
    error('Inputs must be float/double/single');
end
end

function w = local_widths_from_coords(v)
% Compute per-cell widths for a monotonic coordinate vector v (size N x 1)
% Using centered differences for interior, forward/backward for ends.
v = v(:);
N = numel(v);
if N==1
    w = 1; % degenerate, arbitrary 1
    return;
end
if N==2
    d = abs(v(2)-v(1));
    w = [d; d];
    return;
end
% interior widths as half-sum of neighbor gaps; endpoints by forward/backward diff
dv = diff(v);
win = [dv(1); (dv(1:end-1)+dv(2:end))/2; dv(end)];
% ensure positive widths
win = abs(win);
w = win;
end
