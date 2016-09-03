%%%-------------------------------------------------------------------
%%% @author Niclas Axelsson <niclas@burbasconsulting.com>
%%% @doc
%%% Worker module for erlbeat
%%% @end
%%% Created :  3 Sep 2016 by Niclas Axelsson <niclas@burbasconsulting.com>
%%%-------------------------------------------------------------------
-module(erlbeat_worker).

-behaviour(gen_server).

%% API
-export([start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
          service_uri :: pid() | list(), %% The service we are connected to
          protocol :: 'http' | 'erlang', %% We might want to support different protocols?
          last_seen :: {integer(), integer(), integer()}, %% Timestamp
          timeouts = 0 :: integer(), %% How many timeouts do we have?
          timeout = 5000 :: integer(), %% How long are we waiting for a pong?
          waiting_pong = false :: boolean(), %% Are we waiting for a pong?
          ping_process :: pid(), %% The process that are handliing our pingbacks
          is_alive = true :: boolean() %% Indicates if the service is alive or not
         }).

-define(TIMEOUT_THRESHOLD, 10). %% How many timeouts in a row do we concider "okay"
-define(LOG(Level, X), io:format("[~p][~p] ~p~n", [Level, self(), X])).

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Arguments) ->
    gen_server:start_link(?MODULE, Arguments, []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Args) ->
    Uri = proplists:get_value(uri, Args),
    Protocol = proplists:get_value(protocol, Args),
    Timeout = proplists:get_value(timeout, Args, 5000),
    LastSeen = erlang:timestamp(),
    This = self(),
    PingProc = spawn_link(fun() -> ping_function(This, Timeout) end),
    {ok, #state{
            service_uri = Uri,
            last_seen = LastSeen,
            protocol = Protocol,
            timeout = Timeout,
            ping_process = PingProc
           }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(ping, State = #state{waiting_pong = false}) ->
    %% Ping the service we are handling
    case State#state.protocol of
        http ->
            %% Ping via httpc
            httpc:request(get, {State#state.service_uri, []}, [], [{sync, false},
                                                                   {receiver, self()}]);
        erlang ->
            %% Native erlang process which should be fairly simple to
            %% ping.
            This = self(),
            State#state.service_uri ! {ping, This} %% Send a ping
    end,

    %% Check the previous state of the process we're pinging
    case State#state.is_alive of
        true ->
            %% We don't need to do anything
            ok;
        false ->
            %% Set the timeout back to the default value
            State#state.ping_process ! {set_timeout, State#state.timeout}
    end,
    %% We might want to do something with the reply?
    {noreply, State#state{waiting_pong = true}};

handle_cast(ping, State = #state{waiting_pong = true, timeouts = Timeouts}) ->
    case Timeouts of
        T when T > ?TIMEOUT_THRESHOLD ->
            %% We should throw out a big warning that this service is probably down.
            ?LOG(error, "Service is down. Notice the master about it"),
            erlbeat:report(service_down, self(), State#state.service_uri),
            %% Reset the timeout variable so we don't get multiple warnings and increase the timeout value
            %% exponentially
            State#state.ping_process ! double_timeout,
            {noreply, State#state{timeouts = 0, is_alive = false}};
        _ ->
            %% Let's wait for another timeout - Might not be serious but log a small warning
            ?LOG(warning, "Service got timeout."),
            {noreply, State#state{timeouts = State#state.timeouts + 1}}
    end;
handle_cast(stop, State) ->
    %% Stop ping process
    State#state.ping_process ! stop,
    %% Stop this worker normally
    {stop, normal, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({pong, _Message, _From}, State) ->
    %% We got a pong from the service. Do something nice with the message?
    {noreply, State#state{last_seen = erlang:timestamp(),
                          waiting_pong = false}};
handle_info({http, ReplyInfo}, State) ->
    NewState =
        case ReplyInfo of
            {_RequestId, {{_HttpVersion, 200, _}, _Headers, _Body}} ->
                ?LOG(info, "Got ping and all is fine"),
                State#state{last_seen = erlang:timestamp(),
                            waiting_pong = false};
            {_RequestId, {{_HttpVersion, StatusCode, _}, _Headers, _Body}}
              when is_integer(StatusCode) ->
                %% We did not get a 200. This should also be reported and the service
                %% should be concidered to be down.
                case State#state.timeouts of
                    T when T > ?TIMEOUT_THRESHOLD ->
                        ?LOG(error, "Service is down. Notice the master about it"),
                        State#state.ping_process ! double_timeout,
                        State#state{is_alive = false,
                                    timeouts = 0};
                    _ ->
                        ?LOG(warning, "Service got timeout."),
                        State#state{timeouts = State#state.timeouts + 1}
                end;
            ReplyInfo ->
                %% Just push a debug message here
                io:format("Got message: ~p~n", [ReplyInfo]),
                ?LOG(debug, "Unknown message received"),
                State
        end,
    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
ping_function(Worker, Timeout) ->
    receive
        %% Should we receive something here?
        stop ->
            ok;
        double_timeout ->
            ping_function(Worker, Timeout * 2);
        {set_timeout, Value} ->
            ping_function(Worker, Value)
    after Timeout ->
            gen_server:cast(Worker, ping),
            ping_function(Worker, Timeout)
    end.
