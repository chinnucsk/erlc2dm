-module(c2dm_publisher_svr).
-behavior(gen_server).

-export([start_link/1]).
-export([send/3, get_state/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(http_config, {host,
                      port,
                      path,
                      method,
                      headers=[],
                      params=[]}).
-record(state, {auth_token,
                google_login,
                google_c2dm,
                throttle={false, undefined}}).

-define(HTTP_TIMEOUT, timer:seconds(30)).
-define(C2DM_TIMEOUT, 250).
-define(EXPONENTIAL_FACTOR, 2).

-include_lib("pb2utils/include/pb2utils.hrl").
-include("../include/c2dm.hrl").

%% PUBLIC API
start_link(App) ->
    case load_config(App) of
        {ok, LoginConfig, C2dmConfig} ->
            gen_server:start_link({local, ?MODULE}, ?MODULE, [LoginConfig, C2dmConfig], []);
        {error, Error} -> {error, Error}
    end.

send(Type, Key, Proplist) ->
    case Type of
        required ->
            gen_server:call(?MODULE, {send, {Key, Proplist}});
        _ ->
            gen_server:cast(?MODULE, {send, {Key, Proplist}}),
            % all async sends successful
            {ok, Type}
    end.

get_state() ->
    gen_server:call(?MODULE, get_state).

%% GEN_SERVER API
init([LoginConfig, C2dmConfig]) ->
    {ok, #state{  google_login=LoginConfig
                , google_c2dm=C2dmConfig}, 0}.

handle_call(get_state, _From, State0) ->
    {reply, State0, State0};
handle_call({send, {Key, Proplist}}, _From, State0) ->
    case do_send(Key, Proplist, State0) of
        {ok, State1} ->
            {reply, ok, State1};
        {{error, Error},  ErrState} ->
            ?ERROR("~p~n", [Error]),
            {reply, {error, Error}, ErrState}
    end;
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({send, {Key, Proplist}}, State0) ->
    case do_send(Key, Proplist, State0) of
        {ok, State1} ->
            {noreply, State1};
        {{error, Error}, ErrState} ->
            ?ERROR("~p~n", [Error]),
            {noreply, ErrState}
    end;
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(unthrottle, #state{throttle={_, Itr}} = State) ->
    {noreply, State#state{throttle={false, Itr}}};
handle_info(timeout, State) ->
    case http_request(google_login, State) of
        {ok, _Headers, Body} ->
            case process_login_response(Body) of
                {ok, Token} ->
                    {noreply, State#state{auth_token=Token}};
                {error, Error} ->
                    ?ERROR("failed to parse token ~p~n~p~n", [Error, Body]),
                    {noreply, State}
            end;
        {error, Error} ->
            ?ERROR("login error -> ~p~n", [Error]),
            {noreply, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% PRIVATE API
do_send(Lookup, Proplist0, State0) ->
    Proplist1=lists:map(fun({K,V}) -> {"data."++K,V} end,Proplist0),
    case lookup(Lookup) of
        {ok, Regs} ->
            Proplist2 = set_if_undefined(
                            {collapse_key, "default_collapse_key"},
                            Proplist1),
            Proplist3 = set_if_undefined(
                            {delay_while_idle, "0"},
                            Proplist2),
            do_raw_send(Regs, Proplist3, State0);
        {error, Error} ->
            {{error, Error}, State0}
    end.

do_raw_send(RegId, Proplist0, State0) ->
    Proplist1 = [{"registration_id", RegId}|Proplist0],
    case http_request(google_c2dm, Proplist1, State0) of
        {ok, Headers, Body} ->
            %%% check and update auth token in header
            State1 = update_client_auth(Headers, State0),
            %%% get the body in a sane record
            case parse_body(Body) of
                {ok, message_sent, _MsgId} ->
                    SuccessState = handle_success(State1),
                    {ok, SuccessState};
                {error, Error} ->
                    ErrState = handle_error(Error, State1),
                    {{error, Error}, ErrState}
            end;
        {error, Error} ->
            {{error, Error}, State0}
    end.


lookup({username, Username}) ->
    case c2dm_db_svr:lookup({username, Username}) of
        [] ->
            {error, user_has_no_registration};
        [User] ->
            case User#user.registration_id of
                undefined ->
                    {error, user_has_undefined_registration};
                RegId ->
                    {ok, RegId}
            end
    end.

update_client_auth(Headers, State) ->
    case proplists:get_value("Update-Client-Auth", Headers) of
        undefined -> State;
        Token ->
            State#state{auth_token=Token}
    end.

parse_body("id=" ++ MsgId) ->
    {ok, message_sent, MsgId};
parse_body("Error=" ++ Error) ->
    {error, map_error(Error)}.

map_error("QuotaExceeded")       -> quota_exceeded;
map_error("DeviceQuotaExceeded") -> device_quota_exceeded;
map_error("MissingRegistration") -> missing_registration;
map_error("InvalidRegistration") -> invalid_registration;
map_error("MismatchSenderId")    -> mismatch_sender_id;
map_error("NotRegistered")       -> not_registered;
map_error("MessageTooBig")       -> messsge_too_big;
map_error("MissingCollapseKey")  -> missing_collapse_key;
map_error(Err)                   -> ?Atom(Err).

handle_success(State) ->
    %% reset all throttle state
    State#state{throttle={false, 0}}.

%% calculat the next throttle delay
next_delay(Itr) ->
    round((random:uniform() + 1)
        * ?C2DM_TIMEOUT
        * math:pow(?EXPONENTIAL_FACTOR, Itr)).

% Too many messages sent by the sender. Retry after a while.
handle_error(quota_exceeded,
        #state{throttle={false,Itr}}=State) when is_integer(Itr) ->
    %%% first handle after coming out of throttle delay
    %%% if C2DM sends back another quota_exceeded, continue
    %%% the throttle to the next iteration delay
    timer:send_after(next_delay(Itr), unthrottle),
    State#state{throttle={true, Itr + 1}};
handle_error(quota_exceeded, State) ->
    %%$ first quota_exceeded... first throttle iteration
    State#state{throttle={true, 1}};
% Too many messages sent by the sender to a specific device.
% Retry after a while.
handle_error(device_quota_exceeded, State) ->
    %%% should the device be taken offline?
    State;
% Missing registration_id.
% Sender should always add the registration_id to the request.
handle_error(missing_registration, State) ->
    State;
% Bad registration_id. Sender should remove this registration_id.
handle_error(invalid_registration, State) ->
    State;
% The sender_id contained in the registration_id does not match
% the sender id used to register with the C2DM servers.
handle_error(mismatch_sender_id, State) ->
    State;
% The user has uninstalled the application or turned off
% notifications. Sender should stop sending messages to this device
% and delete the registration_id. The client needs to re-register
% with the c2dm servers to receive notifications again.
handle_error(not_registered, State) ->
    State;
% The payload of the message is too big, see the limitations.
% Reduce the size of the message.
handle_error(messsge_too_big, State) ->
    State;
%Collapse key is required. Include collapse key in the request.
handle_error(missing_collapse_key, State) ->
    State;
handle_error(Error, State) ->
    ?ERROR("unknown response -> ~p~n", [Error]),
    State.

%% HTTP REQUSTS
http_request(google_login, State) ->
    http_request(State#state.google_login, [], []).

http_request(google_c2dm, Proplist, State) ->
    Headers = [{"Authorization", "GoogleLogin "
            ++ State#state.auth_token}],
    http_request(State#state.google_c2dm, Proplist, Headers);
http_request(
    #http_config{  host=Host
                 , port=Port
                 , path=Path
                 , headers=ConfigHeaders
                 , method=Method
                 , params=Params}, Proplist, Headers0) ->
    Headers1 = Headers0 ++ ConfigHeaders,
    Opts = [{is_ssl, true}, {ssl_options,[]}],
    Body = urlencode(Proplist ++ Params),
    Url = lists:flatten("https://"
                        ++ ?Str(Host)
                        ++ ":"
                        ++ ?Str(Port)
                        ++ ?Str(Path)),
    Res=ibrowse:send_req(Url, Headers1, Method, Body, Opts, ?HTTP_TIMEOUT),
    handle_status(Res).

%%% RAW HTTP RESPONSE MESSAGE TRANSLATING
handle_status({ok, "200", H, B}) ->
    {ok, H, B};
handle_status({ok, "401", _, _}) ->
    {error, c2dm_bad_token};
handle_status({ok, "403", _, _}) ->
    {error, c2dm_login_bad_auth};
handle_status({ok, "503", _, _}) ->
    {ok, c2dm_throttle};
handle_status({ok, S, H, B}) ->
    ?ERROR("c2dm_unknown_response_code -> ~p~n", [{S, H, B}]),
    {error, c2dm_unknown_response_code};
handle_status({error, Error}) ->
    {error, Error};
handle_status(_) ->
    {error, unexpected_result}.

%%% LOGIN RESPONSE PARSING
parse_for_token([$A,$u,$t,$h|Token], _) ->
    % lower case for subsequent requests
    [$a,$u,$t,$h|Token];
parse_for_token(_, Acc) ->
    Acc.

process_login_response(Body) ->
    % is there a case for \r\n ???
    Lines = string:tokens(Body, "\n"),
    case lists:foldl(fun parse_for_token/2, [], Lines) of
        [] ->
            {error, no_token};
        Token ->
            {ok, Token}
    end.

%%% URL ENCODING UTILITY
urlencode(Props) ->
    RevPairs = lists:foldl(
        fun ({K, V}, Acc) ->
                [[urlencode_term(?Str(K)),
                  $=,
                  urlencode_term(?Str(V))]
                    | Acc]
        end, [], Props),
    lists:flatten(revjoin(RevPairs, $&, [])).

revjoin([], _Separator, Acc) ->
    Acc;
revjoin([S | Rest], Separator, []) ->
    revjoin(Rest, Separator, [S]);
revjoin([S | Rest], Separator, Acc) ->
    revjoin(Rest, Separator, [S, Separator | Acc]).

urlencode_term([H|T]) ->
    if
        H >= $a, $z >= H ->
            [H|urlencode_term(T)];
        H >= $A, $Z >= H ->
            [H|urlencode_term(T)];
        H >= $0, $9 >= H ->
            [H|urlencode_term(T)];
        H == $_; H == $.; H == $-; H == $/; H == $: ->
            [H|urlencode_term(T)];
        true ->
            case integer_to_hex(H) of
                [X, Y] ->
                    [$%, X, Y | urlencode_term(T)];
                [X] ->
                    [$%, $0, X | urlencode_term(T)]
            end
    end;
urlencode_term([]) ->
    [].

integer_to_hex(I) ->
    erlang:integer_to_list(I, 16).

%%% CONFIG LOAD
load_config(App) ->
    case application:get_all_env(App) of
        undefined ->
            {error, no_app_http_config};
        Proplist ->
            case load_http_config(google_login, Proplist) of
                {ok, LoginConfig} ->
                    case load_http_config(google_c2dm, Proplist) of
                        {ok, C2dmConfig} ->
                            {ok, LoginConfig, C2dmConfig};
                        Error -> Error
                    end;
                Error -> Error
            end
    end.

load_http_config(Scope, Config) ->
    case proplists:get_value(Scope, Config) of
        undefined ->
            {error, no_config};
        Proplist ->
            Host = proplists:get_value(host, Proplist),
            Port = proplists:get_value(port, Proplist, 80),
            Path = proplists:get_value(path, Proplist,"/"),
            Method = proplists:get_value(method, Proplist, post),
            Headers = proplists:get_value(headers, Proplist,[]),
            Params = proplists:get_value(params, Proplist,[]),
            HttpConfig = #http_config{
                            host=Host, port=Port, path=Path,
                            method=Method, headers=Headers,
                            params=Params},
            {ok, HttpConfig}
    end. 

%%% GENERAL UTILITIES
set_if_undefined({K,V}, List) ->
    A = ?Atom(K),
    S = ?Str(K),
    case proplists:is_defined(A, List) of
        true  -> List;
        false ->
            case proplists:is_defined(S, List) of
                true  -> List;
                false -> [{K,V}|List]
            end
    end.

