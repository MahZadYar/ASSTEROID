function [periodNm, radiusNm] = getPredictionTargetPoints(db, predictionTarget)
%getPredictionTargetPoints Resolve prediction coordinates from selected target mode.
%   Extracts validated (period, radius) pairs from db.Optima when
%   predictionTarget is "optima". Returns empty for other modes.
%
%   [periodNm, radiusNm] = getPredictionTargetPoints(db, predictionTarget)
%
%   Inputs:
%       db               - Database struct (must have .Optima.period/radius for optima mode).
%       predictionTarget - String ("optima" or "grid").
%
%   Outputs:
%       periodNm - Column vector of period values in nm.
%       radiusNm - Column vector of radius values in nm.

    arguments
        db struct
        predictionTarget string
    end

    periodNm = [];
    radiusNm = [];

    if predictionTarget ~= "optima"
        return;
    end

    if ~isfield(db, "Optima") || ~isstruct(db.Optima) || ...
            ~isfield(db.Optima, "period") || ~isfield(db.Optima, "radius")
        error("getPredictionTargetPoints:MissingOptima", ...
            "No saved optima found in db.Optima. Save optima first in Stage 5.");
    end

    periodNm = double(db.Optima.period(:));
    radiusNm = double(db.Optima.radius(:));
    valid = isfinite(periodNm) & isfinite(radiusNm);
    periodNm = periodNm(valid);
    radiusNm = radiusNm(valid);

    if isempty(periodNm)
        error("getPredictionTargetPoints:EmptyOptima", ...
            "db.Optima contains no valid period/radius points.");
    end
end
