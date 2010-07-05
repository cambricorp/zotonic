%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2009 Marc Worrell
%% @date 2009-06-03

%% @doc Module supervisor.  Starts/restarts module processes.
%% @todo Take module dependencies into account when starting/restarting modules.

%% Copyright 2009 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(z_module_sup).
-author('Marc Worrell <marc@worrell.nl>').

-behaviour(supervisor).

%% External exports
-export([start_link/1, upgrade/1]).

%% supervisor callbacks
-export([init/1, deactivate/2, activate/2, active/1, active/2, active_dir/1, all/1, scan/1, prio/1, prio_sort/1, module_exists/1, title/1]).

-include_lib("zotonic.hrl").

%% The default module priority
-define(MOD_PRIO, 500).



%% @spec start_link(Args) -> ServerRet
%% @doc API for starting the module supervisor.
start_link(SiteProps) ->
    Host = proplists:get_value(host, SiteProps),
    Context = z_context:new(Host),
    Args1 = [{context, Context} | SiteProps],
    Name = z_utils:name_for_host(?MODULE, Host),
    Result = supervisor:start_link({local, Name}, ?MODULE, Args1),
    z_notifier:notify(module_ready, Context),
    Result.


%% @spec upgrade(context()) -> ok
%% @doc Reload the list of all modules, add processes if necessary.
upgrade(Context) ->
    Specs = module_specs(Context),
    ModuleSup = Context#context.module_sup,

    z_depcache:flush(z_modules, Context),
    
    Children = supervisor:which_children(ModuleSup),
    Old  = sets:from_list([Name || {Name, _, _, _} <- Children]),
    OldPid = [{Name,Pid} || {Name, Pid, _, _, _} <- Children],
    New  = sets:from_list([Name || {Name, _, _, _, _, _} <- Specs]),
    Kill = sets:subtract(Old, New),
    Create = sets:to_list(sets:subtract(New, Old)),

    sets:fold(fun (Module, ok) ->
              remove_observers(Module, proplists:get_value(Module, OldPid), Context),
              supervisor:terminate_child(ModuleSup, Module),
              supervisor:delete_child(ModuleSup, Module),
              ok
          end, ok, Kill),

    sets:fold(fun(Module, ok) -> 
                z_notifier:notify({module_deactivate, Module}, Context), 
                ok 
            end, ok, Kill),

    CreateSpecs = [lists:keyfind(C, 1, Specs) || C <- Create],
    CreateResult = [ start_child(ModuleSup, Spec) || Spec <- CreateSpecs ],

    lists:foldl(fun(Module, [{ok,Pid}|Rest]) when is_pid(Pid) -> 
                        add_observers(Module, Pid, Context),
                        z_notifier:notify({module_activate, Module, Pid}, Context), 
                        Rest;
                   (Module, [{ok,undefined}|Rest]) -> 
                        %% module did not start
                        supervisor:delete_child(ModuleSup, Module),
                        Rest;
                   (_, [_|Rest]) -> 
                        Rest
                end, CreateResult, Create),

    z_notifier:notify(module_ready, Context),
    CreateResult.


    %% @doc Try to start the child, do not crash on missing modules.
    start_child(ModuleSup, {Name, _, _, _, _, _} = Spec) ->
        Info =  try
                    erlang:get_module_info(Name, attributes)
                catch
                    M:E -> 
                        ?ERROR("Can not fetch module info for module ~p, error: ~p:~p", [Name, M, E]),
                        error
                end,
        case Info of
            L when is_list(L) ->
                supervisor:start_child(ModuleSup, Spec);
            error ->
                error
        end.
        

%% @spec init(proplist()) -> SupervisorTree
%% @doc supervisor callback.  The proplist is the concatenation of {context,_} and the site configuration.
%% This does not start any modules, they are started by a call to upgrade/1 from z_site_startup.
init(_Args) ->
    {ok, {{one_for_one, 1000, 10}, []}}.


%% @doc Get process specs for all modules
module_specs(Context) ->
    Args = [ {context, Context} | z_sites_sup:get_site_config(z_context:site(Context))],
    Ms0 = lists:filter(fun module_exists/1, active(Context)),
    Ms  = lists:filter(fun(Mod) -> valid(Mod, Context) end, Ms0),
    lists:map(
		fun(M) ->
			GenServerModule = gen_server_module(M),
	        {M, 
	            {GenServerModule, start_link, [Args]},
	            permanent, 5000, worker, [GenServerModule]}
 		end, Ms).

	
	%% When a module does not implement a gen_server then we use a dummy gen_server.
	gen_server_module(M) ->
		case proplists:get_value(behaviour, erlang:get_module_info(M, attributes)) of
			L when is_list(L) ->
				case lists:member(gen_server, L) of
					true -> M;
					false -> z_module_dummy
				end;
			undefined ->
				z_module_dummy
		end.
			

%% @doc Deactivate a module. The module is marked as deactivated and stopped when it was running.
%% @spec deactivate(Module, context()) -> ok
deactivate(Module, Context) ->
    case z_db:q("update module set is_active = false, modified = now() where name = $1", [Module], Context) of
        1 -> upgrade(Context);
        0 -> ok
    end.


%% @doc Activate a module. The module is marked as active and started as a child of the module supervisor.
%% @spec deactivate(Module, context()) -> ok
activate(Module, Context) ->
    Scanned = scan(Context),
    {Module, _Dirname} = proplists:lookup(Module, Scanned),
    F = fun(Ctx) ->
        case z_db:q("update module set is_active = true, modified = now() where name = $1", [Module], Ctx) of
            0 -> z_db:q("insert into module (name, is_active) values ($1, true)", [Module], Ctx);
            1 -> 1
        end
    end,
    z_db:transaction(F, Context),
    case upgrade(Context) of
        [{ok, Pid}] when is_pid(Pid) ->
            %% OK
            true;
        _ ->
            %% Error / not configured
            1 = z_db:q("update module set is_active = false, modified = now() where name = $1", [Module], Context),
            false
    end.


%% @doc Return the list of active modules.
%% @spec active(context()) -> [ atom() ]
active(Context) ->
    Modules = z_db:q("select name from module where is_active = true order by name", Context),
    [ z_convert:to_atom(M) || {M} <- Modules ].


%% @doc Return whether a specific module is active.
%% @spec active(context()) -> [ atom() ]
active(Module, Context) ->
    case z_db:q("select true from module where name = $1 and is_active = true", [Module], Context) of
        [{true}] ->
            true;
        _ ->
            false
    end.


%% @doc Return the list of all active modules and their directories
%% @spec active_dir(context()) -> [ {atom, Dir}, ... ]
active_dir(Context) ->
    Active = active(Context),
    All    = scan(Context),
    [ {M, proplists:get_value(M, All)} || M <- Active ].


%% @doc Return the list of all modules in the database.
%% @spec active(context()) -> [ atom() ]
all(Context) ->
   Modules = z_db:q("select name from module order by name", Context),
   [ z_convert:to_atom(M) || {M} <- Modules ].


%% @doc Scan for a list of modules present in the site's module directories. A module is always a directory,
%% the name of the directory is the same as the name of the module.
%% @spec scan(context()) -> [ {atom(), dirname()} ]
scan(#context{host=Host}) ->
    Priv  = filename:join([z_utils:lib_dir(priv), "sites", Host, "modules", "mod_*"]),
    Src   = filename:join([z_utils:lib_dir(modules), "mod_*"]),
    Site  = filename:join([z_utils:lib_dir(priv), "sites", Host]),
    Files = filelib:wildcard(Priv) ++ filelib:wildcard(Src) ++ [Site],
    [ {z_convert:to_atom(filename:basename(F)), F} ||  F <- Files ].


%% @doc Return the priority of a module. Default priority is 500, lower is higher priority.  Never crash on a missing module.
%% @spec prio(Module) -> integer()
prio(Module) ->
    try
        Info = erlang:get_module_info(Module, attributes),
        case proplists:get_value(mod_prio, Info) of
            [Prio] -> Prio;
            _ -> ?MOD_PRIO
        end
    catch
        _M:_E -> ?MOD_PRIO
    end.


%% @doc Sort the results of a scan on module priority first, module name next. The list is made up of {module, Values} tuples
%% @spec prio_sort(proplist()) -> proplist()
prio_sort(ModuleProps) ->
    WithPrio = [ {z_module_sup:prio(M), {M, X}} || {M, X} <- ModuleProps ],
    Sorted = lists:sort(WithPrio),
    [ X || {_Prio, X} <- Sorted ].


%% @doc Check whether given module is valid for the given host
%% @spec valid(atom(), context()) -> bool()
valid(M, Context) ->
    lists:member(M, [Mod || {Mod,_} <- scan(Context)]).


module_exists(M) ->
    case code:ensure_loaded(M) of
        {module,M} -> true;
        {error, _} -> false
    end.

%%
%% Get the title of a module.
%%    
title(M) ->
    try
        proplists:get_value(mod_title, M:module_info(attributes))
    catch
        _M:_E -> undefined
    end.


%% @doc Add the observers for a module, called after module has been activated
add_observers(Module, Pid, Context) ->
    [ z_notifier:observe(Message, Handler, Context) || {Message, Handler} <- observes(Module, Pid) ].


%% @doc Remove the observers for a module, called before module is deactivated
remove_observers(Module, Pid, Context) ->
    [ z_notifier:detach(Message, Handler, Context) || {Message, Handler} <- lists:reverse(observes(Module, Pid)) ].


%% @doc Get the list of events the module observes.
%% The event functions should be called: observe_<event>
%% observe_xxx/2 functions observer map/notify and observe_xxx/3 functions observe folds.
%% @spec observes(atom(), pid()) -> [{atom(), Handler}]
observes(Module, Pid) ->
    observes(Module, Pid, erlang:get_module_info(Module, exports), []).
    
    observes(_Module, _Pid, [], Acc) ->
        Acc;
    observes(Module, Pid, [{F,Arity}|Rest], Acc) ->
        case atom_to_list(F) of
            "observe_" ++ Message when Arity == 2; Arity == 3 ->
                observes(Module, Pid, Rest, [{list_to_atom(Message), {Module,F}}|Acc]);
            "pid_observe_" ++ Message when Arity == 3; Arity == 4 ->
                observes(Module, Pid, Rest, [{list_to_atom(Message), {Module,F,[Pid]}}|Acc]);
            _ -> 
                observes(Module, Pid, Rest, Acc)
        end;
    observes(Module, Pid, [_|Rest], Acc) -> 
        observes(Module, Pid, Rest, Acc).
