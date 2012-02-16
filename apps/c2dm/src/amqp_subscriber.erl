-module(amqp_subscriber).
-behavior(gen_bunny).

-export([start_link/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_message/2, terminate/2, code_change/3]).

-compile([export_all]).

-record(state, {}).

-include_lib("pb2utils/include/pb2utils.hrl").
-include_lib("gen_bunny/include/gen_bunny.hrl").

start_link(App) ->
    case load_config(App) of
        {error, Error} ->
            {error, Error};
        {ok, Network, Declare} ->
            start_link(Network, Declare, [])
    end.

start_link(ConnectionParams, Declare, Opts) ->
    gen_bunny:start_link(?MODULE,
                              ConnectionParams,
                              Declare,
                              Opts).

pause() ->
    gen_bunny:call(?MODULE, pause).

resume() ->
    gen_bunny:call(?MODULE, resume).

init([]) ->
    {ok, #state{}}.

handle_message(Msg, State) ->
    ?ERROR("~p~n", [Msg]),
    {noreply, State}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

load_config(App) ->
    case application:get_env(App, amqp) of
        undefined ->
            {error, no_app_amqp_config};
        {ok, Proplist} ->
            QName = proplists:get_value(queue, Proplist),
            Queue = #'queue.declare'{
                        queue = QName,
                        durable=true},
            RoutingKey = proplists:get_value(routing_key, Proplist),
            Exchange = #'exchange.declare'{
                            exchange = proplists:get_value(exchange, Proplist),
                            type = <<"topic">>,
                            durable = true},
            Network = #amqp_params_network{
                username = proplists:get_value(user, Proplist),
                password = proplists:get_value(password, Proplist),
                port = proplists:get_value(port, Proplist),
                virtual_host = proplists:get_value(virtual_host, Proplist),
                host = proplists:get_value(host, Proplist),
                ssl_options = proplists:get_value(ssl_options, Proplist)
            },
            {ok, Network, {Exchange, Queue, RoutingKey}}
    end.
