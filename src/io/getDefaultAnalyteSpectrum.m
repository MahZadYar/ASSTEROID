function analyteSpec = getDefaultAnalyteSpectrum(preset)
%getDefaultAnalyteSpectrum Return built-in default gas-phase Raman spectrum.
%
%   analyteSpec = getDefaultAnalyteSpectrum() loads the primary default
%   analyte Raman spectrum (12CH4, DefaultAnalyteSpectrum.dat) in src/io.
%
%   analyteSpec = getDefaultAnalyteSpectrum(preset) selects a built-in
%   default analyte preset:
%       "CH4"  (or "methane", "default") -> DefaultAnalyteSpectrum.dat
%       "C2H4" (or "ethylene", "ethene") -> DefaultAnalyteSpectrum_C2H4.dat
%
%   Output:
%       analyteSpec – struct with fields:
%           .shift_cm       – Raman shifts (cm^-1, row vector)
%           .intensity      – Normalized intensity (integrates to ~1)
%           .raw_intensity  – Original intensity
%           .baseline       – Estimated background (zero for this data)
%           .processed_intensity – Background-removed version
%
%   Behavior:
%     Loads the baseline-free gas-phase 12CH4 (MeCaSDa) or 12C2H4 (ECaSDa)
%     reference Raman spectrum (T = 296 K) across 100-4200 cm^-1 (785 nm
%     photon-yield (nu_L - dnu)^3 weighted, convolved with a 20 cm^-1 FWHM
%     Gaussian slit profile) and normalizes to unit area.
%     This provides a realistic high-shift gas-phase analyte spectrum, NOT a
%     flat spectrum.
%
%   Notes:
%     If a user-provided spectrum is needed, load via
%     loadAndNormalizeAnalyteSpectrum(filePath).

if nargin < 1 || strlength(string(preset)) == 0
    preset = "CH4";
end
presetKey = lower(strtrim(string(preset)));

% Find the requested built-in .dat file
datPath = findDefaultAnalyteDat(presetKey);

if isempty(datPath) || ~isfile(datPath)
    error("getDefaultAnalyteSpectrum:NoFile", ...
        "Default analyte spectrum file not found for preset '%s' in src/io directory.", preset);
end

% Load the .dat file (wavenumber, intensity)
data = readmatrix(datPath, 'NumHeaderLines', 0, 'Delimiter', ',');
shift_cm = data(:, 1);      % Raman shift in cm^-1
raw_intensity = data(:, 2); % Raw intensity values

% Normalize to unit area (trapz integration)
areaInt = trapz(shift_cm, raw_intensity);
intensity = raw_intensity / areaInt;

% Baseline (zero for this spectrum)
baseline = zeros(size(shift_cm));
processed = intensity; % No processing needed

% Return struct matching loadAndNormalizeAnalyteSpectrum output format
analyteSpec = struct();
analyteSpec.shift_cm            = shift_cm';
analyteSpec.intensity           = intensity';
analyteSpec.raw_intensity       = raw_intensity';
analyteSpec.baseline            = baseline';
analyteSpec.processed_intensity = processed';

disp("Loaded default analyte Raman spectrum from " + datPath);
end

function datPath = findDefaultAnalyteDat(presetKey)
    % Search for the requested built-in analyte .dat file in src/io directory
    datPath = "";

    switch presetKey
        case {"c2h4", "ethylene", "ethene"}
            fileName = "DefaultAnalyteSpectrum_C2H4.dat";
        otherwise
            fileName = "DefaultAnalyteSpectrum.dat";
    end

    % Get the function directory (src/io)
    funcDir = fileparts(mfilename('fullpath'));
    fullPath = fullfile(funcDir, fileName);

    if isfile(fullPath)
        datPath = string(fullPath);
    end
end
