use rustler::{Encoder, Env, Error, NifResult, Term};
use rustler::types::binary::{Binary, OwnedBinary};

mod commitment;
mod proof;
mod batch;
mod curve;

use commitment::{compute_commitment};
use proof::{generate_proof, verify_proof};
use batch::{batch_verify_proofs, batch_compute_commitments};

// Register the resource type with Rustler - removed as not needed for basic NIFs

// Define the NIF module
rustler::init!(
    "Elixir.VerkleTree.Crypto.Native",
    [
        // Commitment operations
        commit_to_value,
        commit_to_children,
        compute_root_commitment,
        
        // Proof operations
        generate_verkle_proof,
        verify_verkle_proof,
        
        // Batch operations
        batch_verify,
        batch_commit,
        batch_generate_witnesses,
        
        // Utility functions
        hash_to_scalar,
        point_to_scalar,
        scalar_mul,
        point_add,
        
        // Setup functions
        load_trusted_setup,
        get_generator,
        get_identity,
    ],
    load = on_load
);

fn on_load(_env: Env, _info: Term) -> bool {
    true
}

// Commitment operations

#[rustler::nif]
fn commit_to_value<'a>(env: Env<'a>, value: Binary) -> NifResult<Term<'a>> {
    match compute_commitment(&value) {
        Ok(commitment) => {
            let mut binary = OwnedBinary::new(32).unwrap();
            binary.as_mut_slice().copy_from_slice(&commitment);
            Ok(binary.release(env).encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

#[rustler::nif]
fn commit_to_children<'a>(env: Env<'a>, children: Vec<Binary>) -> NifResult<Term<'a>> {
    if children.len() != 256 {
        return Err(Error::BadArg);
    }
    
    let children_bytes: Vec<Vec<u8>> = children.iter()
        .map(|b| b.as_slice().to_vec())
        .collect();
    
    match commitment::commit_to_children_array(&children_bytes) {
        Ok(commitment) => {
            let mut binary = OwnedBinary::new(32).unwrap();
            binary.as_mut_slice().copy_from_slice(&commitment);
            Ok(binary.release(env).encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

#[rustler::nif]
fn compute_root_commitment<'a>(env: Env<'a>, 
                               existing_root: Binary,
                               key: Binary,
                               value: Binary) -> NifResult<Term<'a>> {
    match commitment::update_root_commitment(
        existing_root.as_slice(),
        key.as_slice(),
        value.as_slice()
    ) {
        Ok(new_root) => {
            let mut binary = OwnedBinary::new(32).unwrap();
            binary.as_mut_slice().copy_from_slice(&new_root);
            Ok(binary.release(env).encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

// Proof operations

#[rustler::nif]
fn generate_verkle_proof<'a>(env: Env<'a>,
                             path_commitments: Vec<Binary>,
                             values: Vec<Binary>,
                             root_commitment: Binary) -> NifResult<Term<'a>> {
    let path_bytes: Vec<Vec<u8>> = path_commitments.iter()
        .map(|b| b.as_slice().to_vec())
        .collect();
    let value_bytes: Vec<Vec<u8>> = values.iter()
        .map(|b| b.as_slice().to_vec())
        .collect();
    
    match generate_proof(&path_bytes, &value_bytes, root_commitment.as_slice()) {
        Ok(proof_data) => {
            let mut binary = OwnedBinary::new(proof_data.len()).unwrap();
            binary.as_mut_slice().copy_from_slice(&proof_data);
            Ok(binary.release(env).encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

#[rustler::nif]
fn verify_verkle_proof<'a>(env: Env<'a>,
                          proof: Binary,
                          root_commitment: Binary,
                          key_value_pairs: Vec<(Binary, Binary)>) -> NifResult<Term<'a>> {
    let kvs: Vec<(Vec<u8>, Vec<u8>)> = key_value_pairs.iter()
        .map(|(k, v)| (k.as_slice().to_vec(), v.as_slice().to_vec()))
        .collect();
    
    match verify_proof(proof.as_slice(), root_commitment.as_slice(), &kvs) {
        Ok(valid) => Ok(valid.encode(env)),
        Err(_) => Err(Error::BadArg)
    }
}

// Batch operations

#[rustler::nif]
fn batch_verify<'a>(env: Env<'a>,
                   proof_sets: Vec<(Binary, Binary, Vec<(Binary, Binary)>)>) -> NifResult<Term<'a>> {
    let proof_data: Vec<(Vec<u8>, Vec<u8>, Vec<(Vec<u8>, Vec<u8>)>)> = proof_sets.iter()
        .map(|(proof, root, kvs)| {
            let kvs_bytes: Vec<(Vec<u8>, Vec<u8>)> = kvs.iter()
                .map(|(k, v)| (k.as_slice().to_vec(), v.as_slice().to_vec()))
                .collect();
            (proof.as_slice().to_vec(), root.as_slice().to_vec(), kvs_bytes)
        })
        .collect();
    
    match batch_verify_proofs(&proof_data) {
        Ok(valid) => Ok(valid.encode(env)),
        Err(_) => Err(Error::BadArg)
    }
}

#[rustler::nif]
fn batch_commit<'a>(env: Env<'a>, values: Vec<Binary>) -> NifResult<Term<'a>> {
    let value_bytes: Vec<Vec<u8>> = values.iter()
        .map(|b| b.as_slice().to_vec())
        .collect();
    
    match batch_compute_commitments(&value_bytes) {
        Ok(commitments) => {
            let result: Vec<Term> = commitments.iter()
                .map(|c| {
                    let mut binary = OwnedBinary::new(32).unwrap();
                    binary.as_mut_slice().copy_from_slice(c);
                    binary.release(env).encode(env)
                })
                .collect();
            Ok(result.encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

// Utility functions

#[rustler::nif]
fn hash_to_scalar<'a>(env: Env<'a>, data: Binary) -> NifResult<Term<'a>> {
    let scalar = curve::hash_to_scalar(data.as_slice());
    let mut binary = OwnedBinary::new(32).unwrap();
    binary.as_mut_slice().copy_from_slice(&scalar);
    Ok(binary.release(env).encode(env))
}

#[rustler::nif]
fn point_to_scalar<'a>(env: Env<'a>, point: Binary) -> NifResult<Term<'a>> {
    match curve::point_to_scalar(point.as_slice()) {
        Ok(scalar) => {
            let mut binary = OwnedBinary::new(32).unwrap();
            binary.as_mut_slice().copy_from_slice(&scalar);
            Ok(binary.release(env).encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

#[rustler::nif]
fn scalar_mul<'a>(env: Env<'a>, scalar: Binary, point: Binary) -> NifResult<Term<'a>> {
    match curve::scalar_multiplication(scalar.as_slice(), point.as_slice()) {
        Ok(result) => {
            let mut binary = OwnedBinary::new(32).unwrap();
            binary.as_mut_slice().copy_from_slice(&result);
            Ok(binary.release(env).encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

#[rustler::nif]
fn point_add<'a>(env: Env<'a>, point1: Binary, point2: Binary) -> NifResult<Term<'a>> {
    match curve::point_addition(point1.as_slice(), point2.as_slice()) {
        Ok(result) => {
            let mut binary = OwnedBinary::new(32).unwrap();
            binary.as_mut_slice().copy_from_slice(&result);
            Ok(binary.release(env).encode(env))
        }
        Err(_) => Err(Error::BadArg)
    }
}

// Setup functions

#[rustler::nif]
fn load_trusted_setup<'a>(env: Env<'a>, setup_data: Binary) -> NifResult<Term<'a>> {
    match commitment::load_setup(setup_data.as_slice()) {
        Ok(_) => Ok(true.encode(env)),
        Err(_) => Ok(false.encode(env))
    }
}

#[rustler::nif]
fn get_generator<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    let generator = curve::get_generator_point();
    let mut binary = OwnedBinary::new(32).unwrap();
    binary.as_mut_slice().copy_from_slice(&generator);
    Ok(binary.release(env).encode(env))
}

#[rustler::nif]
fn get_identity<'a>(env: Env<'a>) -> NifResult<Term<'a>> {
    let identity = curve::get_identity_point();
    let mut binary = OwnedBinary::new(32).unwrap();
    binary.as_mut_slice().copy_from_slice(&identity);
    Ok(binary.release(env).encode(env))
}

// High-performance batch witness generation NIF with parallel processing
#[rustler::nif]
fn batch_generate_witnesses<'a>(env: Env<'a>, 
                                keys: Vec<Binary>,
                                tree_data: rustler::types::map::MapIterator) -> NifResult<Term<'a>> {
    
    // Extract tree data with vectorized memory operations
    let mut root_commitment = [0u8; 32];
    let mut node_cache = Vec::with_capacity(keys.len() * 3); // Increased capacity for better performance
    
    for (key, value) in tree_data {
        match key.decode::<String>() {
            Ok(ref key_str) if key_str == "root_commitment" => {
                if let Ok(binary) = value.decode::<Binary>() {
                    if binary.len() == 32 {
                        // SIMD-friendly memory copy with alignment
                        unsafe {
                            let src = binary.as_slice().as_ptr();
                            let dst = root_commitment.as_mut_ptr();
                            // Use vectorized copy for 32-byte blocks
                            std::ptr::copy_nonoverlapping(src, dst, 32);
                        }
                    }
                }
            }
            Ok(ref key_str) if key_str == "node_cache" => {
                if let Ok(cache_list) = value.decode::<Vec<(Binary, Binary)>>() {
                    // Parallel processing of cache entries for large datasets
                    if cache_list.len() > 128 {
                        // Use parallel iterator for large caches
                        #[cfg(feature = "parallel")]
                        {
                            use rayon::prelude::*;
                            let parallel_entries: Vec<_> = cache_list
                                .par_iter()
                                .filter_map(|(commitment_bin, node_data_bin)| {
                                    if commitment_bin.len() == 32 {
                                        let mut commitment = [0u8; 32];
                                        unsafe {
                                            std::ptr::copy_nonoverlapping(
                                                commitment_bin.as_slice().as_ptr(),
                                                commitment.as_mut_ptr(),
                                                32
                                            );
                                        }
                                        Some((commitment, node_data_bin.as_slice().to_vec()))
                                    } else {
                                        None
                                    }
                                })
                                .collect();
                            node_cache = parallel_entries;
                        }
                        #[cfg(not(feature = "parallel"))]
                        {
                            // Fallback to sequential processing
                            node_cache.reserve(cache_list.len());
                            for (commitment_bin, node_data_bin) in cache_list {
                                if commitment_bin.len() == 32 {
                                    let mut commitment = [0u8; 32];
                                    unsafe {
                                        std::ptr::copy_nonoverlapping(
                                            commitment_bin.as_slice().as_ptr(),
                                            commitment.as_mut_ptr(),
                                            32
                                        );
                                    }
                                    node_cache.push((commitment, node_data_bin.as_slice().to_vec()));
                                }
                            }
                        }
                    } else {
                        // Sequential processing for smaller datasets
                        node_cache.reserve(cache_list.len());
                        for (commitment_bin, node_data_bin) in cache_list {
                            if commitment_bin.len() == 32 {
                                let mut commitment = [0u8; 32];
                                unsafe {
                                    std::ptr::copy_nonoverlapping(
                                        commitment_bin.as_slice().as_ptr(),
                                        commitment.as_mut_ptr(),
                                        32
                                    );
                                }
                                node_cache.push((commitment, node_data_bin.as_slice().to_vec()));
                            }
                        }
                    }
                }
            }
            _ => {} // Ignore other fields
        }
    }
    
    // Create optimized tree data structure with larger proof pool for parallelism
    let tree_batch_data = batch::TreeBatchData {
        root_commitment,
        node_cache,
        proof_pool: batch::ProofMemoryPool::new(256), // Increased pool size for parallel processing
    };
    
    // Optimize key processing with pre-allocated vectors
    let keys_vec: Vec<Vec<u8>> = if keys.len() > 64 {
        // Use parallel processing for large key sets
        #[cfg(feature = "parallel")]
        {
            use rayon::prelude::*;
            keys.par_iter()
                .map(|k| k.as_slice().to_vec())
                .collect()
        }
        #[cfg(not(feature = "parallel"))]
        {
            keys.iter()
                .map(|k| k.as_slice().to_vec())
                .collect()
        }
    } else {
        // Sequential processing for smaller datasets
        keys.iter()
            .map(|k| k.as_slice().to_vec())
            .collect()
    };
    
    // High-performance witness generation with error handling
    match batch::batch_generate_witnesses(&keys_vec, &tree_batch_data) {
        Ok(witnesses) => {
            // Optimize result encoding with vectorized operations
            if witnesses.len() > 32 {
                // Use parallel encoding for large result sets
                #[cfg(feature = "parallel")]
                {
                    use rayon::prelude::*;
                    let results: Result<Vec<Term>, _> = witnesses
                        .par_iter()
                        .map(|w| -> Result<Term<'a>, _> {
                            let mut binary = OwnedBinary::new(w.len())?;
                            binary.as_mut_slice().copy_from_slice(w);
                            Ok(binary.release(env).encode(env))
                        })
                        .collect();
                    
                    match results {
                        Ok(result_terms) => Ok(result_terms.encode(env)),
                        Err(_) => Err(Error::BadArg)
                    }
                }
                #[cfg(not(feature = "parallel"))]
                {
                    // Fallback to sequential encoding
                    let mut result = Vec::with_capacity(witnesses.len());
                    for w in witnesses.iter() {
                        let mut binary = OwnedBinary::new(w.len()).unwrap();
                        binary.as_mut_slice().copy_from_slice(w);
                        result.push(binary.release(env).encode(env));
                    }
                    Ok(result.encode(env))
                }
            } else {
                // Sequential encoding for smaller result sets
                let mut result = Vec::with_capacity(witnesses.len());
                for w in witnesses.iter() {
                    let mut binary = OwnedBinary::new(w.len()).unwrap();
                    binary.as_mut_slice().copy_from_slice(w);
                    result.push(binary.release(env).encode(env));
                }
                Ok(result.encode(env))
            }
        }
        Err(_) => Err(Error::BadArg)
    }
}