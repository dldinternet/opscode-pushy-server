%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2011-2012 Opscode Inc.

-module(pushy_counters).
%-behaviour(gen_server).
%-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([setup_aggregate_counters/0,
         setup_counters/1,
         get_aggregate_counters/0,
         state_change/2]).

-export([mk_state/1,
         get_local_counter_details/0,
         update_counter/2]).

-include_lib("eunit/include/eunit.hrl").

-define(HEARTBEAT_STATES, [down, idle, ready, running, restarting, up, crasheds]).
-define(HEARTBEAT_STATES_TOTAL, [total | ?HEARTBEAT_STATES]).

% Set up aggregate counters to track the state of the system
% This may not be the right place for this.
%

reg(Name, Value) ->
    try
        gproc:reg(Name, Value)
    catch
        error:X ->
            ?debugVal(X),
            ?debugVal(Name),
            ?debugVal(erlang:get_stacktrace())
    end.

gpw(S) ->
    try
        gproc:add_local_aggr_counter(mk_state(S))
    catch
        error:X ->
            ?debugVal(X),
            ?debugVal(S),
            ?debugVal(erlang:get_stacktrace())
    end.

setup_aggregate_counters() ->
    try
%        [ gproc:add_local_aggr_counter(mk_state(S)) || S <- ?HEARTBEAT_STATES_TOTAL] ]
        [ gpw(S) || S <- [total | ?HEARTBEAT_STATES_TOTAL] ]
    catch
        error:X ->
            ?debugVal(X),
            ?debugVal(erlang:get_stacktrace())
    end.

get_aggregate_counters() ->
    [ {State, gproc:lookup_local_aggr_counter(mk_state(State))} || State <- ?HEARTBEAT_STATES_TOTAL ].

get_local_counter_details() ->
    [ {State, gproc:lookup_local_counters(mk_state(State))} || State <- ?HEARTBEAT_STATES_TOTAL ].

setup_counters(State) ->
    try 
        [ reg(mk_counter(S), 0) || S <- ?HEARTBEAT_STATES_TOTAL ],
        update_counter(State,1),
        update_counter(total,1)
    catch
        error:X ->
            ?debugVal(X),
            ?debugVal(erlang:get_stacktrace())
    end.

state_change(Old, New) ->
    update_counter(Old, -1),
    update_counter(New,  1).

update_counter(State, Incr) ->
    try
        gproc:update_counter(mk_cname(State),  Incr)
    catch
        error:X ->
            ?debugVal(gproc:lookup_local_counters(mk_state(State))),
            ?debugVal(X),
            ?debugVal(erlang:get_stacktrace())
    end.

mk_cname(State) ->
    {c, l, mk_state(State)}.

state_map(total) -> total;
state_map(crashed) -> crashed;
state_map(up) -> up;
state_map(down) -> down;
state_map(idle) -> idle;
state_map(ready) -> ready;
state_map(restarting) -> restarting;
state_map(running) -> running.

mk_state(State) ->
    {node_state, state_map(State)}.

%%mk_aggr_counter(State) ->
%%    {a, l, {node_state, state_map(State)}}.
mk_counter(State) ->
    {c, l, {node_state, state_map(State)}}.
