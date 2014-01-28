%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @copyright 2011-2012 Opscode Inc.

-module(pushy_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
%-endif.

-include("pushy.hrl").

-compile([{parse_transform, lager_transform}]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    %% Bail out early if the VM isn't running in SMP mode
    %% ZeroMQ NIFs require SMP due to the way semantics of message
    %% sending changes SMP vs. non-SMP in the VM
    case erlang:system_info(multi_scheduling) of
        enabled ->
            %% TODO - find a better spot for this log setup
                                                % Logs all job message to a specific file
            lager:trace_file("log/jobs.log", [{job_id, '*'}]),
            IncarnationId = list_to_binary(pushy_util:guid_v4()),

            error_logger:info_msg("Starting Pushy incarnation ~s.~n", [IncarnationId]),


            case pushy_sup:start_link(#pushy_state{incarnation_id=IncarnationId}) of
                {ok, Pid} -> {ok, Pid, fake_context};
                Error ->
                    Error
            end;
        _ ->
            lager:critical("Push Job server requires at least 2 CPU cores. "
                           "Server startup aborted because only 1 core was detected."),
            erlang:halt(1)
    end.
stop(_) ->
    ok.
