function r = ternaryVal(cond, trueVal, falseVal)
% TERNARYVAL Conditional ternary evaluator supporting values or lazy closures.
%
%   r = ternaryVal(cond, trueVal, falseVal) returns trueVal if cond is true,
%   and falseVal otherwise. If either trueVal or falseVal is a function_handle,
%   it is evaluated lazily (called with zero arguments) only if its corresponding
%   branch is chosen.
%
%   Examples:
%       v = ternaryVal(isfield(s, 'x'), @() s.x, 0);
%       v = ternaryVal(flag, "yes", "no");
%
%   See also: IF, EVAL

    if cond
        if isa(trueVal, 'function_handle')
            r = trueVal();
        else
            r = trueVal;
        end
    else
        if isa(falseVal, 'function_handle')
            r = falseVal();
        else
            r = falseVal;
        end
    end
end
