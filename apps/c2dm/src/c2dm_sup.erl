
-module(c2dm_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).
-define(CHILD(I, Args, Type), {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).
-define(WEBMACHINE_CHILD(Ip, Port, LogDir, Dispatch),
            {webmachine_mochiweb,
             {webmachine_mochiweb, start,
                    [[  {ip, Ip}
                     , {port, Port}
                     , {log_dir, LogDir}
                     , {dispatch, Dispatch} ]]},
             permanent, 5000, worker, dynamic}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, { {one_for_one, 5, 10}, 
            [
                ?WEBMACHINE_CHILD("0.0.0.0", 5780, "log/webmachine.log", [{["c2dm",type], c2dm_subscriber_resource, []}]),
                ?CHILD(c2dm_db_svr, [c2dm], worker)
              , ?CHILD(c2dm_publisher_svr, [c2dm], worker)
              , ?CHILD(amqp_subscriber, [c2dm], worker)
            ]} }.

