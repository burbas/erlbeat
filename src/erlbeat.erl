%%%-------------------------------------------------------------------
%%% @author Niclas Axelsson <niclas@burbasconsulting.com>
%%% @doc
%%%
%%% @end
%%% Created :  3 Sep 2016 by Niclas Axelsson <niclas@burbasconsulting.com>
%%%-------------------------------------------------------------------
-module(erlbeat).

-behaviour(gen_server).

%% API
-export([start_link/0,
         register_service/1,
         unregister_service/1,
         notify_contact/3,
         report/3
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% Declaration of types
-type uri() :: pid() | binary().
-type protocol() :: 'http' | 'erlang'.
-type contact_type() :: 'sms' | 'email'.
-type contact() :: {contact_type(), string()}.

-record(state, {
          registration_table :: pid() | atom()
         }).

-record(registration, {
          protocol :: protocol(),
          uri :: uri(),
          worker_pid :: pid(),
          contact :: [contact()]
         }).

-define(ETS_FILENAME, "priv/erlbeat.db").

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
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------
%% @doc
%% Register a new service to the monitoring tool
%% @end
%%--------------------------------------------------------------------
-spec register_service(Arguments :: [{atom(), any()}]) -> ok |
                                                          {error, Reason :: atom()}.
register_service(Arguments) ->
    gen_server:call(?MODULE, {register_service, Arguments}).


%%--------------------------------------------------------------------
%% @doc
%% Unregister the service from the monitoring system
%% @end
%%--------------------------------------------------------------------
-spec unregister_service(URI :: uri()) -> ok | {error, Reason :: atom()}.
unregister_service(URI) ->
    gen_server:call(?MODULE, {unregister_service, URI}).

%%--------------------------------------------------------------------
%% @doc
%% Reports an event to the server
%% @end
%%--------------------------------------------------------------------
-spec report(Type :: atom(), Pid :: pid(), ServiceURI :: uri()) -> ok.
report(Type, Pid, ServiceURI) when is_atom(Type),
                                   is_pid(Pid),
                                   is_list(ServiceURI) ->
    gen_server:cast(?MODULE, {new_report, Type, Pid, ServiceURI}).

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
init([]) ->
    RegistrationTable =
        case filelib:is_file(?ETS_FILENAME) of
            true ->
                ets:file2tab(?ETS_FILENAME);
            _ ->
                ets:new(registration_table, [set, {keypos, 3}])
        end,

    {ok, #state{
            registration_table = RegistrationTable
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
handle_call({register_service, Arguments}, _From, State =
           #state{registration_table = RT}) ->
    case erlbeat_worker:start_link(Arguments) of
        {ok, Pid} ->
            %% Get all the things from the argumentlist
            Registration =
                #registration{
                   protocol = proplists:get_value(protocol, Arguments),
                   uri = proplists:get_value(uri, Arguments),
                   worker_pid = Pid,
                   contact = proplists:get_value(contact, Arguments)
                  },
            %% Save the registration in the ETS table
            ets:insert(RT, Registration),
            %% Save ETS to disk
            ets:tab2file(RT, ?ETS_FILENAME, [{sync, true}]),
            {reply, ok, State};
        _ ->
            %% The worker could not be started. Return an error to the caller
            {reply, {error, could_not_start_worker}, State}
    end;
handle_call({unregister_service, URI}, _From, State =
                #state{registration_table = RT}) ->
    Reply =
        case ets:lookup(RT, URI) of
            [Registration = #registration{}] ->
                %% Let's shut down the worker
                gen_server:stop(Registration#registration.worker_pid),
                ok;
            _ ->
                %% We could not find the registration
                {error, registration_not_found}
        end,
    {reply, Reply, State};
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
handle_cast({new_report, service_down, URI}, State =
                #state{registration_table = RT}) ->
    %% Let's see if we can notify the person responsible for the URI somehow.
    case ets:lookup(RT, URI) of
        [#registration{
            contact = Contact
           }] ->
            notify_contact(Contact, service_down, URI);
        _ ->
            %% We should report this as an internal error. This should not happen!
            error
    end,
    {noreply, State};
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
handle_info({'EXIT', FromPid, Reason}, State =
                #state{registration_table = RT}) ->
    %% Need to find the service that's been stopped
    case ets:match(RT, {'_', '_', '$1', FromPid, '$2', '$3'}) of
        [{URI, _UserEmail, _UserMobile}|_] ->
            %% We have found a object matching the FromPid. Extract the URI (Which is
            %% the key) and delete the same object.
            ets:delete(RT, URI),
            case Reason of
                'normal' ->
                    %% This is a normal shutdown so just ignore it
                    ok;
                Reason ->
                    %% This might be a bug so we should be careful to log it.
                    ok
            end,
            ets:tab2file(RT, ?ETS_FILENAME, [{sync, true}]);
        _ ->
            ok
    end,
    {noreply, State};
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
notify_contact([], _Type, _URI) ->
    ok;
notify_contact([{email, Email}|Rest], service_down, URI) ->
    Username = application:get_env(erlbeat, email_username),
    Password = application:get_env(erlbeat, email_password),
    Relay = application:get_env(erlbeat, email_relay),
    From = application:get_env(erlbeat, email_address),
    FromName = application:get_env(erlbeat, email_name),

    gen_smtp_client:send({From, [Email],
                          "Subject: " ++ URI ++ " is down\r\n" ++
                              "From: " ++ FromName ++ "\r\n\r\n" ++
                              "Your service is down"}, [{relay, Relay},
                                                        {username, Username},
                                                        {password, Password}]),
    notify_contact(Rest, service_down, URI);

notify_contact([_Contact|Rest], Type, URI) ->
    notify_contact(Rest, Type, URI).
