%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%%% @author Mark Anderson <mark@opscode.com>
%%% @doc
%%% Mux-demux for commands to clients and responses from clients
%%% @end

%% @copyright Copyright 2012-2012 Chef Software, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
-module(pushy_command_switch).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/2,
         send/1,
         switch_processes_fun/0,
         make_name/1]).

%% ------------------------------------------------------------------
%% Private Exports - only exported for instrumentation
%% ------------------------------------------------------------------

-export([do_send/2]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").

-include("pushy.hrl").
-include_lib("pushy_common/include/pushy_metrics.hrl").
-include_lib("pushy_common/include/pushy_messaging.hrl").

-compile([{parse_transform, lager_transform}]).
-record(state, {}).

-define(PUSHY_MULTI_SEND_CROSSOVER, 100).

%% TODO: some refactoring around this seems necessary.  First, it seems that this is
%% actually multiple messages (see pushy_job_state:do_send/3).  Turning it into a tuple for
%% better specificity might also be a good idea.
-type addressed_message() :: nonempty_list(binary()).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(PushyState, Id) ->
    Name = make_name(Id),
    gen_server:start_link({local, Name}, ?MODULE, [PushyState, Id], []).

-spec send([binary()]) -> ok.
send(Message) ->
    case select_switch() of
        {ok, Pid} ->
            gen_server:call(Pid, {send, Message}, infinity);
        Error ->
            lager:error("Unable to send message. No command switch processes found!"),
            Error
    end.

%% @doc Generate a function suitable for use with pushy_process_monitor that
%% lists the switch processes
-spec switch_processes_fun() -> fun(() -> [{binary(), pid()}]).
switch_processes_fun()->
    fun() ->
            case gproc:select({local, names}, [{{{n,l,{?MODULE, '_'}},'_','_'},[],['$_']}]) of
                [] ->
                   [];
                Switches ->
                    [extract_process_info(Switch) || Switch <- Switches]
            end
    end.

%% @doc Generate an atom appropriate as a registered name for a command switch
-spec make_name(integer()) -> atom().
make_name(N) ->
    list_to_atom("pushy_command_switch_" ++ integer_to_list(N)).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init([_PushyState, Id]) ->
    true = gproc:reg({n, l, {?MODULE, Id}}),
    {ok, #state{}}.

handle_call({send, Message}, _From, State) ->
    NState = ?TIME_IT(?MODULE, do_send, (State, Message)),
    {reply, ok, NState};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({frontend_in, Msg}, State) ->
     ?TIME_IT(pushy_node_state, recv_msg, (Msg)),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

%%%
%%% Send a message to a single node
%%%
-spec do_send(#state{}, addressed_message()) -> #state{}.
do_send(State, RawMessage) ->
    pushy_broker ! {frontend_out, RawMessage},
    State.

-spec select_switch() -> {ok, pid()} | {error, no_switches}.
select_switch() ->
    case gproc:select({local, names}, [{{{n,l,{?MODULE, '_'}},'_','_'},[],['$_']}]) of
        [] ->
            {error, no_switches};
        [Switch] ->
            {_, Pid, _} = Switch,
            {ok, Pid};
        Switches ->
            Pos = random:uniform(length(Switches)),
            {_, Pid, _} = lists:nth(Pos, Switches),
            {ok, Pid}
    end.

extract_process_info({{n,l, {Name, Id}}, Pid, _})  ->
    {list_to_binary(io_lib:format("~s_~B", [Name, Id])), Pid}.
