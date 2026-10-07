function [db, branchPath] = storePredictionResults(db, allDataFiltered, dataSource, predictionTarget)
%storePredictionResults Route predicted metrics to the configured DB sub-branch.
%   Stores prediction results into the appropriate database branch based on
%   data source (model / interpolation) and prediction target (grid / optima).
%
%   [db, branchPath] = storePredictionResults(db, allDataFiltered, dataSource, predictionTarget)
%
%   Inputs:
%       db               - Database struct.
%       allDataFiltered  - SoA struct of predicted/interpolated data.
%       dataSource       - "model" or "interpolation".
%       predictionTarget - "grid" or "optima".
%
%   Outputs:
%       db         - Updated database struct.
%       branchPath - String describing the branch path (e.g., "db.Pred").

    arguments
        db struct
        allDataFiltered struct
        dataSource string
        predictionTarget string = "grid"
    end

    branchName = "Pred";
    if dataSource == "interpolation"
        branchName = "Interp";
    end

    if predictionTarget == "optima"
        if ~isfield(db, "Optima") || ~isstruct(db.Optima)
            db.Optima = struct();
        end
        db.Optima.(branchName) = allDataFiltered;
        branchPath = "db.Optima." + branchName;
    else
        db.(branchName) = allDataFiltered;
        branchPath = "db." + branchName;
    end
end
