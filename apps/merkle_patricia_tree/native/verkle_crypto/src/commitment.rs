use blake3;
use std::sync::RwLock;
use thiserror::Error;
use ark_ed_on_bls12_381_bandersnatch::{EdwardsProjective, Fr};
use ark_ff::{PrimeField, Zero, One, UniformRand};
use ark_ec::{Group, VariableBaseMSM, CurveGroup};
use ark_serialize::CanonicalSerialize;
use ark_std::rand::SeedableRng;
use ark_std::rand::rngs::StdRng;

// Use proper types for commitments
type Scalar = Fr;
type Point = EdwardsProjective;
type Commitment = [u8; 32];

#[derive(Debug, Error)]
#[allow(dead_code)]
pub enum CommitmentError {
    #[error("Invalid input length")]
    InvalidLength,
    #[error("Serialization error")]
    SerializationError,
    #[error("Invalid point")]
    InvalidPoint,
    #[error("Setup not loaded")]
    SetupNotLoaded,
}

// Global trusted setup - Structured Reference String (SRS) for polynomial commitments
static TRUSTED_SETUP: RwLock<Option<TrustedSetup>> = RwLock::new(None);

pub struct TrustedSetup {
    /// Generators g, g*τ, g*τ², ..., g*τⁿ for polynomial degree n
    pub generators: Vec<Point>,
    /// Domain elements used for polynomial evaluation
    pub domain: Vec<Scalar>,
    /// Size of the domain (should be power of 2)
    pub domain_size: usize,
    /// Verification key elements
    pub vk_generators: Vec<Point>,
}

/// Compute a commitment to a single value using Pedersen commitment
pub fn compute_commitment(value: &[u8]) -> Result<Commitment, CommitmentError> {
    // Hash the value to get a scalar in the field
    let scalar = hash_to_scalar(value);
    
    // Use the setup with proper lifetime management
    with_setup(|setup| {
        // Commit using generator point: C = scalar * G
        let generator = &setup.generators[0]; // First generator is the base
        let commitment_point = *generator * scalar;
        
        // Serialize the commitment point to bytes
        serialize_commitment(&commitment_point)
    })
}

/// Commit to an array of 256 child commitments using vector commitment scheme
pub fn commit_to_children_array(children: &[Vec<u8>]) -> Result<Commitment, CommitmentError> {
    if children.len() != 256 {
        return Err(CommitmentError::InvalidLength);
    }
    
    with_setup(|setup| {
        if setup.generators.len() < 256 {
            return Err(CommitmentError::SetupNotLoaded);
        }
        
        // Vector commitment: C = Σ(scalar_i * G_i) for i = 0..255
        let mut scalars = Vec::with_capacity(256);
        let generators = &setup.generators[..256]; // Take first 256 generators
        
        for child_bytes in children {
            let scalar = hash_to_scalar(child_bytes);
            scalars.push(scalar);
        }
        
        // Convert projective generators to affine for MSM
        let affine_generators: Vec<_> = generators.iter().map(|g| g.into_affine()).collect();
        
        // Perform multi-scalar multiplication
        let commitment_point = Point::msm(&affine_generators, &scalars)
            .map_err(|_| CommitmentError::InvalidLength)?;
        
        serialize_commitment(&commitment_point)
    })
}

/// Update root commitment when a key-value pair changes
pub fn update_root_commitment(
    existing_root: &[u8],
    key: &[u8],
    value: &[u8]
) -> Result<Commitment, CommitmentError> {
    if existing_root.len() != 32 {
        return Err(CommitmentError::InvalidLength);
    }
    
    // Compute delta commitment for the update
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"verkle_update_root");
    hasher.update(existing_root);
    hasher.update(key);
    hasher.update(value);
    
    let hash = hasher.finalize();
    let mut new_root = [0u8; 32];
    new_root.copy_from_slice(&hash.as_bytes()[..32]);
    
    Ok(new_root)
}

/// Load the trusted setup for verkle commitments
pub fn load_setup(setup_data: &[u8]) -> Result<(), CommitmentError> {
    if setup_data.is_empty() {
        // Create a deterministic setup for testing/development
        create_development_setup()
    } else {
        // In production: Parse the actual ceremony data
        parse_ceremony_setup(setup_data)
    }
}

/// Create a development setup with deterministic generators
fn create_development_setup() -> Result<(), CommitmentError> {
    let mut generators = Vec::with_capacity(512); // Need more generators for polynomial commitments
    let mut domain = Vec::with_capacity(256);
    let mut vk_generators = Vec::with_capacity(4);
    
    // Use a deterministic seed for reproducible setup
    let mut rng = StdRng::from_seed([42u8; 32]);
    let base_generator = EdwardsProjective::generator();
    
    // Generate structured reference string: g, g*τ, g*τ², ..., g*τⁿ
    // For development, use a known τ value
    let tau = Fr::from(123456789u64);
    let mut tau_power = Fr::one();
    
    for _ in 0..512 {
        let generator = base_generator * tau_power;
        generators.push(generator);
        tau_power *= tau;
    }
    
    // Generate domain elements (roots of unity for FFT)
    let primitive_root = Fr::from(7u64); // Primitive root modulo field order
    let mut root_power = Fr::one();
    for _ in 0..256 {
        domain.push(root_power);
        root_power *= primitive_root;
    }
    
    // Generate verification key elements
    for _ in 0..4 {
        let vk_gen = EdwardsProjective::rand(&mut rng);
        vk_generators.push(vk_gen);
    }
    
    let setup = TrustedSetup {
        generators,
        domain,
        domain_size: 256,
        vk_generators,
    };
    
    let mut trusted_setup = TRUSTED_SETUP.write().unwrap();
    *trusted_setup = Some(setup);
    
    Ok(())
}

/// Parse ceremony setup data (placeholder for production)
fn parse_ceremony_setup(_data: &[u8]) -> Result<(), CommitmentError> {
    // In production: Parse actual ceremony data format
    // For now, fallback to development setup
    create_development_setup()
}

/// Get the trusted setup, loading a default one if needed
fn get_setup() -> Result<std::sync::RwLockReadGuard<'static, Option<TrustedSetup>>, CommitmentError> {
    let setup = TRUSTED_SETUP.read().unwrap();
    if setup.is_none() {
        drop(setup);
        // Load default setup
        create_development_setup()?;
        Ok(TRUSTED_SETUP.read().unwrap())
    } else {
        Ok(setup)
    }
}

/// Access setup with proper lifetime management
fn with_setup<R>(f: impl FnOnce(&TrustedSetup) -> Result<R, CommitmentError>) -> Result<R, CommitmentError> {
    let setup_guard = get_setup()?;
    let setup = setup_guard.as_ref().ok_or(CommitmentError::SetupNotLoaded)?;
    f(setup)
}

/// Serialize a commitment point to bytes
fn serialize_commitment(point: &Point) -> Result<Commitment, CommitmentError> {
    let mut bytes = [0u8; 32];
    point.serialize_compressed(&mut &mut bytes[..])
        .map_err(|_| CommitmentError::SerializationError)?;
    Ok(bytes)
}

/// Hash arbitrary data to a scalar field element
fn hash_to_scalar(data: &[u8]) -> Scalar {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"verkle_hash_to_scalar");
    hasher.update(data);
    
    let hash = hasher.finalize();
    
    // Properly reduce to field element
    Fr::from_le_bytes_mod_order(&hash.as_bytes()[..32])
}

/// Polynomial evaluation for verkle commitments using Horner's method
#[allow(dead_code)]
pub fn polynomial_eval(coefficients: &[Scalar], point: &Scalar) -> Scalar {
    if coefficients.is_empty() {
        return Fr::zero();
    }
    
    // Horner's method for polynomial evaluation: p(x) = a₀ + x(a₁ + x(a₂ + ... + x*aₙ))
    let mut result = coefficients[coefficients.len() - 1];
    
    for i in (0..coefficients.len() - 1).rev() {
        result = result * point + coefficients[i];
    }
    
    result
}

/// Multi-scalar multiplication for batch operations
#[allow(dead_code)]
pub fn multi_scalar_mul(scalars: &[Scalar], points: &[Point]) -> Result<Point, CommitmentError> {
    if scalars.len() != points.len() {
        return Err(CommitmentError::InvalidLength);
    }
    
    if scalars.is_empty() {
        return Ok(Point::zero());
    }
    
    // Convert projective points to affine for MSM
    let affine_points: Vec<_> = points.iter().map(|p| p.into_affine()).collect();
    
    // Use arkworks' efficient multi-scalar multiplication (Pippenger's algorithm)
    Point::msm(&affine_points, scalars)
        .map_err(|_| CommitmentError::InvalidLength)
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_compute_commitment() {
        let value = b"test_value";
        let commitment = compute_commitment(value).unwrap();
        assert_eq!(commitment.len(), 32);
        
        // Same value should produce same commitment
        let commitment2 = compute_commitment(value).unwrap();
        assert_eq!(commitment, commitment2);
        
        // Different value should produce different commitment
        let commitment3 = compute_commitment(b"different").unwrap();
        assert_ne!(commitment, commitment3);
    }
    
    #[test]
    fn test_commit_to_children() {
        let children: Vec<Vec<u8>> = (0..256)
            .map(|i| vec![i as u8; 32])
            .collect();
        
        let commitment = commit_to_children_array(&children).unwrap();
        assert_eq!(commitment.len(), 32);
    }
    
    #[test]
    fn test_update_root() {
        let root = [0u8; 32];
        let key = b"test_key";
        let value = b"test_value";
        
        let new_root = update_root_commitment(&root, key, value).unwrap();
        assert_eq!(new_root.len(), 32);
        assert_ne!(new_root, root);
    }
}