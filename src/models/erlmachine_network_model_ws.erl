-module(erlmachine_network_model_ws).
%% NOTE: https://ninenines.eu/docs/en/gun/2.0/guide/

-behaviour(erlmachine_worker_model).

-export([startup/4]).

-export([process/3, execute/3]).
-export([pressure/3]).

-export([shutdown/3]).

-include_lib("erlmachine/include/erlmachine_user.hrl").
-include_lib("erlmachine/include/erlmachine_system.hrl").

-type state() :: map().

-spec startup(UID::uid(), State::state(), Opt::map(), Env::map()) ->
                  success(state()).
startup(_UID, State, Opt, Env) ->
    Host = erlmachine_network:host(Env), Port = erlmachine_network:port(Env),
    Path = erlmachine_network:path(Env),

    T = erlmachine_network:transport(Opt),
    Retry = erlmachine_network:retry(Opt),
    Timeout = erlmachine_network:retry_timeout(Opt),

    Trace = erlmachine_network:trace(Opt),
    %Protocols = protocols(Opt),

    {ok, Pid} = gun:open(Host, Port, #{
                                       'transport' => T, 'protocols' => [http],
                                       'retry' => Retry,
                                       'retry_timeout' => Timeout,

                                       'trace' => Trace
                                      }),
    {ok, _} = gun:await_up(Pid),

    Ref = gun:ws_upgrade(Pid, Path),
    erlmachine:success(State#{
                              pid => Pid, ref => Ref,

                              host => Host,
                              port => Port,

                              path => Path
                             }).

-spec process(UID::uid(), Event::term(), State::state()) ->
                     success(state()) | failure(term(), term(), state()).
process(_UID, Event, State) ->
    Frame = erlmachine:body(Event),

    Pid = maps:get(pid, State),
    Ref = maps:get(ref, State),

    try
        ok = gun:ws_send(Pid, Ref, Frame),

        erlmachine:success(State)
    catch E:R ->
            erlmachine:failure(E, R, State)
    end.

-spec execute(UID::uid(), Action::term(), State::state()) ->
                     success(term(), state()) | failure(term(), term(), state()).
execute(_UID, Action, State) ->
    %% TODO Upgrade status check;
    Command = erlmachine:command_name(Action),
    _Args = erlmachine:body(Action),

    try Command of
        'info' ->
            Pid = maps:get(pid, State), Res = gun:info(Pid),

            erlmachine:success(Res, State)
    catch E:R ->
            erlmachine:failure(E, R, State)
    end.

-spec pressure(UID::uid(), Load::term(), State::state()) ->
                      success(state()).
pressure(_UID, {gun_ws, _Pid, _Ref, Frame}, State) when Frame == 'close';
                                                        Frame == 'ping';
                                                        Frame == 'pong' ->
    erlmachine:success(State);

pressure(_UID, {gun_ws, _Pid, Ref, {Tag, Msg}}, #{ref := Ref} = State) when Tag == 'text';
                                                                            Tag == 'binary';
                                                                            Tag == 'close' ->
    Host = maps:get(host, State), Port = maps:get(port, State),
    Path = maps:get(path, State),

    Header = #{
                host => Host, port => Port,
                path => Path
              },

    Doc = erlmachine:document(Header, Tag, Msg),
    erlmachine:success(Doc, State);

pressure(_UID, {gun_upgrade, _Pid, _Ref, [<<"websocket">>], _Headers}, State) ->
    %% TODO Upgraded state;
    erlmachine:success(State);

pressure(_UID, {gun_up, _Pid, _Proto}, State) ->
    erlmachine:success(State);

pressure(_UID, {gun_down, Pid, _Proto, closed, _}, State) ->
    Path = maps:get(path, State),

    Ref = gun:ws_upgrade(Pid, Path),
    %% TODO: Throw and restart handle {gun_down,<0.185.0>,http,closed,[]}
    %% MRef = monitor(process, ConnPid).
    erlmachine:success(State#{ ref => Ref });

pressure(_UID, {gun_error, _Pid, _Ref, Reason}, State) ->
    erlmachine:failure(Reason, State);

pressure(_UID, _Load, State) ->
    %% TODO: Logging
    erlmachine:success(State).

-spec shutdown(UID::uid(), Reason::term(), State::state()) ->
                      success().
shutdown(_UID, _Reason, State) ->
    Pid = maps:get(pid, State), ok = gun:close(Pid),

    erlmachine:success().
