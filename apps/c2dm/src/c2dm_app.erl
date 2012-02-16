-module(c2dm_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

-include_lib("pb2utils/include/pb2utils.hrl").
-include("../include/c2dm.hrl").

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    mnesia_utils:create_and_start(),
    wait_for_tables(),
    create_tables(),
    c2dm_sup:start_link().

stop(_State) ->
    ok.

wait_for_tables() ->
    Tables = mnesia:system_info(tables),
    mnesia:wait_for_tables(Tables, timer:seconds(30)).

create_tables() ->
    mnesia_utils:create_or_update_table(c2dm_app,
                                    #tabledef{table_name=user,
                                              fields=fields(user),
                                              table_type=ordered_set,
                                              record_name=user}).


fields(user) ->
    record_info(fields, user).
