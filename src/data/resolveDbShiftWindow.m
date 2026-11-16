function [shiftWindow, sourceLabel] = resolveDbShiftWindow(db, dataSource, laserWl, fallbackWindow)
%resolveDbShiftWindow Auto-detect the Stokes shift window [min, max] cm^-1 from the DB.
%
%   [shiftWindow, sourceLabel] = resolveDbShiftWindow(db, dataSource, laserWl, fallbackWindow)
%   inspects the relevant database branch (Pred, Sim, or Model) and returns
%   the positive Stokes shift window [minShift, maxShift] in cm^-1.
%   Falls back to fallbackWindow (default [100, 4200]) when no valid shift
%   range can be inferred.

    arguments
        db               = struct()
        dataSource (1,1) string = "model"
        laserWl    (1,1) double = 785
        fallbackWindow (1,2) double = [100, 4200]
    end

    shiftWindow = fallbackWindow;
    sourceLabel = "default";

    if ~isstruct(db)
        return;
    end

    % Prioritise branch matching dataSource, then Sim, then Model
    if dataSource == "predictions"
        candidates = ["Pred", "Sim", "Model"];
    elseif dataSource == "interpolation"
        candidates = ["Sim", "Pred", "Model"];
    else
        candidates = ["Sim", "Pred", "Model"];
    end

    for k = 1:numel(candidates)
        bName = candidates(k);
        if ~isfield(db, bName) || ~isstruct(db.(bName))
            continue;
        end
        branch = db.(bName);

        % 1. Explicit StokesWindow / RamanWindow metadata
        for fld = ["StokesWindow", "RamanWindow", "RamanWindowEffective"]
            if isfield(branch, fld) && numel(branch.(fld)) == 2
                w = double(branch.(fld)(:)');
                if all(isfinite(w)) && w(1) > 0 && w(2) > w(1)
                    shiftWindow = w;
                    sourceLabel = "db." + bName + "." + fld;
                    return;
                end
            end
        end

        % 2. Explicit Shifts / RamanShift vector or matrix
        for fld = ["Shifts", "RamanShift"]
            if isfield(branch, fld) && isnumeric(branch.(fld)) && ~isempty(branch.(fld))
                s = double(branch.(fld)(:));
                s = s(isfinite(s) & s > 0);
                if numel(s) >= 2 && max(s) > min(s)
                    shiftWindow = [min(s), max(s)];
                    sourceLabel = "db." + bName + "." + fld;
                    return;
                end
            end
        end

        % 3. Wavelength array (lambda in nm or um)
        if isfield(branch, "lambda") && isnumeric(branch.lambda) && ~isempty(branch.lambda)
            lam = double(branch.lambda(:));
            lam = lam(isfinite(lam) & lam > 0);
            if ~isempty(lam)
                if max(lam) < 10
                    lam = lam * 1e3; % um -> nm
                end
                s = (1 ./ laserWl - 1 ./ lam) * 1e7;
                s = s(isfinite(s) & s > 0);
                if numel(s) >= 2 && max(s) > min(s)
                    shiftWindow = [round(min(s), 4), round(max(s), 4)];
                    sourceLabel = "db." + bName + ".lambda";
                    return;
                end
            end
        end

        % 4. Model dataset wavelengths (column 3 of XTrain/XTest in um)
        if bName == "Model"
            ds = struct();
            if isfield(branch, "Dataset") && isstruct(branch.Dataset)
                ds = branch.Dataset;
            elseif isfield(branch, "Model") && isstruct(branch.Model) && isfield(branch.Model, "dataset")
                ds = branch.Model.dataset;
            elseif isfield(branch, "dataset") && isstruct(branch.dataset)
                ds = branch.dataset;
            end
            for split = ["XTrain", "XValidation", "XTest"]
                if isfield(ds, split) && isnumeric(ds.(split)) && size(ds.(split), 2) >= 3 && ~isempty(ds.(split))
                    lam = double(ds.(split)(:, 3));
                    lam = lam(isfinite(lam) & lam > 0);
                    if ~isempty(lam)
                        if max(lam) < 10
                            lam = lam * 1e3; % um -> nm
                        end
                        s = (1 ./ laserWl - 1 ./ lam) * 1e7;
                        s = s(isfinite(s) & s > 0);
                        if numel(s) >= 2 && max(s) > min(s)
                            shiftWindow = [round(min(s), 4), round(max(s), 4)];
                            sourceLabel = "db.Model.Dataset." + split;
                            return;
                        end
                    end
                end
            end
        end
    end
end
