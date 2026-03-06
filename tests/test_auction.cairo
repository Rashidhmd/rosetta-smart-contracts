use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
    start_cheat_caller_address_global, stop_cheat_caller_address_global,
    start_cheat_block_number_global, stop_cheat_block_number_global,
};
use starknet::ContractAddress;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use auction::auction::{IAuctionDispatcher, IAuctionDispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn seller() -> ContractAddress   { 'seller'.try_into().unwrap() }
fn bidder1() -> ContractAddress  { 'bidder1'.try_into().unwrap() }
fn bidder2() -> ContractAddress  { 'bidder2'.try_into().unwrap() }
fn stranger() -> ContractAddress { 'stranger'.try_into().unwrap() }

const STARTING_BID: u256 = 100_u256;
const DURATION: u64      = 10_u64;
const START_BLOCK: u64   = 50_u64;
const OBJECT: felt252    = 'vintage_watch';

const WAIT_START: u8   = 0;
const WAIT_CLOSING: u8 = 1;
const CLOSED: u8       = 2;

fn deploy_token() -> ContractAddress {
    let class = declare("ERC20Mock").unwrap().contract_class();
    let name: ByteArray   = "TestToken";
    let symbol: ByteArray = "TTK";
    let supply: u256      = 100_000_u256;

    let mut calldata: Array<felt252> = array![];
    name.serialize(ref calldata);
    symbol.serialize(ref calldata);
    supply.serialize(ref calldata);
    // mint to bidder1 and bidder2 by minting to bidder1 first then transferring
    calldata.append(bidder1().into());

    let (token_addr, _) = class.deploy(@calldata).unwrap();

    // send some tokens to bidder2 and seller too
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, bidder1());
    token.transfer(bidder2(), 10_000_u256);
    stop_cheat_caller_address(token_addr);

    token_addr
}

fn deploy_auction(token_addr: ContractAddress) -> ContractAddress {
    let class = declare("Auction").unwrap().contract_class();

    let mut calldata: Array<felt252> = array![];
    calldata.append(OBJECT);
    STARTING_BID.serialize(ref calldata);
    calldata.append(token_addr.into());

    start_cheat_caller_address_global(seller());
    let (auction_addr, _) = class.deploy(@calldata).unwrap();
    stop_cheat_caller_address_global();

    auction_addr
}

fn setup() -> (ContractAddress, ContractAddress) {
    let token_addr   = deploy_token();
    let auction_addr = deploy_auction(token_addr);
    (token_addr, auction_addr)
}

// helper: start the auction at START_BLOCK
fn do_start(auction_addr: ContractAddress) {
    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address(auction_addr, seller());
    IAuctionDispatcher { contract_address: auction_addr }.start(DURATION);
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();
}

// helper: approve + place a bid
fn do_bid(
    token_addr: ContractAddress,
    auction_addr: ContractAddress,
    bidder: ContractAddress,
    amount: u256,
    block: u64,
) {
    let token = IERC20Dispatcher { contract_address: token_addr };
    start_cheat_caller_address(token_addr, bidder);
    token.approve(auction_addr, amount);
    stop_cheat_caller_address(token_addr);

    start_cheat_block_number_global(block);
    start_cheat_caller_address(auction_addr, bidder);
    IAuctionDispatcher { contract_address: auction_addr }.bid(amount);
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[test]
fn test_constructor_sets_fields() {
    let (token_addr, auction_addr) = setup();
    let auction = IAuctionDispatcher { contract_address: auction_addr };

    assert(auction.get_seller()      == seller(),      'wrong seller');
    assert(auction.get_object()      == OBJECT,        'wrong object');
    assert(auction.get_highest_bid() == STARTING_BID,  'wrong starting bid');
    assert(auction.get_state()       == WAIT_START,    'should be WAIT_START');
}

#[test]
fn test_start_transitions_state() {
    let (_, auction_addr) = setup();
    let auction = IAuctionDispatcher { contract_address: auction_addr };

    do_start(auction_addr);

    assert(auction.get_state()     == WAIT_CLOSING,          'should be WAIT_CLOSING');
    assert(auction.get_end_block() == START_BLOCK + DURATION, 'wrong end block');
}

#[test]
fn test_bid_updates_highest() {
    let (token_addr, auction_addr) = setup();
    let auction = IAuctionDispatcher { contract_address: auction_addr };

    do_start(auction_addr);
    do_bid(token_addr, auction_addr, bidder1(), 200_u256, START_BLOCK + 1);

    assert(auction.get_highest_bidder() == bidder1(), 'wrong highest bidder');
    assert(auction.get_highest_bid()    == 200_u256,  'wrong highest bid');
}

#[test]
fn test_outbid_stores_previous_for_withdrawal() {
    let (token_addr, auction_addr) = setup();
    let auction = IAuctionDispatcher { contract_address: auction_addr };

    do_start(auction_addr);
    do_bid(token_addr, auction_addr, bidder1(), 200_u256, START_BLOCK + 1);
    do_bid(token_addr, auction_addr, bidder2(), 300_u256, START_BLOCK + 2);

    // bidder1 was outbid — their 200 should be stored for withdrawal
    assert(auction.get_highest_bidder()     == bidder2(), 'wrong highest bidder');
    assert(auction.get_bid(bidder1())       == 200_u256,  'bidder1 should have 200');
}

#[test]
fn test_withdraw_pending_bid() {
    let (token_addr, auction_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let auction = IAuctionDispatcher { contract_address: auction_addr };

    do_start(auction_addr);
    do_bid(token_addr, auction_addr, bidder1(), 200_u256, START_BLOCK + 1);
    do_bid(token_addr, auction_addr, bidder2(), 300_u256, START_BLOCK + 2);

    let balance_before = token.balance_of(bidder1());

    start_cheat_block_number_global(START_BLOCK + 3);
    start_cheat_caller_address(auction_addr, bidder1());
    auction.withdraw();
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();

    assert(token.balance_of(bidder1()) == balance_before + 200_u256, 'bidder1 not refunded');
    assert(auction.get_bid(bidder1())  == 0,                         'bid should be cleared');
}

#[test]
fn test_end_sends_highest_bid_to_seller() {
    let (token_addr, auction_addr) = setup();
    let token   = IERC20Dispatcher { contract_address: token_addr };
    let auction = IAuctionDispatcher { contract_address: auction_addr };

    do_start(auction_addr);
    do_bid(token_addr, auction_addr, bidder1(), 200_u256, START_BLOCK + 1);

    let seller_balance_before = token.balance_of(seller());

    // end after duration
    start_cheat_block_number_global(START_BLOCK + DURATION);
    start_cheat_caller_address(auction_addr, seller());
    auction.end();
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();

    assert(auction.get_state()         == CLOSED,                          'should be CLOSED');
    assert(token.balance_of(seller())  == seller_balance_before + 200_u256,'seller not paid');
}

#[test]
#[should_panic(expected: ('only the seller',))]
fn test_start_reverts_if_not_seller() {
    let (_, auction_addr) = setup();

    start_cheat_block_number_global(START_BLOCK);
    start_cheat_caller_address(auction_addr, stranger());
    IAuctionDispatcher { contract_address: auction_addr }.start(DURATION);
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('auction already started',))]
fn test_start_reverts_if_already_started() {
    let (_, auction_addr) = setup();

    do_start(auction_addr);

    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(auction_addr, seller());
    IAuctionDispatcher { contract_address: auction_addr }.start(DURATION);
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('auction not started or closed',))]
fn test_bid_reverts_if_not_started() {
    let (token_addr, auction_addr) = setup();

    do_bid(token_addr, auction_addr, bidder1(), 200_u256, START_BLOCK);
}

#[test]
#[should_panic(expected: ('bidding time expired',))]
fn test_bid_reverts_after_end_block() {
    let (token_addr, auction_addr) = setup();

    do_start(auction_addr);
    // bid exactly at or after end block
    do_bid(token_addr, auction_addr, bidder1(), 200_u256, START_BLOCK + DURATION);
}

#[test]
#[should_panic(expected: ('bid must beat highest bid',))]
fn test_bid_reverts_if_too_low() {
    let (token_addr, auction_addr) = setup();

    do_start(auction_addr);
    do_bid(token_addr, auction_addr, bidder1(), STARTING_BID, START_BLOCK + 1);
}

#[test]
#[should_panic(expected: ('auction not ended yet',))]
fn test_end_reverts_before_duration() {
    let (token_addr, auction_addr) = setup();

    do_start(auction_addr);
    do_bid(token_addr, auction_addr, bidder1(), 200_u256, START_BLOCK + 1);

    start_cheat_block_number_global(START_BLOCK + DURATION - 1);
    start_cheat_caller_address(auction_addr, seller());
    IAuctionDispatcher { contract_address: auction_addr }.end();
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();
}

#[test]
#[should_panic(expected: ('nothing to withdraw',))]
fn test_withdraw_reverts_if_nothing_pending() {
    let (_, auction_addr) = setup();

    do_start(auction_addr);

    start_cheat_block_number_global(START_BLOCK + 1);
    start_cheat_caller_address(auction_addr, stranger());
    IAuctionDispatcher { contract_address: auction_addr }.withdraw();
    stop_cheat_caller_address(auction_addr);
    stop_cheat_block_number_global();
}