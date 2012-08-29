%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%%
%% @author Mark Anderson <mark@opscode.com>
%% @author John Keiser <john@opscode.com>
%%
%% @copyright 2012 Opscode Inc.
%% @end

%%
%% @doc simple FSM for tracking node heartbeats and thus up/down status
%%
-module(pushy_node_state2).

-behaviour(gen_fsm).

%% API
-export([current_state/1,
         heartbeat/1,
         set_logging/2,
         start_link/1,
         start_link/2]).

-export([up/2,
         down/2]).

%% Observers
-export([subscribe/1,
         unsubscribe/1]).

-define(SAVE_MODE, gen_server). % direct or gen_server
-define(NO_NODE, {error, no_node}).

%% gen_fsm callbacks
-export([code_change/4,
         handle_event/3,
         handle_info/3,
         handle_sync_event/4,
         init/1,
         init/2,
         terminate/3]).

-include("pushy.hrl").
-include("pushy_sql.hrl").

-include_lib("eunit/include/eunit.hrl").

-type logging_level() :: 'verbose' | 'normal'.

-type eavg() :: any().

-define(DEFAULT_DECAY_INTERVAL, 4).
-define(DEFAULT_UP_THRESHOLD, 0.5).
-define(DEFAULT_DOWN_THRESHOLD, 0.4).

-record(state, {node_ref              :: node_ref(),
                heartbeat_interval    :: integer(),
                decay_window          :: integer(),
                logging = normal      :: logging_level(),
                current_status = down :: node_status(),
                heartbeats_rcvd = 0   :: integer(),
                down_thresh           :: float(),
                up_thresh             :: float(),
                tref,
                heartbeat_rate   :: eavg()
               }).

%%%
%%% External API
%%%
-spec start_link(node_ref() ) -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link(NodeRef) ->
    start_link(NodeRef, down).

-spec start_link(node_ref(), 'up' | 'down' ) -> 'ignore' | {'error',_} | {'ok',pid()}.
start_link(NodeRef, StartState) ->
    gen_fsm:start_link(?MODULE, {NodeRef, StartState}, []).

-spec heartbeat(node_ref()) -> 'ok'.
heartbeat(NodeRef) ->
    Pid = pushy_node_state_sup:get_process(NodeRef),
    gen_fsm:send_event(Pid, heartbeat).

-spec current_state(node_ref()) -> node_status().
current_state(NodeRef) ->
    Pid = pushy_node_state_sup:get_process(NodeRef),
    gen_fsm:sync_send_all_state_event(Pid, current_state, infinity).

-spec set_logging(node_ref(), logging_level()) -> ok.
set_logging(NodeRef, Level) when Level =:= verbose orelse Level =:= normal ->
    Pid = pushy_node_state_sup:get_process(NodeRef),
    gen_fsm:send_all_state_event(Pid, {logging, Level}).

-spec start_watching(node_ref()) -> true.
 subscribe(NodeRef) ->
    gproc:reg(subscribers_key(NodeRef)).

-spec stop_watching(node_ref()) -> true.
unsubscribe(NodeRef) ->
    try
        gproc:unreg(subscribers_key(NodeRef))
    catch error:badarg ->
            ok
    end.

init({NodeRef,StartState}) ->
    init(NodeRef,StartState);
init(NodeRef) ->
    init(NodeRef, down).
%
% This is split into two phases: an 'upper half' to get the minimimal work done required to wire things up
% and a 'lower half' that takes care of things that can wait
%
init(NodeRef, StartState) ->
    GprocName = pushy_node_state_sup:mk_gproc_name(NodeRef),
    try
        %% The most important thing to have happen is this registration; we need to get this
        %% assigned before anyone else tries to start things up gproc:reg can only return
        %% true or throw
        true = gproc:reg({n, l, GprocName}),
        HeartbeatInterval = pushy_util:get_env(pushy, heartbeat_interval, fun is_integer/1),
        DecayWindow = pushy_util:get_env(pushy, decay_window, ?DEFAULT_DECAY_INTERVAL, fun is_integer/1),
        Up = pushy_util:get_env(pushy, up_threshold, ?DEFAULT_UP_THRESHOLD, any), %% TODO constrain to float
        Down = pushy_util:get_env(pushy, down_threshold, ?DEFAULT_DOWN_THRESHOLD, any), %% TODO constrain to float

        InitAvg = case StartState of
                      up -> 1.0;
                      down -> 0.0
                  end,

        State = #state{node_ref = NodeRef,
                       decay_window = DecayWindow,
                       heartbeat_interval = HeartbeatInterval,
                       up_thresh=Up,
                       down_thresh=Down,
                       heartbeat_rate = pushy_ema2:init(DecayWindow, HeartbeatInterval, InitAvg, Up, Down),
                       current_status = StartState
                      },
        {ok, StartState, create_status_record(StartState, State)}
    catch
        error:badarg ->
            %% When we start up from a previous run, we have two ways that the FSM might be started;
            %% from an incoming packet, or the database record for a prior run
            %% There may be some nasty race conditions surrounding this.
            %% We may also want to *not* automatically reanimate FSMs for nodes that aren't
            %% actively reporting; but rather keep them in a 'limbo' waiting for the first
            %% packet, and if one doesn't arrive within a certain time mark them down.
            lager:error("Failed to register:~p for ~p (already exists as ~p?)",
                        [NodeRef,self(), gproc:lookup_pid({n,l,GprocName}) ]),
            {stop, shutdown, undefined}
    end.

up(heartbeat, State) ->
    maybe_transition(heartbeat, up, State).

down(heartbeat, State) ->
    maybe_transition(heartbeat, down, State).

handle_info({timeout, _Ref, update_avg}, CurrentState, State) ->
    maybe_transition(tick, CurrentState, State).

%%
%% These events are handled the same for every state
%%
handle_event({logging, Level}, StateName, State) ->
    {next_state, StateName, State#state{logging=Level}};
handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(current_state, _From, StateName, State) ->
    {reply, StateName, StateName, State};
handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ignored, StateName, State}.

terminate(_Reason, _CurState, _State) ->
    ok.

code_change(_OldVsn, CurState, State, _Extra) ->
    {ok, CurState, State}.

%% Internal functions

create_status_record(Status, #state{node_ref=NodeRef}=State) ->
    notify_subscribers(Status, State),
    pushy_node_status_updater:create(NodeRef, ?POC_ACTOR_ID, Status),
    State.

notify_subscribers(Status, #state{node_ref=NodeRef}) ->
    lager:info("Status change for ~p : ~p", [NodeRef, Status]),
    gproc:send(subscribers_key(NodeRef), {node_state_change, NodeRef, Status}).

subscribers_key(NodeRef) ->
    {p,l,{node_state_monitor,NodeRef}}.

maybe_transition(heartbeat, down, #state{heartbeat_rate=HRate0, up_thresh=Up}=State) ->
    HRate = pushy_ema2:inc(HRate0, 1),
    State1 = State#state{heartbeat_rate=HRate},
    case HRate > Up of
        true ->
            notify_subscribers(up, State1),
            {next_state, up, State1};
        false ->
            {next_state, down, State1}
    end;
maybe_transition(heartbeat, up, #state{heartbeat_rate=HRate}=State) ->
    {next_state, up, State#state{heartbeat_rate=pushy_ema2:inc(HRate, 1)}};
maybe_transition(tick, down, #state{heartbeat_rate=HRate}=State) ->
    NHRate = pushy_ema2:tick(HRate),
    State1 = State#state{heartbeat_rate=NHRate},
    {next_state, down, State1};
maybe_transition(tick, up, #state{heartbeat_rate=HRate, down_thresh=Down}=State) ->
    NHRate = pushy_ema2:tick(HRate),
    State1 = State#state{heartbeat_rate=NHRate},
    case NHRate < Down of
        true ->
            notify_subscribers(down, State1),
            {next_state, down, State1};
        false ->
            {next_state, up, State}
    end.
