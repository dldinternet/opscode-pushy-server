%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2011-2012 Opscode Inc.

-module(pushy_ema2).

-include_lib("eunit/include/eunit.hrl").

%% API
-export([init/4,
         init/5,
         reset_timer/1,
         new_status/2,
         tick/1,
         inc/2,
         value/1]).


-record(ema, {acc = 0        :: integer(),
              avg = 0        :: float(),
              window = 0     :: integer(),
              tick_interval  :: integer(),
              tick_count = 0 :: integer()}).

-spec init(integer(), integer()) -> #ema{}.
init(Window, Interval, Down, Up) when Window>0 ->
    init(Window, Interval, 0.0).

-spec init(integer(), integer(), float()) -> #ema{}.
init(Window, Interval, Avg, Down, Up) when Window>0 ->
    EAvg = #ema{acc=0, avg=Avg, window=Window, tick_interval=Interval,
                 down=Down, up=Up},
    reset_timer(EAvg),
    EAvg.

reset_timer(#ema{tick_interval=I}) ->
    erlang:start_timer(I, self(), update_avg).

-spec tick(#ema{}) -> #ema{}.
tick(#ema{acc=Acc, avg=Avg, window=Window, tick_count=C}=EAvg) ->
    NAvg = (Avg * (Window-1) + Acc)/Window,
    reset_timer(EAvg),
    EAvg#ema{acc=0, avg=NAvg, tick_count=C+1}.

-spec inc(#ema{}, number()) -> #ema{}.
inc(#ema{acc=Acc}=EAvg, Count) ->
    EAvg#ema{acc=Acc+Count}.

-spec value(#ema{}) -> float().
value(#ema{avg=Avg}) ->
    Avg.

