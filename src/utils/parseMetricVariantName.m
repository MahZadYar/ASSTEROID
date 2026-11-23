function info = parseMetricVariantName(inputStr, options)
%parseMetricVariantName Parse a metric field name or variant token uniformly.
%
%   info = parseMetricVariantName(inputStr) parses either:
%     - A derived metric field name (e.g., "EE_V_H2S", "EE_V_broad", "Abs_laser")
%     - Legacy explicit analyte field (e.g., "EE_V_analyte_H2S")
%     - A bare base metric name     (e.g., "EE_V", "EF_vol", "Abs", "EF_max")
%     - A variant token             (e.g., "laser", "broad", "analyte", "H2S")
%
%   Returned struct fields:
%       raw            - Trimmed original string
%       isVariantToken - True when input is purely a variant selector token
%       isDerived      - True when input encodes a scalar/derived variant
%       baseRaw        - Extracted base name before variant suffix ("" for variant tokens)
%       baseCanonical  - Canonicalized base metric name (when known, else baseRaw)
%       variant        - Canonical variant token ("", "laser", "broad", "avg", "analyte", "<KEY>")
%       variantKind    - "spectral" | "laser" | "broad" | "analyte"
%       analyteKey     - Exact analyte suffix key (e.g. "H2S"), or ""
%       suffixRaw      - Exact matched suffix starting with "_" (or "")
%
%   See also: canonicalMetricName, resolveDerivedMetricField, normalizeMetricNames

    arguments
        inputStr (1,1) string
        options.IsVariantToken (1,1) logical = false
        options.KnownAnalyteKeys (1,:) string = string.empty
    end

    s = strtrim(inputStr);
    info = struct( ...
        "raw",            s, ...
        "isVariantToken", false, ...
        "isDerived",      false, ...
        "baseRaw",        "", ...
        "baseCanonical",  "", ...
        "variant",        "", ...
        "variantKind",    "spectral", ...
        "analyteKey",     "", ...
        "suffixRaw",      "");

    if strlength(s) == 0
        return;
    end

    sl = lower(s);
    knownKeys = getKnownAnalyteKeyList(options.KnownAnalyteKeys);
    bareMetricTokens = [ ...
        "ef_max", "e4_max", "m2_max", "ee_v", "ee_s", "ef_vol", "ef_surf", ...
        "abs", "absorptance", "ecc", "eccheck", "reflectance", "transmittance", ...
        "m_vol", "m_surf", "m2_vol", "m2_surf", "e_vol", "e_surf", ...
        "ef_vol_m", "ef_surf_m", "ef_abs", "kappa_v", "kappa_s", ...
        "s_corr", "v_corr", "volcorr", "surfcorr", ...
        "p_um", "r_um", "lambda_um", "lambda_nm", "lambda_exc_nm", ...
        "intw_vol", "intw_t", "resistiveloss", "skindepth"];

    % 1. Pure standard variant tokens
    if sl == "laser"
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = "laser";
        info.variantKind    = "laser";
        return;
    elseif sl == "broad" || sl == "broadband"
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = "broad";
        info.variantKind    = "broad";
        return;
    elseif sl == "avg"
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = "avg";
        info.variantKind    = "broad";
        return;
    elseif sl == "analyte" || sl == "weighted"
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = "analyte";
        info.variantKind    = "analyte";
        return;
    elseif sl == "approx"
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = "laser";
        info.variantKind    = "laser";
        return;
    end

    % 1b. Legacy analyte_<KEY> / weighted_<KEY> variant tokens -> canonical <KEY>
    tokMatch = regexp(char(s), '^(?:analyte|weighted)_([A-Za-z0-9][A-Za-z0-9_]*)$', 'tokens', 'ignorecase', 'once');
    if ~isempty(tokMatch)
        key = string(tokMatch{1});
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = key;
        info.variantKind    = "analyte";
        info.analyteKey     = key;
        return;
    end

    % 1c. Bare analyte key token matching registered/built-in keys or explicit IsVariantToken mode
    knownIdx = find(strcmpi(s, knownKeys), 1);
    if ~isempty(knownIdx)
        key = knownKeys(knownIdx);
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = key;
        info.variantKind    = "analyte";
        info.analyteKey     = key;
        return;
    end
    if options.IsVariantToken && ~any(sl == bareMetricTokens) && ...
            ~isempty(regexp(char(s), '^[A-Za-z][A-Za-z0-9_]*$', 'once'))
        info.isVariantToken = true;
        info.isDerived      = true;
        info.variant        = s;
        info.variantKind    = "analyte";
        info.analyteKey     = s;
        return;
    end

    % 2. Legacy standalone derived names (BEE_vol, BEE_surf, AEE_vol, AEE_surf)
    if sl == "bee_vol" || sl == "bee_surf" || sl == "aee_vol" || sl == "aee_surf"
        info.isDerived = true;
        info.baseRaw = s;
        if contains(sl, "vol")
            info.baseCanonical = "EE_V";
        else
            info.baseCanonical = "EE_S";
        end
        if startsWith(sl, "bee_")
            info.variant = "broad";
            info.variantKind = "broad";
        else
            info.variant = "analyte";
            info.variantKind = "analyte";
        end
        return;
    end

    % 3. Legacy specific analyte field suffix: <base>_analyte_<KEY> or <base>_weighted_<KEY>
    mKey = regexp(char(s), '^(?<base>.+?)_(?<pfx>analyte|weighted)_(?<key>[A-Za-z0-9][A-Za-z0-9_]*)$', 'names', 'ignorecase', 'once');
    if ~isempty(mKey)
        key = canonicalKeyCase(string(mKey.key), knownKeys);
        info.isDerived     = true;
        info.baseRaw       = string(mKey.base);
        info.baseCanonical = canonicalizeBaseToken(info.baseRaw);
        info.variant       = key;
        info.variantKind   = "analyte";
        info.analyteKey    = key;
        info.suffixRaw     = "_" + string(mKey.pfx) + "_" + key;
        return;
    end

    % 4. Standard derived field suffixes
    mStd = regexp(char(s), '^(?<base>.+?)(?<suffix>_(?:analyte|weighted|broadband|broad|avg|laser|approx))$', 'names', 'ignorecase', 'once');
    if ~isempty(mStd)
        sfxLower = lower(string(mStd.suffix));
        info.isDerived     = true;
        info.baseRaw       = string(mStd.base);
        info.baseCanonical = canonicalizeBaseToken(info.baseRaw);
        info.suffixRaw     = string(mStd.suffix);
        switch sfxLower
            case {"_analyte", "_weighted"}
                info.variant     = "analyte";
                info.variantKind = "analyte";
            case {"_broad", "_broadband"}
                info.variant     = "broad";
                info.variantKind = "broad";
            case "_avg"
                info.variant     = "avg";
                info.variantKind = "broad";
            case {"_laser", "_approx"}
                info.variant     = "laser";
                info.variantKind = "laser";
        end
        return;
    end

    % 5. Bare multi-word metric/metadata fields (never split as derived analytes)
    if any(sl == bareMetricTokens)
        info.baseRaw       = s;
        info.baseCanonical = canonicalizeBaseToken(s);
        return;
    end

    % 6. Direct keyed analyte field <base>_<KEY> (e.g., EE_V_H2S, EF_max_CH4, EE_V_CO_probe)
    % 6a. Known analyte keys matching any base metric prefix (including custom COMSOL metrics)
    for ki = 1:numel(knownKeys)
        kk = knownKeys(ki);
        sfx = "_" + kk;
        if strlength(s) > strlength(sfx) && endsWith(sl, lower(sfx))
            basePart = extractBefore(s, strlength(s) - strlength(sfx) + 1);
            if strlength(basePart) > 0
                info.isDerived     = true;
                info.baseRaw       = basePart;
                info.baseCanonical = canonicalizeBaseToken(basePart);
                info.variant       = kk;
                info.variantKind   = "analyte";
                info.analyteKey    = kk;
                info.suffixRaw     = extractAfter(s, strlength(basePart));
                return;
            end
        end
    end

    % 6b. Known base metric prefix + arbitrary valid <KEY> suffix (cold sessions with unloaded custom keys)
    knownBasePrefixes = [ ...
        "Absorptance", "Transmittance", "Reflectance", "ECCheck", ...
        "EF_max", "E4_max", "M2_max", "EF_vol", "EF_surf", "M2_vol", "M2_surf", ...
        "EE_V", "EE_S", "M_vol", "M_surf", "E_vol", "E_surf", "Abs", "ECC"];
    reservedModifiers = [ ...
        "laser", "broad", "broadband", "avg", "analyte", "weighted", "approx", ...
        "m", "max", "min", "um", "nm", "cm", "vol", "surf", "abs", "raw", ...
        "norm", "corr", "grid", "std", "mean", "median", "rmse", "mae", "r2"];
    for bp = knownBasePrefixes
        pref = bp + "_";
        if strlength(s) > strlength(pref) && startsWith(sl, lower(pref))
            rawBase = extractBefore(s, strlength(pref));
            keyPart = extractAfter(s, strlength(pref));
            if ~isempty(regexp(char(keyPart), '^[A-Za-z][A-Za-z0-9_]*$', 'once')) ...
                    && ~any(strcmpi(keyPart, reservedModifiers))
                keyPart = canonicalKeyCase(keyPart, knownKeys);
                info.isDerived     = true;
                info.baseRaw       = rawBase;
                info.baseCanonical = canonicalizeBaseToken(rawBase);
                info.variant       = keyPart;
                info.variantKind   = "analyte";
                info.analyteKey    = keyPart;
                info.suffixRaw     = "_" + keyPart;
                return;
            end
        end
    end

    % 7. Un-derived spectral or scalar metric name
    info.baseRaw       = s;
    info.baseCanonical = canonicalizeBaseToken(s);
end

function keys = getKnownAnalyteKeyList(extraKeys)
    try
        regKeys = knownAnalyteKeysRegistry("list");
    catch
        regKeys = ["CH4", "C2H4", "H2S", "NH3", "C2H2", "H2O"];
    end
    keys = unique([regKeys, strtrim(string(extraKeys(:)'))], "stable");
    keys = keys(strlength(keys) > 0);
end

function key = canonicalKeyCase(rawKey, knownKeys)
    idx = find(strcmpi(rawKey, knownKeys), 1);
    if ~isempty(idx)
        key = knownKeys(idx);
    else
        key = rawKey;
    end
end

function out = canonicalizeBaseToken(baseStr)
    key = regexprep(lower(string(baseStr)), '[^a-z0-9_]', '');
    switch key
        case {"ee_v", "eev", "ee_vol", "eevol", "ef_vol", "efvol", "bee_vol", "aee_vol"}
            out = "EE_V";
        case {"ee_s", "ees", "ee_surf", "eesurf", "ef_surf", "efsurf", "bee_surf", "aee_surf"}
            out = "EE_S";
        case {"ef_max", "efmax", "m2_max", "m2max", "ef_laser_max", "e4_max", "e4max"}
            out = "EF_max";
        case {"abs", "absorptance"}
            out = "Abs";
        case {"ecc", "eccheck"}
            out = "ECC";
        case {"kappa_v", "kappav", "v_corr", "volcorr"}
            out = "kappa_V";
        case {"kappa_s", "kappas", "s_corr", "surfcorr"}
            out = "kappa_S";
        otherwise
            out = string(baseStr);
    end
end
