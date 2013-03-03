%%======================================================================
%%
%% LeoFS Storage
%%
%% Copyright (c) 2012 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% LeoFS Storage
%% @doc
%% @end
%%======================================================================
-module(leo_storage_api).

-author('Yosuke Hara').

-include("leo_storage.hrl").
-include_lib("leo_commons/include/leo_commons.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("eunit/include/eunit.hrl").

%% API
-export([register_in_monitor/1, get_routing_table_chksum/0,
         start/1, start/2, stop/0, attach/1, synchronize/3,
         compact/1, compact/3, get_node_status/0, rebalance/1]).

%%--------------------------------------------------------------------
%% API for Admin and System#1
%%--------------------------------------------------------------------
%% @doc register into the manager's monitor.
%%
-spec(register_in_monitor(first | again) -> ok).
register_in_monitor(RequestedTimes) ->
    case whereis(leo_storage_sup) of
        undefined ->
            {error, not_found};
        Pid ->
            Fun = fun(Node0, Res) ->
                          Node1 = case is_atom(Node0) of
                                      true  -> Node0;
                                      false -> list_to_atom(Node0)
                                  end,

                          case leo_misc:node_existence(Node1) of
                              true ->
                                  case rpc:call(Node1, leo_manager_api, register,
                                                [RequestedTimes, Pid, erlang:node(), storage],
                                                ?DEF_REQ_TIMEOUT) of
                                      ok ->
                                          true;
                                      Error ->
                                          ?error("register_in_monitor/1", "manager:~w, cause:~p", [Node1, Error]),
                                          Res
                                  end;
                              false ->
                                  Res
                          end
                  end,

            case lists:foldl(Fun, false, ?env_manager_nodes(leo_storage)) of
                true  -> ok;
                false -> {error, ?ERROR_COULD_NOT_CONNECT}
            end
    end.

%% @doc get routing_table's checksum.
%%
-spec(get_routing_table_chksum() ->
             {ok, integer()}).
get_routing_table_chksum() ->
    leo_redundant_manager_api:checksum(ring).


%% @doc start storage-server.
%%
-spec(start(list()) ->
             {ok, {atom(), integer()}} | {error, {atom(), any()}}).
start(Members) ->
    start(Members, undefined).
start(Members, SystemConf) ->
    case leo_redundant_manager_api:create(Members) of
        {ok, _NewMembers, [{?CHECKSUM_RING,   Chksums},
                           {?CHECKSUM_MEMBER,_Chksum1}]} ->
            case SystemConf of
                undefined -> void;
                _ ->
                    #system_conf{n = NumOfReplicas,
                                 r = ReadQuorum,
                                 w = WriteQuorum,
                                 d = DeleteQuorum,
                                 bit_of_ring = BitOfRing} = SystemConf,
                    ok = leo_redundant_manager_api:set_options([{n, NumOfReplicas},
                                                                {r, ReadQuorum},
                                                                {w, WriteQuorum},
                                                                {d, DeleteQuorum},
                                                                {bit_of_ring, BitOfRing}])
            end,
            {ok, {node(), Chksums}};
        {error, Cause} ->
            {error, {node(), Cause}}
    end.


%% @doc
%%
-spec(stop() -> any()).
stop() ->
    Target = case init:get_argument(node) of
                 {ok, [[Node]]} ->
                     list_to_atom(Node);
                 error ->
                     erlang:node()
             end,

    _ = rpc:call(Target, leo_storage, stop, [], ?DEF_REQ_TIMEOUT),
    init:stop().


%% @doc attach a cluster.
%%
-spec(attach(#system_conf{}) ->
             ok | {error, any()}).
attach(#system_conf{n = NumOfReplicas,
                    r = ReadQuorum,
                    w = WriteQuorum,
                    d = DeleteQuorum,
                    bit_of_ring = BitOfRing}) ->
    leo_redundant_manager_api:set_options([{n, NumOfReplicas},
                                           {r, ReadQuorum},
                                           {w, WriteQuorum},
                                           {d, DeleteQuorum},
                                           {bit_of_ring, BitOfRing}]).


%%--------------------------------------------------------------------
%% API for Admin and System#3
%%--------------------------------------------------------------------
%% @doc synchronize a data.
%%
-spec(synchronize(object | sync_by_vnode_id, list() | string(), #metadata{} | atom()) ->
             ok | {error, any()}).
synchronize(?TYPE_OBJ, InconsistentNodes, #metadata{addr_id = AddrId,
                                                    key     = Key}) ->
    leo_storage_handler_object:copy(InconsistentNodes, AddrId, Key);

synchronize(?TYPE_OBJ, Key, ErrorType) ->
    {ok, #redundancies{vnode_id = VNodeId}} = leo_redundant_manager_api:get_redundancies_by_key(Key),
    leo_storage_mq_client:publish(?QUEUE_TYPE_PER_OBJECT, VNodeId, Key, ErrorType);

synchronize(sync_by_vnode_id, VNodeId, Node) ->
    leo_storage_mq_client:publish(?QUEUE_TYPE_SYNC_BY_VNODE_ID, VNodeId, Node).


%%--------------------------------------------------------------------
%% API for Admin and System#4
%%--------------------------------------------------------------------
%% @doc
%%
-spec(compact(atom(), 'all' | integer(), integer()) -> ok | {error, any()}).
compact(start, NumOfTargets, MaxProc) ->
    TargetPids1 =
        case leo_compaction_manager_fsm:status() of
            {ok, {[], _, _}} ->
                case leo_object_storage_api:get_object_storage_pid('all') of
                    TargetPids0 when is_list(TargetPids0) ->
                        TargetPids0;
                    _ ->
                        []
                end;
            {ok, {TargetPids0, _, _}} ->
                TargetPids0;
            _ ->
                []
        end,

    case TargetPids1 of
        [] ->
            ok;
        _ ->
            TargetPids2 = case NumOfTargets of
                              'all'  -> TargetPids1;
                              _Other -> lists:sublist(TargetPids1, NumOfTargets)
                          end,
            leo_compaction_manager_fsm:start(
              TargetPids2, MaxProc, fun leo_redundant_manager_api:has_charge_of_node/1)
    end.

compact(suspend) ->
    leo_compaction_manager_fsm:suspend();
compact(resume) ->
    leo_compaction_manager_fsm:resume();
compact(status) ->
    leo_compaction_manager_fsm:status().


%%--------------------------------------------------------------------
%% Maintenance
%%--------------------------------------------------------------------
%%
%%
-spec(get_node_status() -> {ok, #cluster_node_status{}}).
get_node_status() ->
    Version = case application:get_env(leo_storage, system_version) of
                  {ok, EnvVersion} ->
                      EnvVersion;
                  _ ->
                      []
              end,

    {RingHashCur, RingHashPrev} =
        case leo_redundant_manager_api:checksum(ring) of
            {ok, {Chksum0, Chksum1}} -> {Chksum0, Chksum1};
            _ -> {[], []}
        end,

    Directories = [{log,    ?env_log_dir(leo_storage)},
                   {mnesia, []}
                  ],
    RingHashes  = [{ring_cur,  RingHashCur},
                   {ring_prev, RingHashPrev }
                  ],

    NumOfQueue1 = case catch leo_mq_api:status(?QUEUE_ID_PER_OBJECT) of
                      {ok, {Res1, _}} -> Res1;
                      _ -> 0
                  end,
    NumOfQueue2 = case catch leo_mq_api:status(?QUEUE_ID_SYNC_BY_VNODE_ID) of
                      {ok, {Res2, _}} -> Res2;
                      _ -> 0
                  end,
    NumOfQueue3 = case catch leo_mq_api:status(?QUEUE_ID_REBALANCE) of
                      {ok, {Res3, _}} -> Res3;
                      _ -> 0
                  end,

    Statistics  = [{vm_version,       erlang:system_info(version)},
                   {total_mem_usage,  erlang:memory(total)},
                   {system_mem_usage, erlang:memory(system)},
                   {proc_mem_usage,   erlang:memory(processes)},
                   {ets_mem_usage,    erlang:memory(ets)},
                   {num_of_procs,     erlang:system_info(process_count)},
                   {process_limit,    erlang:system_info(process_limit)},
                   {kernel_poll,      erlang:system_info(kernel_poll)},
                   {thread_pool_size, erlang:system_info(thread_pool_size)},
                   {storage,
                    [{num_of_replication_msg, NumOfQueue1},
                     {num_of_sync_vnode_msg,  NumOfQueue2},
                     {num_of_rebalance_msg,   NumOfQueue3}
                    ]}
                  ],
    {ok, #cluster_node_status{type    = server,
                              version = Version,
                              dirs    = Directories,
                              avs     = ?env_storage_device(),
                              ring_checksum = RingHashes,
                              statistics    = Statistics}}.

%% @doc Do rebalance which means "Objects are copied to the specified node".
%% @param RebalanceInfo: [{VNodeId, DestNode}]
%%
-spec(rebalance(list()) ->
             ok | {error, any()}).
rebalance([]) ->
    ok;
rebalance([{VNodeId, Node}|T]) ->
    ok = leo_storage_mq_client:publish(?QUEUE_TYPE_SYNC_BY_VNODE_ID, VNodeId, Node),
    rebalance(T).

