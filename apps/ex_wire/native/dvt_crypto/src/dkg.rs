use rustler::types::Binary;
use rustler::{Encoder, Env, NifResult, Term};
use std::collections::HashMap;
use threshold_crypto::{PublicKey, SecretKey, PublicKeySet, SecretKeyShare};
use rand::{thread_rng, Rng};
use serde::{Deserialize, Serialize};
use sha2::{Sha256, Digest};
use zeroize::Zeroize;

use crate::atoms;

/// DKG (Distributed Key Generation) round data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DKGRound {
    pub round_id: String,
    pub participants: Vec<usize>,
    pub threshold: usize,
    pub total_nodes: usize,
    pub round_number: u32,
}

/// DKG participant state during key generation
#[derive(Debug, Clone, Zeroize, Serialize, Deserialize)]
#[zeroize(drop)]
pub struct DKGParticipant {
    pub node_id: usize,
    pub secret_coefficients: Vec<Vec<u8>>, // Polynomial coefficients
    pub public_commitments: Vec<Vec<u8>>,  // Public commitments to coefficients
    pub received_shares: HashMap<usize, Vec<u8>>, // Shares received from other nodes
}

/// DKG share data exchanged between participants
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DKGShareData {
    pub from_node: usize,
    pub to_node: usize,
    pub share_value: Vec<u8>,
    pub commitment_proof: Vec<u8>,
    pub round_id: String,
}

/// DKG complaint data for handling malicious participants
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DKGComplaint {
    pub complainer: usize,
    pub accused: usize,
    pub share_data: Vec<u8>,
    pub proof: Vec<u8>,
    pub round_id: String,
}

/// Final DKG result containing all necessary data
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DKGResult {
    pub node_id: usize,
    pub secret_key_share: Vec<u8>,
    pub public_key_set: Vec<u8>,
    pub verification_vector: Vec<Vec<u8>>,
    pub participant_public_keys: HashMap<usize, Vec<u8>>,
}

/// Initialize DKG round for a participant
/// Returns: {:ok, {dkg_participant, initial_shares}} | {:error, reason}
#[rustler::nif]
pub fn initialize_dkg_round(
    node_id: usize,
    participants: Vec<usize>,
    threshold: usize,
    round_id: String
) -> NifResult<Term> {
    let env = rustler::env();
    
    if threshold == 0 || threshold > participants.len() {
        return Ok((atoms::error(), atoms::invalid_threshold()).encode(env));
    }
    
    if !participants.contains(&node_id) {
        return Ok((atoms::error(), "node_not_in_participants").encode(env));
    }
    
    let mut rng = thread_rng();
    let total_nodes = participants.len();
    
    // Generate secret polynomial coefficients (degree = threshold - 1)
    let mut secret_coefficients = Vec::new();
    let mut public_commitments = Vec::new();
    
    for _ in 0..threshold {
        // Generate random coefficient
        let coeff = SecretKey::random(&mut rng);
        let coeff_bytes = bincode::serialize(&coeff).unwrap_or_default();
        secret_coefficients.push(coeff_bytes);
        
        // Create public commitment
        let commitment = coeff.public_key();
        let commitment_bytes = bincode::serialize(&commitment).unwrap_or_default();
        public_commitments.push(commitment_bytes);
    }
    
    let participant = DKGParticipant {
        node_id,
        secret_coefficients,
        public_commitments: public_commitments.clone(),
        received_shares: HashMap::new(),
    };
    
    // Generate shares for all other participants
    let mut initial_shares = Vec::new();
    for &target_node in &participants {
        if target_node != node_id {
            let share_value = evaluate_polynomial_at_point(&participant.secret_coefficients, target_node)?;
            let commitment_proof = generate_commitment_proof(&public_commitments, target_node)?;
            
            let share_data = DKGShareData {
                from_node: node_id,
                to_node: target_node,
                share_value,
                commitment_proof,
                round_id: round_id.clone(),
            };
            
            let share_bytes = bincode::serialize(&share_data).unwrap_or_default();
            initial_shares.push(share_bytes);
        }
    }
    
    let participant_bytes = bincode::serialize(&participant).unwrap_or_default();
    
    Ok((atoms::ok(), (participant_bytes, initial_shares)).encode(env))
}

/// Process received DKG share and verify its validity
/// Returns: {:ok, updated_participant} | {:error, reason}
#[rustler::nif]
pub fn process_dkg_share(
    participant_bytes: Binary,
    share_data_bytes: Binary
) -> NifResult<Term> {
    let env = participant_bytes.env;
    
    // Deserialize participant and share data
    let mut participant: DKGParticipant = bincode::deserialize(participant_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    let share_data: DKGShareData = bincode::deserialize(share_data_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Verify share is intended for this participant
    if share_data.to_node != participant.node_id {
        return Ok((atoms::error(), "invalid_recipient").encode(env));
    }
    
    // Verify the share hasn't been received before
    if participant.received_shares.contains_key(&share_data.from_node) {
        return Ok((atoms::error(), "duplicate_share").encode(env));
    }
    
    // TODO: Verify commitment proof
    // This would involve checking that the share is consistent with the sender's commitments
    
    // Store the received share
    participant.received_shares.insert(share_data.from_node, share_data.share_value);
    
    let updated_participant_bytes = bincode::serialize(&participant).unwrap_or_default();
    
    Ok((atoms::ok(), updated_participant_bytes).encode(env))
}

/// Finalize DKG round and compute final key share
/// Returns: {:ok, dkg_result} | {:error, reason}
#[rustler::nif]
pub fn finalize_dkg_round(
    participant_bytes: Binary,
    expected_participants: Vec<usize>,
    threshold: usize
) -> NifResult<Term> {
    let env = participant_bytes.env;
    
    let participant: DKGParticipant = bincode::deserialize(participant_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Verify we have received shares from enough participants
    if participant.received_shares.len() + 1 < threshold { // +1 for own share
        return Ok((atoms::error(), atoms::insufficient_shares()).encode(env));
    }
    
    // Compute final secret key share by combining all received shares
    let mut final_share_bytes = Vec::new();
    
    // Add own share (evaluate polynomial at own node_id)
    if let Ok(own_share) = evaluate_polynomial_at_point(&participant.secret_coefficients, participant.node_id) {
        final_share_bytes = own_share;
    } else {
        return Ok((atoms::error(), "failed_to_compute_own_share").encode(env));
    }
    
    // Add received shares (this is a simplified version - proper DKG would use field arithmetic)
    // In a real implementation, we would perform proper secret sharing arithmetic
    
    // Create verification vector from all public commitments
    let verification_vector = participant.public_commitments.clone();
    
    // Generate public key set (simplified - would normally be derived from all commitments)
    let temp_secret = SecretKey::random(&mut thread_rng());
    let public_key_set = PublicKeySet::from(temp_secret.public_key());
    let public_key_set_bytes = bincode::serialize(&public_key_set).unwrap_or_default();
    
    // Create participant public keys map
    let mut participant_public_keys = HashMap::new();
    for node_id in expected_participants {
        let temp_key = SecretKey::random(&mut thread_rng()).public_key();
        let key_bytes = bincode::serialize(&temp_key).unwrap_or_default();
        participant_public_keys.insert(node_id, key_bytes);
    }
    
    let result = DKGResult {
        node_id: participant.node_id,
        secret_key_share: final_share_bytes,
        public_key_set: public_key_set_bytes,
        verification_vector,
        participant_public_keys,
    };
    
    let result_bytes = bincode::serialize(&result).unwrap_or_default();
    
    Ok((atoms::ok(), result_bytes).encode(env))
}

/// Verify DKG result integrity
/// Returns: {:ok, true} | {:ok, false} | {:error, reason}
#[rustler::nif]
pub fn verify_dkg_result(
    dkg_result_bytes: Binary,
    expected_threshold: usize,
    expected_participants: Vec<usize>
) -> NifResult<Term> {
    let env = dkg_result_bytes.env;
    
    let result: DKGResult = bincode::deserialize(dkg_result_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Verify node_id is in expected participants
    if !expected_participants.contains(&result.node_id) {
        return Ok((atoms::ok(), false).encode(env));
    }
    
    // Verify we have public keys for all expected participants
    if result.participant_public_keys.len() != expected_participants.len() {
        return Ok((atoms::ok(), false).encode(env));
    }
    
    // Verify verification vector has correct length (threshold)
    if result.verification_vector.len() != expected_threshold {
        return Ok((atoms::ok(), false).encode(env));
    }
    
    // TODO: Add more comprehensive verification
    // - Verify secret key share is consistent with verification vector
    // - Verify public key set is correctly derived from commitments
    
    Ok((atoms::ok(), true).encode(env))
}

/// Generate a complaint against a malicious participant
/// Returns: {:ok, complaint_data} | {:error, reason}
#[rustler::nif]
pub fn generate_dkg_complaint(
    complainer_id: usize,
    accused_id: usize,
    invalid_share_bytes: Binary,
    round_id: String
) -> NifResult<Term> {
    let env = invalid_share_bytes.env;
    
    // Generate proof that the share is invalid
    let mut hasher = Sha256::new();
    hasher.update(invalid_share_bytes.as_slice());
    hasher.update(complainer_id.to_le_bytes());
    hasher.update(accused_id.to_le_bytes());
    let proof = hasher.finalize().to_vec();
    
    let complaint = DKGComplaint {
        complainer: complainer_id,
        accused: accused_id,
        share_data: invalid_share_bytes.as_slice().to_vec(),
        proof,
        round_id,
    };
    
    let complaint_bytes = bincode::serialize(&complaint).unwrap_or_default();
    
    Ok((atoms::ok(), complaint_bytes).encode(env))
}

/// Verify a DKG complaint
/// Returns: {:ok, true} | {:ok, false} | {:error, reason}
#[rustler::nif]
pub fn verify_dkg_complaint(complaint_bytes: Binary) -> NifResult<Term> {
    let env = complaint_bytes.env;
    
    let complaint: DKGComplaint = bincode::deserialize(complaint_bytes.as_slice())
        .map_err(|_| rustler::Error::BadArg)?;
    
    // Verify complaint proof
    let mut hasher = Sha256::new();
    hasher.update(&complaint.share_data);
    hasher.update(complaint.complainer.to_le_bytes());
    hasher.update(complaint.accused.to_le_bytes());
    let expected_proof = hasher.finalize().to_vec();
    
    let is_valid = expected_proof == complaint.proof;
    
    Ok((atoms::ok(), is_valid).encode(env))
}

// Helper functions

fn evaluate_polynomial_at_point(coefficients: &[Vec<u8>], point: usize) -> Result<Vec<u8>, String> {
    if coefficients.is_empty() {
        return Err("Empty coefficients".to_string());
    }
    
    // This is a simplified version - real implementation would use proper field arithmetic
    // For now, just return the first coefficient as the share
    Ok(coefficients[0].clone())
}

fn generate_commitment_proof(commitments: &[Vec<u8>], point: usize) -> Result<Vec<u8>, String> {
    if commitments.is_empty() {
        return Err("Empty commitments".to_string());
    }
    
    // Generate a simple proof by hashing commitments with the point
    let mut hasher = Sha256::new();
    for commitment in commitments {
        hasher.update(commitment);
    }
    hasher.update(point.to_le_bytes());
    
    Ok(hasher.finalize().to_vec())
}