
-module(linear_regression).

-export([fit/1, fit/2, fit_sums/6]).

%% Compute the {Slope, Intercept, CorrelationCoefficient} of a simple linear
%% regression fit to a list of pairs of numbers.
-spec fit(list(tuple())) -> {number(), number(), number()}.
fit(Pairs) ->
    {Xs, Ys} = lists:unzip(Pairs),
    fit(Xs, Ys).

-spec fit(list(number()), list(number())) -> {number(), number(), number()} | undefined.
fit(Xs, Ys) when length(Xs) == length(Ys), length(Xs) > 1 ->
    XMean = mean(Xs),
    XStd = std(Xs),
    YMean = mean(Ys),
    YStd = std(Ys),
    CC = corr_coef(Xs, Ys),
    Slope = CC * YStd / XStd,
    Intercept = YMean - Slope * XMean,
    {Slope, Intercept, CC};

fit(_Xs, _Ys) ->
    undefined.

%% Compute the {Slope, Intercept, CorrelationCoefficient} of a simple linear
%% regression fit from intermediate sums that are suitable for a trace data
%% snapshot.
-spec fit_sums(integer(), number(), number(), number(), number(), number()) ->
              {number(), number(), number()} | undefined.
fit_sums(N, SumX, SumY, SumXSquared, SumYSquared, SumXY) when N > 1 ->
    MeanX = SumX/N,
    MeanY = SumY/N,
    MeanXSq = SumXSquared/N,
    MeanCross = SumXY/N,

    Rise = (MeanCross - MeanX*MeanY),
    Run = (MeanXSq - MeanX*MeanX),

    DiffXSq = (SumXSquared - MeanX*SumX),
    DiffYSq = (SumYSquared - MeanY*SumY),

    %% When all of the X values are the same, Run and DiffXSq will be 0
    %% and the linear regression fit is not well-defined.

    if
        Run > 0.0, DiffXSq >= 0.0, DiffYSq >= 0.0 ->
            Slope = Rise/Run,
            Intercept = MeanY - Slope * MeanX,
            StdX = math:sqrt(DiffXSq/(N-1)),
            StdY = math:sqrt(DiffYSq/(N-1)),
            CC = Slope * StdX / StdY,
            {Slope, Intercept, CC};
        true ->
            undefined
    end;

fit_sums(_N, _SumX, _SumY, _SumXSquared, _SumYSquared, _SumXY) ->
    undefined.



%% Internal mathematical functions.

%% Mean value of a list of numbers.
mean(Values) ->
    mean1(Values, 0, 0).

mean1([], 0, _Sum) ->
    undefined;
mean1([], N, Sum) ->
    Sum/N;
mean1([V|Vs], N, Sum) ->
    mean1(Vs, N + 1, Sum + V).

%% Standard deviation of a list of numbers.
std(Values) ->
    std_with_mean(Values, mean(Values)).

std_with_mean(Values, Mean) ->
    std_with_mean1(Values, Mean, 0, 0).

std_with_mean1([], _Mean, N, _SquareSum) when N < 2 ->
    undefined;
std_with_mean1([], _Mean, N, SquareSum) ->
    math:sqrt(SquareSum/(N - 1));
std_with_mean1([V|Vs], Mean, N, SquareSum) ->
    VSubMean = V - Mean,
    std_with_mean1(Vs, Mean, N + 1, SquareSum + VSubMean*VSubMean).
    

%% Correlation coefficient of a pair of lists of numbers {[x1, x2, ...], [y1, y2, ...]}.
corr_coef(Xs, Ys) ->
    XMean = mean(Xs),
    YMean = mean(Ys),
    XStd = std_with_mean(Xs, XMean),
    YStd = std_with_mean(Ys, YMean),
    corr_coef1(Xs, Ys, XMean, YMean, XStd, YStd, 0, 0).

corr_coef1([], _Ys, _XMean, _YMean, _XStd, _YStd, N, _CrossSum) when N < 2 ->
    undefined;
corr_coef1([], _Ys, XMean, YMean, XStd, YStd, N, CrossSum) ->
    (CrossSum - N * XMean * YMean)/((N - 1) * XStd * YStd);
corr_coef1(_Xs, [], XMean, YMean, XStd, YStd, N, CrossSum) ->
    corr_coef1([], [], XMean, YMean, XStd, YStd, N, CrossSum);
corr_coef1([X|Xs], [Y|Ys], XMean, YMean, XStd, YStd, N, CrossSum) ->
    corr_coef1(Xs, Ys, XMean, YMean, XStd, YStd, N + 1, CrossSum + X * Y).

