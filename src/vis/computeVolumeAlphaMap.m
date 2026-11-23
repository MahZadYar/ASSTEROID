function aMap = computeVolumeAlphaMap(curveType, gammaVal, maxAlpha, nLevels)
%COMPUTEVOLUMEALPHAMAP Compute transfer function alphamap for 3D volume rendering.
%
%   aMap = computeVolumeAlphaMap()
%   aMap = computeVolumeAlphaMap(curveType, gammaVal, maxAlpha, nLevels)
%
%   Inputs:
%       curveType - string scalar: "power", "log", "linear", "sigmoid", "exponential" (default: "power")
%       gammaVal  - double scalar: exponent / gamma >= 0.05 (default: 1.5)
%       maxAlpha  - double scalar: peak opacity in [0, 1] (default: 1.0)
%       nLevels   - integer scalar: number of levels in alphamap (default: 4095 for 12-bit)
%
%   Output:
%       aMap      - [nLevels x 1] double vector in [0, 1] suitable for volshow / Alphamap.

    arguments
        curveType (1,1) string {mustBeMember(curveType, ["power", "log", "linear", "sigmoid", "exponential"])} = "power"
        gammaVal (1,1) double {mustBePositive} = 1.5
        maxAlpha (1,1) double {mustBeInRange(maxAlpha, 0, 1)} = 1.0
        nLevels (1,1) double {mustBeInteger, mustBePositive} = 4095
    end

    u = linspace(0, 1, nLevels)';

    switch lower(curveType)
        case "power"
            aMap = u .^ gammaVal;

        case "log"
            epsA = 1e-4;
            t = log(u * (1 - epsA) + epsA);
            aMap = (1 - t / log(epsA)) .^ gammaVal;

        case "linear"
            aMap = u;

        case "sigmoid"
            k = max(0.5, 4 * gammaVal);
            s = 1 ./ (1 + exp(-k * (u - 0.5)));
            s0 = 1 / (1 + exp(k * 0.5));
            s1 = 1 / (1 + exp(-k * 0.5));
            aMap = (s - s0) / (s1 - s0);

        case "exponential"
            if abs(gammaVal) < 1e-4
                aMap = u;
            else
                aMap = (exp(gammaVal * u) - 1) ./ (exp(gammaVal) - 1);
            end

        otherwise
            aMap = u .^ gammaVal;
    end

    aMap = aMap * maxAlpha;
    aMap = max(0, min(1, aMap));
end
