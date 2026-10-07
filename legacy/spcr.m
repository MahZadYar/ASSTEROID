% Compute SpCr_avg for structure-of-arrays allData
matFile    = 'allData.mat';
LaserWl    = 785e-9;     % m
RamanStart = 100;        % cm^-1
RamanEnd   = 3500;       % cm^-1
c = 299792458;           % m/s

S = load(matFile);
assert(isfield(S,'allData'), 'Variable "allData" not found.');
allData = S.allData;

SpCr = allData.SpCr;
if isvector(SpCr), SpCr = reshape(SpCr, 1, []); end  % ensure N x M
N = size(SpCr,1);

% Build RamanShift axis from available fields
if isfield(allData,'RamanShift') && ~isempty(allData.RamanShift)
    rs = allData.RamanShift;
    if size(rs,1) > 1, rs = rs(1,:); end
elseif isfield(allData,'f') && ~isempty(allData.f)
    f = allData.f; if size(f,1) > 1, f = f(1,:); end
    rs = (1./LaserWl - f./c)./100;  % cm^-1
elseif isfield(allData,'lambda') && ~isempty(allData.lambda)
    lam = allData.lambda; if size(lam,1) > 1, lam = lam(1,:); end
    rs = (1./LaserWl - 1./lam)./100; % cm^-1
else
    error('No spectral axis found (need RamanShift, f, or lambda).');
end
rs = rs(:).';  % 1 x M

% Align SpCr with axis if needed
if size(SpCr,2) ~= numel(rs)
    if size(SpCr,1) == numel(rs)
        SpCr = SpCr.';  % transpose to N x M
    else
        error('SpCr size %s does not match spectral axis length %d.', mat2str(size(SpCr)), numel(rs));
    end
end

mask = (rs >= RamanStart) & (rs <= RamanEnd);  % 1 x M
SpCr_avg = mean(SpCr(:, mask), 2, 'omitnan');  % N x 1

allData.SpCr_avg = SpCr_avg;
save(matFile, 'allData', '-append');
disp('SpCr_avg computed and saved.');