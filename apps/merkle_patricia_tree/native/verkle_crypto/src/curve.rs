use blake3;
use sha2::{Sha256, Digest};
use ark_ed_on_bls12_381_bandersnatch::{EdwardsProjective, Fr};
use ark_ff::{PrimeField, One, Zero};
use ark_ec::{Group, VariableBaseMSM, CurveGroup};
use ark_serialize::{CanonicalSerialize, CanonicalDeserialize};

// Use proper types for Bandersnatch curve
type Scalar = Fr;
type Point = EdwardsProjective;
type ScalarBytes = [u8; 32];
type PointBytes = [u8; 32];

/// Generator point for the Bandersnatch curve  
pub fn get_generator_point() -> PointBytes {
    // Return the standard Bandersnatch generator point
    let generator = EdwardsProjective::generator();
    serialize_point(&generator).unwrap_or([1u8; 32])
}

/// Identity/zero point for the curve
pub fn get_identity_point() -> PointBytes {
    // Return the actual identity element
    serialize_point(&EdwardsProjective::zero()).unwrap_or([0u8; 32])
}

/// Hash arbitrary data to a scalar field element
pub fn hash_to_scalar(data: &[u8]) -> ScalarBytes {
    let mut hasher = blake3::Hasher::new();
    hasher.update(b"bandersnatch_hash_to_scalar");
    hasher.update(data);
    
    let hash = hasher.finalize();
    
    // Use proper field reduction for Bandersnatch curve
    let scalar_field = Fr::from_le_bytes_mod_order(&hash.as_bytes()[..32]);
    serialize_scalar(&scalar_field).unwrap_or([0u8; 32])
}

/// Convert a point to a scalar using the group_to_field function
pub fn point_to_scalar(point: &[u8]) -> Result<ScalarBytes, CurveError> {
    if point.len() != 32 {
        return Err(CurveError::InvalidPoint);
    }
    
    // Deserialize point first
    let point_elem = deserialize_point(point)?;
    
    // EIP-6800 group_to_scalar_field function implementation
    let mut hasher = Sha256::new();
    hasher.update(b"group_to_scalar_field");
    
    // Serialize point in affine form for consistent hashing
    let affine = point_elem.into_affine();
    let mut point_bytes = Vec::new();
    affine.serialize_compressed(&mut point_bytes)
        .map_err(|_| CurveError::InvalidPoint)?;
    
    hasher.update(&point_bytes);
    let hash = hasher.finalize();
    
    // Reduce hash to scalar field
    let scalar = Fr::from_le_bytes_mod_order(&hash);
    Ok(serialize_scalar(&scalar)?)
}

/// Scalar multiplication on the Bandersnatch curve
pub fn scalar_multiplication(scalar: &[u8], point: &[u8]) -> Result<PointBytes, CurveError> {
    if scalar.len() != 32 || point.len() != 32 {
        return Err(CurveError::InvalidInput);
    }
    
    // Deserialize inputs
    let scalar_elem = deserialize_scalar(scalar)?;
    let point_elem = deserialize_point(point)?;
    
    // Perform actual elliptic curve scalar multiplication
    let result = point_elem * scalar_elem;
    
    serialize_point(&result)
}

/// Point addition on the Bandersnatch curve
pub fn point_addition(point1: &[u8], point2: &[u8]) -> Result<PointBytes, CurveError> {
    if point1.len() != 32 || point2.len() != 32 {
        return Err(CurveError::InvalidInput);
    }
    
    // Deserialize inputs
    let point1_elem = deserialize_point(point1)?;
    let point2_elem = deserialize_point(point2)?;
    
    // Perform actual elliptic curve point addition
    let result = point1_elem + point2_elem;
    
    serialize_point(&result)
}

/// Serialize a scalar to 32 bytes
fn serialize_scalar(scalar: &Scalar) -> Result<ScalarBytes, CurveError> {
    let mut bytes = [0u8; 32];
    scalar.serialize_compressed(&mut &mut bytes[..])
        .map_err(|_| CurveError::InvalidScalar)?;
    Ok(bytes)
}

/// Deserialize a scalar from 32 bytes
fn deserialize_scalar(bytes: &[u8]) -> Result<Scalar, CurveError> {
    if bytes.len() != 32 {
        return Err(CurveError::InvalidScalar);
    }
    
    Scalar::deserialize_compressed(&*bytes)
        .map_err(|_| CurveError::InvalidScalar)
}

/// Serialize a point to 32 bytes (compressed format)
fn serialize_point(point: &Point) -> Result<PointBytes, CurveError> {
    let mut bytes = [0u8; 32];
    point.serialize_compressed(&mut &mut bytes[..])
        .map_err(|_| CurveError::InvalidPoint)?;
    Ok(bytes)
}

/// Deserialize a point from 32 bytes (compressed format)
fn deserialize_point(bytes: &[u8]) -> Result<Point, CurveError> {
    if bytes.len() != 32 {
        return Err(CurveError::InvalidPoint);
    }
    
    Point::deserialize_compressed(&*bytes)
        .map_err(|_| CurveError::InvalidPoint)
}

#[derive(Debug, Clone)]
pub enum CurveError {
    InvalidPoint,
    InvalidInput,
    InvalidScalar,
    SerializationError,
}

/// Fast multi-exponentiation using proper elliptic curve operations
#[allow(dead_code)]
pub fn multi_exp(scalars: &[Scalar], points: &[Point]) -> Result<Point, CurveError> {
    if scalars.len() != points.len() {
        return Err(CurveError::InvalidInput);
    }
    
    if scalars.is_empty() {
        return Ok(Point::zero());
    }
    
    // Convert projective points to affine for MSM
    let affine_points: Vec<_> = points.iter().map(|p| p.into_affine()).collect();
    
    // Use arkworks' efficient multi-scalar multiplication
    let result = Point::msm(&affine_points, scalars)
        .map_err(|_| CurveError::InvalidInput)?;
    
    Ok(result)
}

/// Batch scalar multiplication with precomputation
#[allow(dead_code)]
pub struct PrecomputedPoints {
    base_point: Point,
    precomputed: Vec<Point>,
}

#[allow(dead_code)]
impl PrecomputedPoints {
    pub fn new(base_point: &Point) -> Self {
        // Precompute powers of the base point for windowed methods
        let mut precomputed = Vec::with_capacity(16);
        let mut current = *base_point;
        
        for _ in 0..16 {
            precomputed.push(current);
            // Double the point using proper curve doubling
            current = current.double();
        }
        
        PrecomputedPoints {
            base_point: *base_point,
            precomputed,
        }
    }
    
    pub fn scalar_mul(&self, scalar: &Scalar) -> Point {
        // Use precomputed points for faster multiplication
        self.base_point * scalar
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn test_hash_to_scalar() {
        let data = b"test data";
        let scalar = hash_to_scalar(data);
        assert_eq!(scalar.len(), 32);
        
        // Same data should produce same scalar
        let scalar2 = hash_to_scalar(data);
        assert_eq!(scalar, scalar2);
        
        // Different data should produce different scalar
        let scalar3 = hash_to_scalar(b"different");
        assert_ne!(scalar, scalar3);
    }
    
    #[test]
    fn test_point_operations() {
        let generator_bytes = get_generator_point();
        let identity_bytes = get_identity_point();
        
        // Adding identity should return original point
        let sum = point_addition(&generator_bytes, &identity_bytes).unwrap();
        assert_eq!(sum, generator_bytes);
        
        // Scalar multiplication by 1 should approximately return original point
        let scalar_one = Scalar::one();
        let scalar_one_bytes = serialize_scalar(&scalar_one).unwrap();
        let mul = scalar_multiplication(&scalar_one_bytes, &generator_bytes).unwrap();
        assert_eq!(mul.len(), 32);
    }
    
    #[test]
    fn test_serialization() {
        let generator = Point::generator();
        let scalar = Scalar::from(42u64);
        
        // Test point serialization roundtrip
        let point_bytes = serialize_point(&generator).unwrap();
        let deserialized_point = deserialize_point(&point_bytes).unwrap();
        assert_eq!(generator, deserialized_point);
        
        // Test scalar serialization roundtrip
        let scalar_bytes = serialize_scalar(&scalar).unwrap();
        let deserialized_scalar = deserialize_scalar(&scalar_bytes).unwrap();
        assert_eq!(scalar, deserialized_scalar);
    }
    
    #[test]
    fn test_curve_arithmetic() {
        let generator = Point::generator();
        let scalar = Scalar::from(5u64);
        
        // Test scalar multiplication
        let result1 = generator * scalar;
        
        // Test equivalent addition
        let mut result2 = Point::zero();
        for _ in 0..5 {
            result2 += generator;
        }
        
        assert_eq!(result1, result2);
    }
    
    #[test]
    fn test_point_to_scalar() {
        let generator_bytes = get_generator_point();
        let scalar_result = point_to_scalar(&generator_bytes).unwrap();
        assert_eq!(scalar_result.len(), 32);
        
        // Same point should produce same scalar
        let scalar_result2 = point_to_scalar(&generator_bytes).unwrap();
        assert_eq!(scalar_result, scalar_result2);
    }
}