function rgb = hex2rgb(hex)
% HEX2RGB Convert hexadecimal color string to 1-by-3 [R G B] double in [0, 1].
%
%   rgb = hex2rgb(hex) converts strings such as "#38bdf8" or "38bdf8"
%   to normalized RGB triplets [r, g, b].
%
%   See also: HEX2DEC

    hex = char(hex);
    if isempty(hex)
        rgb = [0 0 0];
        return;
    end
    if hex(1) == '#'
        hex = hex(2:end);
    end
    if numel(hex) < 6
        rgb = [0.5 0.5 0.5];
        return;
    end
    rgb = [hex2dec(hex(1:2)), hex2dec(hex(3:4)), hex2dec(hex(5:6))] / 255;
end
