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

-record(state, {frontend,
                backend_out,
                backend_in}).

start_link(PushyState) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [PushyState], []).

init([#pushy_state{}]) ->
    %% Let the broker run more often
    erlang:process_flag(priority, high),
    CommandAddress = pushy_util:make_zmq_socket_addr(command_port),

    {ok, FE} = gen_zmq:new_socket(router),
    ok = gen_zmq:setopts(FE, [{active, true}]),

    {ok, BEO} = gen_zmq:new_socket(pull),
    ok = gen_zmq:setopts(BEO, [{active, true}]),

    {ok, BEI} = gen_zmq:new_socket(push),
    ok = gen_zmq:setopts(BEI, [{active, false}]),


%%    [erlzmq:setsockopt(Sock, linger, 0) || Sock <- [FE, BEO, BEI]],

    ok = gen_zmq:bind(FE, CommandAddress),
    ok = gen_zmq:bind(BEO, ?PUSHY_BROKER_OUT),
    ok = gen_zmq:bind(BEI, ?PUSHY_BROKER_IN),
    lager:info("~p has started.~n", [?MODULE]),
    {ok, #state{frontend=FE, backend_out=BEO, backend_in=BEI}}.
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% Incoming traffic goes to command switches
handle_info({zmq, FE, Msg}, #state{frontend=FE, backend_in=BEI}=State) ->
    gen_zmq:write(BEI, {Msg, false}),
    {noreply, State};
handle_info({zmq, FE, Msg, recvmore}, #state{frontend=FE, backend_in=BEI}=State) ->
    gen_zmq:write(BEI, {Msg, true}),
    {noreply, State};

%% Command switches send traffic out
handle_info({zmq, BEO, Msg}, #state{frontend=FE, backend_out=BEO}=State) ->
    gen_zmq:write(FE, {Msg, false}),
    {noreply, State};
handle_info({zmq, BEO, Msg, recvmore}, #state{frontend=FE, backend_out=BEO}=State) ->
    gen_zmq:write(FE, {Msg, true}),
    {noreply, State};
handle_info(Info, State) ->
    lager:info("Getting an unrecognized message! ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
