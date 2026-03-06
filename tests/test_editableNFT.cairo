use snforge_std::{
    declare, ContractClassTrait, DeclareResultTrait,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use nft::nft::{IEditableTokenDispatcher, IEditableTokenDispatcherTrait};
use openzeppelin::token::erc721::interface::{IERC721Dispatcher, IERC721DispatcherTrait};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn owner1() -> ContractAddress { 'owner1'.try_into().unwrap() }
fn owner2() -> ContractAddress { 'owner2'.try_into().unwrap() }

fn deploy() -> ContractAddress {
    let class = declare("EditableToken").unwrap().contract_class();
    let (addr, _) = class.deploy(@array![]).unwrap();
    addr
}

fn setup() -> ContractAddress {
    deploy()
}

// helper: owner1 buys a token
fn do_buy(contract_addr: ContractAddress) -> u256 {
    start_cheat_caller_address(contract_addr, owner1());
    IEditableTokenDispatcher { contract_address: contract_addr }.buy_token();
    stop_cheat_caller_address(contract_addr);
    IEditableTokenDispatcher { contract_address: contract_addr }.get_last_token_id()
}

// ---------------------------------------------------------------------------
// buy_token() tests
// ---------------------------------------------------------------------------
#[test]
fn test_buy_token_mints_and_assigns_owner() {
    let contract_addr = setup();
    let contract  = IEditableTokenDispatcher { contract_address: contract_addr };
    let erc721    = IERC721Dispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    assert(token_id                    == 1,        'first token id should be 1');
    assert(erc721.owner_of(token_id)   == owner1(), 'owner1 should own token');
    assert(contract.get_last_token_id() == 1,        'last token id should be 1');
}

#[test]
fn test_buy_token_increments_id() {
    let contract_addr = setup();

    do_buy(contract_addr);
    do_buy(contract_addr);
    let token_id = do_buy(contract_addr);

    assert(token_id == 3, 'third token id should be 3');
}

#[test]
fn test_buy_token_initializes_empty_data() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);
    let (data, is_sealed) = contract.get_token_data(token_id);

    assert(data      == "",   'data should be empty');
    assert(!is_sealed,        'should not be sealed');
}

// ---------------------------------------------------------------------------
// set_token_data() tests
// ---------------------------------------------------------------------------
#[test]
fn test_set_token_data_updates_data() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner1());
    contract.set_token_data(token_id, "hello world");
    stop_cheat_caller_address(contract_addr);

    let (data, _) = contract.get_token_data(token_id);
    assert(data == "hello world", 'data should be hello world');
}

#[test]
fn test_set_token_data_can_overwrite() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner1());
    contract.set_token_data(token_id, "first");
    contract.set_token_data(token_id, "second");
    stop_cheat_caller_address(contract_addr);

    let (data, _) = contract.get_token_data(token_id);
    assert(data == "second", 'data should be second');
}

#[test]
fn test_set_token_data_stores_long_data() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);
    let long_data: ByteArray = "this is a very long data string that exceeds 31 bytes easily";

    start_cheat_caller_address(contract_addr, owner1());
    contract.set_token_data(token_id, long_data.clone());
    stop_cheat_caller_address(contract_addr);

    let (data, _) = contract.get_token_data(token_id);
    assert(data == long_data, 'long data should match');
}

#[test]
#[should_panic(expected: ('not the token owner',))]
fn test_set_token_data_reverts_if_not_owner() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner2());
    contract.set_token_data(token_id, "hacked");
    stop_cheat_caller_address(contract_addr);
}

#[test]
#[should_panic(expected: ('token is sealed',))]
fn test_set_token_data_reverts_if_sealed() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner1());
    contract.seal_token(token_id);
    contract.set_token_data(token_id, "after seal"); // should panic
    stop_cheat_caller_address(contract_addr);
}

// ---------------------------------------------------------------------------
// transfer_to() tests
// ---------------------------------------------------------------------------
#[test]
fn test_transfer_to_changes_owner() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };
    let erc721   = IERC721Dispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner1());
    contract.transfer_to(owner2(), token_id);
    stop_cheat_caller_address(contract_addr);

    assert(erc721.owner_of(token_id) == owner2(), 'owner2 should own token');
}

#[test]
fn test_transfer_preserves_data() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner1());
    contract.set_token_data(token_id, "important data");
    contract.transfer_to(owner2(), token_id);
    stop_cheat_caller_address(contract_addr);

    let (data, _) = contract.get_token_data(token_id);
    assert(data == "important data", 'data should be preserved');
}

// ---------------------------------------------------------------------------
// seal_token() tests
// ---------------------------------------------------------------------------
#[test]
fn test_seal_token_seals_it() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner1());
    contract.seal_token(token_id);
    stop_cheat_caller_address(contract_addr);

    let (_, is_sealed) = contract.get_token_data(token_id);
    assert(is_sealed, 'token should be sealed');
}

#[test]
#[should_panic(expected: ('not the token owner',))]
fn test_seal_token_reverts_if_not_owner() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner2());
    contract.seal_token(token_id);
    stop_cheat_caller_address(contract_addr);
}

#[test]
#[should_panic(expected: ('token is sealed',))]
fn test_seal_token_reverts_if_already_sealed() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };

    let token_id = do_buy(contract_addr);

    start_cheat_caller_address(contract_addr, owner1());
    contract.seal_token(token_id);
    contract.seal_token(token_id); // should panic
    stop_cheat_caller_address(contract_addr);
}

// ---------------------------------------------------------------------------
// Full flow test — mirrors the spec sequence
// ---------------------------------------------------------------------------
#[test]
fn test_full_flow() {
    let contract_addr = setup();
    let contract = IEditableTokenDispatcher { contract_address: contract_addr };
    let erc721   = IERC721Dispatcher { contract_address: contract_addr };

    // 1. owner1 buys token — id=1
    let token_id = do_buy(contract_addr);
    assert(erc721.owner_of(token_id) == owner1(), 'owner1 should own token');

    // 2. owner1 edits token data
    start_cheat_caller_address(contract_addr, owner1());
    contract.set_token_data(token_id, "my nft data");
    stop_cheat_caller_address(contract_addr);

    let (data, is_sealed) = contract.get_token_data(token_id);
    assert(data == "my nft data", 'data should be set');
    assert(!is_sealed,            'should not be sealed yet');

    // 3. owner1 transfers to owner2
    start_cheat_caller_address(contract_addr, owner1());
    contract.transfer_to(owner2(), token_id);
    stop_cheat_caller_address(contract_addr);

    assert(erc721.owner_of(token_id) == owner2(), 'owner2 should own token');

    // 4. owner2 seals the token
    start_cheat_caller_address(contract_addr, owner2());
    contract.seal_token(token_id);
    stop_cheat_caller_address(contract_addr);

    let (_, is_sealed) = contract.get_token_data(token_id);
    assert(is_sealed, 'token should be sealed');

    // 5. owner2 cannot edit after seal
    // (tested separately in test_set_token_data_reverts_if_sealed)
}