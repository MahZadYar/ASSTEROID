function gridParams = computeDenseGridParams(options)
    % computeDenseGridParams  Compute dense (p, r, lambda) grid sample vectors.
    %
    %   gridParams = computeDenseGridParams(Name=Value) computes uniformly-spaced
    %   sample vectors for period, radius, and wavelength from physical parameters.
    %   Wavelength limits are derived from Stokes shift bounds relative to the laser
    %   wavelength using the standard relation:
    %       lambda_R = lambda_L / (1 - lambda_L * DeltaNu * 1e-7)
    %
    %   This function centralises grid computation that was previously duplicated
    %   across run_locate_maxima, run_prediction_vis, and run_prediction_vis_app.
    %
    %   Name-Value Arguments:
    %       LambdaLaser          (1,1) double — Laser wavelength in nm (default: 785)
    %       PLimits              (1,2) double — [min, max] period bounds in nm
    %       RLimits              (1,2) double — [min, max] radius bounds in nm
    %       StokesShiftLimits    (1,2) double — [min, max] Stokes shift in cm^-1
    %       Resolution           (1,1) double — Spatial resolution in nm (default: 0.75)
    %       StokesShiftResolution (1,1) double — Spectral resolution in cm^-1 (default: 2)
    %       OutputUnit           (1,1) string — "nm" or "um" for output vectors
    %
    %   Output:
    %       gridParams — struct with fields:
    %           pSamples          [1 × Np] period sample vector (in OutputUnit)
    %           rSamples          [1 × Nr] radius sample vector (in OutputUnit)
    %           lambdaSamples     [1 × Nl] wavelength sample vector (in OutputUnit)
    %           lambdaLimits      [1 × 2]  wavelength bounds in nm
    %           stokesShiftSamples [1 × Ns] Stokes shift samples in cm^-1
    %           lambdaLaser       (1,1) laser wavelength in nm
    %           resolution        (1,1) spatial resolution in nm
    %           stokesShiftResolution (1,1) spectral resolution in cm^-1
    %           pLimits           (1,2) period bounds in nm
    %           rLimits           (1,2) radius bounds in nm
    %           stokesShiftLimits (1,2) Stokes shift bounds in cm^-1
    %
    %   Example:
    %       gp = computeDenseGridParams(LambdaLaser=785, PLimits=[750,950], ...
    %           RLimits=[50,450], StokesShiftLimits=[100,3600], Resolution=0.75);
    %       % gp.pSamples in µm, gp.lambdaSamples in µm
    %
    %   See also: predict_dense_spectrum, runLocalizationWorkflow

    arguments
        options.LambdaLaser (1,1) double {mustBePositive} = 785
        options.PLimits (1,2) double {mustBePositive} = [750, 950]
        options.RLimits (1,2) double {mustBePositive} = [50, 450]
        options.StokesShiftLimits (1,2) double = [100, 3600]
        options.Resolution (1,1) double {mustBePositive} = 0.75
        options.StokesShiftResolution (1,1) double {mustBePositive} = 2
        options.OutputUnit (1,1) string {mustBeMember(options.OutputUnit, ["nm", "um"])} = "um"
    end

    lambdaLaser = options.LambdaLaser;
    pLimits = sort(options.PLimits);
    rLimits = sort(options.RLimits);
    stokesLimits = sort(options.StokesShiftLimits);
    res = options.Resolution;
    stokesRes = options.StokesShiftResolution;

    % Compute wavelength limits from Stokes shift bounds
    % lambda_R = lambda_L / (1 - lambda_L * DeltaNu * 1e-7)
    lambdaLimits_nm = lambdaLaser ./ (1 - lambdaLaser * stokesLimits * 1e-7);

    % Stokes shift sample vector
    stokesRange = stokesLimits(2) - stokesLimits(1);
    if stokesRange > 0
        numStokesSamples = round(stokesRange / stokesRes) + 1;
        stokesShiftSamples = linspace(stokesLimits(1), stokesLimits(2), numStokesSamples);
    else
        stokesShiftSamples = stokesLimits(1);
    end

    % Wavelength samples: laser line + Stokes shift samples converted to wavelengths.
    % Uses stokesShiftSamples so the spectral grid is uniformly spaced in Raman
    % shift at stokesShiftResolution (cm^-1), consistent with the Stokes axis.
    % uniquetol deduplicates the laser wavelength when the shift range includes 0
    % (e.g. [-600, 3600]) — the linspace hits shift=0 which maps to exactly
    % lambdaLaser, so the prepended laser point would appear twice.
    if numel(stokesShiftSamples) > 1
        lambdaSamples_nm = [lambdaLaser, lambdaLaser ./ (1 - lambdaLaser .* stokesShiftSamples * 1e-7)];
        lambdaSamples_nm = uniquetol(sort(lambdaSamples_nm), 1e-9 * max(lambdaSamples_nm));
    else
        lambdaSamples_nm = lambdaLaser;
    end

    % Period samples
    pRange = pLimits(2) - pLimits(1);
    numPSamples = round(pRange / res) + 1;
    pSamples_nm = linspace(pLimits(1), pLimits(2), numPSamples);

    % Radius samples
    rRange = rLimits(2) - rLimits(1);
    numRSamples = round(rRange / res) + 1;
    rSamples_nm = linspace(rLimits(1), rLimits(2), numRSamples);

    % Apply unit conversion
    switch options.OutputUnit
        case "um"
            scaleFactor = 1e-3;
        case "nm"
            scaleFactor = 1;
    end

    gridParams = struct();
    gridParams.pSamples = pSamples_nm * scaleFactor;
    gridParams.rSamples = rSamples_nm * scaleFactor;
    gridParams.lambdaSamples = lambdaSamples_nm * scaleFactor;
    gridParams.lambdaLimits = lambdaLimits_nm;
    gridParams.stokesShiftSamples = stokesShiftSamples;
    gridParams.lambdaLaser = lambdaLaser;
    gridParams.resolution = res;
    gridParams.stokesShiftResolution = stokesRes;
    gridParams.pLimits = pLimits;
    gridParams.rLimits = rLimits;
    gridParams.stokesShiftLimits = stokesLimits;
end
