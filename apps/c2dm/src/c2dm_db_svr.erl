-module(c2dm_db_svr).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).
-export([subscribe/1,
         unsubscribe/1,
         lookup/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("pb2utils/include/pb2utils.hrl").
-include("../include/c2dm.hrl").

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(_) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

subscribe(Arg) ->
    gen_server:call(?SERVER, {subscribe, Arg}).

unsubscribe(Arg) ->
    gen_server:call(?SERVER, {unsubscribe, Arg}).

lookup(Lookup) ->
    gen_server:call(?SERVER, {lookup, Lookup}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
    {ok, Args}.

handle_call({subscribe, #user{} = User}, _From, State) ->
    mnesia_utils:dirty_write(user, User),
    {reply, ok ,State};
handle_call({subscribe, [{_,_}|_] = Proplist}, _From, State) ->
    Res = case get_value(username, Proplist) of
        undefined ->
            {error, no_username};
        Username ->
            case get_value(registration_id, Proplist) of
                undefined ->
                    {error, no_registration_id};
                RegId ->
                    mnesia_utils:dirty_write(user,
                        #user{username=Username,
                              registration_id=RegId})
            end
    end,
    {reply, Res, State};
handle_call({unsubscribe, #user{username=Username}}, _From, State) ->
    Res = mnesia_utils:dirty_delete(user, Username),
    {reply, Res, State};
handle_call({unsubscribe, [{_,_}|_] = Proplist}, _From, State) ->
    Username = get_value(username, Proplist),
    Res = mnesia_utils:dirty_delete(user, Username),
    {reply, Res, State};
handle_call({unsubscribe, Username}, _From, State) ->
    Res = mnesia_utils:dirty_delete(user, Username),
    {reply, Res, State};
handle_call({lookup, {username, Username}}, _From, State) ->
    Res = mnesia_utils:dirty_read(user, Username),
    {reply, Res, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unhandled_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

get_value(Key, List) ->
    get_value(Key, List, undefined).

get_value(Key, List, Default) ->
    A = ?Atom(Key),
    S = ?Str(Key),
    case proplists:is_defined(A, List) of
        true -> proplists:get_value(A, List);
        false ->
            case proplists:is_defined(S, List) of
                true -> proplists:get_value(S, List);
                false -> Default
            end
    end.

