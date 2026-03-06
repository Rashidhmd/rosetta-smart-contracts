use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};
use storage::storage::{IStorageDispatcher, IStorageDispatcherTrait};
use starknet::ContractAddress;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
fn deploy_storage() -> ContractAddress {
    let class = declare("Storage").unwrap().contract_class();
    let (contract_addr, _) = class.deploy(@array![]).unwrap();
    contract_addr
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
#[test]
fn test_initial_state_is_empty() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    assert(s.get_bytes() == "", 'bytes should be empty');
    assert(s.get_string() == "", 'string should be empty');
}

#[test]
fn test_store_and_retrieve_bytes() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    let data: ByteArray = "x00x01x02x03xFF";
    s.store_bytes(data.clone());

    assert(s.get_bytes() == data, 'wrong byte sequence');
}

#[test]
fn test_store_and_retrieve_string() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    let text: ByteArray = "Hello, Starknet!";
    s.store_string(text.clone());

    assert(s.get_string() == text, 'wrong string');
}

#[test]
fn test_store_empty_bytes() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    s.store_bytes("");
    assert(s.get_bytes() == "", 'empty bytes should be stored');
}

#[test]
fn test_store_empty_string() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    s.store_string("");
    assert(s.get_string() == "", 'empty string should be stored');
}

#[test]
fn test_overwrite_bytes() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    s.store_bytes("first");
    s.store_bytes("second");

    assert(s.get_bytes() == "second", 'bytes should be overwritten');
}

#[test]
fn test_overwrite_string() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    s.store_string("first string");
    s.store_string("second string");

    assert(s.get_string() == "second string", 'string should be overwritten');
}

#[test]
fn test_bytes_and_string_are_independent() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    s.store_bytes("some bytes");
    s.store_string("some text");

    // updating one should not affect the other
    s.store_bytes("updated bytes");

    assert(s.get_bytes()  == "updated bytes", 'bytes should be updated');
    assert(s.get_string() == "some text",     'string should be unchanged');
}

#[test]
fn test_store_long_string() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    // ByteArray handles arbitrary length — test with a string > 31 bytes
    let long: ByteArray = "This is a longer string that exceeds 31 bytes in length!";
    s.store_string(long.clone());

    assert(s.get_string() == long, 'long string should be stored');
}

#[test]
fn test_store_long_bytes() {
    let contract_addr = deploy_storage();
    let s = IStorageDispatcher { contract_address: contract_addr };

    let long: ByteArray = "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\x20";
    s.store_bytes(long.clone());

    assert(s.get_bytes() == long, 'long bytes should be stored');
}