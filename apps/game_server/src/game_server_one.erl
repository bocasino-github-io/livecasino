-module(game_server_one).
-behavior(gen_fsm).

-compile([{parse_transform, lager_transform}]).
-include("round.hrl").
-include("dealer.hrl").
-include("user.hrl").
-include("game.hrl").

-record(state,{dealer,table,ticker,cards,countdown,round,eventbus,game}).

-export([init/1,code_change/4,handle_event/3,handle_info/3,handle_sync_event/4,terminate/3]).
-export([stopped/3,dealing/3,betting/3]).
-export([start_game_server/3]).

-define(CASINO_DB,mysql_casino_master).
-define(GLOBAL_GAME_SERVER(DealerTableId),{global,{game_server,DealerTableId}}).

start_game_server(Game,DealerTableId,Countdown) when  is_integer(DealerTableId) andalso is_integer(Countdown)->
	gen_fsm:start_link(?GLOBAL_GAME_SERVER(DealerTableId),?MODULE,{Game,DealerTableId,Countdown},[]).

init({Game,Table,Countdown})->
	{ok,EventBus}=gen_event:start_link(),
	{ok,stopped,#state{countdown=Countdown,table=Table,eventbus=EventBus,game=Game}}.

stopped(new_shoe,{Pid,_},State=#state{dealer={Pid,_},round=Round})->
	lager:info("stopped#new_shoe,state ~p",[State]),
	NewRound=casino_shoe_round:new_shoe(Round),
	NewState=State#state{round=NewRound},
	{reply,ok,stopped,NewState};

stopped(start_bet,{Pid,_},State=#state{dealer={Pid,_},round=undefined})->
	lager:info("stopped#start_bet,state ~p",[State]),
	{reply,{error,need_new_shoe},stopped,State};

stopped(start_bet,{Pid,_},State=#state{countdown=Countdown,dealer={Pid,Dealer},round=Round,table=Table,eventbus=EventBus})->
	lager:info("stopped#start_bet,state ~p",[State]),
	NewRound=casino_shoe_round:new_round(Round),
	NewRoundId=casino_shoe_round:persist_round(NewRound,Dealer#dealer.id,Table),
	NewRound2=NewRound#round{id=NewRoundId},
	gen_event:notify(EventBus,{start_bet,{Table,NewRound2,Countdown}}),
	TRef=erlang:send_after(1000,self(),tick),
	NewState=State#state{ticker={TRef,Countdown},cards=#{},round=NewRound2},
	{reply,ok,betting,NewState};
	
stopped(Event,_From,State)->
	lager:error("unexpected event when stopped, event ~p,state ~p",[Event,State]),
	{reply,{error,unexpected},stopped,State}.


betting(Event={try_bet,_Cats,_Amounts},_From,State)->
	lager:info("bet Event ~p,State ~p",[Event,State]),
	{reply,ok,betting,State};
	
betting(stop_bet,{Pid,_},State=#state{ticker={TRef,_},dealer={Pid,_},round=Round,table=Table,eventbus=EventBus})->
	lager:info("betting#stop_bet,state ~p",[State]),
	erlang:cancel_timer(TRef),
	1=mysql_db:update_round(?CASINO_DB,Round#round.id,casino_utils:mills()),
	gen_event:notify(EventBus,{stop_bet,Table}),
	NewState=State#state{ticker=undefined},
	{reply,ok,dealing,NewState};

betting(Event,_From,State)->
	lager:error("unexpected event when betting, event ~p,state ~p",[Event,State]),
	{reply,{error,unexpected},betting,State}.

dealing(Event={deal,Pos,CardL},{Pid,_},State=#state{cards=Cards,dealer={Pid,_},table=Table,eventbus=EventBus,game=#game{module=Module}})->
	lager:info("dealing#deal, Event ~p, State ~p",[Event,State]),
	Card=casino_card:one_card(CardL),
	case Module:put(Pos,Card,Cards) of
		{ok,NewCards} ->
			NewState=State#state{cards=NewCards},
			gen_event:notify(EventBus,{deal,{Table,Pos,Card}}),
			{reply,ok,dealing,NewState};
		error ->
			{reply,error,dealing,State}
	end;


dealing(Event={scan,CardL},{Pid,_},State=#state{cards=Cards,dealer={Pid,_},table=Table,eventbus=EventBus,game=#game{module=Module}})->
	lager:info("dealing#scan, Event ~p, State ~p",[Event,State]),
	Card=casino_card:one_card(CardL),
	case Module:add(Card,Cards) of
		{error,_} ->
			{reply,error,dealing,State};
		{Status,Pos,NewCards}->
			gen_event:notify(EventBus,{deal,{Table,Pos,Card}}),
			{reply,{ok,Status,Pos},dealing,State#state{cards=NewCards}}
	end;


dealing(Event={clear,Pos},{Pid,_},State=#state{cards=Cards,dealer={Pid,_},table=Table,eventbus=EventBus,game=#game{module=Module}})->
	lager:info("dealing#clear, Event ~p, State ~p",[Event,State]),
	case Module:remove(Pos,Cards) of
		{ok,NewCards} ->
			NewState=State#state{cards=NewCards},
			gen_event:notify(EventBus,{clear,{Table,Pos}}),
			{reply,ok,dealing,NewState};
		error ->
			{reply,error,dealing,State}
	end;


dealing(commit,{Pid,_},State=#state{cards=Cards,dealer={Pid,_},round=Round,table=Table,eventbus=EventBus,game=#game{module=Module}})->
	lager:info("dealing#commit, State ~p",[State]),
	%%check the cards are valid in accordence with the game rule
	case Module:validate(Cards) of
		true->
			Mills=casino_utils:mills(),
			Cstr=Module:to_string(Cards),
			1=mysql_db:update_round(?CASINO_DB,Round#round.id,Cstr,Mills),
			gen_event:notify(EventBus,{commit,{Table,Cards}}),				
			{reply,ok,stopped,State};
		false->
			{reply,error,dealing,State}
	end;


dealing(Event,_From,State)->
	lager:error("unexpected event when dealing, event ~p,state ~p",[Event,State]),
	{reply,{error,unexpected},dealing,State}.


handle_info(tick,betting,State=#state{ticker=Ticker,table=Table,eventbus=EventBus})->
	%%send the tick to all players intrested in
	lager:info("handle tick when betting, state ~p",[State]),	
	case Ticker of
		{_,0} ->
			gen_event:notify(EventBus,{tick,{Table,0}}),
			{next_state,betting,State};
		{_,Value}->
			gen_event:notify(EventBus,{tick,{Table,Value}}),
			TRef=erlang:send_after(1000,self(),tick),
			NewState=State#state{ticker={TRef,Value-1}},
			{next_state,betting,NewState}
	end;
handle_info(Info={'DOWN',_Ref,process,Pid,_},StateName,State=#state{dealer={Pid,Dealer},table=Table,eventbus=EventBus})->
	lager:error("handle dealer process DOWN, info ~p,stateName ~p,state ~p",[Info,StateName,State]),
	NewState=State#state{dealer=undefined},
	gen_event:notify(EventBus,{dealer_disconnect,{Table,Dealer}}),
	{next_state,StateName,NewState};
	
handle_info(Info,StateName,State)->
	lager:error("unexpected handle info, info ~p,stateName ~p,state ~p",[Info,StateName,State]),
	{next_state,StateName,State}.

handle_event(Event={player_quit,#user{id=UserId},Reason},StateName,State=#state{eventbus=EventBus})->
	lager:info("player_quit handle_event, event ~p,stateName ~p,state ~p",[Event,StateName,State]),
	gen_event:delete_handler(EventBus,{player_handler,UserId},Reason);

handle_event(Event={dealer_disconnect,Pid},StateName,State=#state{dealer={Pid,Dealer},table=Table,eventbus=EventBus})->
	lager:info("dealer_disconnect handle_event, event ~p,stateName ~p,state ~p",[Event,StateName,State]),
	gen_event:notify(EventBus,{dealer_disconnect,{Table,Dealer}}),
	NewState=State#state{dealer=undefined},
	{next_state,StateName,NewState};

handle_event(Event,StateName,State)->
	lager:error("unexpected handle_event, event ~p,stateName ~p,state ~p",[Event,StateName,State]),
	{next_state,StateName,State}.


handle_sync_event(Event={player_join,User=#user{id=UserId},PlayerTableId},From,StateName,State=#state{table=Table,eventbus=EventBus,game=#game{name=GameName}})->
	lager:info("player_join, event ~p,from ~p,stateName ~p,state ~p",[Event,From,StateName,State]),
	Handlers=gen_event:which_handlers(EventBus),
	case lists:member({player_handler,UserId},Handlers) of
		true->
			{reply,{error,already_joined},StateName,State};
		_->
			Result=casino_sup:start_player(GameName,Table,self(),EventBus,PlayerTableId,User),
			{reply,Result,StateName,State}
	end;

handle_sync_event(Event={update_countdown,Countdown},From,StateName,State)->
	lager:info("update_countdown, event ~p,from ~p,stateName ~p,state ~p",[Event,From,StateName,State]),
	if 
		Countdown > 0 -> 
			NewState=State#state{countdown=Countdown},
			{reply,ok,StateName,NewState};
		true ->
			{reply,error,StateName,State}
	end;

handle_sync_event(Event={dealer_connect,Dealer},From={Pid,_},StateName,State=#state{dealer=undefined,table=Table,eventbus=EventBus,game=#game{name=GameName}})->
	lager:info("dealer_connected, event ~p,from ~p,stateName ~p,state ~p",[Event,From,StateName,State]),
	NewState=State#state{dealer={Pid,Dealer}},
	erlang:monitor(process,Pid),
	gen_event:notify(EventBus,{dealer_connect,{Table,Dealer}}),
	{reply,{ok,GameName},StateName,NewState};

handle_sync_event(Event={dealer_connect,_Dealer},From,StateName,State)->
	lager:info("dealer_connected, event ~p,from ~p,stateName ~p,state ~p",[Event,From,StateName,State]),
	{reply,{error,dealer_existed},StateName,State};

handle_sync_event(Event,From,StateName,State)->
	lager:error("unexpected handle_sync_event, event ~p,from ~p,stateName ~p,state ~p",[Event,From,StateName,State]),
	{next_state,StateName,State}.

terminate(Reason,StateName,State)->
	lager:info("terminate, reason ~p,stateName ~p,state ~p",[Reason,StateName,State]),
	ok.

code_change(OldVsn,StateName,State,Extra)->
	lager:info("code_change oldVsn ~p,stateName ~p,state ~p,extra ~p",[OldVsn,StateName,State,Extra]),
	{ok,StateName,State}.