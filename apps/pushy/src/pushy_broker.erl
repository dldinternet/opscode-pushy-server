%% @copyright Copyright 2014 Chef Software, Inc. All Rights Reserved.
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
-module(pushy_broker).

-behaviour(gen_server).

-include("pushy.hrl").

-compile([{parse_transform, lager_transform}]).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {
          frontend,
          num_switches,
          switches = []
         }).

start_link(PushyState) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [PushyState], []).

init([#pushy_state{ctx=Ctx, curve_secret_key=Sec}]) ->
    %% Let the broker run more often
    erlang:process_flag(priority, high),
    CommandAddress = pushy_util:make_zmq_socket_addr(command_port),
    {ok, FE} = erlzmq:socket(Ctx, [router, {active, true}]),
    erlzmq:setsockopt(FE, linger, 0),
    case envy:get(pushy, disable_curve_encryption, false, boolean) of
        false ->
            %% Configure front-end socket as Curve-encrypted
            pushy_zap:wait_for_start(),     % Make sure ZAP-handler is started before we create any servers that depend on it
            ok = erlzmq:setsockopt(FE, curve_server, 1),
            ok = erlzmq:setsockopt(FE, curve_secretkey, Sec);
        _ -> ok
    end,
    ok = erlzmq:bind(FE, CommandAddress),
    NumSwitches = envy:get(pushy, command_switches, 10, integer),
    % We use a tuple, because the element/2 lookup is constant-time
    % XXX Needs benchmarking to determine whether the constant it actually lower than a lists:nth call would be
    SwitchNames = list_to_tuple([pushy_command_switch:make_name(N) || N <- lists:seq(1, NumSwitches)]),
    lager:info("~p has started.~n", [?MODULE]),
    {ok, #state{frontend=FE, num_switches = NumSwitches, switches = SwitchNames}}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Incoming traffic goes to command switches
handle_info({zmq, FE, Frame, [rcvmore]}, #state{frontend=FE}=State) ->
    case pushy_messaging:receive_message_async(FE, Frame) of
        [_Address, _Header, _Body] = Message->
            lager:debug("RECV: ~s~nRECV: ~s~nRECV: ~s~n",
                       [pushy_tools:bin_to_hex(_Address), _Header, _Body]),
            send_to_switch(State, Message);
        _Packets ->
            lager:debug("Received runt/overlength message with ~n packets~n", [length(_Packets)])
    end,
    {noreply, State};
%% Command switches send traffic out
handle_info({frontend_out, RawMessage}, #state{frontend=FE}=State) ->
    [_Address, _Header, _Body] = RawMessage,
    lager:debug("SEND: ~s~nSEND: ~s~nSEND: ~s~n",
               [pushy_tools:bin_to_hex(_Address), _Header, _Body]),
    ok = pushy_messaging:send_message(FE, RawMessage),
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

send_to_switch(#state{num_switches = NumSwitches, switches = Switches}, [Addr, _, _] = Message) ->
    SwitchNum = (erlang:phash2(Addr) rem NumSwitches) + 1,
    Name = element(SwitchNum, Switches),
    Name ! {frontend_in, Message}.
