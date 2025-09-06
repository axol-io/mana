use rustler::types::Binary;
use rustler::{Decoder, Encoder, Env, NifResult, Term};
use std::collections::HashMap;
use threshold_crypto::{PublicKey, SecretKey, Signature, PublicKeySet, SecretKeyShare, SignatureShare};
use rand::thread_rng;
use zeroize::Zeroize;
use serde::{Deserialize, Serialize};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        invalid_threshold,
        invalid_signature,
        invalid_share,
        key_generation_failed,
        signing_failed,
        verification_failed,
        insufficient_shares,
        duplicate_share,
        invalid_message
    }
}

// Threshold configuration for DVT operations
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ThresholdConfig {
    pub threshold: usize,
    pub total_nodes: usize,
}

// Key share data structure for secure storage
#[derive(Debug, Clone, Zeroize, Serialize, Deserialize)]
#[zeroize(drop)]
pub struct KeyShareData {
    pub node_id: usize,
    pub secret_share: Vec<u8>,
    pub public_key_set: Vec<u8>,
    pub threshold: usize,
    pub total_nodes: usize,
}

// Signature share for threshold signing
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SignatureShareData {
    pub node_id: usize,
    pub signature_share: Vec<u8>,
    pub message_hash: Vec<u8>,
}

// DVT cluster state for managing multiple validators
#[derive(Debug, Clone)]
pub struct DVTCluster {
    pub cluster_id: String,
    pub validators: HashMap<String, KeyShareData>,
    pub threshold_config: ThresholdConfig,
}

mod dkg;

rustler::init!("Elixir.ExWire.DVT.Crypto", [
    // Threshold signature operations
    generate_threshold_keys,
    create_signature_share,
    aggregate_signature_shares,
    verify_threshold_signature,
    verify_signature_share,
    reconstruct_secret_key,
    get_public_key_from_share,
    validate_threshold_config,
    
    // DKG operations
    dkg::initialize_dkg_round,
    dkg::process_dkg_share,
    dkg::finalize_dkg_round,
    dkg::verify_dkg_result,
    dkg::generate_dkg_complaint,
    dkg::verify_dkg_complaint
]);

/// Generate threshold keys for DVT cluster
/// Returns: {:ok, {public_key_set, key_shares}} | {:error, reason}
#[rustler::nif]
fn generate_threshold_keys(threshold: usize, total_nodes: usize) -> NifResult<Term> {
    if threshold == 0 || threshold > total_nodes {
        return Ok((atoms::error(), atoms::invalid_threshold()).encode(env));
    }

    let mut rng = thread_rng();
    
    // Generate threshold keys using threshold_crypto
    let secret_key = SecretKey::random(&mut rng);
    let public_key = secret_key.public_key();
    
    // Create threshold key shares
    let key_shares: Vec<SecretKeyShare> = (0..total_nodes)
        .map(|i| secret_key.clone()) // Simplified for now - proper threshold implementation needed
        .collect();
    
    let public_key_set = PublicKeySet::from(public_key);
    
    // Serialize public key set
    let public_key_set_bytes = bincode::serialize(&public_key_set)
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Serialize key shares
    let shares_data: Vec<KeyShareData> = key_shares
        .into_iter()
        .enumerate()
        .map(|(node_id, share)| {
            let share_bytes = bincode::serialize(&share).unwrap_or_default();
            KeyShareData {
                node_id,
                secret_share: share_bytes,
                public_key_set: public_key_set_bytes.clone(),
                threshold,
                total_nodes,
            }
        })
        .collect();
    
    let shares_bytes: Vec<Vec<u8>> = shares_data
        .into_iter()
        .map(|share| bincode::serialize(&share).unwrap_or_default())
        .collect();
    
    Ok((atoms::ok(), (public_key_set_bytes, shares_bytes)).encode(env))
}

/// Create a signature share for a message using a key share
/// Returns: {:ok, signature_share_data} | {:error, reason}
#[rustler::nif]
fn create_signature_share(key_share_bytes: Binary, message: Binary) -> NifResult<Term> {
    let env = key_share_bytes.env;
    
    // Deserialize key share
    let key_share_data: KeyShareData = bincode::deserialize(key_share_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    let secret_share: SecretKeyShare = bincode::deserialize(&key_share_data.secret_share)
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Create signature share
    let signature_share = secret_share.sign(message.as_slice());
    let signature_share_bytes = bincode::serialize(&signature_share)
        .map_err(|_| rustler::Error::BadArg)?;
    
    let share_data = SignatureShareData {
        node_id: key_share_data.node_id,
        signature_share: signature_share_bytes,
        message_hash: message.as_slice().to_vec(),
    };
    
    let share_data_bytes = bincode::serialize(&share_data)
        .map_err(|_| rustler::Error::BadArg)?;
    
    Ok((atoms::ok(), share_data_bytes).encode(env))
}

/// Aggregate signature shares into a threshold signature
/// Returns: {:ok, threshold_signature} | {:error, reason}
#[rustler::nif]
fn aggregate_signature_shares(
    public_key_set_bytes: Binary,
    signature_shares_list: Vec<Binary>,
    threshold: usize
) -> NifResult<Term> {
    let env = public_key_set_bytes.env;
    
    if signature_shares_list.len() < threshold {
        return Ok((atoms::error(), atoms::insufficient_shares()).encode(env));
    }
    
    // Deserialize public key set
    let public_key_set: PublicKeySet = bincode::deserialize(public_key_set_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Deserialize signature shares
    let mut signature_shares = HashMap::new();
    let mut message_hash: Option<Vec<u8>> = None;
    
    for share_binary in signature_shares_list.iter().take(threshold) {
        let share_data: SignatureShareData = bincode::deserialize(share_binary.as_slice())
            .map_err(|_| rustler::Error::BadArg)?;
        
        // Verify all shares are for the same message
        if let Some(ref hash) = message_hash {
            if *hash != share_data.message_hash {
                return Ok((atoms::error(), atoms::invalid_message()).encode(env));
            }
        } else {
            message_hash = Some(share_data.message_hash.clone());
        }
        
        // Check for duplicate shares
        if signature_shares.contains_key(&share_data.node_id) {
            return Ok((atoms::error(), atoms::duplicate_share()).encode(env));
        }
        
        let signature_share: SignatureShare = bincode::deserialize(&share_data.signature_share)
            .map_err(|_| rustler::Error::BadArg)?;
        
        signature_shares.insert(share_data.node_id, signature_share);
    }
    
    // Aggregate signatures using threshold cryptography
    let signature = public_key_set.combine_signatures(&signature_shares)
        .map_err(|_| rustler::Error::BadArg)?;
    
    let signature_bytes = bincode::serialize(&signature)
        .map_err(|_| rustler::Error::BadArg)?;
    
    Ok((atoms::ok(), signature_bytes).encode(env))
}

/// Verify a threshold signature
/// Returns: {:ok, true} | {:ok, false} | {:error, reason}
#[rustler::nif]
fn verify_threshold_signature(
    public_key_bytes: Binary,
    signature_bytes: Binary,
    message: Binary
) -> NifResult<Term> {
    let env = public_key_bytes.env;
    
    // Deserialize public key and signature
    let public_key: PublicKey = bincode::deserialize(public_key_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    let signature: Signature = bincode::deserialize(signature_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Verify signature
    let is_valid = public_key.verify(&signature, message.as_slice());
    
    Ok((atoms::ok(), is_valid).encode(env))
}

/// Verify an individual signature share
/// Returns: {:ok, true} | {:ok, false} | {:error, reason}
#[rustler::nif]
fn verify_signature_share(
    public_key_set_bytes: Binary,
    share_data_bytes: Binary,
    message: Binary
) -> NifResult<Term> {
    let env = public_key_set_bytes.env;
    
    // Deserialize components
    let public_key_set: PublicKeySet = bincode::deserialize(public_key_set_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    let share_data: SignatureShareData = bincode::deserialize(share_data_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    let signature_share: SignatureShare = bincode::deserialize(&share_data.signature_share)
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Verify the signature share
    let public_key_share = public_key_set.public_key_share(share_data.node_id);
    let is_valid = public_key_share.verify(&signature_share, message.as_slice());
    
    Ok((atoms::ok(), is_valid).encode(env))
}

/// Reconstruct the full secret key from threshold shares (for testing/recovery)
/// Returns: {:ok, secret_key} | {:error, reason}
#[rustler::nif]
fn reconstruct_secret_key(key_shares_list: Vec<Binary>, threshold: usize) -> NifResult<Term> {
    if key_shares_list.is_empty() {
        return Ok((atoms::error(), atoms::insufficient_shares()).encode(&key_shares_list[0].env));
    }
    
    let env = key_shares_list[0].env;
    
    if key_shares_list.len() < threshold {
        return Ok((atoms::error(), atoms::insufficient_shares()).encode(env));
    }
    
    // This is a placeholder - full reconstruction requires proper threshold crypto implementation
    // For now, return error to indicate this is for testing only
    Ok((atoms::error(), atoms::key_generation_failed()).encode(env))
}

/// Get public key from a key share
/// Returns: {:ok, public_key} | {:error, reason}
#[rustler::nif]
fn get_public_key_from_share(key_share_bytes: Binary) -> NifResult<Term> {
    let env = key_share_bytes.env;
    
    let key_share_data: KeyShareData = bincode::deserialize(key_share_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    let public_key_set: PublicKeySet = bincode::deserialize(&key_share_data.public_key_set)
        .map_err(|_| rustler::Error::BadArg)?;
    
    let public_key = public_key_set.public_key();
    let public_key_bytes = bincode::serialize(&public_key)
        .map_err(|_| rustler::Error::BadArg)?;
    
    Ok((atoms::ok(), public_key_bytes).encode(env))
}

/// Validate threshold configuration
/// Returns: {:ok, true} | {:error, reason}
#[rustler::nif]
fn validate_threshold_config(threshold: usize, total_nodes: usize) -> NifResult<Term> {
    if threshold == 0 || threshold > total_nodes {
        return Ok((atoms::error(), atoms::invalid_threshold()).encode(&rustler::env()));
    }
    
    if total_nodes > 256 {  // Reasonable upper limit
        return Ok((atoms::error(), atoms::invalid_threshold()).encode(&rustler::env()));
    }
    
    // Ensure meaningful threshold (at least majority)
    if threshold < (total_nodes / 2) + 1 {
        return Ok((atoms::error(), atoms::invalid_threshold()).encode(&rustler::env()));
    }
    
    Ok((atoms::ok(), true).encode(&rustler::env()))
}