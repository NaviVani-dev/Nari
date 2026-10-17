use aes::cipher::generic_array::GenericArray;
use aes::cipher::{
    BlockCipher, BlockDecrypt, BlockDecryptMut, BlockEncrypt, BlockEncryptMut, InnerIvInit, KeyInit, KeyIvInit, StreamCipher,
    StreamCipherSeek,
};
use aes::{Aes128, Aes192, Aes256};
use blowfish::Blowfish;
use md5::{Digest, Md5};
use mlua::{Lua, LuaString, Table, UserData, UserDataMethods, Value};
use num_bigint::BigUint;
use sha1::Sha1;
use sha2::Sha256;

const HMAC_BLOCK: usize = 64;

pub fn hmac<D: Digest>(key: &[u8], text: &[u8]) -> Vec<u8> {
    let mut block = [0u8; HMAC_BLOCK];
    if key.len() > HMAC_BLOCK {
        let hashed = D::digest(key);
        block[..hashed.len()].copy_from_slice(&hashed);
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let pad = |byte: u8| block.iter().map(|value| value ^ byte).collect::<Vec<_>>();
    let inner = D::digest([pad(0x36), text.to_vec()].concat());
    D::digest([pad(0x5c), inner.to_vec()].concat()).to_vec()
}

pub fn hmac_named(algorithm: &str, key: &[u8], text: &[u8]) -> Result<Vec<u8>, String> {
    match algorithm {
        "md5" => Ok(hmac::<Md5>(key, text)),
        "sha1" => Ok(hmac::<Sha1>(key, text)),
        "sha256" => Ok(hmac::<Sha256>(key, text)),
        other => Err(format!("nari.hmac(): unknown algorithm '{other}' (md5, sha1 or sha256)")),
    }
}

pub fn modpow(base: &[u8], exponent: &[u8], modulus: &[u8]) -> Result<Vec<u8>, String> {
    let modulus = BigUint::from_bytes_be(modulus);
    if modulus == BigUint::ZERO {
        return Err("nari.modpow(): the modulus can't be zero".into());
    }
    let result = BigUint::from_bytes_be(base).modpow(&BigUint::from_bytes_be(exponent), &modulus);
    Ok(if result == BigUint::ZERO { vec![0] } else { result.to_bytes_be() })
}

trait Keystream {
    fn apply(&mut self, data: &mut [u8]);
    fn seek(&mut self, offset: u64);
}

impl<T: StreamCipher + StreamCipherSeek> Keystream for T {
    fn apply(&mut self, data: &mut [u8]) {
        self.apply_keystream(data);
    }

    fn seek(&mut self, offset: u64) {
        StreamCipherSeek::seek(self, offset);
    }
}

trait Blocks {
    fn size(&self) -> usize;
    fn apply(&mut self, block: &mut [u8]);
}

struct CbcDecrypt<C: BlockDecryptMut + BlockCipher>(cbc::Decryptor<C>);
struct CbcEncrypt<C: BlockEncryptMut + BlockCipher>(cbc::Encryptor<C>);
struct Ecb<C>(C, bool);

impl<C: BlockDecryptMut + BlockCipher> Blocks for CbcDecrypt<C> {
    fn size(&self) -> usize {
        C::block_size()
    }

    fn apply(&mut self, block: &mut [u8]) {
        self.0.decrypt_block_mut(GenericArray::from_mut_slice(block));
    }
}

impl<C: BlockEncryptMut + BlockCipher> Blocks for CbcEncrypt<C> {
    fn size(&self) -> usize {
        C::block_size()
    }

    fn apply(&mut self, block: &mut [u8]) {
        self.0.encrypt_block_mut(GenericArray::from_mut_slice(block));
    }
}

impl<C: BlockEncrypt + BlockDecrypt + BlockCipher> Blocks for Ecb<C> {
    fn size(&self) -> usize {
        C::block_size()
    }

    fn apply(&mut self, block: &mut [u8]) {
        let block = GenericArray::from_mut_slice(block);
        if self.1 {
            self.0.decrypt_block(block);
        } else {
            self.0.encrypt_block(block);
        }
    }
}

enum Engine {
    Stream(Box<dyn Keystream>),
    Blocks(Box<dyn Blocks>),
}

#[derive(Clone)]
struct Spec {
    algorithm: String,
    key: Vec<u8>,
    iv: Vec<u8>,
    decrypt: bool,
}

pub struct Cipher {
    spec: Spec,
    engine: Engine,
}

fn bad_key<E>(_: E) -> String {
    "nari.cipher(): the key or the iv has the wrong length".into()
}

fn block_engine<C>(spec: &Spec, mode: &str) -> Result<Engine, String>
where
    C: BlockCipher + BlockEncrypt + BlockDecrypt + KeyInit + 'static,
{
    let cipher = C::new_from_slice(&spec.key).map_err(bad_key)?;
    let blocks: Box<dyn Blocks> = match (mode, spec.decrypt) {
        ("ecb", decrypt) => Box::new(Ecb(cipher, decrypt)),
        ("cbc", true) => Box::new(CbcDecrypt(cbc::Decryptor::inner_iv_slice_init(cipher, &spec.iv).map_err(bad_key)?)),
        ("cbc", false) => Box::new(CbcEncrypt(cbc::Encryptor::inner_iv_slice_init(cipher, &spec.iv).map_err(bad_key)?)),
        _ => unreachable!(),
    };
    Ok(Engine::Blocks(blocks))
}

fn ctr_engine<T: KeyIvInit + StreamCipher + StreamCipherSeek + 'static>(spec: &Spec) -> Result<Engine, String> {
    Ok(Engine::Stream(Box::new(T::new_from_slices(&spec.key, &spec.iv).map_err(bad_key)?)))
}

fn build(spec: &Spec) -> Result<Engine, String> {
    let (family, mode) = spec.algorithm.split_once('-').unwrap_or((spec.algorithm.as_str(), ""));
    match (family, mode, spec.key.len()) {
        ("aes", "ctr", 16) => ctr_engine::<ctr::Ctr128BE<Aes128>>(spec),
        ("aes", "ctr", 24) => ctr_engine::<ctr::Ctr128BE<Aes192>>(spec),
        ("aes", "ctr", 32) => ctr_engine::<ctr::Ctr128BE<Aes256>>(spec),
        ("aes", "cbc" | "ecb", 16) => block_engine::<Aes128>(spec, mode),
        ("aes", "cbc" | "ecb", 24) => block_engine::<Aes192>(spec, mode),
        ("aes", "cbc" | "ecb", 32) => block_engine::<Aes256>(spec, mode),
        ("aes", "ctr" | "cbc" | "ecb", _) => Err("nari.cipher(): AES keys are 16, 24 or 32 bytes".into()),
        ("blowfish", "cbc" | "ecb", _) => block_engine::<Blowfish>(spec, mode),
        _ => Err(format!(
            "nari.cipher(): unknown algorithm '{}' (aes-ctr, aes-cbc, aes-ecb, blowfish-cbc or blowfish-ecb)",
            spec.algorithm
        )),
    }
}

impl Cipher {
    pub fn from_table(table: &Table) -> mlua::Result<Self> {
        let bytes = |key: &str| -> mlua::Result<Vec<u8>> {
            Ok(table.get::<Option<LuaString>>(key)?.map(|text| text.as_bytes().to_vec()).unwrap_or_default())
        };
        let spec = Spec {
            algorithm: table.get::<String>("algorithm")?.to_lowercase(),
            key: bytes("key")?,
            iv: bytes("iv")?,
            decrypt: table.get::<Option<bool>>("decrypt")?.unwrap_or(true),
        };
        let engine = build(&spec).map_err(mlua::Error::runtime)?;
        Ok(Self { spec, engine })
    }

    fn update(&mut self, data: &[u8]) -> Result<Vec<u8>, String> {
        let mut data = data.to_vec();
        match &mut self.engine {
            Engine::Stream(stream) => stream.apply(&mut data),
            Engine::Blocks(blocks) => {
                let size = blocks.size();
                if data.len() % size != 0 {
                    return Err(format!("cipher:update(): {} needs data in blocks of {size} bytes", self.spec.algorithm));
                }
                data.chunks_exact_mut(size).for_each(|block| blocks.apply(block));
            }
        }
        Ok(data)
    }
}

impl UserData for Cipher {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method_mut("update", |lua, cipher, data: LuaString| {
            lua.create_string(cipher.update(&data.as_bytes()).map_err(mlua::Error::runtime)?)
        });
        methods.add_method_mut("seek", |_, cipher, offset: u64| match &mut cipher.engine {
            Engine::Stream(stream) => {
                stream.seek(offset);
                Ok(())
            }
            Engine::Blocks(_) => Err(mlua::Error::runtime("cipher:seek(): only CTR ciphers can seek")),
        });
        methods.add_method_mut("reset", |_, cipher, ()| {
            cipher.engine = build(&cipher.spec).map_err(mlua::Error::runtime)?;
            Ok(())
        });
    }
}

pub fn install(lua: &Lua, nari: &Table) -> mlua::Result<()> {
    nari.set("cipher", lua.create_function(|_, spec: Table| Cipher::from_table(&spec))?)?;
    nari.set(
        "hmac",
        lua.create_function(|lua, (algorithm, key, text, raw): (String, LuaString, LuaString, Option<bool>)| {
            let bytes = hmac_named(&algorithm.to_lowercase(), &key.as_bytes(), &text.as_bytes()).map_err(mlua::Error::runtime)?;
            super::digest(lua, &bytes, raw)
        })?,
    )?;
    nari.set(
        "modpow",
        lua.create_function(|lua, (base, exponent, modulus): (LuaString, LuaString, LuaString)| {
            let bytes = modpow(&base.as_bytes(), &exponent.as_bytes(), &modulus.as_bytes()).map_err(mlua::Error::runtime)?;
            lua.create_string(bytes).map(Value::String)
        })?,
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(text: &str) -> Vec<u8> {
        (0..text.len()).step_by(2).map(|at| u8::from_str_radix(&text[at..at + 2], 16).unwrap()).collect()
    }

    fn run(algorithm: &str, key: &str, iv: &str, decrypt: bool, data: &str) -> String {
        let spec = Spec { algorithm: algorithm.into(), key: unhex(key), iv: unhex(iv), decrypt };
        let mut cipher = Cipher { engine: build(&spec).unwrap(), spec };
        super::super::hex(&cipher.update(&unhex(data)).unwrap())
    }

    #[test]
    fn ciphers_match_nist_and_schneier_vectors() {
        let key = "2b7e151628aed2a6abf7158809cf4f3c";
        let plain = "6bc1bee22e409f96e93d7e117393172a";
        assert_eq!(run("aes-ecb", key, "", false, plain), "3ad77bb40d7a3660a89ecaf32466ef97");
        assert_eq!(run("aes-ecb", key, "", true, "3ad77bb40d7a3660a89ecaf32466ef97"), plain);
        let iv = "000102030405060708090a0b0c0d0e0f";
        assert_eq!(run("aes-cbc", key, iv, false, plain), "7649abac8119b246cee98e9b12e9197d");
        assert_eq!(run("aes-cbc", key, iv, true, "7649abac8119b246cee98e9b12e9197d"), plain);
        let counter = "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff";
        assert_eq!(run("aes-ctr", key, counter, true, plain), "874d6191b620e3261bef6864990db6ce");
        assert_eq!(run("blowfish-ecb", "0000000000000000", "", false, "0000000000000000"), "4ef997456198dd78");
    }

    #[test]
    fn ctr_seeks_and_blocks_reset() {
        let spec = Spec { algorithm: "aes-ctr".into(), key: vec![7; 16], iv: vec![1; 16], decrypt: true };
        let mut whole = Cipher { engine: build(&spec).unwrap(), spec: spec.clone() };
        let stream = whole.update(&[0; 100]).unwrap();
        let mut part = Cipher { engine: build(&spec).unwrap(), spec };
        let Engine::Stream(keystream) = &mut part.engine else { panic!() };
        keystream.seek(37);
        assert_eq!(part.update(&[0; 63]).unwrap(), stream[37..]);
        let spec = Spec { algorithm: "blowfish-cbc".into(), key: b"secretkey1234567".to_vec(), iv: (0..8).collect(), decrypt: true };
        let mut blowfish = Cipher { engine: build(&spec).unwrap(), spec: spec.clone() };
        let first = blowfish.update(&[9; 16]).unwrap();
        assert_ne!(blowfish.update(&[9; 16]).unwrap(), first);
        blowfish.engine = build(&spec).unwrap();
        assert_eq!(blowfish.update(&[9; 16]).unwrap(), first);
        assert!(blowfish.update(&[9; 5]).is_err());
        assert!(build(&Spec { algorithm: "aes-ctr".into(), key: vec![0; 10], iv: vec![0; 16], decrypt: true }).is_err());
        assert!(build(&Spec { algorithm: "rot13".into(), key: vec![], iv: vec![], decrypt: true }).is_err());
    }

    #[test]
    fn hmac_and_modpow_match_known_values() {
        assert_eq!(super::super::hex(&hmac_named("sha1", &[0x0b; 20], b"Hi There").unwrap()), "b617318655057264e28bc0b6fb378c8ef146be00");
        assert_eq!(super::super::hex(&hmac_named("md5", b"Jefe", b"what do ya want for nothing?").unwrap()), "750c783e6ab0b503eaa86e310a5db738");
        assert_eq!(modpow(&[4], &[13], &[1, 241]).unwrap(), vec![1, 189]);
        assert_eq!(modpow(&[5], &[3], &[5]).unwrap(), vec![0]);
        assert!(modpow(&[2], &[2], &[]).is_err());
    }
}
