function analyteSpec = getDefaultAnalyteSpectrum(preset)
%getDefaultAnalyteSpectrum Return built-in default gas-phase Raman spectrum.
%
%   analyteSpec = getDefaultAnalyteSpectrum() loads the primary default
%   analyte Raman spectrum (12CH4, DefaultAnalyteSpectrum.dat) in src/io.
%
%   analyteSpec = getDefaultAnalyteSpectrum(preset) selects a built-in
%   default analyte preset from the gas-phase fingerprint library:
%       "CH4"  (or "methane", "default")    -> DefaultAnalyteSpectrum.dat
%       "C2H4" (or "ethylene", "ethene")    -> DefaultAnalyteSpectrum_C2H4.dat
%       "H2S"  (or "hydrogen sulfide")      -> DefaultAnalyteSpectrum_H2S.dat
%       "NH3"  (or "ammonia")               -> DefaultAnalyteSpectrum_NH3.dat
%       "C2H2" (or "acetylene", "ethyne")   -> DefaultAnalyteSpectrum_C2H2.dat
%       "H2O"  (or "water", "steam")        -> DefaultAnalyteSpectrum_H2O.dat
%       "SF6"  (or "sulfur hexafluoride")   -> DefaultAnalyteSpectrum_SF6.dat
%       "SO2"  (or "sulfur dioxide")        -> DefaultAnalyteSpectrum_SO2.dat
%       "CO2"  (or "carbon dioxide")        -> DefaultAnalyteSpectrum_CO2.dat
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
%     Loads the baseline-free gas-phase 12CH4 (MeCaSDa), 12C2H4 (ECaSDa),
%     32SF6 (SHeCaSDa), or SO2 / CO2 / H2S / NH3 / C2H2 / H2O
%     (NIST WebBook + CCCBDB MP2=FULL/aug-cc-pVTZ) reference Raman spectrum
%     (T = 296 K) across 100-4200 cm^-1 (785 nm photon-yield scaled, convolved
%     with a 20 cm^-1 FWHM Gaussian slit profile) and normalizes to unit area.
%     This provides a realistic high-shift gas-phase analyte spectrum, NOT a
%     flat spectrum.
%
%   Notes:
%     If a user-provided experimental spectrum is needed, load via
%     loadAndNormalizeAnalyteSpectrum(filePath).

if nargin < 1 || strlength(string(preset)) == 0
    preset = "CH4";
end

% Find the requested built-in .dat file via shared catalog
[datPath, ~, displayLabel] = resolveDefaultAnalyteSpectrumPath(string(preset), Strict=true);

% Load the .dat file (wavenumber, intensity; skip # provenance comments)
data = readmatrix(datPath, 'CommentStyle', '#', 'Delimiter', ',');
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

disp("Loaded default analyte Raman spectrum (" + displayLabel + ") from " + datPath);
end
