%%======================================================================
%%
%% LeoFS Storage
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
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
-export([register_in_monitor/1, register_in_monitor/2,
         get_disk_usage/0,
         get_routing_table_chksum/0,
         update_manager_nodes/1, recover_remote/2,
         start/1, start/2, start/3, stop/0, attach/1, synchronize/1, synchronize/2,
         compact/1, compact/3, diagnose_data/0,
         get_node_status/0,
         rebalance/1, rebalance/3]).

%% interval to notify to leo_manager
-define(CHECK_INTERVAL, 3000).

%%--------------------------------------------------------------------
%% API for Admin and System#1
%%--------------------------------------------------------------------
%% @doc register into the manager's monitor.
%%
-spec(register_in_monitor(first | again) ->
             ok | {error, not_found}).
register_in_monitor(RequestedTimes) ->
    case whereis(leo_storage_sup) of
        undefined ->
            {error, not_found};
        Pid ->
            register_in_monitor(Pid, RequestedTimes)
    end.

-spec(register_in_monitor(pid(), first | again) ->
             ok | {error, any()}).
register_in_monitor(Pid, RequestedTimes) ->
    Fun = fun(Node0, Res) ->
                  Node1 = case is_atom(Node0) of
                              true  -> Node0;
                              false -> list_to_atom(Node0)
                          end,
                  case leo_misc:node_existence(Node1) of
                      true ->
                          GroupL1 = ?env_grp_level_1(),
                          GroupL2 = ?env_grp_level_2(),
                          NumOfNodes = ?env_num_of_vnodes(),
                          RPCPort = ?env_rpc_port(),

                          case rpc:call(Node1, leo_manager_api, register,
                                        [RequestedTimes, Pid, erlang:node(), storage,
                                         GroupL1, GroupL2, NumOfNodes, RPCPort],
                                        ?DEF_REQ_TIMEOUT) of
                              {ok, SystemConf} ->
                                  case leo_cluster_tbl_conf:update(SystemConf) of
                                      ok ->
                                          Options = lists:zip(
                                                      record_info(
                                                        fields, ?SYSTEM_CONF),
                                                      tl(tuple_to_list(SystemConf))),
                                          ok = leo_redundant_manager_api:set_options(Options),
                                          true;
                                      _ ->
                                          false
                                  end;
                              Error ->
                                  ?error("register_in_monitor/1",
                                         "manager:~w, cause:~p", [Node1, Error]),
                                  Res
                          end;
                      false ->
                          Res
                  end
          end,

    case lists:foldl(Fun, false, ?env_manager_nodes(leo_storage)) of
        true ->
            ok;
        false ->
            timer:apply_after(?CHECK_INTERVAL, ?MODULE, register_in_monitor,
                              [Pid, RequestedTimes]),
            ok
    end.

%% @doc get routing_table's checksum.
%%
-spec(get_routing_table_chksum() ->
             {ok, integer()}).
get_routing_table_chksum() ->
    leo_redundant_manager_api:checksum(?CHECKSUM_RING).

%% @doc update manager nodes
%%
-spec(update_manager_nodes(list()) ->
             ok).
update_manager_nodes(Managers) ->
    ?update_env_manager_nodes(leo_storage, Managers),
    leo_membership_cluster_local:update_manager_nodes(Managers).

%% @doc start storage-server.
%%
-spec(start(list()) ->
             {ok, {atom(), integer()}} | {error, {atom(), any()}}).
start(MembersCur) ->
    start(MembersCur, undefined).
start([], _) ->
    {error, 'empty_members'};
start(MembersCur, SystemConf) ->
    start(MembersCur, [], SystemConf).

start(MembersCur, MembersPrev, SystemConf) ->
    case SystemConf of
        undefined -> ok;
        [] -> ok;
        _ ->
            ok = leo_redundant_manager_api:set_options(
                   [{cluster_id, SystemConf#?SYSTEM_CONF.cluster_id},
                    {dc_id,      SystemConf#?SYSTEM_CONF.dc_id},
                    {n, SystemConf#?SYSTEM_CONF.n},
                    {r, SystemConf#?SYSTEM_CONF.r},
                    {w, SystemConf#?SYSTEM_CONF.w},
                    {d, SystemConf#?SYSTEM_CONF.d},
                    {bit_of_ring, SystemConf#?SYSTEM_CONF.bit_of_ring},
                    {num_of_dc_replicas,   SystemConf#?SYSTEM_CONF.num_of_dc_replicas},
                    {num_of_rack_replicas, SystemConf#?SYSTEM_CONF.num_of_rack_replicas}])
    end,
    start_1(MembersCur, MembersPrev).

%% @private
start_1(MembersCur, MembersPrev) ->
    case leo_redundant_manager_api:synchronize(
           ?SYNC_TARGET_MEMBER, [{?VER_CUR,  MembersCur },
                                 {?VER_PREV, MembersPrev}]) of
        {ok,_MembersChecksum} ->
            case leo_redundant_manager_api:create() of
                {ok,_,_} ->
                    {ok, Chksums} = leo_redundant_manager_api:checksum(?CHECKSUM_RING),
                    {ok, {node(), Chksums}};
                {error, Cause} ->
                    {error, {node(), Cause}}
            end;
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
-spec(attach(#?SYSTEM_CONF{}) ->
             ok | {error, any()}).
attach(SystemConf) ->
    ok = leo_redundant_manager_api:set_options(
           [{cluster_id, SystemConf#?SYSTEM_CONF.cluster_id},
            {dc_id,      SystemConf#?SYSTEM_CONF.dc_id},
            {n, SystemConf#?SYSTEM_CONF.n},
            {r, SystemConf#?SYSTEM_CONF.r},
            {w, SystemConf#?SYSTEM_CONF.w},
            {d, SystemConf#?SYSTEM_CONF.d},
            {bit_of_ring, SystemConf#?SYSTEM_CONF.bit_of_ring},
            {num_of_dc_replicas,   SystemConf#?SYSTEM_CONF.num_of_dc_replicas},
            {num_of_rack_replicas, SystemConf#?SYSTEM_CONF.num_of_rack_replicas}]).


%%--------------------------------------------------------------------
%% API for Admin and System#3
%%--------------------------------------------------------------------
%% @doc synchronize a data.
%%
-spec(synchronize(atom()) ->
             ok | {error, any()}).
synchronize(Node) ->
    leo_storage_mq:publish(?QUEUE_TYPE_RECOVERY_NODE, Node).

-spec(synchronize([atom()]|binary(), #?METADATA{}|atom()) ->
             ok | not_found | {error, any()}).
synchronize(InconsistentNodes, #?METADATA{addr_id = AddrId,
                                          key     = Key}) ->
    leo_storage_handler_object:replicate(InconsistentNodes, AddrId, Key);

synchronize(Key, ErrorType) ->
    {ok, #redundancies{vnode_id_to = VNodeId}} = leo_redundant_manager_api:get_redundancies_by_key(Key),
    leo_storage_mq:publish(?QUEUE_TYPE_PER_OBJECT, VNodeId, Key, ErrorType).


%%--------------------------------------------------------------------
%% API for Admin and System#4
%%--------------------------------------------------------------------
%% @doc
%%
-spec(compact(atom(), 'all' | integer(), integer()) -> ok | {error, any()}).
compact(start, NumOfTargets, MaxProc) ->
    case leo_redundant_manager_api:get_member_by_node(erlang:node()) of
        {ok, #member{state = ?STATE_RUNNING}} ->
            TargetPids1 =
                case leo_compact_fsm_controller:state() of
                    {ok, #compaction_stats{status = Status,
                                           pending_targets = PendingTargets}}
                      when Status == ?ST_SUSPENDING;
                           Status == ?ST_IDLING ->
                        PendingTargets;
                    _ ->
                        []
                end,

            case TargetPids1 of
                [] ->
                    {error, "Not exists compaction-targets"};
                _ ->
                    TargetPids2 =
                        case NumOfTargets of
                            'all' ->
                                TargetPids1;
                            _Other ->
                                lists:sublist(TargetPids1, NumOfTargets)
                        end,
                    leo_object_storage_api:compact_data(
                      TargetPids2, MaxProc,
                      fun leo_redundant_manager_api:has_charge_of_node/2)
            end;
        _ ->
            {error,'not_running'}
    end.

compact(Method) ->
    case leo_redundant_manager_api:get_member_by_node(erlang:node()) of
        {ok, #member{state = ?STATE_RUNNING}} ->
            compact_1(Method);
        _ ->
            {error,'not_running'}
    end.

%% @private
compact_1(suspend) ->
    leo_compact_fsm_controller:suspend();
compact_1(resume) ->
    leo_compact_fsm_controller:resume();
compact_1(status) ->
    leo_compact_fsm_controller:state().


%% @doc Diagnose the data
-spec(diagnose_data() ->
             ok | {error, any()}).
diagnose_data() ->
    leo_compact_fsm_controller:diagnose().


%%--------------------------------------------------------------------
%% Maintenance
%%--------------------------------------------------------------------
%%
%%
-spec(get_node_status() ->
             {ok, [tuple()]}).
get_node_status() ->
    Version = case application:get_key(leo_storage, vsn) of
                  {ok, _Version} -> _Version;
                  _ -> "undefined"
              end,

    {RingHashCur, RingHashPrev} =
        case leo_redundant_manager_api:checksum(?CHECKSUM_RING) of
            {ok, {Chksum0, Chksum1}} -> {Chksum0, Chksum1};
            _ -> {[], []}
        end,

    QueueDir  = case application:get_env(leo_storage, queue_dir) of
                    {ok, EnvQueueDir} -> EnvQueueDir;
                    _ -> []
                end,
    SNMPAgent = case application:get_env(leo_storage, snmp_agent) of
                    {ok, EnvSNMPAgent} -> EnvSNMPAgent;
                    _ -> []
                end,
    Directories = [{log,        ?env_log_dir(leo_storage)},
                   {mnesia,     []},
                   {queue,      QueueDir},
                   {snmp_agent, SNMPAgent}
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
                    [
                     {num_of_replication_msg, NumOfQueue1},
                     {num_of_sync_vnode_msg,  NumOfQueue2},
                     {num_of_rebalance_msg,   NumOfQueue3}
                    ]}
                  ],
    {ok, [
          {type,          storage},
          {version,       Version},
          {num_of_vnodes, ?env_num_of_vnodes()},
          {grp_level_2,   ?env_grp_level_2()},
          {dirs,          Directories},
          {avs,           ?env_storage_device()},
          {ring_checksum, RingHashes},
          {statistics,    Statistics}
         ]}.


%% @doc Do rebalance which means "Objects are copied to the specified node".
%% @param RebalanceInfo: [{VNodeId, DestNode}]
%%
-spec(rebalance([tuple()]) ->
             ok).
rebalance(RebalanceList) ->
    catch leo_redundant_manager_api:force_sync_workers(),
    rebalance_1(RebalanceList).


-spec(rebalance(list(), list(#member{}), list(#member{})) ->
             ok | {error, any()}).
rebalance(RebalanceList, MembersCur, MembersPrev) ->
    case leo_redundant_manager_api:synchronize(
           ?SYNC_TARGET_BOTH, [{?VER_CUR,  MembersCur},
                               {?VER_PREV, MembersPrev}]) of
        {ok, Hashes} ->
            ok = rebalance(RebalanceList),
            {ok, Hashes};
        Error ->
            Error
    end.


%% @private
-spec(rebalance_1([tuple()]) ->
             ok).
rebalance_1([]) ->
    ok;
rebalance_1([{VNodeId, Node}|T]) ->
    _ = leo_storage_mq:publish(?QUEUE_TYPE_SYNC_BY_VNODE_ID, VNodeId, Node),
    rebalance_1(T).


%% recover a remote cluster's object
-spec(recover_remote(integer(), binary()) ->
             ok | {error, any()}).
recover_remote(AddrId, Key) ->
    case leo_object_storage_api:get({AddrId, Key}) of
        {ok, _Metadata, Object} ->
            leo_sync_remote_cluster:defer_stack(Object);
        not_found = Cause ->
            {error, Cause};
        {error, Cause} ->
            {error, Cause}
    end.

%% @doc
%% Get the disk usage(Total, Free) on leo_storage in KByte
-spec(get_disk_usage() -> {ok, {Total::pos_integer(), Free::pos_integer()}}).
get_disk_usage() ->
    PathList = case ?env_storage_device() of
                   [] -> [];
                   Devices ->
                       lists:map(fun(Item) ->
                                         leo_misc:get_value(path, Item)
                                 end, Devices)
               end,
    get_disk_usage(PathList, dict:new()).
get_disk_usage([], Dict) ->
    Ret = dict:fold(fun(_MountPath, {Total, Free}, {SumTotal, SumFree}) ->
                            {SumTotal + Total, SumFree + Free}
                    end,
                    {0, 0},
                    Dict),
    {ok, Ret};
get_disk_usage([Path|Rest], Dict) ->
    case leo_file:file_get_mount_path(Path) of
        {ok, {MountPath, TotalSize, UsedPercentage}} ->
            FreeSize = TotalSize * (100 - UsedPercentage) / 100,
            NewDict = dict:store(MountPath, {TotalSize, FreeSize}, Dict),
            get_disk_usage(Rest, NewDict);
        Error ->
            {error, Error}
    end.

