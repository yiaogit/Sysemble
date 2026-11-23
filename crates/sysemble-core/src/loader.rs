//! Loading `buildspec.yaml` files from disk.

use std::path::Path;

use crate::error::SpecError;
use crate::model::BuildSpec;

/// Read and deserialize a build spec.
///
/// `.yaml` and `.yml` are the documented formats and `.json` works too, since
/// JSON is a subset of YAML and both go through `serde_yaml`. Parsing is
/// content-based rather than extension-based, so a temporary file without a
/// suffix loads just as well.
///
/// This function only answers "is this a well-formed build spec?". Version and
/// semantic checks belong to [`crate::validate_spec`], so an unknown
/// `apiVersion` still loads and is reported as a diagnostic.
pub fn load_spec(path: &Path) -> Result<BuildSpec, SpecError> {
    let text = std::fs::read_to_string(path).map_err(|source| SpecError::Read {
        path: path.to_path_buf(),
        source,
    })?;

    serde_yaml::from_str(&text).map_err(|source| SpecError::Parse {
        path: path.to_path_buf(),
        source,
    })
}
