%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%%% @author John Keiser <jkeiser@opscode.com>
%%% @copyright Copyright 2012-2012 Opscode Inc.
%%% @doc
%%% REST resource for creating and listing push jobs
%%% @end
-module(pushy_jobs_resource).

-export([init/1,
         allowed_methods/2,
         content_types_accepted/2,
         content_types_provided/2,
         is_authorized/2,
         from_json/2,
         to_json/2,
         post_is_create/2,
         create_path/2]).

-include("pushy_sql.hrl").

-include_lib("webmachine/include/webmachine.hrl").

-include_lib("eunit/include/eunit.hrl").

-record(config_state, {
          organization_guid :: string(),
          job :: #pushy_job{}
        }).

init(_Config) ->
    % ?debugVal(_Config),
    State = #config_state{},
    {ok, State}.
%%    {{trace, "/tmp/traces"}, State}.
%% then in console: wmtrace_resource:add_dispatch_rule("wmtrace", "/tmp/traces").
%% then go to localhost:WXYZ/wmtrace

is_authorized(Req, State) ->
    OrgName =  wrq:path_info(organization_id, Req),
    %?debugVal(OrgName),
    State2 = State#config_state{organization_guid = pushy_object:fetch_org_id(OrgName) },
    {true, Req, State2}.

allowed_methods(Req, State) ->
    {['POST', 'GET'], Req, State}.

content_types_accepted(Req, State) ->
    {[{"application/json", from_json}], Req, State}.

content_types_provided(Req, State) ->
    {[{"application/json", to_json}], Req, State}.

% {
%   'command' = 'chef-client',
%   'nodes' = [ 'DERPY', 'RAINBOWDASH' ]
% }

post_is_create(Req, State) ->
    {true, Req, State}.

% This creates the job record
create_path(Req, #config_state{organization_guid = OrgId} = State) ->
    [ Command, NodeNames ] = parse_post_body(Req),
    Job = pushy_object:new_record(pushy_job, OrgId, NodeNames),
    Job2 = Job#pushy_job{command = Command},
    State2 = State#config_state{job = Job2},
    {binary_to_list(Job#pushy_job.id), Req, State2}.

% This processes POST /pushy/jobs
from_json(Req, State) ->
    pushy_job_state_sup:start(State#config_state.job),
    Req2 = ripped_from_chef_rest:set_uri_of_created_resource(Req),
    {true, Req2, State}.

%% GET /pushy/jobs
to_json(Req, State) ->
    Jobs = jobs_to_json(get_jobs(pushy_job_state_sup:get_processes())),

    {jiffy:encode(Jobs), Req, State}.

get_jobs(JobTuples) ->
    [pushy_job_state:get_job_state(JobId) || {JobId, _} <- JobTuples].


jobs_to_json(Jobs) ->
    [job_to_json(Job) || Job <- Jobs].

job_to_json(#pushy_job{
        id = Id,
        command = Command,
        status = Status,
        finished_reason = Reason,
        job_nodes = Nodes}) ->
    NodesJson = job_nodes_json_by_status(Nodes),
    {[ {<<"id">>, iolist_to_binary(Id)},
       {<<"command">>, iolist_to_binary(Command)},
       {<<"status">>, atom_to_binary(case Status of finished -> Reason; _ -> Status end, utf8)},
       {<<"duration">>, 300},
       {<<"nodes">>, NodesJson}
    ]}.

job_nodes_json_by_status(Nodes) ->
    NodesByStatus = job_nodes_by_status(Nodes, dict:new()),
    {[
        { erlang:atom_to_binary(Status, utf8), dict:fetch(Status, NodesByStatus) }
        || Status <- dict:fetch_keys(NodesByStatus)
    ]}.

job_nodes_by_status([], Dict) ->
    Dict;
job_nodes_by_status([#pushy_job_node{node_name = Name, status = Status} | Nodes], Dict) ->
    Dict2 = dict:append(Status, Name, Dict),
    job_nodes_by_status(Nodes, Dict2).


% Private stuff

parse_post_body(Req) ->
    Body = wrq:req_body(Req),
    JobJson = jiffy:decode(Body),
    Command = ej:get({<<"command">>}, JobJson),
    NodeNames = ej:get({<<"nodes">>}, JobJson),
    [ Command, NodeNames ].
