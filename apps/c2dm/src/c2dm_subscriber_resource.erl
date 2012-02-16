-module(c2dm_subscriber_resource).

-export([init/1]).
-export([allowed_methods/2,
         resource_exists/2,
         post_is_create/2,
         process_post/2]).

-include_lib("webmachine/include/webmachine.hrl").
-include_lib("pb2utils/include/pb2utils.hrl").
-include("../include/c2dm.hrl").

init([]) -> {ok, undefined}.

allowed_methods(Req, Context) ->
    {['POST'], Req, Context}.

resource_exists(Req, Context) ->
    {true, Req, Context}.

post_is_create(Req, Context) ->
    {false, Req, Context}.

request_type(Req) ->
    Type = wrq:path_info(type, Req),
    LowerType = string:to_lower(Type),
    ?Atom(LowerType).

process_post(Req, Context) ->
    process_post(request_type(Req), Req, Context).

process_post(Action, Req, Context) ->
    case from_json(Req) of
        {struct, Proplist} ->
            Response = case c2dm_db_svr:Action(Proplist) of
                ok -> {struct, [{"success", true}]};
                _  -> {struct, [{"success", false}]}
            end,
            Res = send_json(Response, Req),
            {true, Res, Context};
        _ ->
            web_utils:error(true, invalid_request, Req, Context)
    end.

send_json(Json, Req) ->
    wrq:append_to_resp_body(to_json(Json), Req).

to_json(Json = {struct, _ }) ->
    mochijson:encode(Json).

from_json(Req) ->
    JsonOrError = try mochijson:decode(wrq:req_body(Req)) of
        Val -> Val
    catch
        _:Error -> {error, Error}
    end,
    JsonOrError.

