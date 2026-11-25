function style = applyAssteroidPlotStyle(target, options)
%APPLYASSTEROIDPLOTSTYLE Enforce OKHSL swatches and 6-9 pt Fira Sans / Fira Math typography.
%
%   style = applyAssteroidPlotStyle(target) normalizes fonts, sizes (6-9 pt),
%   weights, and OKHSL contrast hierarchy across figures, uifigures, panels,
%   tiledlayouts, axes, colorbars, legends, and annotations in ASSTEROID.
%
%   Sizes enforced per Rule 05 Section 8:
%     - Tick numbers (axes & colorbar):  7 pt, Regular
%     - Notes, callouts, annotations:    7 pt, Bold (clamped within 6-9 pt)
%     - Legends:                         8 pt, Regular
%     - Axis & colorbar labels:          8 pt, Bold
%     - Titles:                          9 pt, Bold

    arguments
        target = gcf
        options.Theme (1,1) string {mustBeMember(options.Theme, ["auto", "dark", "light"])} = "auto"
        options.ApplyColors (1,1) logical = true
        options.WrapPlainText (1,1) logical = true
        options.WrapAutoTicks (1,1) logical = false
    end

    style = localBuildStyleSpec();

    if isempty(target)
        return;
    end

    rootList = target(:);
    for r = 1:numel(rootList)
        hRoot = rootList(r);
        if isempty(hRoot) || ~isvalid(hRoot)
            continue;
        end
        localStyleRoot(hRoot, style, options);
    end
end

function style = localBuildStyleSpec()
    style = struct();
    style.fontText = "Fira Sans";
    style.fontMath = "Fira Math Light";
    style.fontMathBold = "Fira Math SemiBold";
    style.fontSize = struct( ...
        "min",       6, ...
        "max",       9, ...
        "tick",      7, ...
        "cbarTick",  7, ...
        "annot",     7, ...
        "subtitle",  7, ...
        "legend",    8, ...
        "axisLabel", 8, ...
        "cbarLabel", 8, ...
        "title",     9);

    % OKHSL swatch tokens (palette.json)
    style.colors = struct( ...
        "W",    [255, 255, 255] / 255, ...
        "K",    [  0,   0,   0] / 255, ...
        "A12",  [  2,   0,  35] / 255, ...
        "A15",  [  3,   0,  51] / 255, ...
        "A20",  [  8,   0,  80] / 255, ...
        "A40",  [ 36,  30, 195] / 255, ...
        "A50",  [ 56,  74, 224] / 255, ...
        "A80",  [167, 187, 249] / 255, ...
        "B50",  [127,   0, 224] / 255, ...
        "C60",  [ 39, 146, 141] / 255, ...
        "C70",  [ 72, 178, 172] / 255, ...
        "C80",  [107, 209, 203] / 255, ...
        "D70",  [201, 148,  44] / 255, ...
        "D80",  [235, 179,  79] / 255, ...
        "G40",  [ 72,  72,  72] / 255, ...
        "G60",  [128, 128, 128] / 255, ...
        "G70",  [158, 158, 158] / 255, ...
        "G80",  [190, 190, 190] / 255, ...
        "G98",  [248, 248, 248] / 255);
end

function localStyleRoot(hRoot, style, options)
    if isa(hRoot, "matlab.ui.Figure")
        figTheme = localResolveTheme(hRoot, options.Theme);
        if options.ApplyColors && figTheme == "light" && isprop(hRoot, "Color")
            hRoot.Color = style.colors.W;
        end
        if isprop(hRoot, "Theme")
            try
                if figTheme == "light"
                    hRoot.Theme = "light";
                end
            catch
            end
        end
    end

    % Style tiledlayout headings
    tList = findall(hRoot, "Type", "tiledlayout");
    if isa(hRoot, "matlab.graphics.layout.TiledChartLayout")
        tList = unique([hRoot; tList(:)]);
    end
    for k = 1:numel(tList)
        localStyleTiledLayout(tList(k), style, options);
    end

    % Style axes & uiaxes
    axList = findall(hRoot, "Type", "axes");
    if isgraphics(hRoot, "axes") || isa(hRoot, "matlab.ui.control.UIAxes")
        axList = unique([hRoot; axList(:)]);
    end
    for k = 1:numel(axList)
        localStyleAxes(axList(k), style, options);
    end

    % Style colorbars
    cbList = findall(hRoot, "Type", "colorbar");
    for k = 1:numel(cbList)
        localStyleColorbar(cbList(k), style, options);
    end

    % Style legends
    legList = findall(hRoot, "Type", "legend");
    for k = 1:numel(legList)
        localStyleLegend(legList(k), style, options);
    end

    % Clamp annotation textboxes into [6, 9] pt Fira Sans
    annList = findall(hRoot, "Type", "textboxshape");
    for k = 1:numel(annList)
        localClampTextObj(annList(k), style, options);
    end
end

function theme = localResolveTheme(hObj, requested)
    if requested ~= "auto"
        theme = requested;
        return;
    end
    bg = [];
    if isprop(hObj, "Color") && isnumeric(hObj.Color) && numel(hObj.Color) == 3
        bg = hObj.Color;
    elseif isprop(hObj, "BackgroundColor") && isnumeric(hObj.BackgroundColor) && numel(hObj.BackgroundColor) == 3
        bg = hObj.BackgroundColor;
    end
    if isempty(bg)
        ancPanel = ancestor(hObj, "matlab.ui.container.Panel");
        if ~isempty(ancPanel) && isvalid(ancPanel) && isnumeric(ancPanel.BackgroundColor) && numel(ancPanel.BackgroundColor) == 3
            bg = ancPanel.BackgroundColor;
        end
    end
    if isempty(bg)
        ancFig = ancestor(hObj, "figure");
        if ~isempty(ancFig) && isvalid(ancFig) && isprop(ancFig, "Color") && isnumeric(ancFig.Color) && numel(ancFig.Color) == 3
            bg = ancFig.Color;
        end
    end
    if ~isempty(bg) && mean(bg) < 0.5
        theme = "dark";
    else
        theme = "light";
    end
end

function localStyleTiledLayout(t, style, options)
    theme = localResolveTheme(t, options.Theme);
    ink = style.colors.K;
    if theme == "dark", ink = style.colors.G98; end

    if isprop(t, "Title") && ~isempty(t.Title) && isvalid(t.Title)
        t.Title.FontName = style.fontText;
        t.Title.FontSize = style.fontSize.title;
        t.Title.FontWeight = "bold";
        if options.ApplyColors, t.Title.Color = ink; end
    end
    if isprop(t, "Subtitle") && ~isempty(t.Subtitle) && isvalid(t.Subtitle)
        t.Subtitle.FontName = style.fontText;
        t.Subtitle.FontSize = style.fontSize.subtitle;
        if options.ApplyColors, t.Subtitle.Color = ink; end
    end
    for pName = ["XLabel", "YLabel"]
        if isprop(t, pName) && ~isempty(t.(pName)) && isvalid(t.(pName))
            lbl = t.(pName);
            lbl.FontName = style.fontText;
            lbl.FontSize = style.fontSize.axisLabel;
            lbl.FontWeight = "bold";
            if options.ApplyColors, lbl.Color = ink; end
        end
    end
end

function localStyleAxes(ax, style, options)
    if isempty(ax) || ~isvalid(ax)
        return;
    end
    theme = localResolveTheme(ax, options.Theme);

    ax.FontName = style.fontText;
    ax.FontSize = style.fontSize.tick;
    ax.FontWeight = "normal";

    % Enforce 7 pt Regular on X/Y/Z rulers (including dual-Y rulers)
    if isprop(ax, "XAxis") && ~isempty(ax.XAxis)
        ax.XAxis.FontName = style.fontText;
        ax.XAxis.FontSize = style.fontSize.tick;
        ax.XAxis.FontWeight = "normal";
    end
    if isprop(ax, "YAxis") && ~isempty(ax.YAxis)
        for yi = 1:numel(ax.YAxis)
            ax.YAxis(yi).FontName = style.fontText;
            ax.YAxis(yi).FontSize = style.fontSize.tick;
            ax.YAxis(yi).FontWeight = "normal";
        end
    end
    if isprop(ax, "ZAxis") && ~isempty(ax.ZAxis)
        ax.ZAxis.FontName = style.fontText;
        ax.ZAxis.FontSize = style.fontSize.tick;
        ax.ZAxis.FontWeight = "normal";
    end

    if options.WrapAutoTicks
        localWrapAxisTicks(ax);
    end

    % Theme colors without clobbering dark canvas colors expected by UI & tests
    if options.ApplyColors
        if theme == "light"
            ax.Color = style.colors.W;
            ax.XColor = style.colors.K;
            if numel(ax.YAxis) == 1
                ax.YColor = style.colors.K;
            end
            if isprop(ax, "ZColor"), ax.ZColor = style.colors.K; end
            ax.GridColor = style.colors.G70;
            ax.GridAlpha = 0.45;
            if isprop(ax, "MinorGridColor")
                ax.MinorGridColor = style.colors.G80;
                ax.MinorGridAlpha = 0.30;
            end
        else
            if isnumeric(ax.Color) && mean(ax.Color) >= 0.5
                ax.Color = style.colors.A15;
            end
        end
    end

    % Labels (8 pt Bold), Title (9 pt Bold), Subtitle (7 pt Regular)
    labelInk = style.colors.K;
    if theme == "dark", labelInk = style.colors.G98; end

    for r = 1:numel(ax.YAxis)
        if isprop(ax.YAxis(r), "Label") && isvalid(ax.YAxis(r).Label)
            yl = ax.YAxis(r).Label;
            yl.FontName = style.fontText;
            yl.FontSize = style.fontSize.axisLabel;
            yl.FontWeight = "bold";
            if options.ApplyColors && theme == "light"
                yl.Color = labelInk;
            end
            if options.WrapPlainText, localWrapPlainStringProp(yl); end
        end
    end

    for pName = ["XLabel", "ZLabel"]
        if isprop(ax, pName) && isvalid(ax.(pName))
            lbl = ax.(pName);
            lbl.FontName = style.fontText;
            lbl.FontSize = style.fontSize.axisLabel;
            lbl.FontWeight = "bold";
            if options.ApplyColors && theme == "light"
                lbl.Color = labelInk;
            end
            if options.WrapPlainText, localWrapPlainStringProp(lbl); end
        end
    end

    if isprop(ax, "Title") && isvalid(ax.Title)
        ttl = ax.Title;
        ttl.FontName = style.fontText;
        ttl.FontSize = style.fontSize.title;
        ttl.FontWeight = "bold";
        if options.ApplyColors && theme == "light"
            ttl.Color = labelInk;
        end
        if options.WrapPlainText, localWrapPlainStringProp(ttl); end
    end

    if isprop(ax, "Subtitle") && isvalid(ax.Subtitle)
        sub = ax.Subtitle;
        sub.FontName = style.fontText;
        sub.FontSize = style.fontSize.subtitle;
        if options.WrapPlainText, localWrapPlainStringProp(sub); end
    end

    % In-axes text annotations (notes/callouts -> 7 pt Bold clamped 6-9 pt)
    txtObjs = findall(ax, "Type", "text");
    for k = 1:numel(txtObjs)
        localClampTextObj(txtObjs(k), style, options);
    end
    clObjs = findall(ax, "Type", "constantline");
    for k = 1:numel(clObjs)
        if isprop(clObjs(k), "FontName"), clObjs(k).FontName = style.fontText; end
        if isprop(clObjs(k), "FontSize"), clObjs(k).FontSize = style.fontSize.annot; end
        if isprop(clObjs(k), "FontWeight"), clObjs(k).FontWeight = "bold"; end
    end
end

function localStyleColorbar(cb, style, options)
    if isempty(cb) || ~isvalid(cb), return; end
    cb.FontName = style.fontText;
    cb.FontSize = style.fontSize.cbarTick;
    if isprop(cb, "FontWeight"), cb.FontWeight = "normal"; end
    if isprop(cb, "Label") && ~isempty(cb.Label) && isvalid(cb.Label)
        cb.Label.FontName = style.fontText;
        cb.Label.FontSize = style.fontSize.cbarLabel;
        cb.Label.FontWeight = "bold";
    end
    if options.WrapAutoTicks
        localWrapColorbarTicks(cb);
    end
end

function localStyleLegend(leg, style, options)
    if isempty(leg) || ~isvalid(leg), return; end
    leg.FontName = style.fontText;
    leg.FontSize = style.fontSize.legend;
    leg.FontWeight = "normal";

    % Guard against Qt PNG bold rasterization bug only when Interpreter == "tex"
    if options.WrapPlainText && isprop(leg, "Interpreter") && strcmpi(leg.Interpreter, "tex")
        if iscell(leg.String)
            for idx = 1:numel(leg.String)
                leg.String{idx} = char(localSafeTexPrefix(string(leg.String{idx})));
            end
        elseif isstring(leg.String)
            for idx = 1:numel(leg.String)
                leg.String(idx) = localSafeTexPrefix(leg.String(idx));
            end
        end
    end
end

function localClampTextObj(t, style, options)
    if isempty(t) || ~isvalid(t), return; end
    if isprop(t, "FontName"), t.FontName = style.fontText; end
    if isprop(t, "FontSize")
        fs = double(t.FontSize);
        if ~isfinite(fs) || fs < style.fontSize.min || fs > style.fontSize.max
            t.FontSize = style.fontSize.annot;
        end
    end
    if options.WrapPlainText && isprop(t, "FontWeight") && strcmpi(t.FontWeight, "normal")
        localWrapPlainStringProp(t);
    end
end

function localWrapAxisTicks(ax)
    if ~isprop(ax, "TickLabelInterpreter") || ~strcmpi(ax.TickLabelInterpreter, "tex")
        return;
    end
    if ~isempty(ax.XTickLabel)
        lbls = string(ax.XTickLabel);
        for i = 1:numel(lbls)
            lbls(i) = localSafeTexPrefix(lbls(i));
        end
        ax.XTickLabel = cellstr(lbls);
    end
    for r = 1:numel(ax.YAxis)
        if ~isempty(ax.YAxis(r).TickLabels)
            lbls = string(ax.YAxis(r).TickLabels);
            for i = 1:numel(lbls)
                lbls(i) = localSafeTexPrefix(lbls(i));
            end
            ax.YAxis(r).TickLabels = cellstr(lbls);
        end
    end
end

function localWrapColorbarTicks(cb)
    if isprop(cb, "TickLabelInterpreter") && strcmpi(cb.TickLabelInterpreter, "tex") ...
            && isprop(cb, "TickLabels") && ~isempty(cb.TickLabels)
        lbls = string(cb.TickLabels);
        for i = 1:numel(lbls)
            lbls(i) = localSafeTexPrefix(lbls(i));
        end
        cb.TickLabels = cellstr(lbls);
    end
end

function localWrapPlainStringProp(obj)
    if ~isprop(obj, "String") || ~isprop(obj, "Interpreter") || ~strcmpi(obj.Interpreter, "tex")
        return;
    end
    if isstring(obj.String) || ischar(obj.String)
        s = string(obj.String);
        for i = 1:numel(s)
            s(i) = localSafeTexPrefix(s(i));
        end
        if ischar(obj.String), obj.String = char(s); else, obj.String = s; end
    end
end

function out = localSafeTexPrefix(s)
    if strlength(s) == 0 || startsWith(s, "{}") || contains(s, ["\", "{", "}", "^", "_"])
        out = s;
    else
        out = "{}" + s;
    end
end
