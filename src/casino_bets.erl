-module(casino_bets).
-export([is_valid_bets/3,create_bet_req/5,insert_bets/4,payout_bets/2]).
-include("db.hrl").

is_valid_bet_cats(Cats,AllBetCats)->
	Cs=sets:from_list(Cats),
	L= sets:size(Cs),
	case length(Cats) of
		L->
			sets:is_subset(Cs,sets:from_list(AllBetCats));
		_ ->
			false
	end.
	
is_valid_bet_amounts(Amounts)->
	lists:all(fun(E)-> E>0 end,Amounts).
		
is_valid_bets(Cats=[C1|_],Amounts=[A1|_],AllBetCats=[_|_]) when is_integer(C1) andalso is_number(A1) andalso length(Cats)==length(Amounts)->
	is_valid_bet_cats(Cats,AllBetCats) andalso is_valid_bet_amounts(Amounts);
is_valid_bets(_,_,_)->
	false.

create_bet_req(RoundId,UserId,TableId,Cats,Amounts)->
	Cstr = string:join([integer_to_list(C) || C <-Cats],","),
	Astr = string:join([float_to_list(A,[{decimals,2}]) || A <-Amounts],","),	
	Total = lists:sum(Amounts),
 	#db_bet_req{round_id=RoundId,player_id=UserId,player_table_id=TableId,bet_cats=Cstr,bet_amounts=Astr,total_amount=Total}.


insert_bets(BetEts,BetBundleId,Cats,Amounts)->
	Ts=lists:zipwith(fun(C,A)->{{BetBundleId,C},A,0} end, Cats, Amounts),
	ets:insert(BetEts,Ts).

payout_bet('$end_of_table',_BetEts,_RatioMap)->
	ok;
payout_bet(Key={_,Cat},BetEts,RatioMap)->
	case maps:find(Cat,RatioMap) of
		{ok,Ratio}-> 
			ets:update_element(BetEts,Key,{3,Ratio});
		error ->
			ok
	end,	
	payout_bet(ets:next(BetEts,Key),BetEts,RatioMap).
payout_bets(BetEts,RatioMap)->
	payout_bet(ets:first(BetEts),BetEts,RatioMap).
