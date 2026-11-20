classdef SpectralStorage
% SPECTRALSTORAGE Compression and HDF5 sidecar storage for [N x L] spectral arrays.
%
%   Keeps all [N x 1] scalar arrays (period, radius, *_laser, *_broad,
%   *_analyte, etc.) in their original double format while optionally
%   compressing or externalizing [N x L] spectral metric arrays.
%
%   Supported storage modes:
%     "none"       - Uncompressed double (still deduplicates uniform lambda/RamanShift to 1xL)
%     "single"     - 32-bit float (single), ~2x smaller
%     "log_uint16" - Log10/linear uint16 quantization, ~6-10x smaller on disk
%     "svd"        - Truncated SVD / PCA in log10/linear space (C * B), ~30-60x smaller
%     "sidecar_h5" - External chunked+deflate HDF5 sidecar (.h5), 0 MB in .mat
%
%   See also: PredictionController, VisualizeController, extractBranchAsSoA

    methods (Static)

        function [SOut, stats] = encodeBranch(S, options)
        % ENCODEBRANCH Encode [N x L] spectral arrays in a SoA branch struct.
        %   Scalar [N x 1] fields remain untouched in original double.
            arguments
                S (1,1) struct
                options.Mode (1,1) string {mustBeMember(options.Mode, ...
                    ["none", "single", "log_uint16", "svd", "sidecar_h5"])} = "none"
                options.SvdMaxRank (1,1) double {mustBePositive, mustBeInteger} = 32
                options.SvdMaxError (1,1) double {mustBeNonnegative} = 0.005
                options.SidecarFile (1,1) string = ""
                options.SidecarGroup (1,1) string = "/Pred"
                options.SidecarSubtype (1,1) string {mustBeMember(options.SidecarSubtype, ...
                    ["single", "log_uint16", "double"])} = "single"
                options.Reporter = []
            end

            SOut = SpectralStorage.deduplicateAxes(S);
            nRows = structRowCount(SOut);

            stats = struct( ...
                "mode", options.Mode, ...
                "encodedFields", {{}}, ...
                "rawBytes", 0, ...
                "storedBytes", 0, ...
                "sidecarFile", "", ...
                "details", "");

            if nRows == 0
                return;
            end

            specFields = SpectralStorage.findSpectralMetricFields(SOut, nRows);
            if isempty(specFields)
                return;
            end

            % Measure original raw byte footprint of spectral fields
            rawBytes = 0;
            for i = 1:numel(specFields)
                v = SOut.(specFields(i));
                w = whos("v");
                rawBytes = rawBytes + w.bytes;
            end
            stats.rawBytes = rawBytes;
            stats.encodedFields = cellstr(specFields);

            if options.Mode == "none"
                stats.storedBytes = rawBytes;
                stats.details = "Uncompressed double (axes deduplicated to 1xL)";
                return;
            end

            if options.Mode == "sidecar_h5"
                h5Path = options.SidecarFile;
                if strlength(h5Path) == 0
                    h5Path = fullfile(pwd, "ASSTEROID_spectral_sidecar.h5");
                end
                h5Dir = fileparts(h5Path);
                if strlength(h5Dir) > 0 && ~isfolder(h5Dir)
                    mkdir(h5Dir);
                end
                stats.sidecarFile = h5Path;
                SpectralStorage.writeAxisMetadataH5(h5Path, options.SidecarGroup, SOut);
            end

            detailParts = strings(1, 0);
            storedBytes = 0;
            for i = 1:numel(specFields)
                fn = specFields(i);
                M = SOut.(fn);
                if ~isnumeric(M)
                    continue;
                end

                switch options.Mode
                    case "single"
                        enc = single(M);
                        w = whos("enc");
                        storedBytes = storedBytes + w.bytes;

                    case "log_uint16"
                        enc = SpectralStorage.encodeLogUint16(M, fn);
                        w = whos("enc");
                        storedBytes = storedBytes + w.bytes;

                    case "svd"
                        [enc, infoStr] = SpectralStorage.encodeSVD( ...
                            M, fn, options.SvdMaxRank, options.SvdMaxError);
                        w = whos("enc");
                        storedBytes = storedBytes + w.bytes;
                        detailParts(end+1) = sprintf("%s (%s)", fn, infoStr); %#ok<AGROW>

                    case "sidecar_h5"
                        enc = SpectralStorage.writeSidecarH5( ...
                            M, fn, h5Path, options.SidecarGroup, options.SidecarSubtype);
                        w = whos("enc");
                        storedBytes = storedBytes + w.bytes;
                end

                SOut.(fn) = enc;
            end

            stats.storedBytes = storedBytes;
            if ~isempty(detailParts)
                stats.details = strjoin(detailParts, "; ");
            elseif options.Mode == "sidecar_h5"
                stats.details = sprintf("HDF5 sidecar (%s): %s", options.SidecarSubtype, h5Path);
            else
                stats.details = sprintf("%s encoding applied to %d spectral array(s)", options.Mode, numel(specFields));
            end
        end

        function tf = isEncodedSpectral(val, expectedRows)
        % ISENCODEDSPECTRAL True if val is a compressed or sidecar spectral struct.
            tf = isstruct(val) && isscalar(val) && isfield(val, "codec") && isfield(val, "size");
            if tf && nargin >= 2 && ~isempty(expectedRows)
                tf = numel(val.size) >= 2 && val.size(1) == expectedRows && val.size(2) > 1;
            end
        end

        function sz = getSpectralSize(val)
        % GETSPECTRALSIZE Return [N, L] dimensions of raw numeric or encoded spectral field.
            if isnumeric(val)
                sz = size(val);
            elseif SpectralStorage.isEncodedSpectral(val)
                sz = double(val.size);
            else
                sz = [0, 0];
            end
        end

        function vals = readColumns(val, colIdx)
        % READCOLUMNS Read/decode selected wavelength column(s) [N x numel(colIdx)] as double.
            if isnumeric(val)
                vals = double(val(:, colIdx));
                return;
            end
            if ~SpectralStorage.isEncodedSpectral(val)
                error("SpectralStorage:InvalidField", "Unsupported spectral field format.");
            end

            colIdx = colIdx(:)';
            switch string(val.codec)
                case "log_uint16"
                    qSub = val.q(:, colIdx);
                    vals = SpectralStorage.decodeLogUint16Sub(qSub, val);

                case "svd"
                    Ysub = double(val.C) * double(val.B(:, colIdx)) + double(val.mu(1, colIdx));
                    if string(val.domain) == "log10"
                        vals = 10 .^ Ysub;
                    else
                        vals = Ysub;
                    end
                    if isfield(val, "nanMask") && ~isempty(val.nanMask)
                        vals(val.nanMask(:, colIdx)) = NaN;
                    end

                case "sidecar_h5"
                    h5Path = SpectralStorage.resolveH5Path(val.h5File);
                    dsPath = char(val.h5Dataset);
                    N = double(val.size(1));
                    vals = zeros(N, numel(colIdx));
                    for k = 1:numel(colIdx)
                        rawCol = h5read(h5Path, dsPath, [1, double(colIdx(k))], [N, 1]);
                        vals(:, k) = SpectralStorage.decodeSidecarBlock(rawCol, val);
                    end

                otherwise
                    error("SpectralStorage:UnknownCodec", "Unknown spectral codec: %s", string(val.codec));
            end
        end

        function vals = readSubmatrix(val, rowIdx, colIdx)
        % READSUBMATRIX Read/decode a subset of rows & columns [numel(rowIdx) x numel(colIdx)] as double.
            if isnumeric(val)
                vals = double(val(rowIdx, colIdx));
                return;
            end
            if ~SpectralStorage.isEncodedSpectral(val)
                error("SpectralStorage:InvalidField", "Unsupported spectral field format.");
            end

            rowIdx = rowIdx(:);
            colIdx = colIdx(:)';
            switch string(val.codec)
                case "log_uint16"
                    qSub = val.q(rowIdx, colIdx);
                    vals = SpectralStorage.decodeLogUint16Sub(qSub, val);

                case "svd"
                    Ysub = double(val.C(rowIdx, :)) * double(val.B(:, colIdx)) + double(val.mu(1, colIdx));
                    if string(val.domain) == "log10"
                        vals = 10 .^ Ysub;
                    else
                        vals = Ysub;
                    end
                    if isfield(val, "nanMask") && ~isempty(val.nanMask)
                        vals(val.nanMask(rowIdx, colIdx)) = NaN;
                    end

                case "sidecar_h5"
                    h5Path = SpectralStorage.resolveH5Path(val.h5File);
                    dsPath = char(val.h5Dataset);
                    % Fast strided hyperslab read when rowIdx & colIdx are uniform arithmetic progressions
                    [isRegR, rStart, rStep] = SpectralStorage.isUniformStride(rowIdx);
                    [isRegC, cStart, cStep] = SpectralStorage.isUniformStride(colIdx);
                    if isRegR && isRegC
                        rawSub = h5read(h5Path, dsPath, [rStart, cStart], ...
                            [numel(rowIdx), numel(colIdx)], [rStep, cStep]);
                    else
                        % Read bounding hyperslab in row chunks if needed, or column-by-column
                        rMin = min(rowIdx); rMax = max(rowIdx);
                        rRel = rowIdx - rMin + 1;
                        rawSub = zeros(numel(rowIdx), numel(colIdx), 'double');
                        for k = 1:numel(colIdx)
                            block = h5read(h5Path, dsPath, [rMin, double(colIdx(k))], [rMax - rMin + 1, 1]);
                            rawSub(:, k) = double(block(rRel));
                        end
                    end
                    vals = SpectralStorage.decodeSidecarBlock(rawSub, val);

                otherwise
                    error("SpectralStorage:UnknownCodec", "Unknown spectral codec: %s", string(val.codec));
            end
        end

        function M = decodeField(val)
        % DECODEFIELD Materialize full [N x L] double array from any encoded representation.
            if isnumeric(val)
                M = double(val);
                return;
            end
            sz = SpectralStorage.getSpectralSize(val);
            M = SpectralStorage.readSubmatrix(val, 1:sz(1), 1:sz(2));
        end

        function SOut = decodeStruct(S)
        % DECODESTRUCT Decode all encoded spectral fields in a SoA struct to double.
            SOut = S;
            if ~isstruct(S) || ~isscalar(S)
                return;
            end
            flds = fieldnames(S);
            for i = 1:numel(flds)
                fn = flds{i};
                if SpectralStorage.isEncodedSpectral(S.(fn))
                    SOut.(fn) = SpectralStorage.decodeField(S.(fn));
                end
            end
        end

        function S = deduplicateAxes(S)
        % DEDUPLICATEAXES Collapse [N x L] lambda and RamanShift to [1 x L] when all rows match.
            if ~isstruct(S) || ~isscalar(S)
                return;
            end
            for axName = ["lambda", "RamanShift"]
                if isfield(S, axName) && isnumeric(S.(axName)) && ~isempty(S.(axName))
                    A = S.(axName);
                    if size(A, 1) > 1
                        row1 = A(1, :);
                        % Fast check: compare columnwise min/max against row1 (handles NaN identically)
                        diffMat = abs(A - row1);
                        maxDiff = max(diffMat, [], "all", "omitnan");
                        sameNans = isequal(isnan(A), repmat(isnan(row1), size(A, 1), 1));
                        if sameNans && (isempty(maxDiff) || maxDiff <= 1e-12 * max(1, max(abs(row1), [], "omitnan")))
                            S.(axName) = row1;
                        end
                    end
                end
            end
        end

        function specFields = findSpectralMetricFields(S, nRows)
        % FINDSPECTRALMETRICFIELDS Return [N x L] metric field names (excluding axes/metadata).
            meta = ["period", "radius", "lambda", "lambda_nm", "RamanShift", ...
                    "LaserWl", "lambda_exc_nm", "RamanWindow", "RamanWindowEffective", ...
                    "MetricsRamanWindow", "p", "r", "particle_r", "f", ...
                    "femPeriod", "femRadius", "matchDistance", "optimaIndex", ...
                    "isVerified", "surrogateMetricValue", "kappa_V", "kappa_S", ...
                    "VolCorr", "SurfCorr", "V_corr", "S_corr", ...
                    "Source", "Parent", "Method", "ModelRef", "Resolution", ...
                    "SourceFiles", "TrainDataRef", "LaserWl", "StokesWindow", "Shifts"];
            specFields = strings(1, 0);
            if ~isstruct(S) || ~isscalar(S) || nRows <= 0
                return;
            end
            flds = string(fieldnames(S));
            for i = 1:numel(flds)
                fn = flds(i);
                if ismember(fn, meta)
                    continue;
                end
                v = S.(fn);
                if isnumeric(v) && ismatrix(v) && size(v, 1) == nRows && size(v, 2) > 1
                    specFields(end+1) = fn; %#ok<AGROW>
                end
            end
        end

        function deleteSidecars(S)
        % DELETESIDECARS Delete any external HDF5 sidecar files referenced by branch S.
            if ~isstruct(S) || ~isscalar(S)
                return;
            end
            flds = fieldnames(S);
            deleted = strings(1, 0);
            for i = 1:numel(flds)
                v = S.(flds{i});
                if SpectralStorage.isEncodedSpectral(v) && string(v.codec) == "sidecar_h5"
                    p = SpectralStorage.resolveH5Path(v.h5File);
                    if strlength(p) > 0 && isfile(p) && ~ismember(p, deleted)
                        try
                            delete(p);
                            deleted(end+1) = p; %#ok<AGROW>
                        catch
                        end
                    end
                end
            end
        end
    end

    %% Private Codec Helpers
    methods (Static, Access = private)

        function useLog = shouldUseLogDomain(M, metricName)
            fin = isfinite(M);
            if ~any(fin, "all")
                useLog = false;
                return;
            end
            low = lower(string(metricName));
            if ismember(low, ["abs", "absorptance", "ecc", "eccheck"])
                useLog = false;
                return;
            end
            mFin = M(fin);
            minVal = min(mFin);
            maxVal = max(mFin);
            useLog = (minVal > 0) && ((maxVal / max(minVal, realmin)) > 50);
        end

        function enc = encodeLogUint16(M, metricName)
            M = double(M);
            [N, L] = size(M);
            useLog = SpectralStorage.shouldUseLogDomain(M, metricName);
            fin = isfinite(M);

            if useLog
                domain = "log10";
                Y = nan(N, L);
                posFin = fin & (M > 0);
                Y(posFin) = log10(M(posFin));
                finY = posFin;
            else
                domain = "linear";
                Y = M;
                finY = fin;
            end

            q = repmat(uint16(65535), N, L);
            if any(finY, "all")
                yMin = double(min(Y(finY)));
                yMax = double(max(Y(finY)));
                if yMax <= yMin
                    q(finY) = uint16(0);
                else
                    scale = 65534 / (yMax - yMin);
                    q(finY) = uint16(round((Y(finY) - yMin) * scale));
                end
            else
                yMin = 0;
                yMax = 1;
            end

            enc = struct( ...
                "codec", "log_uint16", ...
                "domain", domain, ...
                "q", q, ...
                "minVal", yMin, ...
                "maxVal", yMax, ...
                "size", [N, L]);
        end

        function vals = decodeLogUint16Sub(qSub, enc)
            nanMask = (qSub == uint16(65535));
            yMin = double(enc.minVal);
            yMax = double(enc.maxVal);
            if yMax <= yMin
                Y = repmat(yMin, size(qSub));
            else
                Y = yMin + double(qSub) * ((yMax - yMin) / 65534);
            end
            if string(enc.domain) == "log10"
                vals = 10 .^ Y;
            else
                vals = Y;
            end
            vals(nanMask) = NaN;
        end

        function [enc, infoStr] = encodeSVD(M, metricName, maxRank, maxTol)
            M = double(M);
            [N, L] = size(M);
            useLog = SpectralStorage.shouldUseLogDomain(M, metricName);
            fin = isfinite(M);

            if useLog
                domain = "log10";
                Y = nan(N, L);
                posFin = fin & (M > 0);
                Y(posFin) = log10(M(posFin));
                hasNan = ~all(posFin, "all");
            else
                domain = "linear";
                Y = M;
                hasNan = ~all(fin, "all");
            end

            mu = mean(Y, 1, "omitnan");
            mu(~isfinite(mu)) = 0;

            nanMask = [];
            if hasNan
                nanMask = ~isfinite(Y);
                % Fill missing entries with column mean for orthogonal projection
                [rNan, cNan] = find(nanMask);
                Y(sub2ind([N, L], rNan, cNan)) = mu(cNan);
            end

            % Batched Gram matrix G = Yc' * Yc (L x L) to avoid full [N x L] SVD memory spike
            G = zeros(L, L);
            batchRows = 20000;
            for b0 = 1:batchRows:N
                b1 = min(N, b0 + batchRows - 1);
                Yb = Y(b0:b1, :) - mu;
                G = G + (Yb' * Yb);
            end
            G = 0.5 * (G + G');

            [V, D] = eig(G, "vector");
            [svals2, ord] = sort(max(real(D), 0), "descend");
            V = V(:, ord);

            capRank = min([maxRank, L, N]);
            if maxTol > 0 && capRank > 1
                totalVar = sum(svals2);
                cumResid = max(0, totalVar - cumsum(svals2));
                rmsePerRank = sqrt(cumResid / max(1, N * L));
                hit = find(rmsePerRank(1:capRank) <= maxTol, 1, "first");
                if isempty(hit)
                    k = capRank;
                else
                    k = max(min(4, capRank), hit);
                end
            else
                k = capRank;
            end

            B = V(:, 1:k)';   % [k x L] double
            C = zeros(N, k, "single");
            for b0 = 1:batchRows:N
                b1 = min(N, b0 + batchRows - 1);
                Yb = Y(b0:b1, :) - mu;
                C(b0:b1, :) = single(Yb * B');
            end

            % Estimate actual reconstruction RMSE on a fast sample
            nSample = min(N, 5000);
            sIdx = round(linspace(1, N, nSample));
            Yhat = double(C(sIdx, :)) * B + mu;
            estRmse = sqrt(mean((Y(sIdx, :) - Yhat).^2, "all", "omitnan"));

            enc = struct( ...
                "codec", "svd", ...
                "domain", domain, ...
                "C", C, ...
                "B", B, ...
                "mu", mu, ...
                "rank", k, ...
                "rmse", estRmse, ...
                "size", [N, L], ...
                "nanMask", nanMask);

            unitLbl = ternary(domain == "log10", "dex", "abs");
            infoStr = sprintf("rank=%d/%d, RMSE=%.4g %s", k, L, estRmse, unitLbl);
        end

        function enc = writeSidecarH5(M, metricName, h5Path, groupPath, subtype)
            [N, L] = size(M);
            if ~startsWith(groupPath, "/")
                groupPath = "/" + groupPath;
            end
            dsPath = char(groupPath + "/" + string(metricName));
            h5Char = char(h5Path);

            % Ensure parent group exists and remove pre-existing dataset cleanly
            SpectralStorage.ensureH5GroupAndReplace(h5Char, char(groupPath), dsPath);

            chunkSize = [min(N, 2048), min(L, 64)];
            minVal = NaN;
            maxVal = NaN;
            domain = "linear";

            switch subtype
                case "single"
                    dataToWrite = single(M);
                    dtype = 'single';
                case "double"
                    dataToWrite = double(M);
                    dtype = 'double';
                case "log_uint16"
                    qEnc = SpectralStorage.encodeLogUint16(M, metricName);
                    dataToWrite = qEnc.q;
                    dtype = 'uint16';
                    minVal = qEnc.minVal;
                    maxVal = qEnc.maxVal;
                    domain = qEnc.domain;
            end

            h5create(h5Char, dsPath, [N, L], ...
                'Datatype', dtype, ...
                'ChunkSize', chunkSize, ...
                'Deflate', 4, ...
                'Shuffle', true);
            h5write(h5Char, dsPath, dataToWrite);

            h5writeatt(h5Char, dsPath, 'storageType', char(subtype));
            h5writeatt(h5Char, dsPath, 'domain', char(domain));
            if isfinite(minVal)
                h5writeatt(h5Char, dsPath, 'minVal', double(minVal));
                h5writeatt(h5Char, dsPath, 'maxVal', double(maxVal));
            end

            [~, fName, fExt] = fileparts(h5Path);
            enc = struct( ...
                "codec", "sidecar_h5", ...
                "h5File", string(h5Path), ...
                "h5FileName", string(fName) + string(fExt), ...
                "h5Dataset", string(dsPath), ...
                "storageType", string(subtype), ...
                "domain", string(domain), ...
                "minVal", minVal, ...
                "maxVal", maxVal, ...
                "size", [N, L]);
        end

        function writeAxisMetadataH5(h5Path, groupPath, S)
            h5Char = char(h5Path);
            if ~startsWith(groupPath, "/")
                groupPath = "/" + groupPath;
            end
            for axName = ["lambda", "RamanShift", "period", "radius"]
                if isfield(S, axName) && isnumeric(S.(axName)) && ~isempty(S.(axName))
                    arr = double(S.(axName));
                    dsPath = char(groupPath + "/" + axName);
                    SpectralStorage.ensureH5GroupAndReplace(h5Char, char(groupPath), dsPath);
                    h5create(h5Char, dsPath, size(arr), 'Datatype', 'double');
                    h5write(h5Char, dsPath, arr);
                end
            end
        end

        function ensureH5GroupAndReplace(h5Char, groupChar, dsChar)
            if ~isfile(h5Char)
                fid = H5F.create(h5Char, 'H5F_ACC_TRUNC', 'H5P_DEFAULT', 'H5P_DEFAULT');
                H5F.close(fid);
            end
            fid = H5F.open(h5Char, 'H5F_ACC_RDWR', 'H5P_DEFAULT');
            cFid = onCleanup(@() H5F.close(fid));
            try
                gid = H5G.open(fid, groupChar);
                H5G.close(gid);
            catch
                gid = H5G.create(fid, groupChar, 'H5P_DEFAULT', 'H5P_DEFAULT', 'H5P_DEFAULT');
                H5G.close(gid);
            end
            if H5L.exists(fid, dsChar, 'H5P_DEFAULT')
                H5L.delete(fid, dsChar, 'H5P_DEFAULT');
            end
        end

        function vals = decodeSidecarBlock(rawBlock, enc)
            if isfield(enc, "storageType") && string(enc.storageType) == "log_uint16"
                vals = SpectralStorage.decodeLogUint16Sub(uint16(rawBlock), enc);
            else
                vals = double(rawBlock);
            end
        end

        function p = resolveH5Path(h5File)
            p = string(h5File);
            if isfile(p)
                return;
            end
            [~, nm, ext] = fileparts(p);
            cand = fullfile(pwd, nm + ext);
            if isfile(cand)
                p = cand;
            end
        end

        function [tf, startVal, stepVal] = isUniformStride(idx)
            n = numel(idx);
            if n == 0
                tf = false; startVal = 1; stepVal = 1;
                return;
            end
            startVal = double(idx(1));
            if n == 1
                tf = true; stepVal = 1;
                return;
            end
            d = diff(double(idx));
            stepVal = d(1);
            tf = (stepVal >= 1) && all(d == stepVal);
        end
    end
end

function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end
